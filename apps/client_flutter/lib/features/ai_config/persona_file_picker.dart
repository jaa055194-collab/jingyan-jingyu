import 'dart:io';

import '../../platform/native_platform.dart';
import 'persona_card_import.dart';

enum PersonaFileProblem { unreadable, tooLarge, invalid }

/// Typed file-import failure. Carries no path, file content or raw exception.
class PersonaFileImportException implements Exception {
  const PersonaFileImportException(this.problem);
  final PersonaFileProblem problem;

  @override
  String toString() => 'PersonaFileImportException(${problem.name})';
}

/// A parsed card plus the display-only name of the user-selected file.
class PersonaFileImport {
  const PersonaFileImport({required this.name, required this.card});
  final String name;
  final PersonaCard card;

  /// Display basename only; never an absolute path. Control characters fall back.
  static String safeSourceName(String raw) {
    final segments = raw.split(RegExp(r'[\\/]'));
    final name = segments.isEmpty ? '' : segments.last.trim();
    if (name.isEmpty ||
        name.length > 120 ||
        name.codeUnits.any(
          (unit) => unit < 0x20 || (unit >= 0x7f && unit <= 0x9f),
        )) {
      return '所选文件';
    }
    return name;
  }
}

/// Explicit local read of one user-picked persona card file.
abstract interface class PersonaFilePicker {
  Future<PersonaFileImport?> pick();
}

/// Reuses the existing platform file picker; no new native protocol.
class NativePersonaFilePicker implements PersonaFilePicker {
  NativePersonaFilePicker({NativePlatform? platform})
    : _platform = platform ?? NativePlatform();

  final NativePlatform _platform;

  @override
  Future<PersonaFileImport?> pick() async {
    final PickedAttachment? picked;
    try {
      picked = await _platform.pickAttachment('file');
    } catch (_) {
      throw const PersonaFileImportException(PersonaFileProblem.unreadable);
    }
    if (picked == null) return null;
    final file = File(picked.path);
    try {
      final type = await FileSystemEntity.type(picked.path, followLinks: false);
      if (type != FileSystemEntityType.file) {
        throw const PersonaFileImportException(PersonaFileProblem.unreadable);
      }
      final bytes = await _readBounded(file);
      final PersonaCard card;
      try {
        card = PersonaCard.parseBytes(bytes);
      } on FormatException {
        throw const PersonaFileImportException(PersonaFileProblem.invalid);
      }
      return PersonaFileImport(
        name: PersonaFileImport.safeSourceName(picked.name),
        card: card,
      );
    } on PersonaFileImportException {
      rethrow;
    } catch (_) {
      throw const PersonaFileImportException(PersonaFileProblem.unreadable);
    } finally {
      // Remove only the picker-owned cache copy; user files are never touched.
      if (picked.temporary) {
        try {
          await file.delete();
        } catch (_) {
          // Best effort: the parsed card no longer retains the path or bytes.
        }
      }
    }
  }

  /// Reads at most the card limit plus one byte so an oversized file is
  /// rejected from actual bytes, independent of length/stat.
  Future<List<int>> _readBounded(File file) async {
    final builder = <int>[];
    final input = await file.open(mode: FileMode.read);
    try {
      while (true) {
        final chunk = await input.read(8 * 1024);
        if (chunk.isEmpty) break;
        builder.addAll(chunk);
        if (builder.length > personaCardMaxBytes) {
          throw const PersonaFileImportException(PersonaFileProblem.tooLarge);
        }
      }
    } finally {
      await input.close();
    }
    return builder;
  }
}
