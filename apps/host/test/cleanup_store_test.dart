/// [InMemoryCleanupStore] 通过统一的 [cleanupStoreContract] 契约测试。
library;

import 'package:jingyu_host/src/lifecycle/cleanup.dart';

import 'cleanup_store_contract.dart';

void main() {
  cleanupStoreContract('InMemoryCleanupStore', () => InMemoryCleanupStore());
}
