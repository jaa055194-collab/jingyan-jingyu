/// Trusted one-time administrator initialization. Does not bind an HTTP port.
///
/// Run `dart run bin/init_accounts.dart` with JINGYU_ADMIN_NAME and
/// JINGYU_ADMIN_PASSWORD supplied by the process environment. JINGYU_DATA_DIR
/// selects the same persistent database used by bin/server.dart.
library;

import 'dart:io';

import 'package:jingyu_host/jingyu_host.dart';

Future<void> main() async {
  final name = Platform.environment['JINGYU_ADMIN_NAME'];
  final password = Platform.environment['JINGYU_ADMIN_PASSWORD'];
  if (name == null || password == null) {
    stderr.writeln('Set JINGYU_ADMIN_NAME and JINGYU_ADMIN_PASSWORD.');
    exitCode = 64;
    return;
  }

  Host? host;
  try {
    host = await buildHost(
      config: HostConfig.fromEnvironment(Platform.environment),
    );
    final result = await host.auth.bootstrapAdmin(
      displayName: name,
      password: password,
    );
    if (result.isErr) {
      stderr.writeln(
        'Administrator initialization failed: ${result.failureOrNull!.code.name}',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln('Administrator account: ${result.value.value}');
  } catch (error) {
    // Do not render exception contents: environment secrets must never be logged.
    stderr.writeln('Administrator initialization failed: ${error.runtimeType}');
    exitCode = 1;
  } finally {
    if (host != null) {
      final errors = await host.shutdown();
      if (errors.isNotEmpty) {
        stderr.writeln('Host shutdown failed.');
        exitCode = 1;
      }
    }
  }
}
