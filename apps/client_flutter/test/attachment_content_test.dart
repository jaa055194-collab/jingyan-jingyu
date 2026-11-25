import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/attachments/attachment_content.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('jingyu-attachment-content-');
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'loads image type, exact size, safe name and digest without exposing bytes',
    () async {
      final bytes = utf8.encode('synthetic image content');
      final file = File('${root.path}/家庭 照片.PNG');
      await file.writeAsBytes(bytes);

      final content = await FileAttachmentContent.load(
        file.path,
        kind: 'image',
        displayName: '家庭 照片.PNG',
      );

      expect(content.kind, 'image');
      expect(content.mime, 'image/png');
      expect(content.size, bytes.length);
      expect(content.sha256, sha256.convert(bytes).toString());
      expect(content.displayName, '家庭 照片.PNG');
      expect(await content.openRead().expand((part) => part).toList(), bytes);
    },
  );

  test('file kind uses the opaque MIME for non-empty content', () async {
    final file = File('${root.path}/report.pdf');
    await file.writeAsBytes([1, 2, 3]);
    final content = await FileAttachmentContent.load(
      file.path,
      kind: 'file',
      displayName: 'report.pdf',
    );
    expect(content.mime, 'application/octet-stream');
    expect(content.size, 3);
  });

  test('file kind rejects an empty file before HTTP', () async {
    final file = File('${root.path}/README.internal');
    await file.writeAsBytes(const []);
    await expectLater(
      FileAttachmentContent.load(
        file.path,
        kind: 'file',
        displayName: 'README.internal',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('provider display names do not expose path components', () async {
    final file = File('${root.path}/photo.png');
    await file.writeAsBytes([137, 80, 78, 71]);
    final content = await FileAttachmentContent.load(
      file.path,
      kind: 'image',
      displayName: r'private/folder\camera.png',
    );
    expect(content.displayName, 'camera.png');
  });

  test(
    'image MIME can come from the picker when the name has no extension',
    () async {
      final file = File('${root.path}/no-extension');
      await file.writeAsBytes([137, 80, 78, 71]);
      final content = await FileAttachmentContent.load(
        file.path,
        kind: 'image',
        displayName: 'no-extension',
        declaredMime: 'image/png',
      );
      expect(content.mime, 'image/png');
    },
  );

  test('unsupported image extensions are rejected before any read', () async {
    final file = File('${root.path}/not-really-image.txt');
    await file.writeAsBytes([1, 2, 3]);
    await expectLater(
      FileAttachmentContent.load(file.path, kind: 'image'),
      throwsA(isA<FormatException>()),
    );
  });

  test('missing and unsupported files fail with safe messages', () async {
    await expectLater(
      FileAttachmentContent.load('${root.path}/missing.png', kind: 'image'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      FileAttachmentContent.load('${root.path}/x', kind: 'video'),
      throwsA(isA<FormatException>()),
    );
  });
}
