import 'dart:convert';
import 'dart:io';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

const _model3 = 'avatar.model3.json';
final _day1 = DateTime.utc(2026, 1, 1);
final _day2 = DateTime.utc(2026, 1, 2);

// Small synthetic model files; [version] tells two imports apart.
Map<String, List<int>> _files(String version) => {
  _model3: utf8.encode('{"Version": 3, "build": "$version"}'),
  'textures/skin.png': utf8.encode('png $version'),
};

Live2DProfile _profile(String id, {int rev = 1}) => Live2DProfile.fromJson({
  'schemaVersion': 1,
  'modelId': id,
  'profileRev': rev,
  'modelFile': _model3,
  'paramMap': {
    'mouthOpen': 'ParamMouthOpenY',
    'blinkLeft': 'ParamEyeLOpen',
    'blinkRight': 'ParamEyeROpen',
    'noExpressions': false,
    'noMotions': false,
    'expressions': {'happy': 'F01'},
    'motions': {
      'wave': {'group': 'Idle', 'index': 0},
    },
  },
});

// The ready event of the synthetic model. An incomplete one lacks both eyes,
// the mapped expression and every motion.
Live2DModelInfo _ready({bool complete = true}) =>
    Live2DModelInfo.fromReadyEvent({
      'parameters': [
        {'id': 'ParamMouthOpenY'},
        if (complete) ...[
          {'id': 'ParamEyeLOpen'},
          {'id': 'ParamEyeROpen'},
        ],
      ],
      'expressions': [complete ? 'F01' : 'F02'],
      if (complete)
        'motions': [
          {'group': 'Idle', 'count': 1},
        ],
    });

String _under(String dir, String path) =>
    [dir, ...path.split('/')].join(Platform.pathSeparator);

String _skin(Live2DFileStore store) => File(
  _under(store.modelDirectory('m'), 'textures/skin.png'),
).readAsStringSync();

// Copies every file under [from], hidden ones included, to the same place
// under [to]. The crash states below are built from real store output.
void _copyDir(String from, String to) {
  Directory(to).createSync(recursive: true);
  for (final entity in Directory(from).listSync(recursive: true)) {
    if (entity is! File) continue;
    final copy = File('$to${entity.path.substring(from.length)}');
    copy.parent.createSync(recursive: true);
    entity.copySync(copy.path);
  }
}

// Opens [root] with model m imported as v1, its profile saved and active.
Future<Live2DFileStore> _activeStore(String root) async {
  final store = await Live2DFileStore.open(root);
  await store.importModel(
    modelId: 'm',
    displayName: 'Model m',
    model3: _model3,
    files: _files('v1'),
    importedAt: _day1,
  );
  await store.saveProfile(_profile('m'));
  await store.setActive('m', _ready());
  return store;
}

// [_activeStore], then m replaced by v2.
Future<Live2DFileStore> _replacedStore(String root) async {
  final store = await _activeStore(root);
  await store.importModel(
    modelId: 'm',
    displayName: 'Model m',
    model3: _model3,
    files: _files('v2'),
    replace: true,
    importedAt: _day2,
  );
  return store;
}

