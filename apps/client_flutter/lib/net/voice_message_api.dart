import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Verified, bounded bytes for one visible canonical audio message.
class MessageVoice {
  MessageVoice._(this.bytes, this.sha256);

  static const maxBytes = 8 * 1024 * 1024;
  static const _mime = 'audio/mp4';
  // The host's four-field JSON envelope is small and base64 needs no escaping.
  static const maxResponseBytes = ((maxBytes + 2) ~/ 3) * 4 + 1024;

  final Uint8List bytes;
  final String sha256;
  String get mime => _mime;

  factory MessageVoice.fromJson(Map<String, Object?> json) {
    const invalid = FormatException('语音响应无效');
    const keys = {'mime', 'size', 'sha256', 'dataBase64'};
    final size = json['size'];
    final digest = json['sha256'];
    final encoded = json['dataBase64'];
    if (json.length != keys.length ||
        !json.keys.every(keys.contains) ||
        json['mime'] != _mime ||
        size is! int ||
        size < 1 ||
        size > maxBytes ||
        digest is! String ||
        digest.length != 64 ||
        encoded is! String ||
        encoded.length != ((size + 2) ~/ 3) * 4) {
      throw invalid;
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw invalid;
    }
    if (bytes.length != size ||
        base64Encode(bytes) != encoded ||
        !_hasFileTypeBox(bytes) ||
        _digest(bytes) != digest) {
      throw invalid;
    }
    return MessageVoice._(bytes.asUnmodifiableView(), digest);
  }

  static String _digest(Uint8List bytes) =>
      crypto.sha256.convert(bytes).toString();

  // #159 verifies the complete sound-only container. This is a coarse header
  // check, not a second container parser or an assertion about codec support.
  static bool _hasFileTypeBox(Uint8List bytes) {
    if (bytes.length < 16) return false;
    final view = ByteData.sublistView(bytes);
    if (view.getUint32(4) != 0x66747970) return false; // ftyp
    var header = 8;
    var size = view.getUint32(0);
    if (size == 1) {
      if (view.getUint32(8) != 0) return false;
      size = view.getUint32(12);
      header = 16;
    }
    return size >= header + 8 &&
        (size - header) % 4 == 0 &&
        size <= bytes.length - 8;
  }
}

class VoiceMessageApi {
  const VoiceMessageApi(this.connection);

  final HostConnection connection;

  Future<MessageVoice> read({
    required String conversationId,
    required String messageId,
    HostReadCancellation? cancellation,
  }) async {
    final path = Routes.messageVoiceAttachment
        .replaceFirst(
          '{conversationId}',
          ConversationId.parse(conversationId).value,
        )
        .replaceFirst('{messageId}', MessageId.parse(messageId).value);
    return MessageVoice.fromJson(
      await connection.getBoundedJson(
        path,
        maxResponseBytes: MessageVoice.maxResponseBytes,
        cancellation: cancellation,
      ),
    );
  }
}
