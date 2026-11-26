import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/world/street3d_protocol.dart';
import 'package:client_flutter/features/world/street3d_source.dart';
import 'package:client_flutter/net/friends_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/world_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';

final _now = DateTime.utc(2026, 11, 26);
const _missing = HostRequestException(
  Failure(FailureCode.notFound, 'layout not found'),
);
const _down = HostRequestException(Failure(FailureCode.unavailable, 'down'));

WorldSpaceLayout _layout(String id) => WorldSpaceLayout(
  spaceId: id,
  version: 2,
  style: 'forest',
  mainColor: null,
  rooms: const [],
  updatedAt: _now,
);

WorldPresenceRecord _rec(String id, String spaceId) => WorldPresenceRecord(
  residentId: id,
  spaceId: spaceId,
  x: 0,
  y: 0,
  z: -2,
  motion: 'idle',
  updatedAt: _now,
);

// Each map value is the answer for that space: a layout or presence list, or
// the error to throw. Spaces that are not listed answer notFound.
HostStreet3DDataSource _source({
  Map<String, Object> layouts = const {},
  Map<String, Object> presence = const {},
  List<FriendContact> friends = const [],
  Object? friendsError,
  List<ShellOwnedAi> ownAis = const [],
  List<String>? reads,
}) => HostStreet3DDataSource(
  selfId: 'alice',
  ownAis: ownAis,
  readLayout: (id) async {
    reads?.add(id);
    final answer = layouts[id] ?? _missing;
    if (answer is WorldSpaceLayout) return answer;
    throw answer;
  },
  readPresence: (id) async {
    final answer = presence[id] ?? _missing;
    if (answer is List<WorldPresenceRecord>) return answer;
    throw answer;
  },
  readFriends: () async {
    final error = friendsError;
    if (error != null) throw error;
    return friends;
  },
);

void main() {
  test(
    'the street holds the account, its AIs and its friends that have a villa',
    () async {
      final street = await _source(
        ownAis: const [
          ShellOwnedAi(accountId: 'ai1', displayName: '小鲸', disabled: false),
          ShellOwnedAi(accountId: 'ai2', displayName: '停用', disabled: true),
        ],
        friends: const [
          FriendContact(
            accountId: 'bob',
            displayName: '阿青',
            state: FriendState.friends,
          ),
          FriendContact(
            accountId: 'carol',
            displayName: '待通过',
            state: FriendState.outgoingPending,
          ),
        ],
        layouts: {
          'alice': _layout('alice'),
          'ai2': _layout('ai2'),
          'bob': _layout('bob'),
          'carol': _layout('carol'),
        },
      ).loadStreet();
      // ai1 has saved no layout yet, ai2 is disabled and carol is not a friend.
      expect(street.spaceIds, ['alice', 'bob']);
      expect([for (final s in street.spaces) s.slot], [0, 1]);
      expect([for (final s in street.spaces) s.label], ['我的别墅', '阿青']);
      expect(
        [for (final s in street.spaces) s.relation],
        [Street3DRelation.self, Street3DRelation.friend],
      );
      expect(street.people.keys, ['alice', 'ai1', 'bob']);
      expect(street.failedSpaces, 0);
      expect(street.friendsFailed, isFalse);
    },
  );

  test('a friend list that fails still shows the own villa', () async {
    final street = await _source(
      friendsError: _down,
      layouts: {'alice': _layout('alice')},
    ).loadStreet();
    expect(street.spaceIds, ['alice']);
    expect(street.friendsFailed, isTrue);
  });

  test(
    'villas that fail are counted; a street with nothing to show is an error',
    () async {
      final partly = await _source(
        friends: const [
          FriendContact(
            accountId: 'bob',
            displayName: '阿青',
            state: FriendState.friends,
          ),
        ],
        layouts: {'alice': _layout('alice'), 'bob': _down},
      ).loadStreet();
      expect(partly.spaceIds, ['alice']);
      expect(partly.failedSpaces, 1);
      await expectLater(
        _source(layouts: {'alice': _down}).loadStreet(),
        throwsA(same(_down)),
      );
    },
  );

  test('no saved layout anywhere is an empty street, not an error', () async {
    final street = await _source().loadStreet();
    expect(street.spaces, isEmpty);
    expect(street.failedSpaces, 0);
  });

  test('an owner with no villa leaves its place to the next; a failed one keeps it', () async {
    String friend(int i) => 'f${i.toString().padLeft(2, '0')}';
    final reads = <String>[];
    final street = await _source(
      friends: [
        for (var i = 1; i <= 13; i++)
          FriendContact(
            accountId: friend(i),
            displayName: '朋友$i',
            state: FriendState.friends,
          ),
      ],
      layouts: {
        'alice': _layout('alice'),
        for (var i = 2; i <= 13; i++)
          friend(i): i == 3 ? _down : _layout(friend(i)),
      },
      reads: reads,
    ).loadStreet();
    // f01 has no villa, so f12 is read in a second batch. f03 could not be
    // read but keeps its place, so the street is full without f13.
    expect(reads, ['alice', for (var i = 1; i <= 12; i++) friend(i)]);
    expect(street.spaceIds, [
      'alice',
      friend(2),
      for (var i = 4; i <= 12; i++) friend(i),
    ]);
    expect(street.failedSpaces, 1);
    expect(
      [for (final s in street.spaces) s.slot],
      [for (var i = 0; i < 11; i++) i],
    );
  });

  test('presence merges the spaces and lists each resident once', () async {
    final source = _source(
      presence: {
        'alice': [_rec('alice', 'alice'), _rec('ai1', 'alice')],
        'bob': [_rec('ai1', 'bob'), _rec('bob', 'bob')],
      },
    );
    final records = await source.presence(['alice', 'bob', 'gone']);
    expect([for (final r in records) r.residentId], ['alice', 'ai1', 'bob']);
    await expectLater(
      _source(presence: {'alice': _down}).presence(['alice']),
      throwsA(same(_down)),
    );
  });

  test('residents are named from the people on the street', () {
    const street = Street3DStreet(
      spaces: [],
      people: {'alice': Street3DPerson('我', Street3DRole.self)},
    );
    final me = street.resident(_rec('alice', 'alice'));
    final stranger = street.resident(_rec('zed', 'alice'));
    expect((me.label, me.role), ('我', Street3DRole.self));
    expect((stranger.label, stranger.role), (null, Street3DRole.other));
  });
}
