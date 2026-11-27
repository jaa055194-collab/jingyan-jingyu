import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/features/world/live2d_import_panel.dart';
import 'package:client_flutter/features/world/live2d_local_import.dart';
import 'package:client_flutter/features/world/live2d_preview_stage.dart';
import 'package:client_flutter/platform/native_platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_client_kit/jingyu_client_kit.dart';

// Synthetic ZIP with a nested manifest, a stub MOC3, two 1px PNGs, and physics.
// Inline to avoid depending on archive encoding or shipping a real model.
const _previewZip =
    'UEsDBBQAAAAIAAAAIVx6P26tYgAAAHsAAAAZAAAAc2FtcGxlL3NvdXJjZS5tb2RlbDMuanNv'
    'bqtWCkstKs7Mz1OyUjDWUVByy8xJDUpNSy1KzUtOLQYKViv55icDaaXi/NKi5FS93PxkYyWg'
    'wpDUipLSIrCSaKUqvYK8dJBoIpgRC2QFZFQWZyYXI+ksgIgY62UVA62rrQUAUEsDBBQAAAAI'
    'AAAAIVzUIF7LCQAAACgAAAASAAAAc2FtcGxlL3NvdXJjZS5tb2Mz8/V3NmZlIAwAUEsDBBQA'
    'AAAIAAAAIVy73mDzPwAAAEYAAAAMAAAAc2FtcGxlL2EucG5n6wzwc+flkuJiYGDg9fRwCQLS'
    'jCDMwQYk5UWPdIIlXBxDKuYkJyT8+C/PwMzE+P9ZOfc6oASDp6ufyzqnhCYAUEsDBBQAAAAI'
    'AAAAIVw5YQprPwAAAEYAAAAMAAAAc2FtcGxlL3oucG5n6wzwc+flkuJiYGDg9fRwCQLSjCDM'
    'wQYk5UWPdIIlXBxDKuYk/zh/4IM8AysD4//OmbayQAkGT1c/l3VOCU0AUEsDBBQAAAAIAAAA'
    'IVxDv6ajBAAAAAIAAAAbAAAAc2FtcGxlL3NvdXJjZS5waHlzaWNzMy5qc29uq64FAFBLAQIU'
    'ABQAAAAIAAAAIVx6P26tYgAAAHsAAAAZAAAAAAAAAAAAAACAAQAAAABzYW1wbGUvc291cmNl'
    'Lm1vZGVsMy5qc29uUEsBAhQAFAAAAAgAAAAhXNQgXssJAAAAKAAAABIAAAAAAAAAAAAAAIAB'
    'mQAAAHNhbXBsZS9zb3VyY2UubW9jM1BLAQIUABQAAAAIAAAAIVy73mDzPwAAAEYAAAAMAAAA'
    'AAAAAAAAAACAAdIAAABzYW1wbGUvYS5wbmdQSwECFAAUAAAACAAAACFcOWEKaz8AAABGAAAA'
    'DAAAAAAAAAAAAAAAgAE7AQAAc2FtcGxlL3oucG5nUEsBAhQAFAAAAAgAAAAhXEO/pqMEAAAA'
    'AgAAABsAAAAAAAAAAAAAAIABpAEAAHNhbXBsZS9zb3VyY2UucGh5c2ljczMuanNvblBLBQYA'
    'AAAABQAFAEQBAADhAQAAAAA=';

