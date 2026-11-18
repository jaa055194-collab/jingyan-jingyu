import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Uint8List inflatePreviewEntry(Uint8List input, int limit) {
  final output = _BoundedSink(limit);
  final decoder = ZLibDecoder(raw: true).startChunkedConversion(output);
  decoder.add(input);
  decoder.close();
  if (output.length != limit) {
    throw const FormatException('ZIP entry length mismatch');
  }
  return output.bytes;
}

class _BoundedSink extends ByteConversionSink {
  _BoundedSink(int limit) : bytes = Uint8List(limit);

  final Uint8List bytes;
  int length = 0;

  @override
  void add(List<int> chunk) {
    final end = length + chunk.length;
    if (end > bytes.length) {
      throw const FormatException('ZIP entry exceeds its declared length');
    }
    bytes.setRange(length, end, chunk);
    length = end;
  }

  @override
  void close() {}
}
