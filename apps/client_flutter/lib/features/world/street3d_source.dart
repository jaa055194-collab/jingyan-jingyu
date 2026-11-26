import 'package:jingyu_core/jingyu_core.dart';

import '../../app/shell_view_model.dart';
import '../../net/friends_api.dart';
import '../../net/host_connection.dart';
import '../../net/world_api.dart';
import 'street3d_protocol.dart';

/// How the 3D street labels one account, as a villa owner or as a resident.
class Street3DPerson {
  const Street3DPerson(this.label, this.role);

  final String? label;
  final Street3DRole role;
}

/// The villas on the street, and the accounts the page can name.
class Street3DStreet {
  const Street3DStreet({
    required this.spaces,
    this.people = const <String, Street3DPerson>{},
    this.failedSpaces = 0,
    this.friendsFailed = false,
  });

  final List<Street3DSpace> spaces;

  /// Account id -> label and role, used for residents.
  final Map<String, Street3DPerson> people;

  /// Villas whose layout exists but could not be read this time.
  final int failedSpaces;

  /// The friend list could not be read, so no friend's villa is shown.
  final bool friendsFailed;

  List<String> get spaceIds => [
    for (final space in spaces) space.layout.spaceId,
  ];

  Street3DResident resident(WorldPresenceRecord record) {
    final person = people[record.residentId];
    return Street3DResident(
      record: record,
      label: person?.label,
      role: person?.role ?? Street3DRole.other,
    );
  }
}

/// Where the street's villas and the residents' positions come from.
abstract interface class Street3DDataSource {
  Future<Street3DStreet> loadStreet();

  /// Everyone currently in [spaceIds], each resident once.
  Future<List<WorldPresenceRecord>> presence(List<String> spaceIds);
}

typedef _Owner = ({String id, String label, Street3DRelation relation});
typedef _Read = ({WorldSpaceLayout? layout, Object? error});

/// Reads the street from the host.
///
/// The host has no street listing: a villa's space id is its owner's account
/// id. The street is therefore the signed-in account, its own AIs and its
/// friends, in that order and at most [street3dMaxSpaces]. An owner who has
/// not saved a layout has no villa yet and is left out.
class HostStreet3DDataSource implements Street3DDataSource {
  HostStreet3DDataSource({
    required this.selfId,
    required this.readLayout,
    required this.readPresence,
    this.readFriends,
    this.ownAis = const <ShellOwnedAi>[],
  });

  factory HostStreet3DDataSource.connected(
    HostConnection connection, {
    required String selfId,
    List<ShellOwnedAi> ownAis = const <ShellOwnedAi>[],
  }) {
    final world = WorldApi(connection);
    return HostStreet3DDataSource(
      selfId: selfId,
      ownAis: ownAis,
      readLayout: world.layout,
      readPresence: world.presence,
      readFriends: FriendsApi(connection).list,
    );
  }

  final String selfId;
  final List<ShellOwnedAi> ownAis;
  final Future<WorldSpaceLayout> Function(String spaceId) readLayout;
  final Future<List<WorldPresenceRecord>> Function(String spaceId) readPresence;
  final Future<List<FriendContact>> Function()? readFriends;

  @override
  Future<Street3DStreet> loadStreet() async {
    final owners = <_Owner>[
      (id: selfId, label: '我的别墅', relation: Street3DRelation.self),
    ];
    final people = <String, Street3DPerson>{
      selfId: const Street3DPerson('我', Street3DRole.self),
    };
    for (final ai in ownAis) {
      if (ai.disabled || people.containsKey(ai.accountId)) continue;
      owners.add((
        id: ai.accountId,
        label: ai.displayName,
        relation: Street3DRelation.ownAi,
      ));
      people[ai.accountId] = Street3DPerson(ai.displayName, Street3DRole.ownAi);
    }
    var friendsFailed = false;
    final readFriends = this.readFriends;
    if (readFriends != null) {
      try {
        for (final friend in await readFriends()) {
          if (friend.state != FriendState.friends ||
              people.containsKey(friend.accountId)) {
            continue;
          }
          owners.add((
            id: friend.accountId,
            label: friend.displayName,
            relation: Street3DRelation.friend,
          ));
          people[friend.accountId] = Street3DPerson(
            friend.displayName,
            Street3DRole.friend,
          );
        }
      } catch (_) {
        friendsFailed = true;
      }
    }
    final picked = owners.take(street3dMaxSpaces).toList();
    final reads = await Future.wait([
      for (final owner in picked) _read(owner.id),
    ]);
    final spaces = <Street3DSpace>[];
    var failed = 0;
    Object? firstError;
    for (var i = 0; i < picked.length; i++) {
      final (:layout, :error) = reads[i];
      if (layout != null) {
        // Consecutive slots, so the villas that exist stand side by side.
        spaces.add(
          Street3DSpace(
            layout: layout,
            slot: spaces.length,
            label: picked[i].label,
            relation: picked[i].relation,
          ),
        );
      } else if (error != null) {
        failed += 1;
        firstError ??= error;
      }
    }
    // Nothing to draw and something failed: report it instead of an empty street.
    if (spaces.isEmpty && firstError != null) throw firstError;
    return Street3DStreet(
      spaces: spaces,
      people: people,
      failedSpaces: failed,
      friendsFailed: friendsFailed,
    );
  }

  Future<_Read> _read(String spaceId) async {
    try {
      return (layout: await readLayout(spaceId), error: null);
    } on HostRequestException catch (error) {
      // notFound: this owner has not saved a layout, so there is no villa yet.
      if (error.failure.code == FailureCode.notFound) {
        return (layout: null, error: null);
      }
      return (layout: null, error: error);
    } catch (error) {
      return (layout: null, error: error);
    }
  }

  @override
  Future<List<WorldPresenceRecord>> presence(List<String> spaceIds) async {
    final lists = await Future.wait([
      for (final id in spaceIds) _positions(id),
    ]);
    final seen = <String>{};
    return [
      for (final list in lists)
        for (final record in list)
          if (seen.add(record.residentId)) record,
    ];
  }

  Future<List<WorldPresenceRecord>> _positions(String spaceId) async {
    try {
      return await readPresence(spaceId);
    } on HostRequestException catch (error) {
      if (error.failure.code == FailureCode.notFound) {
        return const <WorldPresenceRecord>[];
      }
      rethrow;
    }
  }
}
