import 'dart:async';
import 'dart:typed_data';

import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'attachment_upload_api.dart';
import 'host_connection.dart';

/// Injected content source for one attachment.
///
/// This abstraction deliberately has no file-system, picker, or platform
/// coupling: callers inject either in-memory bytes or a stream factory together
/// with the metadata the host upload contract requires. The coordinator never
/// chooses a file, reads a path, or authenticates.
abstract interface class AttachmentContentSource {
  /// Host attachment kind: one of file/image/video/voice/text/live2d.
  String get kind;

  /// Declared byte length. Must match the bytes returned by [openRead].
  int get size;

  /// Declared MIME type forwarded to the host initiate stage.
  String get mime;

  /// Lower-case hex SHA-256 (64 chars) expected by the complete stage.
  String get sha256;

  /// Opens a fresh byte stream. Called once per upload attempt so an explicit
  /// caller-driven retry can re-open the same content.
  Stream<List<int>> openRead();
}

/// In-memory content source. The bytes are copied at construction so later
/// caller mutation cannot change what is uploaded.
class InjectedBytesContent implements AttachmentContentSource {
  InjectedBytesContent({
    required this.kind,
    required this.mime,
    required this.sha256,
    required List<int> bytes,
  })  : _bytes = Uint8List.fromList(bytes),
        size = bytes.length;

  @override
  final String kind;
  @override
  final int size;
  @override
  final String mime;
  @override
  final String sha256;
  final Uint8List _bytes;

  @override
  Stream<List<int>> openRead() async* {
    yield _bytes;
  }
}

/// Stream-backed content source with explicitly declared metadata. Useful when
/// bytes are produced incrementally; [size] is still required up front by the
/// host initiate contract and is cross-checked after streaming.
class InjectedStreamContent implements AttachmentContentSource {
  InjectedStreamContent(
    this._openRead, {
    required this.kind,
    required this.size,
    required this.mime,
    required this.sha256,
  });

  @override
  final String kind;
  @override
  final int size;
  @override
  final String mime;
  @override
  final String sha256;
  final Stream<List<int>> Function() _openRead;

  @override
  Stream<List<int>> openRead() => _openRead();
}

/// Thrown when an upload is cancelled between stages or chunks.
class AttachmentSendCancelled implements Exception {
  const AttachmentSendCancelled();

  @override
  String toString() => '附件发送已取消';
}

/// Cooperative cancellation token. [cancel] is safe to call while an HTTP stage
/// is in flight; the flow observes it at the next stage boundary and between
/// chunks. An upload already past the complete request cannot be undone.
class AttachmentSendCancellation {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() {
    _cancelled = true;
  }

  void _throwIfCancelled() {
    if (_cancelled) throw const AttachmentSendCancelled();
  }
}

/// Result of a successful attachment upload, ready to become an Outbox message.
///
/// [body] is the message body the host accepts for a file/image/text message; it
/// references the stored attachment by id. Use [outboxPayload] with the
/// client-generated idempotency key, or [submission] for the existing transport
/// envelope.
class AttachmentSendResult {
  const AttachmentSendResult({
    required this.attachmentId,
    required this.conversationId,
    required this.kind,
    required this.size,
    required this.sha256,
    required this.body,
  });

  final String attachmentId;
  final String conversationId;
  final MessageKind kind;
  final int size;
  final String sha256;
  final Map<String, Object?> body;

  /// The exact payload the Outbox submit path sends: clientMsgId + kind + body.
  Map<String, Object?> outboxPayload(String clientMsgId) => {
        'clientMsgId': clientMsgId,
        'kind': kind.wire,
        'body': body,
      };

  /// Convenience envelope for the existing host submission transport.
  OutboxSubmission submission(String clientMsgId) =>
      OutboxSubmission(conversationId, outboxPayload(clientMsgId));
}

/// Drives the existing explicit attachment upload stages (initiate → chunks →
/// complete) from an injected content source and, on success, builds the Outbox
/// message payload for sending.
///
/// Policy:
/// * Each stage is awaited exactly once; this coordinator performs no retries.
///   Uncertain initiate/complete failures are surfaced, never silently replayed.
/// * A single bounded 401 authentication replay is preserved by
///   [HostConnection]; this flow never loops on repeated 401 responses.
/// * Cancellation is observed before initiate, between chunks, and before
///   complete.
/// * Declared size is cross-checked against the streamed byte count before the
///   complete stage, and against the host's completed size afterwards.
class AttachmentSendFlow {
  AttachmentSendFlow(this.api);

  final AttachmentUploadApi api;

  /// Maps a host attachment kind to the message kind used for sending. Video
  /// and Live2D have no dedicated message kind in the current contract, so
  /// callers must pass an explicit [messageKind] override for them.
  static MessageKind? messageKindFor(String attachmentKind) =>
      switch (attachmentKind) {
        'text' => MessageKind.text,
        'image' => MessageKind.image,
        'file' => MessageKind.file,
        'voice' => MessageKind.audio,
        _ => null,
      };

  Future<AttachmentSendResult> upload({
    required AttachmentContentSource source,
    required String conversationId,
    AttachmentSendCancellation? cancellation,
    MessageKind? messageKind,
  }) async {
    final cancel = cancellation ?? AttachmentSendCancellation();
    final kind = messageKind ?? messageKindFor(source.kind);
    if (kind == null) {
      throw FormatException('附件种类 ${source.kind} 无法映射到消息种类');
    }

    cancel._throwIfCancelled();
    final session = await api.initiate(
      mime: source.mime,
      size: source.size,
      kind: source.kind,
      conversationId: conversationId,
    );
    cancel._throwIfCancelled();

    var index = 0;
    var uploaded = 0;
    await for (final chunk in _chunked(source.openRead(), session.chunkSize)) {
      cancel._throwIfCancelled();
      if (chunk.isEmpty) continue;
      await api.putChunk(
        uploadId: session.uploadId,
        index: index,
        bytes: chunk,
      );
      uploaded += chunk.length;
      index += 1;
      cancel._throwIfCancelled();
    }

    cancel._throwIfCancelled();
    if (uploaded != source.size) {
      throw const FormatException('附件字节数与声明大小不一致');
    }

    final completed = await api.complete(
      uploadId: session.uploadId,
      expectedSha256: source.sha256,
    );
    if (completed.size != source.size) {
      throw const FormatException('附件完成大小与声明大小不一致');
    }
    cancel._throwIfCancelled();

    return AttachmentSendResult(
      attachmentId: completed.attachmentId,
      conversationId: conversationId,
      kind: kind,
      size: completed.size,
      sha256: completed.sha256,
      body: {
        'attachmentId': completed.attachmentId,
      },
    );
  }

  /// Splits [input] into chunks of exactly [chunkSize] bytes, with a final short
  /// chunk when the length is not a multiple. Holds at most one chunk worth of
  /// buffering at a time.
  static Stream<List<int>> _chunked(
    Stream<List<int>> input,
    int chunkSize,
  ) async* {
    final buffer = BytesBuilder(copy: true);
    await for (final data in input) {
      if (data.isEmpty) continue;
      buffer.add(data);
      while (buffer.length >= chunkSize) {
        final bytes = buffer.takeBytes();
        var offset = 0;
        while (bytes.length - offset >= chunkSize) {
          yield Uint8List.sublistView(bytes, offset, offset + chunkSize);
          offset += chunkSize;
        }
        if (offset < bytes.length) {
          buffer.add(Uint8List.sublistView(bytes, offset));
        }
      }
    }
    if (buffer.length > 0) yield buffer.takeBytes();
  }
}
