import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'outbox.dart';
import 'persistence.dart';
import 'sync_cursor.dart';

class DroppedMessage {
  const DroppedMessage(this.item, this.failure);
  final OutboxItem item;
  final Failure failure;
}

/// Durable operations are serialized, including transport, to prevent duplicate
/// concurrent flushes and lost snapshot updates. Call initialize before binding.
class ClientShellController {
  ClientShellController({
    required this.persistence,
    required Submit submit,
    required this.requestSync,
    Outbox? outbox,
    Clock clock = const SystemClock(),
  }) : outbox = outbox ?? Outbox(clock: clock),
       _submit = submit,
       _clock = clock;
  final ClientPersistence persistence;
  final Outbox outbox;
  final Submit _submit;
  final Future<void> Function(SyncRequestFrame) requestSync;
  final Clock _clock;
  final _serial = SerialOperations();
  final _cursors = <String, SyncCursor>{};
  final _messages = <String, List<MessageEventFrame>>{};
  final _drafts = <String, String>{};
  final _readSeq = <String, int>{};
  /// Device-local confirmed edit markers, conversationId -> message ids.
  final _edited = <String, Set<String>>{};
  final _dropped = <DroppedMessage>[];
  bool _initialized = false;
  int _requestId = 0;
  Future<FlushReport>? _flushFlight;

  List<DroppedMessage> get dropped => List.unmodifiable(_dropped);
  List<MessageEventFrame> messagesFor(String id) =>
      List.unmodifiable(_messages[id] ?? []);
  String draftFor(String id) => _drafts[id] ?? '';
  int readSeqFor(String id) => _readSeq[id] ?? 0;

  Future<void> initialize() => _serial.run(() async {
    if (_initialized) return;
    final snapshot = await persistence.read();
    final data = snapshot?['shell'] as Map?;
    if (data != null) {
      final restored = [
        for (final raw in data['outbox'] as List) _decodeItem(raw as Map),
      ];
      final messages = <String, List<MessageEventFrame>>{};
      for (final raw in data['messages'] as List) {
        final frame =
            decodeFrameMap(Map<String, Object?>.from(raw as Map)).value
                as MessageEventFrame;
        (messages[frame.conversationId] ??= []).add(frame);
      }
      final failures = [
        for (final raw in data['dropped'] as List)
          DroppedMessage(
            _decodeItem((raw as Map)['item'] as Map),
            Failure(
              FailureCode.values.byName(raw['code'] as String),
              raw['message'] as String,
            ),
          ),
      ];
      outbox.restore(restored);
      _messages.addAll(messages);
      _drafts.addAll(Map<String, String>.from(data['drafts'] as Map));
      final readSeq = data['readSeq'];
      if (readSeq is Map) {
        for (final entry in readSeq.entries) {
          final value = entry.value;
          if (entry.key is String && value is int && value > 0) {
            _readSeq[entry.key as String] = value;
          }
        }
      }
      for (final entry in (data['cursors'] as Map).entries) {
        _cursors[entry.key as String] = SyncCursor(lastSeq: entry.value as int);
      }
      // `readSeq` is newer than the cursor map, so an install from before this
      // feature restores cursors without it. Only that one-time upgrade seeds
      // already-synced history as read; once the key exists, an absent
      // conversation stays at 0 so never-opened history keeps counting.
      if (!data.containsKey('readSeq')) {
        for (final entry in _cursors.entries) {
          _readSeq[entry.key] = entry.value.lastSeq;
        }
      }
      final edited = data['edited'];
      if (edited is Map) {
        for (final entry in edited.entries) {
          final value = entry.value;
          if (entry.key is String && value is List) {
            final ids = {
              for (final id in value)
                if (id is String && id.isNotEmpty) id,
            };
            if (ids.isNotEmpty) _edited[entry.key as String] = ids;
          }
        }
      }
      _dropped.addAll(failures);
    }
    _initialized = true;
  });

  void _requireInitialized() {
    if (!_initialized) throw StateError('Call initialize first');
  }

