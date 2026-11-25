/// 离线发件箱（FR-10、FR-14、NFR-03）。
///
/// 宿主离线时消息先入发件箱；联网后按入队顺序逐条提交，同一 clientMsgId
/// 重发由服务端幂等去重，所以"不确定是否送达"时可以放心重试。
library;

import 'dart:async';
import 'dart:collection';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// 发件箱条目。
class OutboxItem {
  OutboxItem({
    required this.conversationId,
    required this.clientMsgId,
    required this.kind,
    required Map<String, Object?> body,
    required this.queuedAt,
    this.attempts = 0,
  }) : body = _snapshotBody(body);

  final String conversationId;
  final String clientMsgId;
  final MessageKind kind;

  /// Detached, recursively read-only JSON containers captured at construction.
  /// Non-container custom leaves retain identity; serialization remains the
  /// encoder's responsibility. Editing a queued payload requires a new item.
  final Map<String, Object?> body;
  final DateTime queuedAt;
  int attempts;
}

Map<String, Object?> _snapshotBody(Map<String, Object?> source) {
  final copies = HashMap<Object, Object>.identity();
  Object? copy(Object? value) {
    if (value is Map) {
      final known = copies[value];
      if (known != null) return known;
      if (value is Map<String, Object?>) {
        final backing = <String, Object?>{};
        final view = UnmodifiableMapView<String, Object?>(backing);
        copies[value] = view;
        for (final entry in value.entries) {
          backing[entry.key] = copy(entry.value);
        }
        return view;
      }
      // Retain existing deferred JSON validation for non-string map keys.
      final backing = <Object?, Object?>{};
      final view = UnmodifiableMapView<Object?, Object?>(backing);
      copies[value] = view;
      for (final entry in value.entries) {
        backing[entry.key] = copy(entry.value);
      }
      return view;
    }
    if (value is List) {
      final known = copies[value];
      if (known != null) return known;
      final backing = <Object?>[];
      final view = UnmodifiableListView<Object?>(backing);
      copies[value] = view;
      for (final element in value) {
        backing.add(copy(element));
      }
      return view;
    }
    return value;
  }

  return copy(source) as Map<String, Object?>;
}

/// 提交函数：返回 Ok 表示服务端已接受（含幂等命中）。
typedef Submit = Future<Result<void>> Function(OutboxItem item);

/// 一次冲刷的结果。
class FlushReport {
  const FlushReport({
    required this.sent,
    required this.remaining,
    this.stoppedBy,
  });

  final int sent;
  final int remaining;

  /// 中断冲刷的失败；全部发完时为 null。
  final Failure? stoppedBy;
}

/// 发件箱。持久化由外壳负责（把 [items] 写入本地库）；这里只管顺序与重试语义。
class Outbox {
  Outbox({Clock clock = const SystemClock(), String Function()? newClientMsgId})
    : _clock = clock,
      _newId = newClientMsgId ?? _counter();

  final Clock _clock;
  final String Function() _newId;
  final List<OutboxItem> _items = [];
  Future<FlushReport>? _flight;

  static String Function() _counter() {
    var n = 0;
    return () => 'c${DateTime.now().microsecondsSinceEpoch}-${++n}';
  }

  List<OutboxItem> get items => List.unmodifiable(_items);

  /// 入队，返回分配的 clientMsgId。
  String enqueue(
    String conversationId,
    MessageKind kind,
    Map<String, Object?> body,
  ) {
    final item = _newItem(conversationId, kind, body);
    _items.add(item);
    return item.clientMsgId;
  }

  OutboxItem _newItem(
    String conversationId,
    MessageKind kind,
    Map<String, Object?> body,
  ) => OutboxItem(
    conversationId: conversationId,
    clientMsgId: _newId(),
    kind: kind,
    body: body,
    queuedAt: _clock.now(),
  );

  /// 恢复持久化条目（重启后调用）。保持原 clientMsgId。
  void restore(Iterable<OutboxItem> items) => _items.addAll(items);

  /// 按顺序提交。
  ///
  /// * 网络类失败（unavailable / rateLimited / internal）：停止冲刷，保留队首，等下次；
  /// * 永久失败（invalidArgument / forbidden / notFound 等）：丢弃该条并继续，
  ///   由外壳把它标成"发送失败"展示给用户——不能卡死整条队列。
  /// Overlapping calls join the current flight, using its initial callbacks.
  /// Joining never schedules an implicit retry after a transient stop. Callbacks
  /// may reenter without awaiting, but must not await the flight they block.
  Future<FlushReport> flush(
    Submit submit, {
    void Function(OutboxItem, Failure)? onDropped,
  }) {
    final active = _flight;
    if (active != null) return active;
    final completion = Completer<FlushReport>();
    final flight = completion.future;
    // Publish before invoking submit, including its synchronous reentry.
    _flight = flight;
    _drain(submit, onDropped: onDropped).then<void>(
      (report) {
        _flight = null;
        completion.complete(report);
      },
      onError: (Object error, StackTrace stack) {
        _flight = null;
        completion.completeError(error, stack);
      },
    );
    return flight;
  }

  Future<FlushReport> _drain(
    Submit submit, {
    void Function(OutboxItem, Failure)? onDropped,
  }) async {
    var sent = 0;
    while (_items.isNotEmpty) {
      final item = _items.first;
      item.attempts++;
      final result = await submit(item);
      if (result.isOk) {
        _items.removeAt(0);
        sent++;
        continue;
      }
      final failure = result.failureOrNull!;
      if (_isTransient(failure.code)) {
        return FlushReport(
          sent: sent,
          remaining: _items.length,
          stoppedBy: failure,
        );
      }
      _items.removeAt(0);
      onDropped?.call(item, failure);
    }
    return FlushReport(sent: sent, remaining: 0);
  }

  static bool _isTransient(FailureCode code) =>
      code == FailureCode.unavailable ||
      code == FailureCode.rateLimited ||
      code == FailureCode.internal;
}

/// Package-internal support for the shell's serialized snapshot writes.
extension OutboxCheckpoint on Outbox {
  /// Stages an item until the checkpoint commits. The caller serializes all
  /// queue mutations, and the callback must fail only before committing.
  Future<String> enqueueWithCheckpoint(
    String conversationId,
    MessageKind kind,
    Map<String, Object?> body,
    Future<void> Function(OutboxItem) checkpoint,
  ) async {
    final item = _newItem(conversationId, kind, body);
    await checkpoint(item);
    _items.add(item);
    return item.clientMsgId;
  }
}
