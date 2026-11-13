import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../security/url_guard.dart';
import '../storage/cipher.dart';
import '../storage/database.dart';

/// M05 capabilities; chatFast is the chat.fast sub-binding, not a fallback.
enum ProviderCapability {
  chat,
  chatFast,
  vision,
  imageGen,
  tts,
  asr,
  embedding,
}

/// The only provider representation suitable for responses or exports.
final class ProviderView {
  ProviderView({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.keyMask,
    required this.enabled,
    required Set<ProviderCapability> capabilities,
  }) : capabilities = Set.unmodifiable(capabilities);

  final String id;
  final String name;
  final String baseUrl;
  final String keyMask;
  final bool enabled;
  final Set<ProviderCapability> capabilities;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'base_url': baseUrl,
    'key_mask': keyMask,
    'enabled': enabled,
    'capabilities': capabilities.map((c) => c.name).toList(),
  };
}

/// Internal gateway input only. Never return this object through an HTTP route,
/// audit, log or export. The gateway must recheck UrlGuard at request time and
/// each redirect; saving a URL does not pin future DNS results.
/// No JSON serializer is provided and diagnostics deliberately omit the key.
final class ProviderGatewayConfig {
  const ProviderGatewayConfig._(this.providerId, this.baseUrl, this.apiKey);
  final String providerId;
  final String baseUrl;
  final String apiKey;

  @override
  String toString() => 'ProviderGatewayConfig(<redacted>)';
}

/// Owner-scoped provider repository only. Model discovery, connection tests,
/// bindings, account defaults and budgets are deferred to later M05 slices.
/// Construct only from the authenticated principal, never an owner in a body.
final class ProviderRegistry {
  ProviderRegistry.forOwner({
    required String ownerId,
    required Database db,
    required ColumnCipher cipher,
    required UrlGuard urlGuard,
    required Clock clock,
  }) : _ownerId = validateId(ownerId, kind: 'owner'),
       _db = db,
       _cipher = cipher,
       _urlGuard = urlGuard,
       _clock = clock;

  final String _ownerId;
  final Database _db;
  final ColumnCipher _cipher;
  final UrlGuard _urlGuard;
  final Clock _clock;
  final Random _random = Random.secure();

  String _aad(String id) => '$_ownerId:$id:api_key';
  String _mask(String key) =>
      key.length <= 4 ? '****' : '****${key.substring(key.length - 4)}';
  bool _validKey(String key) =>
      key.trim().isNotEmpty && !RegExp(r'[\x00-\x20\x7f*•]').hasMatch(key);

  Future<Result<String>> _checkedUrl(String raw) async {
    final checked = await _urlGuard.check(raw);
    if (checked case Err<Uri>(:final failure)) return Err(failure);
    final uri = checked.value;
    if (raw.trim() != raw ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(raw) ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        // Also reject an explicitly empty userinfo component.
        uri.authority.contains('@')) {
      return err(
        FailureCode.invalidArgument,
        'Base URL must not contain credentials, query or fragment',
      );
    }
    return Ok(raw);
  }

  ProviderView _view(Map<String, Object?> row) => ProviderView(
    id: row['id'] as String,
    name: row['name'] as String,
    baseUrl: row['base_url'] as String,
    keyMask: row['key_mask'] as String,
    enabled: row['enabled'] == 1,
    capabilities: (jsonDecode(row['capabilities'] as String) as List)
        .map((c) => ProviderCapability.values.byName(c as String))
        .toSet(),
  );

  static const _viewColumns =
      'id, name, base_url, key_mask, enabled, capabilities';

