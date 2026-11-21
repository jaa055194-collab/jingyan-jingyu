import 'dart:io';

import 'package:test/test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('Live2D viewer distribution', () {
    test('no PurismCore runtime binary is committed', () {
      expect(
        File('web/runtime/purismcore/purismcore.js').existsSync(),
        isFalse,
        reason: 'the pinned runtime is fetched locally, never committed',
      );
    });

    test('viewer page loads only local scripts in dependency order', () {
      final html = _read('web/live2d_viewer.html');
      expect(html.toLowerCase(), isNot(contains('https://')));
      expect(html.toLowerCase(), isNot(contains('http://')));
      final runtime = html.indexOf('runtime/purismcore/purismcore.js');
      final renderer = html.indexOf('live2d_renderer_webgl.js');
      final viewer = html.indexOf('live2d_viewer.js');
      expect(runtime, isNonNegative);
      expect(renderer, greaterThan(runtime));
      expect(viewer, greaterThan(renderer));
    });

    test('viewer and renderer carry no remote model URLs', () {
      for (final path in [
        'web/live2d_viewer.js',
        'web/live2d_renderer_webgl.js',
      ]) {
        final source = _read(path).toLowerCase();
        expect(source, isNot(contains('http://')), reason: path);
        expect(source, isNot(contains('https://')), reason: path);
        expect(source, isNot(contains('.moc3')), reason: path);
      }
    });

    test('fetch script pins the runtime version and checksum only', () {
      final script = _read('tool/fetch_purismcore.ps1');
      expect(script, contains('v1.1.0'));
      expect(
        script,
        contains(
          'ee229d1b28c33a9f57f02c777f8633141042cd771e5e47bf4795ba345b3a0b39',
        ),
      );
      expect(script, contains('Get-FileHash'));
      expect(script.toLowerCase(), isNot(contains('moc3')));
      expect(script.toLowerCase(), isNot(contains('model3')));
    });
  });
}
