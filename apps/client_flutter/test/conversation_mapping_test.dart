import 'package:client_flutter/app/conversation_mapping.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('groups use name, direct use neutral label, duplicates collapse', () {
    final result = mapConversations(
      groups: [
        {'id': 'g1', 'name': '家人', 'kind': 'group'},
        {'id': 'g2', 'name': '  ', 'kind': 'group'},
      ],
      directs: [
        {'id': 'd1', 'kind': 'direct', 'accountLow': 'a', 'accountHigh': 'b'},
        {'id': 'g1', 'name': '家人重复'},
        {'id': '', 'kind': 'direct'},
        'not-a-map',
      ],
    );
    expect(result.map((e) => e.id), containsAll(['g1', 'g2', 'd1']));
    expect(result.map((e) => e.id).length, 3);
    expect(result.firstWhere((e) => e.id == 'd1').title, '私聊');
    expect(result.firstWhere((e) => e.id == 'g2').title, '会话');
  });

  test('empty and malformed payloads yield an empty list', () {
    expect(mapConversations(groups: null, directs: []), isEmpty);
    expect(mapConversations(groups: 'x', directs: 5), isEmpty);
  });
}
