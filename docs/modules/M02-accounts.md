# M02 · accounts：邀请码、登录、设备、管理员

> 依据：v4.2 FR-04/05/06/07、AC-02；口径 C-4（管理员只有一个）。依赖：storage。

## 目标

替换框架里的 `StaticTokenAuthenticator`：真实的账号、邀请码、密码登录、设备 token、设备上限、管理员。

## 允许新增的依赖

- `crypto`（sha256）。密码哈希用 Argon2id；若 pub.dev 没有可用的纯 Dart 实现，用 PBKDF2-HMAC-SHA256、至少 600000 轮，并在 PR 里说明。

## 要写的文件

```text
apps/host/lib/src/accounts/
  accounts_module.dart     name 'accounts'，dependsOn ['storage']
  account_service.dart     abstract class AccountService
  device_service.dart      abstract class DeviceService
  invite_service.dart      abstract class InviteService
  password_hasher.dart
  db_authenticator.dart    实现 Authenticator 签名，替换 buildHost 里的 auth
  accounts_migrations.dart 迁移 100–199：account、ai_operator、device、invite、refresh_token
apps/host/test/accounts_test.dart
```

## 接口

```dart
enum AccountKind { human, ai }

abstract class AccountService {
  Future<Result<AccountId>> createHuman({required String displayName, required String password});
  Future<Result<AccountId>> createAi({required AccountId operator, required String displayName});
  Future<Result<void>> disable(AccountId id);
  Future<Result<void>> resetPassword(AccountId id, String newPassword); // 仅管理员
  Future<bool> isOperatorOf(AccountId human, AccountId ai);
}

abstract class InviteService {
  /// 返回明文邀请码（128-bit，base64url），只此一次；库里只存 sha256。
  Future<Result<String>> issue({required DateTime expiresAt, int maxUses = 1});
  /// 兑换：必须在一个事务里检查并递增 used_count，防并发双花。
  Future<Result<AccountId>> redeem(String code, {required String displayName, required String password});
  Future<Result<void>> revoke(String inviteId);
}

abstract class DeviceService {
  /// 登录成功后调用。超过 2 台时踢掉最久未使用的一台并立即吊销其 token。
  Future<Result<DeviceTokens>> register(AccountId account, {required String deviceName});
  Future<Result<DeviceTokens>> refresh(String refreshToken);
  Future<List<DeviceInfo>> list(AccountId account);
  Future<Result<void>> revoke(AccountId account, DeviceId device);
}
```

## 路由

在 `Routes` 已有的 `authLogin`、`authRefresh`、`authDevices`、`authDeviceRevoke` 上实现。新增：`/api/v1/admin/invites`（POST，`Access.admin`）、`/api/v1/admin/accounts`（GET/POST，`Access.admin`）。

## 规则

1. token 与 refresh token 只存 sha256，不存明文。
2. 失败锁定按账号：连续 5 次失败锁 15 分钟。限流维度：IP + 账号 + 邀请码。
3. 管理员接口只返回元数据（账号名、状态、设备数、用量），**不返回**任何正文、记忆、key（FR-07）。
4. 管理员只有一个：首次初始化脚本创建，之后不能再创建第二个管理员。
5. 吊销后下一次请求立即 401（框架已有测试，替换实现后必须仍然通过）。

## 验收

- [ ] AC-02a 同一邀请码 20 个并发兑换，只有 `maxUses` 个成功。
- [ ] AC-02b 过期、已吊销、已用尽的邀请码兑换失败。
- [ ] AC-02c 连续 5 次密码错误后锁定；锁定期内正确密码也失败。
- [ ] AC-02d 第 3 台设备登录后最久未用的设备 token 立即 401。
- [ ] AC-02e 远程下线设备后其 token 立即 401。
- [ ] FR-04 AI 账号必须有 operator；非 operator 不能管理该 AI。
- [ ] FR-07 管理员接口响应里搜不到任何消息正文（注入一条已知正文后断言）。
- [ ] 库里搜不到明文密码、明文 token、明文邀请码。