void main() {
  late Directory base;
  setUp(() {
    base = Directory.systemTemp.createTempSync('live2d_file_store_');
  });
  tearDown(() {
    base.deleteSync(recursive: true);
  });
  String rootAt(String name) => _under(base.path, name);

  group('Live2DFileStore', () {
    test('reopening reads back models, files, profile and selection', () async {
      final root = rootAt('a');
      final store = await _activeStore(root);
      final entry = store.model('m')!;
      expect(store.root, root);
      expect(store.modelDirectory('m'), _under(root, 'models/m'));
      expect([entry.displayName, entry.model3], ['Model m', _model3]);
      final again = await Live2DFileStore.open(root);
      expect(
        [for (final model in again.models) model.toJson()],
        [entry.toJson()],
      );
      expect(again.profile('m')!.toJson(), _profile('m').toJson());
      expect(again.activeModelId, 'm');
      expect(_skin(again), 'png v1');
    });

    test(
      'open removes what interrupted writes left and keeps the selection',
      () async {
        final root = rootAt('a');
        final dir = (await _activeStore(root)).modelDirectory('m');
        // A JSON write stopped before its rename, a replace before its swap, a
        // new import before or after its rename, a delete after models.json.
        File(
          _under(root, 'models.json.pending'),
        ).writeAsStringSync('{"models": [');
        File(_under(root, 'profiles/m.json.pending')).writeAsStringSync('{');
        File(
          _under(root, 'profiles/m.json'),
        ).copySync(_under(root, 'profiles/n.json'));
        for (final copy in [
          '$dir.pending',
          _under(root, 'models/n.pending'),
          _under(root, 'models/n'),
        ]) {
          _copyDir(dir, copy);
        }
        final store = await Live2DFileStore.open(root);
        expect([for (final model in store.models) model.id], ['m']);
        expect(store.profile('m')!.toJson(), _profile('m').toJson());
        expect(store.activeModelId, 'm');
        expect(_skin(store), 'png v1');
        for (final path in [
          'models.json.pending',
          'profiles/m.json.pending',
          'profiles/n.json',
          'models/m.pending',
          'models/n.pending',
          'models/n',
        ]) {
          expect(
            FileSystemEntity.typeSync(_under(root, path)),
            FileSystemEntityType.notFound,
            reason: path,
          );
        }
      },
    );

    test('open rolls back a replace that stopped before models.json', () async {
      final a = await _activeStore(rootAt('a'));
      final b = await _replacedStore(rootAt('b'));
      final dir = a.modelDirectory('m');
      final v2 = b.modelDirectory('m');
      for (final (state, crash) in <(String, void Function())>[
        (
          'old files moved aside, new ones not in place',
          () {
            Directory(dir).renameSync('$dir.old');
            _copyDir(v2, '$dir.pending');
          },
        ),
        (
          'new files in place',
          () {
            _copyDir(dir, '$dir.old');
            Directory(dir).deleteSync(recursive: true);
            _copyDir(v2, dir);
          },
        ),
      ]) {
        crash();
        final store = await Live2DFileStore.open(a.root);
        expect(_skin(store), 'png v1', reason: state);
        expect(
          store.model('m')!.toJson(),
          a.model('m')!.toJson(),
          reason: state,
        );
        expect(store.profile('m'), isNotNull, reason: state);
        // A leftover old copy clears the selection; .pending alone does not.
        expect(store.activeModelId, isNull, reason: state);
        for (final suffix in ['.old', '.pending']) {
          expect(Directory('$dir$suffix').existsSync(), isFalse, reason: state);
        }
        await store.setActive('m', _ready());
      }
    });

    test('open keeps a replace that reached models.json', () async {
      final a = await _activeStore(rootAt('a'));
      final b = await _replacedStore(rootAt('b'));
      // Replacing keeps the profile, but the mapping must be checked again.
      expect(b.activeModelId, isNull);
      expect(b.profile('m')!.toJson(), _profile('m').toJson());
      final dir = b.modelDirectory('m');
      _copyDir(a.modelDirectory('m'), '$dir.old');
      final store = await Live2DFileStore.open(b.root);
      expect(_skin(store), 'png v2');
      expect(store.model('m')!.toJson(), b.model('m')!.toJson());
      expect(Directory('$dir.old').existsSync(), isFalse);
    });

    test(
      'delete removes files and profile, and the selection with them',
      () async {
        final root = rootAt('a');
        final store = await _activeStore(root);
        await store.importModel(
          modelId: 'k',
          displayName: 'Model k',
          model3: _model3,
          files: _files('v1'),
        );
        await store.saveProfile(_profile('k'));
        final dir = store.modelDirectory('m');
        expect(await store.delete('k'), isTrue);
        expect(store.activeModelId, 'm');
        expect(await store.delete('m'), isTrue);
        expect(await store.delete('m'), isFalse);
        expect(store.models, isEmpty);
        expect(store.profile('m'), isNull);
        expect(store.activeModelId, isNull);
        expect(() => store.modelDirectory('m'), throwsStateError);
        for (final path in [
          dir,
          _under(root, 'profiles/m.json'),
          _under(root, 'profiles/k.json'),
        ]) {
          expect(
            FileSystemEntity.typeSync(path),
            FileSystemEntityType.notFound,
            reason: path,
          );
        }
        final again = await Live2DFileStore.open(root);
        expect(again.models, isEmpty);
        expect(again.activeModelId, isNull);
      },
    );

    test('setActive lists every missing target and changes nothing', () async {
      final root = rootAt('a');
      final store = await _activeStore(root);
      await store.importModel(
        modelId: 'k',
        displayName: 'Model k',
        model3: _model3,
        files: _files('v1'),
      );
      await expectLater(() => store.setActive('k', _ready()), throwsStateError);
      await store.saveProfile(_profile('k'));
      await expectLater(
        () => store.setActive('k', _ready(complete: false)),
        throwsA(
          isA<Live2DTargetException>().having(
            (error) => [for (final miss in error.misses) miss.field],
            'missed fields',
            ['blinkLeft', 'blinkRight', 'expressions[happy]', 'motions[wave]'],
          ),
        ),
      );
      await expectLater(
        () => store.setActive('missing', _ready()),
        throwsStateError,
      );
      expect(store.activeModelId, 'm');
      final again = await Live2DFileStore.open(root);
      expect(again.activeModelId, 'm');
      expect(again.profile('k')!.toJson(), _profile('k').toJson());
      await again.setActive('k', _ready());
      expect(again.activeModelId, 'k');
    });

    test(
      'saveProfile checks model, file and revision, and clears the selection',
      () async {
        final store = await _activeStore(rootAt('a'));
        final otherFile = {
          ..._profile('m', rev: 2).toJson(),
          'modelFile': 'other.model3.json',
        };
        await expectLater(
          () => store.saveProfile(_profile('k')),
          throwsStateError,
        );
        await expectLater(
          () => store.saveProfile(_profile('m')),
          throwsFormatException,
        );
        await expectLater(
          () => store.saveProfile(Live2DProfile.fromJson(otherFile)),
          throwsFormatException,
        );
        expect(store.activeModelId, 'm');
        await store.saveProfile(_profile('m', rev: 2));
        expect(store.profile('m')!.profileRev, 2);
        expect(store.activeModelId, isNull);
      },
    );

    test('import refuses a taken ID, also in another case', () async {
      final store = await _activeStore(rootAt('a'));
      for (final id in ['m', 'M']) {
        await expectLater(
          () => store.importModel(
            modelId: id,
            displayName: 'Again',
            model3: _model3,
            files: _files('v2'),
          ),
          throwsStateError,
          reason: id,
        );
      }
      expect(_skin(store), 'png v1');
      expect(store.activeModelId, 'm');
    });

    test(
      'rejects bad IDs and paths and writes nothing outside the root',
      () async {
        final root = rootAt('root');
        final store = await Live2DFileStore.open(root);
        Future<void> rejects(
          String id,
          Map<String, List<int>> files, {
          String model3 = _model3,
        }) => expectLater(
          () => store.importModel(
            modelId: id,
            displayName: 'Bad',
            model3: model3,
            files: files,
          ),
          throwsFormatException,
          reason: '$id $model3 ${files.keys}',
        );
        for (final id in [
          '',
          '..',
          '.hidden',
          'a/b',
          r'a\b',
          'm.pending',
          'M.OLD',
          'x' * 129,
        ]) {
          await rejects(id, _files('v1'));
        }
        for (final path in [
          '../escape.png',
          '/escape.png',
          r'..\escape.png',
          'textures/../../escape.png',
          'notes.txt',
          'Textures/Skin.png',
          'textures/skin.png/x.png',
        ]) {
          await rejects('m', {
            ..._files('v1'),
            path: [0],
          });
        }
        await rejects('m', {
          'textures/skin.png': [0],
        });
        await rejects('m', _files('v1'), model3: '../avatar.model3.json');
        expect(await store.delete('..'), isFalse);
        expect(() => store.modelDirectory('..'), throwsStateError);
        await expectLater(
          Live2DFileStore.open('relative'),
          throwsArgumentError,
        );
        expect(store.models, isEmpty);
        for (final dir in ['models', 'profiles']) {
          expect(Directory(_under(root, dir)).listSync(), isEmpty, reason: dir);
        }
        final inside = '$root${Platform.pathSeparator}';
        expect([
          for (final entity in base.listSync(recursive: true))
            if (entity.path != root && !entity.path.startsWith(inside))
              entity.path,
        ], isEmpty);
      },
    );

    test('open refuses an unreadable models.json before cleaning up', () async {
      final root = rootAt('a');
      final store = await _activeStore(root);
      final dir = store.modelDirectory('m');
      _copyDir(dir, '$dir.pending');
      File(_under(root, 'models.json')).writeAsStringSync('{"models": [');
      await expectLater(Live2DFileStore.open(root), throwsFormatException);
      expect(Directory('$dir.pending').existsSync(), isTrue);
      expect(_skin(store), 'png v1');
    });
  });
}