  Future<String> enqueue(
    String conversationId,
    MessageKind kind,
    Map<String, Object?> body,
  ) => _serial.run(() async {
    _requireInitialized();
    final id = outbox.enqueue(conversationId, kind, body);
    await _persist();
    return id;
  });

  /// Queues an item only after its durable checkpoint. Unlike [enqueue], a
  /// failed checkpoint does not leave an in-memory item that later retries can
  /// submit without a backing attachment or other external resource.
  Future<String> enqueueDurable(
    String conversationId,
    MessageKind kind,
    Map<String, Object?> body, {
    void Function()? checkActive,
  }) => _serial.run(() async {
    _requireInitialized();
    checkActive?.call();
    return outbox.enqueueWithCheckpoint(
      conversationId,
      kind,
      body,
      (item) => _persist(pendingItem: item, checkActive: checkActive),
    );
  });

  /// Queues an explicitly sent text and consumes its matching local draft in
  /// the same checkpoint. A failed replacement leaves both unchanged.
  Future<String> enqueueTextDraft(String conversationId, String text) =>
      _serial.run(() async {
        _requireInitialized();
        final drafts = {..._drafts};
        final consumed = drafts[conversationId] == text;
        if (consumed) drafts.remove(conversationId);
        final id = await outbox.enqueueWithCheckpoint(
          conversationId,
          MessageKind.text,
          {'text': text},
          (item) => _persist(pendingItem: item, drafts: drafts),
        );
        if (consumed) _drafts.remove(conversationId);
        return id;
      });

  /// Overlapping callers share this flight; a transient stop is not implicitly
  /// retried by a queued joiner. A later explicit call may start a fresh flight.
  Future<FlushReport> flush() {
    final active = _flushFlight;
    if (active != null) return active;
    final completion = Completer<FlushReport>();
    final flight = completion.future;
    _flushFlight = flight;
    _flush().then<void>(
      (report) {
        _flushFlight = null;
        completion.complete(report);
      },
      onError: (Object error, StackTrace stack) {
        _flushFlight = null;
        completion.completeError(error, stack);
      },
    );
    return flight;
  }

  Future<FlushReport> _flush() => _serial.run(() async {
    _requireInitialized();
    // Also retries a prior failed enqueue checkpoint before any network IO.
    await _persist();
    try {
      final report = await outbox.flush(
        (item) async {
          // Persist each prior acknowledgement/drop before submitting the next.
          await _persist();
          return _submit(item);
        },
        onDropped: (item, failure) =>
            _dropped.add(DroppedMessage(item, failure)),
      );
      await _persist();
      return report;
    } catch (_) {
      // Keep an uncertain delivery queued with its original id.
      await _persist();
      rethrow;
    }
  });

  /// Publishes a draft only after its snapshot replacement succeeds.
  /// [checkActive] can cancel before the shared writer reads or replaces the
  /// snapshot. A replacement that has already started cannot be cancelled.
  Future<void> saveDraft(
    String id,
    String text, {
    void Function()? checkActive,
  }) => _serial.run(() async {
    _requireInitialized();
    checkActive?.call();
    await _persist(drafts: {..._drafts, id: text}, checkActive: checkActive);
    _drafts[id] = text;
  });
  int lastSeqFor(String conversationId) =>
      _cursors[conversationId]?.lastSeq ?? 0;

  /// Advances the persisted read position, clamped to the cached canonical head.
  /// Only an explicit open calls this; a failed checkpoint keeps the old value.
  Future<void> markRead(String id, int seq, {void Function()? checkActive}) =>
      _serial.run(() async {
        _requireInitialized();
        checkActive?.call();
        final head = lastSeqFor(id);
        final next = seq < 0 ? 0 : (seq > head ? head : seq);
        if (next <= readSeqFor(id)) return;
        await _persist(
          readSeq: {..._readSeq, id: next},
          checkActive: checkActive,
        );
        _readSeq[id] = next;
      });

