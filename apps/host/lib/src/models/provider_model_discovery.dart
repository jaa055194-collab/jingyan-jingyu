import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import '../security/url_guard.dart';
import '../storage/cipher.dart';
import '../storage/database.dart';
import 'openai_chat_adapter.dart';
import 'provider_registry.dart';

/// Owner-scoped OpenAI-compatible catalog lookup for an already-saved provider.
/// No generation, persistence, retries, or inferred model capabilities.
final class ProviderModelDiscovery {
  ProviderModelDiscovery.forOwner({
    required String ownerId,
    required Database db,
    required ColumnCipher cipher,
    required UrlGuard urlGuard,
    required Clock clock,
    GuardedChatRequest? request,
  }) : _registry = ProviderRegistry.forOwner(
         ownerId: ownerId,
         db: db,
         cipher: cipher,
         urlGuard: urlGuard,
         clock: clock,
       ),
       _guard = urlGuard,
       _request = request;

  final ProviderRegistry _registry;
  final UrlGuard _guard;
  final GuardedChatRequest? _request;
  static const _maxResponseBytes = 4 * 1024 * 1024;
  static const _maxModels = 1000;
  static const _maxIdLength = 256;

  Result<List<String>> _unavailable() =>
      err(FailureCode.modelUnavailable, 'Provider model discovery unavailable');

  /// The request callback is a trusted transport boundary and must enforce DNS
  /// pinning, redirect rejection and resource limits (production uses a worker).
  /// Results contain only validated IDs, never upstream metadata or credentials.
  Future<Result<List<String>>> discover(String providerId) async {
    try {
      validateId(providerId, kind: 'provider');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'Invalid provider ID');
    }
    final credential = await _registry.credentialForGateway(providerId);
    if (credential.isErr) return Err(credential.failureOrNull!);
    final request = _request;
    if (request == null) return _unavailable();

    try {
      final config = credential.value;
      final checked = await _guard.check(config.baseUrl);
      if (checked.isErr) {
        return checked.failureOrNull!.code == FailureCode.forbidden
            ? err(FailureCode.forbidden, 'Provider request blocked')
            : _unavailable();
      }
      final base = checked.value;
      // Revalidate URL shape as well as DNS; do not trust persisted URL data.
      if (config.baseUrl.trim() != config.baseUrl ||
          RegExp(r'[\x00-\x20\x7f]').hasMatch(config.baseUrl) ||
          base.hasQuery ||
          base.hasFragment ||
          base.userInfo.isNotEmpty ||
          base.authority.contains('@')) {
        return err(FailureCode.forbidden, 'Provider request blocked');
      }
      final path = base.path.replaceFirst(RegExp(r'/+$'), '');
      final result = await request(
        'GET',
        base.replace(path: '$path/models'),
        headers: {
          'accept': 'application/json',
          'authorization': 'Bearer ${config.apiKey}',
        },
      );
      if (result.isErr) {
        return result.failureOrNull!.code == FailureCode.forbidden
            ? err(FailureCode.forbidden, 'Provider request blocked')
            : _unavailable();
      }
      final response = result.value;
      if (response.statusCode == 401 || response.statusCode == 403) {
        return err(FailureCode.forbidden, 'Provider authorization failed');
      }
      if (response.statusCode == 429) {
        return err(FailureCode.rateLimited, 'Provider rate limit reached');
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        return err(FailureCode.forbidden, 'Provider request blocked');
      }
      if (response.statusCode != 200 ||
          response.body.length > _maxResponseBytes) {
        return _unavailable();
      }
      final payload = jsonDecode(utf8.decode(response.body));
      if (payload is! Map<String, dynamic>) return _unavailable();
      final data = payload['data'];
      if (data is! List || data.length > _maxModels) return _unavailable();
      final ids = <String>{};
      for (final item in data) {
        if (item is! Map<String, dynamic>) return _unavailable();
        final id = item['id'];
        if (id is! String ||
            id.trim().isEmpty ||
            id.trim() != id ||
            id.length > _maxIdLength ||
            RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(id) ||
            id.contains(config.apiKey)) {
          return _unavailable();
        }
        ids.add(id);
      }
      return Ok(List<String>.unmodifiable(ids));
    } catch (_) {
      // Upstream exceptions and JSON may echo credentials. Never retain details.
      return _unavailable();
    }
  }
}
