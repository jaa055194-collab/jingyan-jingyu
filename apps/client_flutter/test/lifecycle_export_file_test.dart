import 'dart:convert';

import 'package:client_flutter/net/lifecycle_api.dart';
import 'package:flutter_test/flutter_test.dart';

LifecycleExportBundle _bundle() => LifecycleExportBundle.fromJson({
  'ownerAccountId': 'owner',
  'files': {'manifest.json': '{}', 'conversations/a.jsonl': '{"seq":1}'},
  'manifest': {
    'formatVersion': 1,
    'counts': {
      'conversations': 1,
      'messages': 1,
      'memories': 0,
      'attachments': 0,
      'persona': 0,
    },
  },
  'sha256sums': 'abc  manifest.json',
});

void main() {
  test('export file is the exact round-trippable version-1 envelope', () {
    final bundle = _bundle();
    final content = bundle.exportFileContents();
    final decoded = jsonDecode(content) as Map<String, Object?>;

    expect(decoded, {
      'ownerAccountId': 'owner',
      'files': bundle.files,
      'manifest': bundle.manifest,
      'sha256sums': bundle.sha256sums,
    });
    expect(LifecycleExportBundle.fromJson(decoded).files, bundle.files);
    expect(content, isNot(contains('secret-persona-text')));
  });

  test('export file refuses content above the local bridge bound', () {
    final oversized = LifecycleExportBundle.fromJson({
      'ownerAccountId': 'owner',
      'files': {'manifest.json': 'x' * LifecycleExportBundle.maxFileBytes},
      'manifest': {
        'formatVersion': 1,
        'counts': {
          'conversations': 0,
          'messages': 0,
          'memories': 0,
          'attachments': 0,
          'persona': 0,
        },
      },
      'sha256sums': 'abc  manifest.json',
    });

    expect(oversized.exportFileContents, throwsFormatException);
  });
}