  /// Checkpoints a host-confirmed visibility bound before applying its page.
  /// Only this conversation's canonical cache can be pruned; other gaps still
  /// need to be filled by [acceptMessage]. [checkActive] may throw to cancel
  /// when the operation reaches the queue head, before a write starts.
  Future<void> applySyncHistoryFloor(
    String conversationId,
    int firstVisibleSeq, {
    void Function()? checkActive,
  }) => _serial.run(() async {
    _requireInitialized();
    checkActive?.call();
    if (firstVisibleSeq < 1) {
      throw ArgumentError.value(
        firstVisibleSeq,
        'firstVisibleSeq',
        'must be positive',
      );
    }
    final lastSeq = lastSeqFor(conversationId);
    final hiddenThrough = firstVisibleSeq - 1;
    final nextSeq = lastSeq < hiddenThrough ? hiddenThrough : lastSeq;
    final cached = _messages[conversationId];
    final retained =
        cached != null && cached.any((m) => m.seq < firstVisibleSeq)
        ? cached.where((m) => m.seq >= firstVisibleSeq).toList()
        : null;
    if (nextSeq == lastSeq && retained == null) return;

    final cursor = SyncCursor(lastSeq: nextSeq);
    await _persist(
      cursors: {..._cursors, conversationId: cursor},
      messages: retained == null
          ? null
          : {..._messages, conversationId: retained},
      checkActive: checkActive,
    );
    _cursors[conversationId] = cursor;
    if (retained != null) _messages[conversationId] = retained;
  });

  Future<MergeOutcome> acceptMessage(
    MessageEventFrame message, {
    void Function()? checkActive,
  }) async {
    SyncRequestFrame? request;
    final outcome = await _serial.run(() async {
      _requireInitialized();
      checkActive?.call();
      final conversationId = message.conversationId;
      final cursor = SyncCursor(lastSeq: lastSeqFor(conversationId));
      final outcome = cursor.accept(message.seq);
      if (outcome == MergeOutcome.gap) {
        request = SyncRequestFrame(
          id: 'sync-${++_requestId}',
          at: _clock.now(),
          conversationId: message.conversationId,
          afterSeq: cursor.lastSeq,
        );
      } else if (outcome == MergeOutcome.applied) {
        await _persist(
          cursors: {..._cursors, conversationId: cursor},
          pendingMessage: message,
          checkActive: checkActive,
        );
        _cursors[conversationId] = cursor;
        (_messages[conversationId] ??= []).add(message);
      }
      return outcome;
    });
    // Network adapters may apply a sync page by re-entering acceptMessage.
    // Release the state queue before awaiting that adapter.
    final pending = request;
    if (pending != null) {
      checkActive?.call();
      await requestSync(pending);
    }
    return outcome;
  }

  /// Applies an explicit edit or recall receipt for messages the cache already
  /// holds under the same seq.
  ///
  /// Edits and recalls keep the message seq, so an incremental sync does not
  /// replay them; this method replaces the cached row only after the host
  /// confirmed the mutation and echoed the same canonical identity. A recalled
  /// row is terminal and is always stored as the bare tombstone: an older page
  /// or a leftover plaintext body can never resurrect the removed text. Rows
  /// for an unknown seq are ignored, never invented into the cache, and the
  /// cursor/ACK state is never touched. [markEdited] records the locally
  /// confirmed edit marker in the same atomic checkpoint. Returns the number of
  /// replaced rows; a failed checkpoint leaves body, marker and cursor
  /// unchanged.
  Future<int> applyMessageRevisions(
    String conversationId,
    Iterable<MessageEventFrame> rows, {
    String? markEdited,
    void Function()? checkActive,
  }) => _serial.run(() async {
    _requireInitialized();
    checkActive?.call();
    final next = <MessageEventFrame>[...?_messages[conversationId]];
    final bySeq = {for (var i = 0; i < next.length; i++) next[i].seq: i};
    var changed = 0;
    for (final row in rows) {
      if (row.conversationId != conversationId || row.seq < 1) {
        throw const FormatException(
          'revision row does not match the cached conversation',
        );
      }
      final index = bySeq[row.seq];
      if (index == null) continue;
      final current = next[index];
      if (current.messageId != row.messageId ||
          current.senderId != row.senderId ||
          current.kind != row.kind ||
          current.sentAt != row.sentAt) {
        throw const FormatException('conflicting sequence identity');
      }
      if (current.body['recalled'] == true) continue;
      final replacement = row.body['recalled'] == true
          ? _tombstone(row)
          : row;
      if (_sameBody(replacement.body, current.body)) {
        continue;
      }
      next[index] = replacement;
      changed++;
    }
    final marks = {...?_edited[conversationId]};
    var marksChanged = false;
    if (markEdited != null &&
        next.any((row) => row.messageId == markEdited && row.body['recalled'] != true)) {
      marksChanged = marks.add(markEdited);
    }
    for (final row in next) {
      if (row.body['recalled'] == true && marks.remove(row.messageId)) {
        marksChanged = true;
      }
    }
    final edited = !marksChanged ? null : {..._edited};
    if (edited != null) {
      if (marks.isEmpty) {
        edited.remove(conversationId);
      } else {
        edited[conversationId] = marks;
      }
    }
    if (changed == 0 && edited == null) return 0;
    checkActive?.call();
    await _persist(
      messages: {..._messages, conversationId: next},
      edited: edited,
      checkActive: checkActive,
    );
    _messages[conversationId] = next;
    if (edited != null) {
      _edited
        ..clear()
        ..addAll(edited);
    }
    return changed;
  });

