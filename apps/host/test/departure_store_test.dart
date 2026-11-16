/// [InMemoryDepartureStore] 通过统一的 [departureStoreContract] 契约测试。
library;

import 'package:jingyu_host/src/lifecycle/departure.dart';

import 'departure_store_contract.dart';

void main() {
  departureStoreContract(
    'InMemoryDepartureStore',
    () => InMemoryDepartureStore(),
    (store) async {
      (store as InMemoryDepartureStore).seed('u1', {
        'conversations': 2,
        'messages': 10,
        'memories': 5,
        'attachments': 4,
      }, moments: 3);
    },
  );
}