void main() {
  late Directory parent;
  late Live2DPreviewBundle bundle;

  setUp(() async {
    parent = await Directory.systemTemp.createTemp('jingyu preview #%-');
    addTearDown(() => parent.delete(recursive: true));
    bundle = prepareLive2DPreview(base64Decode(_previewZip));
  });

  test('reads back only the files the stage wrote', () async {
    final stage = await stageLive2DPreview(parent, bundle);
    addTearDown(stage.dispose);
    await File.fromUri(stage.directory.uri.resolve('extra.png'))
        .writeAsBytes([1]);
    final files = await stage.readFiles();
    expect(files.keys, stage.names);
    expect(stage.names, stagedLive2DPreviewNames(bundle.files.keys));
    for (final name in stage.names) {
      expect(files[name], bundle.files[name], reason: name);
    }
  });

  test(
    'prepares a selected ZIP in the isolate and preserves the source',
    () async {
      final source = File.fromUri(parent.uri.resolve('selected.zip'));
      await source.writeAsBytes(base64Decode(_previewZip));
      final session = await openLocalLive2DZip(
        platform: _Picker(parent.path, {
          'path': source.path,
          'temporary': false,
        }),
      );
      expect(session, isNotNull);
      expect(await parent.list().where((item) => item is Directory).length, 1);
      await session!.close();
      expect(await parent.list().where((item) => item is Directory).length, 0);
      expect(await source.exists(), isTrue);
    },
  );

  test(
    'the session names its stage directly inside the preview directory',
    () async {
      // Android serves only directories inside <cacheDir>/live2d-preview,
      // the directory that getLive2DPreviewDirectory returns.
      final source = File.fromUri(parent.uri.resolve('selected.zip'));
      await source.writeAsBytes(base64Decode(_previewZip));
      final session = await openLocalLive2DZip(
        platform: _Picker(parent.path, {
          'path': source.path,
          'temporary': false,
        }),
      );
      final stage = Directory(session!.previewDirectory!);
      expect(stage.isAbsolute, isTrue);
      expect(stage.parent.path, parent.path);
      // The file the preview view loads from the served base URL.
      expect(
        await File.fromUri(stage.uri.resolve('model.model3.json')).exists(),
        isTrue,
      );
      await session.close();
      expect(await stage.exists(), isFalse);
    },
  );

  test(
    'a pending picker blocks overlapping imports and releases its guard',
    () async {
      final pending = Completer<Map<Object?, Object?>?>();
      final picker = _PendingPicker(parent.path, pending.future);
      final first = openLocalLive2DZip(platform: picker);
      try {
        await expectLater(
          openLocalLive2DZip(platform: picker),
          throwsA(isA<Live2DImportFailure>()),
        );
      } finally {
        pending.complete(null);
      }
      expect(await first, isNull);
      expect(await openLocalLive2DZip(platform: picker), isNull);
    },
  );

  test('invalid temporary ZIP is deleted and exposes no path', () async {
    final source = File.fromUri(parent.uri.resolve('live2d-zip-test.zip'));
    await source.writeAsBytes([1, 2, 3]);
    await expectLater(
      openLocalLive2DZip(
        platform: _Picker(parent.path, {
          'path': source.path,
          'temporary': true,
        }),
      ),
      throwsA(
        isA<Live2DImportFailure>().having(
          (error) => error.message,
          'message',
          isNot(contains(source.path)),
        ),
      ),
    );
    expect(await parent.list().toList(), isEmpty);
  });

  test('stages only the fixed-name preview files and reopens them', () async {
    final stage = await stageLive2DPreview(parent, bundle);
    addTearDown(stage.dispose);

    expect(stage.directory.parent.path, parent.path);
    expect(stage.model3File.uri.pathSegments.last, 'model.model3.json');
    final entries = await stage.directory.list(followLinks: false).toList();
    expect(entries, everyElement(isA<File>()));
    expect(
      entries.map((entry) => entry.uri.pathSegments.last),
      unorderedEquals([
        'model.model3.json',
        'model.moc3',
        'texture-0.png',
        'texture-1.png',
      ]),
    );
    for (final file in entries.cast<File>()) {
      final name = file.uri.pathSegments.last;
      final reopened = File.fromUri(stage.directory.uri.resolve(name));
      expect(await reopened.readAsBytes(), bundle.files[name], reason: name);
    }
    final manifest = jsonDecode(
      await stage.model3File.readAsString(),
    ) as Map<String, Object?>;
    expect(manifest['FileReferences'], {
      'Moc': 'model.moc3',
      'Textures': ['texture-0.png', 'texture-1.png'],
    });
  });

  test('stages expression and motion files under dense names', () {
    expect(
      stagedLive2DPreviewNames([
        'motion-0.motion3.json',
        'expression-1.exp3.json',
        'texture-0.png',
        'model.moc3',
        'motion-1.motion3.json',
        'expression-0.exp3.json',
        'texture-1.png',
        'model.model3.json',
      ]),
      [
        'model.model3.json',
        'model.moc3',
        'texture-0.png',
        'texture-1.png',
        'expression-0.exp3.json',
        'expression-1.exp3.json',
        'motion-0.motion3.json',
        'motion-1.motion3.json',
      ],
    );
    // Expressions and motions are optional, each on its own.
    const base = ['model.model3.json', 'model.moc3', 'texture-0.png'];
    expect(stagedLive2DPreviewNames(base), base);
    for (final name in ['expression-0.exp3.json', 'motion-0.motion3.json']) {
      expect(stagedLive2DPreviewNames([...base, name]), [...base, name]);
    }
    // The fixture bundle's names, in the order they are written.
    expect(stagedLive2DPreviewNames(bundle.files.keys), [
      'model.model3.json',
      'model.moc3',
      'texture-0.png',
      'texture-1.png',
    ]);
  });

  test('rejects any other set of preview file names', () {
    const base = ['model.model3.json', 'model.moc3', 'texture-0.png'];
    const rejected = {
      'no texture': [
        'model.model3.json',
        'model.moc3',
        'expression-0.exp3.json',
      ],
      'no MOC3': ['model.model3.json', 'texture-0.png'],
      'no model3': ['model.moc3', 'texture-0.png'],
      'a gap': [...base, 'expression-0.exp3.json', 'expression-2.exp3.json'],
      'not counting from 0': [...base, 'motion-1.motion3.json'],
      'a leading zero': [
        ...base,
        'expression-0.exp3.json',
        'expression-01.exp3.json',
      ],
      'a negative index': [...base, 'motion--1.motion3.json'],
      'a swapped suffix': [...base, 'expression-0.motion3.json'],
      'a bare JSON suffix': [...base, 'motion-0.json'],
      'an upper-case name': [...base, 'Expression-0.exp3.json'],
      'an upper-case suffix': [...base, 'texture-1.PNG'],
      'a subdirectory': [...base, 'motions/motion-0.motion3.json'],
      'a parent path': [...base, '../expression-0.exp3.json'],
      'a trailing separator': [...base, 'expression-0.exp3.json/'],
      'an unstaged type': [...base, 'model.physics3.json'],
      'a motion sound': [...base, 'motion-0.wav'],
    };
    for (final MapEntry(key: label, value: names) in rejected.entries) {
      expect(stagedLive2DPreviewNames(names), isNull, reason: label);
    }
  });

  test(
    'disposes one of two concurrent stages without affecting the other',
    () async {
      final sibling = await File.fromUri(parent.uri.resolve('keep.txt'))
          .writeAsString('keep');
      final [first, second] = await Future.wait([
        stageLive2DPreview(parent, bundle),
        stageLive2DPreview(parent, bundle),
      ]);

      expect(first.directory.path, isNot(second.directory.path));
      await Future.wait([first.dispose(), first.dispose()]);
      await first.dispose();
      expect(await first.directory.exists(), isFalse);
      expect(await second.model3File.exists(), isTrue);
      await second.dispose();
      expect(await second.directory.exists(), isFalse);
      expect(await sibling.readAsString(), 'keep');
    },
  );

  test(
    'disposes successfully when the staged directory is already gone',
    () async {
      final stage = await stageLive2DPreview(parent, bundle);
      await stage.directory.delete(recursive: true);

      await stage.dispose();
      expect(await parent.list().toList(), isEmpty);
    },
  );

  test('removes the partial stage when a file write fails', () async {
    final staging = IOOverrides.runWithIOOverrides(
      () => stageLive2DPreview(parent, bundle),
      _BlockMocWrite(),
    );

    await expectLater(
      staging,
      throwsA(
        isA<FileSystemException>().having(
          (error) => error.path,
          'blocked file',
          endsWith('model.moc3'),
        ),
      ),
    );
    expect(await parent.list().toList(), isEmpty);
  });

  test(
    'preserves both errors when rollback fails and can retry cleanup',
    () async {
      final staging = IOOverrides.runWithIOOverrides(
        () => stageLive2DPreview(_CleanupFaultDirectory(parent), bundle),
        _BlockMocWrite(),
      );
      try {
        await staging;
        fail('Expected staging to fail');
      } on Live2DPreviewCleanupFailure catch (failure) {
        expect(failure.writeError, isA<FileSystemException>());
        expect(failure.cleanupError, isA<FileSystemException>());
        expect(await parent.list().toList(), hasLength(1));
        await failure.retryCleanup();
        expect(await parent.list().toList(), isEmpty);
      }
    },
  );

  test('does not create a missing trusted parent', () async {
    final missing = Directory.fromUri(parent.uri.resolve('missing/'));
    await expectLater(
      stageLive2DPreview(missing, bundle),
      throwsA(isA<FileSystemException>()),
    );
    expect(await parent.list().toList(), isEmpty);
  });
}

