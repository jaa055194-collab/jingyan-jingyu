import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../../storage/cipher.dart';
import '../../storage/database.dart';
import 'persona_service.dart';

/// Explicit owner configuration only; no model/self-iteration or memory routes.
class PersonaModule extends HostModule {
  PersonaModule({
    required this.database,
    required this.cipher,
    required this.clock,
    required this.authenticate,
  });

  final Database database;
  final ColumnCipher cipher;
  final Clock clock;
  final Authenticator authenticate;

  @override
  String get name => 'persona';

  @override
  List<String> get dependsOn => const ['storage', 'accounts'];

  HostResponse _bad() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid persona input'),
  );

  Future<HostResponse> _handle(
    HostRequest request,
    Future<HostResponse> Function(SqlitePersonaService service, AiId ai) action,
  ) async {
    final current = await authenticate(request);
    if (current == null ||
        current.accountId != request.principal?.accountId ||
        current.deviceId != request.principal?.deviceId) {
      return HostResponse.failure(
        const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
      );
    }
    final AiId ai;
    try {
      ai = AiId.parse(request.pathParams['aiId'] ?? '');
    } on FormatException {
      return _bad();
    }
    if (request.query.isNotEmpty) return _bad();
    return action(
      SqlitePersonaService.forOwner(
        ownerId: current.accountId,
        actorAccountId: current.accountId,
        database: database,
        cipher: cipher,
        clock: clock,
      ),
      ai,
    );
  }

  Map<String, Object?>? _body(HostRequest request, Set<String> fields) {
    final json = request.jsonObject().valueOrNull;
    if (json == null || json.keys.any((key) => !fields.contains(key))) {
      return null;
    }
    // Bound direct in-process calls too, not just the reference HTTP adapter.
    try {
      if (utf8.encode(jsonEncode(json)).length > 1 << 20) return null;
    } on JsonUnsupportedObjectError {
      return null;
    }
    return json;
  }

  Map<String, String?>? _map(Object? raw, {required bool nullable}) {
    if (raw is! Map) return null;
    final result = <String, String?>{};
    for (final entry in raw.entries) {
      if (entry.key is! String ||
          !(entry.value is String || (nullable && entry.value == null))) {
        return null;
      }
      result[entry.key as String] = entry.value as String?;
    }
    return result;
  }

  Map<String, Object?> _card(PersonaCard card) => {
    'aiId': card.ai.value,
    'version': card.version,
    'locked': card.locked,
    'layers': card.layers.toJson(),
  };

  Map<String, Object?> _change(AiId ai, PersonaChange change) => _card(
    PersonaCard(
      ai: ai,
      version: change.version,
      locked: change.lockedAfter,
      layers: change.after,
    ),
  );

  @override
  void mount(Router router) {
    router.get(
      Routes.aiPersona,
      (request) => _handle(request, (service, ai) async {
        return HostResponse.fromResult(await service.current(ai), _card);
      }),
    );

    router.post(
      Routes.aiPersonaInitialize,
      (request) => _handle(request, (service, ai) async {
        final json = _body(request, const {'p0', 'p1', 'p2'});
        if (json == null || json.length != 3) return _bad();
        final p0 = _map(json['p0'], nullable: false);
        final p1 = _map(json['p1'], nullable: false);
        final p2 = _map(json['p2'], nullable: false);
        if (p0 == null || p1 == null || p2 == null) return _bad();
        final result = await service.initialize(
          ai,
          initial: PersonaLayers(
            p0: p0.cast<String, String>(),
            p1: p1.cast<String, String>(),
            p2: p2.cast<String, String>(),
          ),
        );
        return HostResponse.fromResult(result, _card);
      }),
    );

    router.add(
      'PATCH',
      Routes.aiPersona,
      (request) => _handle(request, (service, ai) async {
        final json = _body(request, const {
          'expectedVersion',
          'reason',
          'diff',
        });
        if (json == null || json.length != 3) return _bad();
        final version = json['expectedVersion'];
        final reason = json['reason'];
        final rawDiff = json['diff'];
        if (version is! int ||
            version < 1 ||
            reason is! String ||
            rawDiff is! Map ||
            rawDiff.keys.any(
              (key) => !const {'p0', 'p1', 'p2'}.contains(key),
            )) {
          return _bad();
        }
        Map<String, String?>? layer(String name) => rawDiff.containsKey(name)
            ? _map(rawDiff[name], nullable: true)
            : <String, String?>{};
        final p0 = layer('p0');
        final p1 = layer('p1');
        final p2 = layer('p2');
        if (p0 == null || p1 == null || p2 == null) return _bad();
        final result = await service.edit(
          ai,
          PersonaDiff(p0: p0, p1: p1, p2: p2),
          expectedVersion: version,
          reason: reason,
        );
        return HostResponse.fromResult(result, (change) => _change(ai, change));
      }),
    );

    router.put(
      Routes.aiPersonaLock,
      (request) => _handle(request, (service, ai) async {
        final json = _body(request, const {'expectedVersion', 'locked'});
        if (json == null || json.length != 2) return _bad();
        final version = json['expectedVersion'];
        final locked = json['locked'];
        if (version is! int || version < 1 || locked is! bool) return _bad();
        final result = await service.lock(
          ai,
          locked: locked,
          expectedVersion: version,
        );
        return HostResponse.fromResult(result, (change) => _change(ai, change));
      }),
    );
  }
}
