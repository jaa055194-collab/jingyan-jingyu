import 'dart:io';

import 'package:test/test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('live2d_web assets', () {
    test('viewer html and js exist and reference vendored runtime', () {
      expect(File('web/live2d_viewer.html').existsSync(), isTrue);
      expect(File('web/live2d_viewer.js').existsSync(), isTrue);
      final html = _read('web/live2d_viewer.html');
      expect(html, contains('runtime/purismcore/purismcore.js'));
      expect(html, contains('live2d_viewer.js'));
      expect(html.toLowerCase(), isNot(contains('https://')));
    });

    test('viewer protocol implements every bridge command and event', () {
      final js = _read('web/live2d_viewer.js');
      for (final cmd in ['load', 'setParam', 'setExpression', 'setMotion', 'dispose']) {
        expect(js, contains("case '$cmd'"), reason: cmd);
      }
      expect(js, contains("event: 'ready'"));
      expect(js, contains("event: 'error'"));
      expect(js, contains('model.update()'));
    });

    test('viewer carries no model bytes or remote model urls', () {
      final js = _read('web/live2d_viewer.js');
      expect(js.toLowerCase(), isNot(contains('.moc3')));
      expect(js, isNot(contains('http://')));
      expect(js, isNot(contains('https://')));
    });

    test('fetch script pins version and checksum and never fetches a model', () {
      final script = _read('tool/fetch_purismcore.ps1');
      expect(script, contains('v1.1.0'));
      expect(script,
          contains('ee229d1b28c33a9f57f02c777f8633141042cd771e5e47bf4795ba345b3a0b39'));
      expect(script, contains('Get-FileHash'));
      expect(script.toLowerCase(), isNot(contains('moc3')));
      expect(script.toLowerCase(), isNot(contains('model3')));
    });
  });
}