final class _CleanupFaultDirectory implements Directory {
  _CleanupFaultDirectory(this.delegate);

  final Directory delegate;
  bool _failDelete = true;

  @override
  Directory get absolute => this;

  @override
  Uri get uri => delegate.uri;

  @override
  Future<Directory> createTemp([String? prefix]) async =>
      _CleanupFaultDirectory(await delegate.createTemp(prefix));

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    if (_failDelete) {
      _failDelete = false;
      throw FileSystemException('test cleanup failure', delegate.path);
    }
    return delegate.delete(recursive: recursive);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _Picker extends NativePlatform {
  _Picker(this.directory, this.selection);

  final String directory;
  final Map<Object?, Object?> selection;

  @override
  Future<T?> invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    return switch (method) {
      'getLive2DPreviewDirectory' => directory as T,
      'pickLive2DZip' => selection as T,
      _ => throw StateError('Unexpected platform operation'),
    };
  }
}

final class _PendingPicker extends NativePlatform {
  _PendingPicker(this.directory, this.selection);

  final String directory;
  final Future<Map<Object?, Object?>?> selection;

  @override
  Future<T?> invoke<T>(String method, [Map<String, Object?>? arguments]) async {
    return switch (method) {
      'getLive2DPreviewDirectory' => directory as T,
      'pickLive2DZip' => (await selection) as T?,
      _ => throw StateError('Unexpected platform operation'),
    };
  }
}

final class _BlockMocWrite extends IOOverrides {
  @override
  File createFile(String path) {
    final file = super.createFile(path);
    if (file.uri.pathSegments.last == 'model.moc3') {
      // Force the native write to fail after the manifest has reached disk.
      expect(
        File.fromUri(file.parent.uri.resolve('model.model3.json')).existsSync(),
        isTrue,
      );
      super.createDirectory(path).createSync();
    }
    return file;
  }
}
