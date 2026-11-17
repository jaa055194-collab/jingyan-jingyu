import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart' show HostRequestException;

/// A validated device session. Passwords and invitation codes are never stored.
class ClientCredentials {
  ClientCredentials._({
    required this.host,
    required this.accountId,
    required this.deviceId,
    required this.accessToken,
    required this.refreshToken,
  });

  final Uri host;
  final String accountId;
  final String deviceId;
  final String accessToken;
  final String refreshToken;

  factory ClientCredentials.fromJson(Map<String, Object?> json) =>
      ClientCredentials._(
        host: _hostOrigin(_requiredString(json, 'host')),
        accountId: _checkedId(_requiredString(json, 'accountId'), 'account'),
        deviceId: _checkedId(_requiredString(json, 'deviceId'), 'device'),
        accessToken: _requiredString(json, 'accessToken'),
        refreshToken: _requiredString(json, 'refreshToken'),
      );

  Map<String, Object?> toJson() => {
    'host': host.toString(),
    'accountId': accountId,
    'deviceId': deviceId,
    'accessToken': accessToken,
    'refreshToken': refreshToken,
  };
}

/// Performs invitation redemption followed by device login over host HTTP APIs.
class AccountAuthenticator {
  ({Uri host, String invite, String displayName})? _redemption;
  String? _redeemedAccountId;

  /// Available immediately after successful redemption, even if login failed.
  String? get redeemedAccountId => _redeemedAccountId;

  Future<ClientCredentials> connect({
    required String hostAddress,
    required String password,
    required String deviceName,
    String invite = '',
    String displayName = '',
    String accountId = '',
  }) async {
    final host = _hostOrigin(hostAddress);
    var id = accountId.isEmpty ? '' : _checkedId(accountId, 'account');
    final redemption = (host: host, invite: invite, displayName: displayName);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      if (id.isEmpty) {
        if (_redemption != redemption) {
          _redemption = null;
          _redeemedAccountId = null;
        }
        if (_redeemedAccountId == null) {
          final redeemed = await _post(client, host, Routes.authInviteRedeem, {
            'code': invite,
            'displayName': displayName,
            'password': password,
          });
          id = _checkedId(_requiredString(redeemed, 'accountId'), 'account');
          _redemption = redemption;
          _redeemedAccountId = id;
        } else {
          id = _redeemedAccountId!;
        }
      }
      final session = await _post(client, host, Routes.authLogin, {
        'accountId': id,
        'password': password,
        'deviceName': deviceName,
      });
      // The login route returns only device tokens; account and host are local
      // trusted context and must not be overridden by unexpected response keys.
      return ClientCredentials.fromJson({
        'host': host.toString(),
        'accountId': id,
        'deviceId': session['deviceId'],
        'accessToken': session['accessToken'],
        'refreshToken': session['refreshToken'],
      });
    } on FormatException {
      throw const FormatException('Invalid host authentication response');
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, 'Host authentication timed out'),
      );
    } on IOException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, 'Host authentication unavailable'),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Rotates tokens on the existing device without changing snapshot identity.
  Future<ClientCredentials> refresh(ClientCredentials current) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final session = await _post(client, current.host, Routes.authRefresh, {
        'refreshToken': current.refreshToken,
      });
      final refreshed = ClientCredentials.fromJson({
        'host': current.host.toString(),
        'accountId': current.accountId,
        'deviceId': session['deviceId'],
        'accessToken': session['accessToken'],
        'refreshToken': session['refreshToken'],
      });
      if (refreshed.deviceId != current.deviceId) {
        throw const FormatException('Host refresh changed device identity');
      }
      return refreshed;
    } on FormatException {
      throw const FormatException('Invalid host authentication response');
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, 'Host authentication timed out'),
      );
    } on IOException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, 'Host authentication unavailable'),
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<Map<String, Object?>> _post(
    HttpClient client,
    Uri host,
    String route,
    Map<String, Object?> body,
  ) async {
    final request = await client
        .postUrl(host.replace(path: route))
        .timeout(const Duration(seconds: 15));
    // Never send credentials to a redirected origin (including HTTPS -> HTTP).
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close().timeout(const Duration(seconds: 15));
    final text = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 15));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      // Do not include the upstream body: even host/proxy errors may echo secrets.
      final code = switch (response.statusCode) {
        400 => FailureCode.invalidArgument,
        401 => FailureCode.unauthenticated,
        403 => FailureCode.forbidden,
        404 => FailureCode.notFound,
        409 => FailureCode.conflict,
        429 => FailureCode.rateLimited,
        _ => FailureCode.unavailable,
      };
      throw HostRequestException(
        Failure(code, 'Host authentication failed (${response.statusCode})'),
      );
    }
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid host authentication response');
    }
    return decoded;
  }
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw const FormatException('Invalid client credentials');
  }
  return value;
}

String _checkedId(String value, String kind) {
  try {
    return validateId(value, kind: kind);
  } on FormatException {
    // validateId attaches its input as source; never expose untrusted payloads.
    throw const FormatException('Invalid account or device identifier');
  }
}

Uri _hostOrigin(String address) {
  const invalid = FormatException('Invalid host origin; HTTPS is required');
  try {
    // Uri.parse normalizes empty userinfo, backslashes and dot segments away.
    // Validate the supplied shape first so none can masquerade as an origin.
    if (!RegExp(
      r'^https?://[^/?#@\s\\]+/?$',
      caseSensitive: false,
    ).hasMatch(address)) {
      throw invalid;
    }
    final uri = Uri.parse(address);
    if (!uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.port < 1 ||
        uri.port > 65535) {
      throw invalid;
    }
    final ip = InternetAddress.tryParse(uri.host);
    final loopback = uri.host == 'localhost' || (ip?.isLoopback ?? false);
    if (uri.scheme == 'http' && !loopback) throw invalid;
    return Uri.parse(uri.origin);
  } on FormatException {
    // Uri.parse errors can contain URL userinfo; return no raw input or source.
    throw invalid;
  }
}
