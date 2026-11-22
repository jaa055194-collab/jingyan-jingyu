import 'dart:convert';

import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import 'owner_reply_preferences_fixture.dart';

const memoryProfileA = 'profile-a';
const memoryProfileB = 'profile-b';
const memoryTarget = <String, Object?>{
  'providerId': 'fixture-provider',
  'model': 'fixture-memory-model',
  'origin': 'https://provider.example.invalid:8443',
  'token': 'memory-target-A',
};
const memoryCreated = '2026-01-01T09:00:00.000Z';

Map<String, Object?> memoryNote({
  String id = 'note-a',
  String text = '喜欢桂花',
  String createdAt = memoryCreated,
  String updatedAt = memoryCreated,
}) => {'id': id, 'text': text, 'createdAt': createdAt, 'updatedAt': updatedAt};

Map<String, Object?> memoryState({
  int revision = 0,
  bool enabled = false,
  int maxNotes = 20,
  int maxNoteBytes = 512,
  List<Map<String, Object?>>? notes,
  Map<String, Object?>? target,
}) => {
  'revision': revision,
  'enabled': enabled,
  'maxNotes': maxNotes,
  'maxNoteBytes': maxNoteBytes,
  'notes': notes ?? <Map<String, Object?>>[],
  'target': target,
};

/// Extends the existing loopback preferences fixture: the real Settings route,
/// AI profile resolution and editor remain in use; only host boundaries are
/// synthetic. Preferences behavior is inherited unchanged.
class MemoryNotesConnection extends PreferencesConnection {
  MemoryNotesConnection() : super();
  final memory = <String, Map<String, Object?>>{
    memoryProfileA: memoryState(),
    memoryProfileB: memoryState(),
  };
  final memoryCalls = <(String method, String path, String raw)>[];
  int memoryReadStatus = 200;
  int memoryWriteStatus = 200;
  Future<void> Function(String profile)? beforeMemoryRead;
  Future<void> Function(String profile, Map<String, Object?> body)?
  beforeMemoryWrite;

  String _profileOf(String path) => path.split('/')[4];
  bool _isMemory(String path) => path.contains('/owner-memory-notes');

  @override
  Future<Map<String, Object?>> getBoundedJson(
    String path, {
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) async {
    if (!_isMemory(path)) {
      return super.getBoundedJson(
        path,
        maxResponseBytes: maxResponseBytes,
        cancellation: cancellation,
      );
    }
    final profile = _profileOf(path);
    memoryCalls.add(('GET', path, ''));
    await beforeMemoryRead?.call(profile);
    if (memoryReadStatus != 200) {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, 'memory read unavailable'),
      );
    }
    return Map<String, Object?>.from(memory[profile]!);
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    if (!_isMemory(path)) {
      return super.request(
        method,
        path,
        body: body,
        query: query,
        retryAuthentication: retryAuthentication,
        allowEmptySuccess: allowEmptySuccess,
      );
    }
    final profile = _profileOf(path);
    final raw = body == null ? '' : jsonEncode(body);
    memoryCalls.add((method, path, raw));
    await beforeMemoryWrite?.call(profile, body ?? const {});
    if (memoryWriteStatus != 200) {
      throw HostRequestException(
        Failure(
          memoryWriteStatus == 409
              ? FailureCode.conflict
              : FailureCode.unavailable,
          'memory write failed',
        ),
      );
    }
    final state = memory[profile]!;
    final expected = body?['expectedRevision'];
    if (expected is! int || expected != state['revision']) {
      throw const HostRequestException(
        Failure(FailureCode.conflict, 'memory revision changed'),
      );
    }
    final notes = (state['notes']! as List)
        .cast<Map<String, Object?>>()
        .toList();
    if (method == 'POST') {
      if (notes.length >= (state['maxNotes']! as int)) {
        throw const HostRequestException(
          Failure(FailureCode.invalidArgument, 'memory note limit'),
        );
      }
      final id = 'note-${notes.length + 1}';
      notes.insert(0, memoryNote(id: id, text: body!['text']! as String));
      state['notes'] = notes;
      state['revision'] = expected + 1;
    } else if (method == 'PATCH') {
      final id = path.split('/').last;
      final index = notes.indexWhere((note) => note['id'] == id);
      if (index < 0) {
        throw const HostRequestException(
          Failure(FailureCode.notFound, 'note missing'),
        );
      }
      notes[index] = memoryNote(id: id, text: body!['text']! as String);
      state['notes'] = notes;
      state['revision'] = expected + 1;
    } else if (method == 'DELETE' && path.endsWith('/owner-memory-notes')) {
      state['notes'] = <Map<String, Object?>>[];
      state['revision'] = expected + 1;
    } else if (method == 'DELETE') {
      final id = path.split('/').last;
      notes.removeWhere((note) => note['id'] == id);
      state['notes'] = notes;
      state['revision'] = expected + 1;
    } else if (method == 'PUT' && path.endsWith('/settings')) {
      final enabled = body!['enabled']! as bool;
      final target = state['target'] as Map<String, Object?>?;
      final token = body['expectedTargetToken'] as String?;
      if (enabled && (target == null || token != target['token'])) {
        throw const HostRequestException(
          Failure(FailureCode.conflict, 'memory target changed'),
        );
      }
      if (!enabled && token != null) {
        throw const HostRequestException(
          Failure(FailureCode.invalidArgument, 'bad target token'),
        );
      }
      state['enabled'] = enabled;
      state['revision'] = expected + 1;
    } else {
      throw StateError('unexpected memory route $method $path');
    }
    return Map<String, Object?>.from(memory[profile]!);
  }
}

Future<void> openMemoryEditor(
  WidgetTester tester,
  PreferencesRuntime runtime, {
  Key? boundary,
}) async {
  await openPreferencesEditor(tester, runtime, boundary: boundary);
  final section = memoryKey('owner-memory-notes-section');
  await tester.scrollUntilVisible(
    section,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Finder memoryKey(String value) => find.byKey(Key(value));
