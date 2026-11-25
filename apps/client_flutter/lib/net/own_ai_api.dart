import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Current operator metadata only. An AI account is not a configured reply agent.
class OwnedAiAccount {
  const OwnedAiAccount({
    required this.accountId,
    required this.displayName,
    required this.disabled,
  });
  final String accountId;
  final String displayName;
  final bool disabled;
  factory OwnedAiAccount.fromJson(Object? value) {
    if (value is! Map ||
        value['accountId'] is! String ||
        value['displayName'] is! String ||
        value['disabled'] is! bool ||
        (value['displayName'] as String).trim().isEmpty ||
        (value['displayName'] as String).length > 100) {
      throw const FormatException('AI账户响应无效');
    }
    return OwnedAiAccount(
      accountId: AccountId.parse(value['accountId'] as String).value,
      displayName: value['displayName'] as String,
      disabled: value['disabled'] as bool,
    );
  }
}

class OwnAiApi {
  OwnAiApi(this.connection);
  final HostConnection connection;
  Future<List<OwnedAiAccount>> list() async {
    try {
      return List.unmodifiable(
        (await connection.requestList(
          'GET',
          Routes.ownAiAccounts,
        )).map(OwnedAiAccount.fromJson),
      );
    } on FormatException {
      throw const FormatException('AI账户列表响应无效');
    }
  }

  Future<String> create(String displayName) async {
    if (displayName.trim().isEmpty || displayName.length > 100) {
      throw const FormatException('名称须为1–100个字符');
    }
    try {
      final result = await connection.request(
        'POST',
        Routes.ownAiAccounts,
        body: {'displayName': displayName.trim()},
      );
      final id = result['accountId'];
      if (id is! String) throw const FormatException('Invalid ID');
      return AccountId.parse(id).value;
    } on FormatException {
      throw const FormatException('AI账户创建响应无效');
    }
  }

  /// Explicit one-shot logical removal: no body, query, redirect, authentication
  /// replay or automatic retry. A transport or response-validation failure may
  /// follow a committed removal; callers must refresh instead of retrying.
  Future<void> remove(String accountId) async {
    final String id;
    try {
      id = AccountId.parse(accountId).value;
    } on FormatException {
      throw const FormatException('AI账户 ID 无效');
    }
    final path = Routes.ownAiAccount.replaceFirst(
      '{accountId}',
      Uri.encodeComponent(id),
    );
    try {
      final result = await connection.requestBoundedObject(
        'DELETE',
        path,
        maxResponseBytes: 1024,
        expectedStatus: 200,
      );
      if (result.length != 1 || result['removed'] != true) {
        throw const FormatException('AI账户移除响应无效');
      }
    } on FormatException {
      throw const FormatException('AI账户移除响应无效');
    }
  }
}