  Future<Result<ProviderView>> create({
    required String name,
    required String baseUrl,
    required String apiKey,
    required Set<ProviderCapability> capabilities,
    bool enabled = true,
  }) async {
    if (name.trim().isEmpty || !_validKey(apiKey)) {
      return err(
        FailureCode.invalidArgument,
        'Invalid provider name or API key',
      );
    }
    final url = await _checkedUrl(baseUrl);
    if (url case Err<String>(:final failure)) return Err(failure);
    final id =
        'p_${_clock.now().microsecondsSinceEpoch.toRadixString(16)}_${List.generate(16, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    final mask = _mask(apiKey);
    await _db.execute(
      'INSERT INTO providers (owner_id, id, name, base_url, encrypted_key, key_mask, enabled, capabilities) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      [
        _ownerId,
        id,
        name,
        url.value,
        _cipher.encrypt(apiKey, aad: _aad(id)),
        mask,
        enabled ? 1 : 0,
        jsonEncode(capabilities.map((c) => c.name).toList()),
      ],
    );
    return Ok(
      ProviderView(
        id: id,
        name: name,
        baseUrl: url.value,
        keyMask: mask,
        enabled: enabled,
        capabilities: capabilities,
      ),
    );
  }

  Future<Result<ProviderView>> get(String id) async {
    final rows = await _db.query(
      'SELECT $_viewColumns FROM providers WHERE owner_id = ? AND id = ?',
      [_ownerId, id],
    );
    return rows.isEmpty
        ? err(FailureCode.notFound, 'Provider not found')
        : Ok(_view(rows.single));
  }

  Future<Result<List<ProviderView>>> list() async => Ok([
    for (final row in await _db.query(
      'SELECT $_viewColumns FROM providers WHERE owner_id = ? ORDER BY id',
      [_ownerId],
    ))
      _view(row),
  ]);

  /// Omitted key preserves the encrypted column. Masks and empty values are
  /// rejected rather than accidentally overwriting a working credential.
  Future<Result<ProviderView>> update(
    String id, {
    String? name,
    String? baseUrl,
    String? apiKey,
    Set<ProviderCapability>? capabilities,
    bool? enabled,
  }) async {
    final existing = await get(id);
    if (existing case Err<ProviderView>(:final failure)) return Err(failure);
    if ((name != null && name.trim().isEmpty) ||
        (apiKey != null && !_validKey(apiKey))) {
      return err(
        FailureCode.invalidArgument,
        'Invalid provider name or API key',
      );
    }
    final url = await _checkedUrl(baseUrl ?? existing.value.baseUrl);
    if (url case Err<String>(:final failure)) return Err(failure);
    final fields = <String>['base_url = ?'];
    final args = <Object?>[url.value];
    void set(String column, Object value) {
      fields.add('$column = ?');
      args.add(value);
    }

    if (name != null) set('name', name);
    if (enabled != null) set('enabled', enabled ? 1 : 0);
    if (capabilities != null) {
      set('capabilities', jsonEncode(capabilities.map((c) => c.name).toList()));
    }
    if (apiKey != null) {
      set('encrypted_key', _cipher.encrypt(apiKey, aad: _aad(id)));
      set('key_mask', _mask(apiKey));
    }
    final count = await _db.execute(
      'UPDATE providers SET ${fields.join(', ')} WHERE owner_id = ? AND id = ?',
      [...args, _ownerId, id],
    );
    if (count == 0) return err(FailureCode.notFound, 'Provider not found');
    return get(id);
  }

  /// Bound providers cannot be deleted until the caller explicitly unbinds.
  /// Check and deletion share one transaction so binding creation cannot race.
  Future<Result<void>> delete(String id) => _db.transaction((tx) async {
    final present = await tx.query(
      'SELECT id FROM providers WHERE owner_id = ? AND id = ?',
      [_ownerId, id],
    );
    if (present.isEmpty) return err(FailureCode.notFound, 'Provider not found');
    final hasBindings = await tx.query(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'model_bindings'",
    );
    if (hasBindings.isNotEmpty &&
        (await tx.query(
          'SELECT 1 FROM model_bindings WHERE owner_id = ? AND provider_id = ? LIMIT 1',
          [_ownerId, id],
        )).isNotEmpty) {
      return err(FailureCode.conflict, 'Provider has active bindings');
    }
    await tx.execute('DELETE FROM providers WHERE owner_id = ? AND id = ?', [
      _ownerId,
      id,
    ]);
    return const Ok(null);
  });

  /// Internal owner/provider-limited credential retrieval for a trusted gateway.
  /// No HTTP endpoint exposes this method or its secret-bearing return value.
  Future<Result<ProviderGatewayConfig>> credentialForGateway(
    String providerId,
  ) async {
    final rows = await _db.query(
      'SELECT id, base_url, enabled, encrypted_key FROM providers WHERE owner_id = ? AND id = ?',
      [_ownerId, providerId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'Provider not found');
    final row = rows.single;
    if (row['enabled'] != 1) {
      return err(FailureCode.modelUnavailable, 'Provider disabled');
    }
    final key = _cipher.decrypt(
      row['encrypted_key'] as String,
      aad: _aad(providerId),
    );
    if (key.isErr) {
      return err(FailureCode.internal, 'Provider credential unavailable');
    }
    return Ok(
      ProviderGatewayConfig._(providerId, row['base_url'] as String, key.value),
    );
  }
}
