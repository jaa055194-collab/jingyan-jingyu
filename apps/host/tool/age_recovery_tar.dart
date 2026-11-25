// Strict reader for the two regular files produced by Windows bsdtar's
// --format ustar. Not a general tar extraction API. No name from an archive
// is used as a filesystem path; only these fixed member identifiers escape.
import 'dart:convert';
import 'dart:typed_data';

import 'age_recovery_windows.dart';

const databaseMember = 'host.sqlite';
const protectedKeyMember = 'host.sqlite.kek';
const databaseLimit = 64 * 1024 * 1024;
const keyLimit = 64 * 1024;
const tarLimit = databaseLimit + keyLimit + 64 * 1024;
const ageLimit = tarLimit + 128 * 1024;
const _block = 512;

final class SnapshotPair {
  const SnapshotPair(this.database, this.protectedKey);
  final Uint8List database;
  final Uint8List protectedKey;
}

SnapshotPair decodeSnapshotTar(Uint8List bytes) {
  if (bytes.length > tarLimit || bytes.length % _block != 0) _reject();
  Uint8List? database;
  Uint8List? key;
  var offset = 0;
  while (offset + _block <= bytes.length) {
    final header = Uint8List.sublistView(bytes, offset, offset + _block);
    if (header.every((byte) => byte == 0)) {
      if (database == null ||
          key == null ||
          bytes.length - offset < 2 * _block ||
          !_zero(bytes, offset, bytes.length)) {
        _reject();
      }
      return SnapshotPair(database, key);
    }
    if (!_exactName(header, 257, 6, 'ustar') ||
        header[263] != 0x30 ||
        header[264] != 0x30 ||
        (header[156] != 0x30 && header[156] != 0) ||
        !_zero(header, 157, 257) ||
        !_zero(header, 345, 512)) {
      _reject();
    }
    var checksum = 0;
    for (var i = 0; i < _block; i++) {
      checksum += i >= 148 && i < 156 ? 0x20 : header[i];
    }
    if (_octal(header, 148, 156) != checksum) _reject();
    final isDatabase = _exactName(header, 0, 100, databaseMember);
    final isKey = _exactName(header, 0, 100, protectedKeyMember);
    if ((!isDatabase && !isKey) ||
        (isDatabase && database != null) ||
        (isKey && key != null)) {
      _reject();
    }
    final size = _octal(header, 124, 136);
    final start = offset + _block;
    if (size < 1 ||
        size > (isDatabase ? databaseLimit : keyLimit) ||
        size > bytes.length - start) {
      _reject();
    }
    final end = start + size;
    final next = start + ((size + _block - 1) ~/ _block) * _block;
    if (next > bytes.length || !_zero(bytes, end, next)) _reject();
    final data = Uint8List.sublistView(bytes, start, end);
    if (isDatabase) {
      database = data;
    } else {
      key = data;
    }
    offset = next;
  }
  _reject();
}

bool _exactName(Uint8List header, int start, int width, String expected) {
  for (var i = 0; i < expected.length; i++) {
    if (header[start + i] != expected.codeUnitAt(i)) return false;
  }
  return _zero(header, start + expected.length, start + width);
}

bool _zero(Uint8List bytes, int start, int end) {
  for (var i = start; i < end; i++) {
    if (bytes[i] != 0) return false;
  }
  return true;
}

int _octal(Uint8List bytes, int start, int end) {
  final field = latin1.decode(Uint8List.sublistView(bytes, start, end));
  final match = RegExp(r'^ *([0-7]+)[\x00 ]+$').firstMatch(field);
  if (match == null) _reject();
  return int.parse(match.group(1)!, radix: 8);
}

Never _reject() => throw const RecoveryFailure('archive_members');
