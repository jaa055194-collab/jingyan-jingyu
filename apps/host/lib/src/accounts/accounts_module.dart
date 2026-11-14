import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'accounts_rate_limiter.dart';
import 'db_authenticator.dart';

/// HTTP boundary for accounts. The host supplies shared admin route constants
/// and a trusted transport-IP accessor when assembling this module.
class AccountsModule extends HostModule {
  AccountsModule({
    required this.domain,
    this.adminAccountsPath = Routes.adminAccounts,
    this.adminInvitesPath = Routes.adminInvites,
    String Function(HostRequest)? peerIp,
  }) : peerIp = peerIp ?? _trustedIp,
       limiter = AccountsRateLimiter(clock: domain.clock);

  final AccountsDomain domain;
  final String adminAccountsPath;
  final String adminInvitesPath;
  final String Function(HostRequest) peerIp;
  final AccountsRateLimiter limiter;
  static String _trustedIp(HostRequest request) =>
      request.remoteAddress ?? 'unknown';

  @override
  String get name => 'accounts';
  @override
  List<String> get dependsOn => const ['storage'];
  @override
  Future<void> configure(HostServices services) async {
    services.provide<AccountsDomain>(domain, owner: name);
  }

  @override
  Future<void> start() async {
    // Initialize module-owned migrations before the host accepts requests.
    await domain.store.snapshot();
  }

  @override
  void mount(Router router) {
    router.post(Routes.authInviteRedeem, _redeem, access: Access.public);
    router.post(Routes.authLogin, _login, access: Access.public);
    router.post(Routes.authRefresh, _refresh, access: Access.public);
    router.get(Routes.authDevices, _devices);
    router.post(Routes.authDeviceRevoke, _revoke);
    router.get(Routes.ownAiAccounts, _ownAi);
    router.post(Routes.ownAiAccounts, _createOwnAi);
    router.post(adminInvitesPath, _invite, access: Access.admin);
    router.get(adminAccountsPath, _accounts, access: Access.admin);
    router.post(adminAccountsPath, _create, access: Access.admin);
    router.post(
      Routes.adminAccountPasswordReset,
      _resetPassword,
      access: Access.admin,
    );
  }

