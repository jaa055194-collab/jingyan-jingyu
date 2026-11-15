import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import 'file_persistence.dart';

/// A private index maps validated host/account/device identity to a random
/// filename. Legacy unscoped client.json is deliberately never read/migrated.
class AccountSnapshots {
  AccountSnapshots(this.root);
  final Directory root;
  static final Map<String, Future<void>> _pending = {};

  Future<FilePersistence> open(
    Uri host,
    String accountId,
    String deviceId,
  ) async {
    validateId(accountId, kind: 'account');
    validateId(deviceId, kind: 'device');
    if (!host.hasAuthority ||
        !['http', 'https'].contains(host.scheme) ||
        host.userInfo.isNotEmpty ||
        host.hasQuery ||
        host.hasFragment ||
        (host.path.isNotEmpty && host.path != '/')) {
      throw const FormatException('Invalid host origin');
    }
    final identity = jsonEncode([host.origin, accountId, deviceId]);
    final indexPath = '${root.absolute.path}/accounts/index.json';
    final previous = _pending[indexPath] ?? Future<void>.value();
    late String filename;
    final operation = previous.then((_) async {
      final index = File(indexPath);
      var entries = <String, Object?>{};
      if (await index.exists()) {
        final decoded = jsonDecode(await index.readAsString());
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Invalid identity index');
        }
        entries = decoded;
      }
      final existing = entries[identity];
      if (existing != null) {
        if (existing is! String ||
            !RegExp(r'^[a-f0-9]{32}$').hasMatch(existing)) {
          throw const FormatException('Invalid identity snapshot reference');
        }
        filename = existing;
      } else {
        final random = Random.secure();
        do {
          filename = List.generate(
            16,
            (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
        } while (entries.values.contains(filename));
        entries[identity] = filename;
        await index.parent.create(recursive: true);
        final temporary = File('$indexPath.tmp');
        await temporary.writeAsString(jsonEncode(entries), flush: true);
        await temporary.rename(indexPath);
      }
    });
    _pending[indexPath] = operation.then(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await operation;
    return FilePersistence(File('${root.path}/accounts/$filename.json'));
  }
}
