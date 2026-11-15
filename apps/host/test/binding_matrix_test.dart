import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/models/ai_identity.dart';
import 'package:jingyu_host/src/models/binding_matrix.dart';
import 'package:jingyu_host/src/models/binding_migrations.dart';
import 'package:jingyu_host/src/models/models_migrations.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late BindingMatrix alice;
  late BindingMatrix bob;
  late BindingMatrix admin;
  final ai = AiId.parse('profile-one');
  const chat = ProviderCapability.chat;
  const fast = ProviderCapability.chatFast;
  const migrations = [
    ...allMigrations,
    ...accountsMigrations,
    ...modelsMigrations,
    aiIdentityMigration,
    bindingMigration,
  ];

  void scopes() {
    alice = BindingMatrix.forOwner('alice', db);
    bob = BindingMatrix.forOwner('bob', db);
    admin = BindingMatrix.forOwner('admin', db);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('binding-matrix-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: migrations,
    );
    for (final id in ['alice', 'bob', 'admin']) {
      await db.execute(
        'INSERT INTO account (id, display_name, kind, is_admin, disabled, password_hash, failed_passwords, locked_until) '
        "VALUES (?, ?, 'human', ?, 0, 'fixture', 0, 0)",
        [id, id, id == 'admin' ? 1 : 0],
      );
    }
    await db.execute(
      'INSERT INTO account (id, display_name, kind, is_admin, disabled, password_hash, failed_passwords, locked_until) '
      "VALUES ('ai-account', 'AI', 'ai', 0, 0, NULL, 0, 0)",
    );
    await db.execute("INSERT INTO ai_operator VALUES ('ai-account', 'alice')");
    await db.execute(
      "INSERT INTO ai_profile VALUES ('profile-one', 'ai-account')",
    );
    for (final owner in ['alice', 'bob']) {
      await db.execute(
        'INSERT INTO providers (owner_id,id,name,base_url,encrypted_key,key_mask,enabled,capabilities) '
        "VALUES (?, 'provider', 'fixture', 'https://models.example/v1', 'secret-ciphertext', '****1234', 1, ?)",
        [owner, '["chat","chatFast","tts"]'],
      );
    }
    scopes();
  });

  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'set persists safe views and resolve provides identifiers without credentials',
    () async {
      final saved = (await alice.set(
        ai,
        chat,
        providerId: 'provider',
        model: 'main-model',
      )).value;
      expect(saved.aiProfileId, ai);
      expect(saved.ownerId, 'alice');
      expect(saved.providerId, 'provider');
      expect(saved.model, 'main-model');
      expect(saved.capability, chat);
      final resolved = (await alice.resolve(ai, chat)).value;
      expect(resolved.aiAccountId, AccountId.parse('ai-account'));
      expect(resolved.aiProfileId, ai);
      expect(resolved.ownerId, 'alice');
      expect(resolved.providerId, 'provider');
      expect(resolved.model, 'main-model');
      expect(resolved.capability, chat);
      expect(jsonEncode(saved.toJson()), isNot(contains('secret-ciphertext')));
      expect(jsonEncode(resolved.toJson()), isNot(contains('key')));
      expect((await alice.get(ai, chat)).value.model, 'main-model');
      expect((await alice.list(ai)).value.map((b) => b.model), ['main-model']);
      expect(
        (await db.query('SELECT model FROM model_bindings')).single['model'],
        'main-model',
      );
    },
  );

  test(
    'chatFast never reads chat and each binding updates independently',
    () async {
      await alice.set(ai, chat, providerId: 'provider', model: 'slow');
      expect(
        (await alice.get(ai, fast)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await alice.resolve(ai, fast)).failureOrNull?.code,
        FailureCode.notFound,
      );
      await alice.set(ai, fast, providerId: 'provider', model: 'quick');
      await alice.set(ai, chat, providerId: 'provider', model: 'slow-v2');
      expect((await alice.resolve(ai, fast)).value.model, 'quick');
      expect((await alice.resolve(ai, chat)).value.model, 'slow-v2');
      expect((await alice.list(ai)).value.length, 2);
      expect((await alice.clear(ai, fast)).isOk, isTrue);
      expect(
        (await alice.resolve(ai, fast)).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect((await alice.resolve(ai, chat)).value.model, 'slow-v2');
      expect((await alice.clear(ai, fast)).isOk, isTrue);
    },
  );

  test(
    'cross owner and nonoperator admin receive notFound for every operation',
    () async {
      await alice.set(ai, chat, providerId: 'provider', model: 'private');
      for (final scope in [bob, admin]) {
        for (final result in [
          await scope.set(ai, chat, providerId: 'provider', model: 'attack'),
          await scope.get(ai, chat),
          await scope.resolve(ai, chat),
          await scope.clear(ai, chat),
          await scope.list(ai),
        ]) {
          expect(result.failureOrNull?.code, FailureCode.notFound);
        }
      }
      expect((await alice.get(ai, chat)).value.model, 'private');
    },
  );

  test('foreign provider and missing provider cannot be bound', () async {
    await db.execute(
      "UPDATE providers SET id = 'bob-only' WHERE owner_id = 'bob'",
    );
    for (final id in ['bob-only', 'missing']) {
      expect(
        (await alice.set(
          ai,
          chat,
          providerId: id,
          model: 'm',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
    }
    expect((await alice.list(ai)).value, isEmpty);
  });

  test(
    'disabled provider retains binding and cannot receive a new binding',
    () async {
      await alice.set(ai, chat, providerId: 'provider', model: 'original');
      await db.execute(
        "UPDATE providers SET enabled = 0 WHERE owner_id = 'alice'",
      );
      expect(
        (await alice.resolve(ai, chat)).failureOrNull?.code,
        FailureCode.modelUnavailable,
      );
      expect(
        (await alice.set(
          ai,
          chat,
          providerId: 'provider',
          model: 'replacement',
        )).failureOrNull?.code,
        FailureCode.modelUnavailable,
      );
      expect((await alice.get(ai, chat)).value.model, 'original');
      expect((await alice.list(ai)).value.single.model, 'original');
      await db.execute(
        "UPDATE providers SET enabled = 1 WHERE owner_id = 'alice'",
      );
      expect((await alice.resolve(ai, chat)).value.model, 'original');
    },
  );

  test(
    'provider capability changes fail resolution without rewriting bindings',
    () async {
      await alice.set(ai, fast, providerId: 'provider', model: 'quick');
      await db.execute(
        "UPDATE providers SET capabilities = '[\"chat\"]' WHERE owner_id = 'alice'",
      );
      expect(
        (await alice.resolve(ai, fast)).failureOrNull?.code,
        FailureCode.modelUnavailable,
      );
      expect(
        (await alice.set(
          ai,
          ProviderCapability.tts,
          providerId: 'provider',
          model: 'voice',
        )).failureOrNull?.code,
        FailureCode.modelUnavailable,
      );
      expect((await alice.get(ai, fast)).value.model, 'quick');
    },
  );

  test('active AI and operator are rechecked on every operation', () async {
    await alice.set(ai, chat, providerId: 'provider', model: 'm');
    for (final change in [
      "UPDATE account SET disabled = 1 WHERE id = 'ai-account'",
      "UPDATE account SET disabled = 0, kind = 'human', password_hash = 'fixture' WHERE id = 'ai-account'",
      "UPDATE ai_operator SET operator_id = 'bob' WHERE ai_id = 'ai-account'",
    ]) {
      await db.execute(
        "UPDATE account SET disabled = 0, kind = 'ai', password_hash = NULL WHERE id = 'ai-account'",
      );
      await db.execute(change);
      for (final result in [
        await alice.get(ai, chat),
        await alice.resolve(ai, chat),
        await alice.list(ai),
        await alice.clear(ai, chat),
        await alice.set(ai, chat, providerId: 'provider', model: 'changed'),
      ]) {
        expect(result.failureOrNull?.code, FailureCode.notFound);
      }
    }
    await db.execute(
      "UPDATE account SET kind = 'ai', password_hash = NULL WHERE id = 'ai-account'",
    );
    expect((await bob.get(ai, chat)).failureOrNull?.code, FailureCode.notFound);
    expect((await bob.list(ai)).value, isEmpty);
    await bob.set(ai, chat, providerId: 'provider', model: 'bob-model');
    expect((await bob.resolve(ai, chat)).value.model, 'bob-model');
    expect(
      (await db.query('SELECT model FROM model_bindings WHERE owner_id = ?', [
        'alice',
      ])).single['model'],
      'm',
    );
  });

  final ownerStates = {
    'disabled': "UPDATE account SET disabled = 1 WHERE id = 'alice'",
    'nonhuman':
        "UPDATE account SET kind = 'ai', password_hash = NULL WHERE id = 'alice'",
  };
  final ownerOperations = <String, Future<Result<Object?>> Function()>{
    'get': () => alice.get(ai, chat),
    'list': () => alice.list(ai),
    'resolve': () => alice.resolve(ai, chat),
    'set': () =>
        alice.set(ai, chat, providerId: 'provider', model: 'replacement'),
    'clear': () => alice.clear(ai, chat),
  };
  for (final state in ownerStates.entries) {
    for (final operation in ownerOperations.entries) {
      test('${state.key} owner cannot ${operation.key} bindings', () async {
        await alice.set(ai, chat, providerId: 'provider', model: 'original');
        final before = await db.query('SELECT * FROM model_bindings');
        await db.execute(state.value);

        final result = await operation.value();

        expect(result.failureOrNull?.code, FailureCode.notFound);
        expect(await db.query('SELECT * FROM model_bindings'), before);
      });
    }
  }

  test(
    're-enabled human owner regains binding access without data loss',
    () async {
      await alice.set(ai, chat, providerId: 'provider', model: 'original');
      await db.execute("UPDATE account SET disabled = 1 WHERE id = 'alice'");
      expect(
        (await alice.get(ai, chat)).failureOrNull?.code,
        FailureCode.notFound,
      );
      await db.execute("UPDATE account SET disabled = 0 WHERE id = 'alice'");

      expect((await alice.get(ai, chat)).value.model, 'original');
      expect((await alice.resolve(ai, chat)).value.model, 'original');
      expect((await alice.list(ai)).value.single.model, 'original');
      expect(
        (await alice.set(
          ai,
          chat,
          providerId: 'provider',
          model: 'updated',
        )).value.model,
        'updated',
      );
      expect((await alice.clear(ai, chat)).isOk, isTrue);
      expect(await db.query('SELECT * FROM model_bindings'), isEmpty);
    },
  );

  test('missing mappings never implicitly register accounts', () async {
    final missing = AiId.parse('ai-account');
    expect(
      (await alice.set(
        missing,
        chat,
        providerId: 'provider',
        model: 'm',
      )).failureOrNull?.code,
      FailureCode.notFound,
    );
    expect(
      (await alice.list(missing)).failureOrNull?.code,
      FailureCode.notFound,
    );
    expect((await db.query('SELECT id FROM ai_profile')).length, 1);
  });

  test(
    'empty and control character models are rejected without replacing binding',
    () async {
      await alice.set(ai, chat, providerId: 'provider', model: 'original');
      for (final model in [
        '',
        '   ',
        'bad\nmodel',
        'bad\u0000model',
        'bad\u007fmodel',
        'bad\u0085model',
      ]) {
        expect(
          (await alice.set(
            ai,
            chat,
            providerId: 'provider',
            model: model,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
      }
      expect((await alice.get(ai, chat)).value.model, 'original');
    },
  );

  test(
    'surrounding model whitespace cannot create or replace a binding',
    () async {
      for (final model in [' S2', 'S2 ', ' S2 ']) {
        expect(
          (await alice.set(
            ai,
            chat,
            providerId: 'provider',
            model: model,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
        expect((await alice.list(ai)).value, isEmpty);
      }
      await alice.set(ai, chat, providerId: 'provider', model: 'original');
      for (final model in [' S2', 'S2 ', ' S2 ']) {
        expect(
          (await alice.set(
            ai,
            chat,
            providerId: 'provider',
            model: model,
          )).failureOrNull?.code,
          FailureCode.invalidArgument,
        );
        expect((await alice.get(ai, chat)).value.model, 'original');
      }
    },
  );

  test('bindings survive restart and clear is persisted', () async {
    await alice.set(ai, chat, providerId: 'provider', model: 'durable');
    await db.close();
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: migrations,
    );
    scopes();
    expect(await db.schemaVersion(), 502);
    expect((await alice.resolve(ai, chat)).value.model, 'durable');
    expect((await alice.clear(ai, chat)).isOk, isTrue);
    expect(
      (await alice.get(ai, chat)).failureOrNull?.code,
      FailureCode.notFound,
    );
    expect(await db.query('SELECT * FROM model_bindings'), isEmpty);
  });

  test(
    'migration restricts provider deletion and rejects composite foreign owner mismatch',
    () async {
      await alice.set(ai, chat, providerId: 'provider', model: 'm');
      await expectLater(
        db.execute("DELETE FROM providers WHERE owner_id = 'alice'"),
        throwsException,
      );
      await db.execute(
        "UPDATE providers SET id = 'bob-only' WHERE owner_id = 'bob'",
      );
      await expectLater(
        db.execute(
          'INSERT INTO model_bindings (owner_id,ai_profile_id,capability,provider_id,model) VALUES (?,?,?,?,?)',
          ['alice', 'profile-one', 'tts', 'bob-only', 'voice'],
        ),
        throwsException,
      );
      await expectLater(
        db.execute(
          'INSERT INTO model_bindings (owner_id,ai_profile_id,capability,provider_id,model) VALUES (?,?,?,?,?)',
          ['alice', 'missing-profile', 'tts', 'provider', 'voice'],
        ),
        throwsException,
      );
      await alice.clear(ai, chat);
      expect(
        await db.execute("DELETE FROM providers WHERE owner_id = 'alice'"),
        1,
      );
    },
  );
}
