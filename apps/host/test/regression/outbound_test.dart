/// NFR-05 / AC-10 出站防护回归（骨架 + 可运行子集）。
///
/// 设计意图（见 docs/modules/M13-hardening.md 规则 3）：把 UrlGuard 换成记录调用的
/// 假实现，跑完各模块出站路径后断言每一次出站都先经过它。
///
/// 当前可运行子集覆盖两部分：
///  1) 结构不变式扫描：整个 `apps/host/lib` 中只有 `security/guarded_http.dart`
///     直接创建出站 socket/HttpClient；且所有出站组件都把 `UrlGuard` 作为依赖。
///  2) 依赖接缝：用记录型 `RecordingUrlGuard` 注入 `ProviderRegistry`，验证
///     provider 的 base_url 在保存前必经该 guard，私有地址被拒、公网字面量放行。
///
/// 运行时“每个模块的每一次真实出站都先经过记录型 guard”尚未在此子集覆盖，
/// 在文件末尾如实 skip，不伪造通过。
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/models/provider_registry.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:test/test.dart';

import 'hardening_support.dart';

/// 记录每一次 `check` 的假 UrlGuard；解析器置空，仅依赖 IP 字面量，离线可用。
class RecordingUrlGuard extends UrlGuard {
  RecordingUrlGuard() : super(resolver: (host) async => <InternetAddress>[]);

  final List<String> checked = <String>[];

  @override
  Future<Result<Uri>> check(String raw) async {
    checked.add(raw);
    return super.check(raw);
  }
}

Directory locateHostLib() {
  for (final candidate in <Directory>[Directory('lib'), Directory('apps/host/lib')]) {
    if (File('${candidate.path}/src/security/guarded_http.dart').existsSync()) {
      return candidate;
    }
  }
  throw StateError('无法定位 apps/host/lib（当前目录 ${Directory.current.path}）');
}

List<File> dartFiles(Directory root) => <File>[
  for (final entity in root.listSync(recursive: true))
    if (entity is File && entity.path.endsWith('.dart')) entity,
];

void main() {
  group('NFR-05 出站经 UrlGuard', () {
    test('结构不变式：出站 socket/HttpClient 只存在于 guarded_http.dart', () {
      final lib = locateHostLib();
      const primitives = <String>[
        'HttpClient(',
        'Socket.startConnect',
        'SecureSocket.secure',
      ];
      final offenders = <String>[];
      for (final file in dartFiles(lib)) {
        final content = file.readAsStringSync();
        if (primitives.any(content.contains)) {
          final normalized = file.path.replaceAll('\\', '/');
          if (!normalized.endsWith('src/security/guarded_http.dart')) {
            offenders.add(normalized);
          }
        }
      }
      expect(offenders, isEmpty, reason: '发现 guarded_http.dart 之外的出站原语');
    });

    test('guarded_http 用 UrlGuard.isBlocked 校验解析后的地址', () {
      final file = File(
        '${locateHostLib().path}/src/security/guarded_http.dart',
      );
      expect(file.readAsStringSync(), contains('UrlGuard.isBlocked'));
    });

    test('所有出站组件都把 UrlGuard 作为依赖（构造注入接缝存在）', () {
      final lib = locateHostLib();
      const components = <String>[
        'src/models/model_gateway.dart',
        'src/models/model_runtime.dart',
        'src/models/provider_model_discovery.dart',
        'src/models/provider_registry.dart',
        'src/ai/context/contextual_chat.dart',
      ];
      for (final relative in components) {
        final file = File('${lib.path}/$relative');
        expect(file.existsSync(), isTrue, reason: relative);
        expect(
          file.readAsStringSync(),
          contains('UrlGuard'),
          reason: '$relative 未声明 UrlGuard 依赖',
        );
      }
    });

    test('provider 的 base_url 在保存前必经注入的 RecordingUrlGuard', () async {
      final harness = await Harness.boot();
      try {
        final owner = await harness.seedAccount(
          displayName: 'Owner',
          id: 'acct-owner',
          token: syntheticToken('o'),
        );
        final db = harness.host.registry.services.get<Database>();
        final cipher = harness.host.registry.services.get<ColumnCipher>();
        final guard = RecordingUrlGuard();
        final registry = ProviderRegistry.forOwner(
          ownerId: owner.id,
          db: db,
          cipher: cipher,
          urlGuard: guard,
          clock: const SystemClock(),
        );

        final blocked = await registry.create(
          name: 'private',
          baseUrl: 'http://10.0.0.1/v1',
          apiKey: 'k',
          capabilities: <ProviderCapability>{ProviderCapability.chat},
        );
        expect(blocked.isErr, isTrue);
        expect(guard.checked, contains('http://10.0.0.1/v1'));

        final allowed = await registry.create(
          name: 'public',
          baseUrl: offlineSafeBaseUrl,
          apiKey: 'k',
          capabilities: <ProviderCapability>{ProviderCapability.chat},
        );
        expect(allowed.isOk, isTrue);
        expect(guard.checked, contains(offlineSafeBaseUrl));
      } finally {
        await harness.dispose();
      }
    });

    test(
      '未覆盖：各模块真实出站请求的运行时记录（无真实公网调用）',
      () {},
      skip: '当前默认宿主无真实模型/语音/生图出站调用（需显式配置 worker 与真实 provider）。'
          '本子集只覆盖结构不变式与 provider 配置接缝；真实运行时全链路未覆盖。',
    );
  });
}