  HostResponse _bad() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid input'),
  );
  HostResponse _limited() => HostResponse.failure(
    const Failure(FailureCode.rateLimited, 'Rate limited'),
  );
  Future<Result<AccountSession>> _session(HostRequest request) {
    final header = request.headers['authorization'] ?? '';
    return domain.scope(
      header.startsWith('Bearer ') ? header.substring(7).trim() : '',
    );
  }

  Future<({AccountSession session, AccountId actor})?> _currentSession(
    HostRequest request,
  ) async {
    final principal = request.principal;
    if (principal == null) return null;
    final scoped = await _session(request);
    if (scoped.isErr) return null;
    final header = request.headers['authorization'] ?? '';
    final current = await domain.authenticate(
      header.startsWith('Bearer ') ? header.substring(7).trim() : '',
    );
    if (current == null ||
        current.accountId != principal.accountId ||
        current.deviceId != principal.deviceId) {
      return null;
    }
    return (session: scoped.value, actor: AccountId.parse(current.accountId));
  }

  HostResponse _unauthenticated() => HostResponse.failure(
    const Failure(FailureCode.unauthenticated, 'Invalid credentials'),
  );

  Future<HostResponse> _ownAi(HostRequest request) async {
    final scope = await _currentSession(request);
    if (scope == null) return _unauthenticated();
    return HostResponse.fromResult(await scope.session.ownAiMetadata());
  }

  Future<HostResponse> _createOwnAi(HostRequest request) async {
    final scope = await _currentSession(request);
    if (scope == null) return _unauthenticated();
    final body = request.jsonObject().valueOrNull;
    if (body == null || body.length != 1 || body['displayName'] is! String) {
      return _bad();
    }
    return HostResponse.fromResult(
      await scope.session.accounts.createAi(
        operator: scope.actor,
        displayName: body['displayName'] as String,
      ),
      (id) => {'accountId': id.value},
    );
  }

  Future<HostResponse> _resetPassword(HostRequest request) async {
    final scope = await _currentSession(request);
    if (scope == null) return _unauthenticated();
    final body = request.jsonObject().valueOrNull;
    if (body == null || body.length != 1 || body['newPassword'] is! String) {
      return _bad();
    }
    final AccountId target;
    try {
      target = AccountId.parse(request.pathParams['accountId'] ?? '');
    } on FormatException {
      return _bad();
    }
    final result = await scope.session.accounts.resetPassword(
      target,
      body['newPassword'] as String,
    );
    return HostResponse.fromResult(result, (_) => {'reset': true});
  }

  Future<HostResponse> _login(HostRequest request) async {
    final body = request.jsonObject().valueOrNull;
    if (body == null) return _bad();
    final id = body['accountId'];
    final password = body['password'];
    final name = body['deviceName'];
    if (id is! String || password is! String || name is! String) return _bad();
    AccountId account;
    try {
      account = AccountId.parse(id);
    } on FormatException {
      return _bad();
    }
    if (!limiter.allow(ip: peerIp(request), account: id)) return _limited();
    return HostResponse.fromResult(
      await domain.login(account, password, deviceName: name),
      (t) => t.toJson(),
    );
  }

  Future<HostResponse> _redeem(HostRequest request) async {
    final body = request.jsonObject().valueOrNull;
    if (body == null) return _bad();
    final code = body['code'];
    final name = body['displayName'];
    final password = body['password'];
    if (code is! String || name is! String || password is! String) {
      return _bad();
    }
    if (code.length > 128 ||
        !limiter.allow(ip: peerIp(request), invite: code)) {
      return _limited();
    }
    return HostResponse.fromResult(
      await domain.redeem(code, displayName: name, password: password),
      (id) => {'accountId': id.value},
    );
  }

  Future<HostResponse> _refresh(HostRequest request) async {
    final token = request.jsonObject().valueOrNull?['refreshToken'];
    if (token is! String) return _bad();
    if (!limiter.allow(ip: peerIp(request))) return _limited();
    return HostResponse.fromResult(
      await domain.refresh(token),
      (t) => t.toJson(),
    );
  }

  Future<HostResponse> _devices(HostRequest request) async {
    final session = await _session(request);
    if (session.isErr) return HostResponse.failure(session.failureOrNull!);
    return HostResponse.ok(
      (await session.value.devices.list(
        AccountId.parse(request.principal!.accountId),
      )).map((d) => d.toJson()).toList(),
    );
  }

  Future<HostResponse> _revoke(HostRequest request) async {
    DeviceId device;
    try {
      device = DeviceId.parse(request.pathParams['deviceId'] ?? '');
    } on FormatException {
      return _bad();
    }
    final session = await _session(request);
    if (session.isErr) return HostResponse.failure(session.failureOrNull!);
    return HostResponse.fromResult(
      await session.value.devices.revoke(
        AccountId.parse(request.principal!.accountId),
        device,
      ),
    );
  }

  Future<HostResponse> _invite(HostRequest request) async {
    final body = request.jsonObject().valueOrNull;
    if (body == null) return _bad();
    final expires = body['expiresAt'];
    final uses = body['maxUses'] ?? 1;
    final at = expires is String ? DateTime.tryParse(expires) : null;
    if (at == null || uses is! int) return _bad();
    final session = await _session(request);
    if (session.isErr) return HostResponse.failure(session.failureOrNull!);
    return HostResponse.fromResult(
      await session.value.invites.issue(expiresAt: at, maxUses: uses),
      (code) => {'code': code},
    );
  }

  Future<HostResponse> _accounts(HostRequest request) async {
    final session = await _session(request);
    if (session.isErr) return HostResponse.failure(session.failureOrNull!);
    return HostResponse.fromResult(await session.value.accountMetadata());
  }

  Future<HostResponse> _create(HostRequest request) async {
    final body = request.jsonObject().valueOrNull;
    if (body == null) return _bad();
    final name = body['displayName'];
    final password = body['password'];
    if (name is! String || password is! String) return _bad();
    final session = await _session(request);
    if (session.isErr) return HostResponse.failure(session.failureOrNull!);
    return HostResponse.fromResult(
      await session.value.accounts.createHuman(
        displayName: name,
        password: password,
      ),
      (id) => {'accountId': id.value},
    );
  }
}
