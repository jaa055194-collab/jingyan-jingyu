import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'provider_registry.dart';

/// Cumulative known tokens from all currently retained ledger rows.
/// Exact BigInt aggregation scans/materializes the ledger; it is not bounded
/// runtime/memory or billing, and unknown rows make recorded totals incomplete.
final class AdminUsageReader {
  AdminUsageReader({required this.database, required this.clock});
  final Database database;
  final Clock clock;
  static final _decimal = RegExp(r'^(0|[1-9][0-9]*)$');
  BigInt _counter(Object? value) {
    if (value is! String || !_decimal.hasMatch(value)) {
      throw const FormatException('Invalid recorded counter');
    }
    return BigInt.parse(value);
  }

  Future<Result<Map<String, Object?>>> summary({
    required String bearer,
    required String accountId,
    required String deviceId,
  }) async {
    if (bearer.length != 22) {
      return err(FailureCode.unauthenticated, 'Invalid credentials');
    }
    final digest = sha256.convert(utf8.encode(bearer)).toString();
    return database.transaction((tx) async {
      final credentials = await tx.query(
        '''
SELECT a.kind,a.is_admin,a.disabled FROM device d
JOIN account a ON a.id=d.account_id
JOIN refresh_token r ON r.device_id=d.id
WHERE d.access_hash=? AND d.id=? AND d.account_id=? AND d.access_expires>?
''',
        [digest, deviceId, accountId, clock.now().millisecondsSinceEpoch],
      );
      if (credentials.isEmpty || credentials.single['disabled'] != 0) {
        return err(FailureCode.unauthenticated, 'Invalid credentials');
      }
      if (credentials.single['kind'] != 'human' ||
          credentials.single['is_admin'] != 1) {
        return err(FailureCode.forbidden, 'Administrator required');
      }
      final rows = await tx.query('''
SELECT layer,capability,input_tokens,output_tokens,total_tokens,source_usage_unknown
FROM usage_ledger
''');
      final layers = {
        for (final layer in BudgetLayer.values) layer.name: BigInt.zero,
      };
      final capabilities = {
        for (final cap in ProviderCapability.values) cap.name: BigInt.zero,
      };
      var total = BigInt.zero;
      var unknown = false;
      try {
        for (final row in rows) {
          final layer = row['layer'];
          final capability = row['capability'];
          if (!layers.containsKey(layer) ||
              !capabilities.containsKey(capability)) {
            throw const FormatException('Invalid recorded category');
          }
          if (row['source_usage_unknown'] == 1) {
            if (row['input_tokens'] != null ||
                row['output_tokens'] != null ||
                row['total_tokens'] != null) {
              throw const FormatException('Invalid pending usage');
            }
            unknown = true;
            continue;
          }
          if (row['source_usage_unknown'] != 0) {
            throw const FormatException('Invalid recorded status');
          }
          final input = _counter(row['input_tokens']);
          final output = _counter(row['output_tokens']);
          final used = _counter(row['total_tokens']);
          if (input + output != used) {
            throw const FormatException('Inconsistent recorded counters');
          }
          total += used;
          layers[layer as String] = layers[layer]! + used;
          capabilities[capability as String] = capabilities[capability]! + used;
        }
      } on FormatException {
        return err(FailureCode.internal, 'Stored usage cannot be decoded');
      }
      return Ok<Map<String, Object?>>({
        'basis': 'allRecordedLedgerRows',
        'recordedTokens': total.toString(),
        'byLayer': {for (final e in layers.entries) e.key: e.value.toString()},
        'byCapability': {
          for (final e in capabilities.entries) e.key: e.value.toString(),
        },
        'sourceUsageUnknown': unknown,
      });
    });
  }
}