  /// A locally confirmed edit marker for one message. It is device-local: the
  /// wire body is left exactly as the host stored it.
  bool isMessageEdited(String conversationId, String messageId) =>
      _edited[conversationId]?.contains(messageId) ?? false;

  static MessageEventFrame _tombstone(MessageEventFrame row) =>
      MessageEventFrame(
        id: row.id,
        at: row.at,
        conversationId: row.conversationId,
        seq: row.seq,
        messageId: row.messageId,
        senderId: row.senderId,
        kind: row.kind,
        body: const {'recalled': true},
        sentAt: row.sentAt,
      );

  static bool _sameBody(
    Map<String, Object?> left,
    Map<String, Object?> right,
  ) => jsonEncode(left) == jsonEncode(right);

  Future<void> _persist({
    OutboxItem? pendingItem,
    Map<String, String>? drafts,
    Map<String, SyncCursor>? cursors,
    Map<String, int>? readSeq,
    Map<String, List<MessageEventFrame>>? messages,
    Map<String, Set<String>>? edited,
    MessageEventFrame? pendingMessage,
    void Function()? checkActive,
  }) => writeClientSection(persistence, 'shell', {
    'outbox': [
      for (final item in outbox.items) _encodeItem(item),
      if (pendingItem != null) _encodeItem(pendingItem),
    ],
    'dropped': [
      for (final d in _dropped)
        {
          'item': _encodeItem(d.item),
          'code': d.failure.code.name,
          'message': d.failure.message,
        },
    ],
    'drafts': drafts ?? {..._drafts},
    'cursors': {
      for (final e in (cursors ?? _cursors).entries) e.key: e.value.lastSeq,
    },
    'readSeq': {...(readSeq ?? _readSeq)},
    if ((edited ?? _edited).isNotEmpty)
      'edited': {
        for (final entry in (edited ?? _edited).entries)
          entry.key: (entry.value.toList()..sort()),
      },
    'messages': [
      for (final list in (messages ?? _messages).values)
        for (final m in list) m.toEnvelope(),
      if (pendingMessage != null) pendingMessage.toEnvelope(),
    ],
  }, checkActive: checkActive);
  static Map<String, Object?> _encodeItem(OutboxItem item) => {
    'conversationId': item.conversationId,
    'clientMsgId': item.clientMsgId,
    'kind': item.kind.name,
    'body': item.body,
    'queuedAt': item.queuedAt.toUtc().toIso8601String(),
    'attempts': item.attempts,
  };
  static OutboxItem _decodeItem(Map<Object?, Object?> raw) => OutboxItem(
    conversationId: raw['conversationId'] as String,
    clientMsgId: raw['clientMsgId'] as String,
    kind: MessageKind.values.byName(raw['kind'] as String),
    body: Map<String, Object?>.from(raw['body'] as Map),
    queuedAt: DateTime.parse(raw['queuedAt'] as String),
    attempts: raw['attempts'] as int,
  );
}
