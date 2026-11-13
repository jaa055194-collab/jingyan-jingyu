@Timeout(Duration(minutes: 10))
library;

import 'package:test/test.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/accounts_store.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';

import 'accounts_domain_contract.dart';
import 'accounts_store_contract.dart';

void main() {
  accountsStoreContract('memory', InMemoryAccountsStore.new);
  accountsDomainContract('memory', () async => InMemoryAccountsStore());

  late SqliteDatabase database;
  accountsDomainContract('SQLite', () async {
    database = await SqliteDatabase.open(':memory:');
    final store = SqlAccountsStore(database);
    await store.start();
    return store;
  }, cleanup: () => database.close());
}
