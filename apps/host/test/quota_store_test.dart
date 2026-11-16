/// [InMemoryQuotaStore] 通过统一的 [quotaStoreContract] 契约测试。
library;

import 'package:jingyu_host/src/lifecycle/quota_service.dart';

import 'quota_store_contract.dart';

void main() {
  quotaStoreContract('InMemoryQuotaStore', () => InMemoryQuotaStore());
}
