import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:realm_core/realm_core.dart';
import 'package:realm_firebase/realm_firebase.dart';
import 'package:test/test.dart';

void main() {
  late FakeFirebaseFirestore firestore;
  late WorldTypeRegistry registry;
  late FirestoreRoomConfigStore store;

  setUp(() {
    firestore = FakeFirebaseFirestore();
    registry = WorldTypeRegistry()
      // Factory is never invoked by the config store; a dummy suffices.
      ..register('tech_world', (_) => throw UnimplementedError());
    store = FirestoreRoomConfigStore(
      worldTypeRegistry: registry,
      collection: firestore.collection('rooms'),
    );
  });

  NewRoomSpec spec({
    String name = 'Imagination Center',
    RoomVisibility visibility = RoomVisibility.public,
    Map<String, Object?> worldConfig = const {},
    List<UserId> editorIds = const [],
  }) =>
      NewRoomSpec(
        displayName: name,
        worldType: WorldTypeId.parse('tech_world', registry),
        ownerId: const UserId('owner-1'),
        visibility: visibility,
        worldConfig: worldConfig,
        editorIds: editorIds,
      );

  test('is a RoomConfigStore', () {
    expect(store, isA<RoomConfigStore>());
  });

  group('createRoom → getRoom round-trip', () {
    test('maps every engine field back', () async {
      final created = await store.createRoom(spec(
        editorIds: const [UserId('ed-1'), UserId('ed-2')],
      ));
      final fetched = await store.getRoom(created.id);

      expect(fetched, isNotNull);
      expect(fetched!.id.value, created.id.value);
      expect(fetched.displayName, 'Imagination Center');
      expect(fetched.worldType.value, 'tech_world');
      expect(fetched.visibility, RoomVisibility.public);
      expect(fetched.ownerId.value, 'owner-1');
      expect(fetched.editorIds.map((e) => e.value), ['ed-1', 'ed-2']);
    });

    test('worldConfig is opaque — round-trips verbatim, no engine keys leak',
        () async {
      final config = {
        'mapData': {
          'walls': [
            {'style': 'modern_gray_07'}
          ]
        },
        'mapVersion': 'v3',
      };
      final created = await store.createRoom(spec(worldConfig: config));
      final fetched = await store.getRoom(created.id);

      expect(fetched!.worldConfig, config);
      // Engine metadata must NOT bleed into the opaque blob.
      expect(fetched.worldConfig.containsKey('name'), isFalse);
      expect(fetched.worldConfig.containsKey('isPublic'), isFalse);
      expect(fetched.worldConfig.containsKey('worldType'), isFalse);
    });
  });

  group('visibility mapping (unlisted is inexpressible)', () {
    test('public ↔ isPublic true', () async {
      final r = await store.createRoom(spec(visibility: RoomVisibility.public));
      expect((await store.getRoom(r.id))!.visibility, RoomVisibility.public);
      final raw = await firestore.collection('rooms').doc(r.id.value).get();
      expect(raw.data()!['isPublic'], isTrue);
    });

    test('private ↔ isPublic false', () async {
      final r = await store.createRoom(spec(visibility: RoomVisibility.private));
      expect((await store.getRoom(r.id))!.visibility, RoomVisibility.private);
      final raw = await firestore.collection('rooms').doc(r.id.value).get();
      expect(raw.data()!['isPublic'], isFalse);
    });

    test("NewRoomSpec's default visibility (private) is creatable", () async {
      final r = await store.createRoom(NewRoomSpec(
        displayName: 'Default',
        worldType: WorldTypeId.parse('tech_world', registry),
        ownerId: const UserId('owner-1'),
      ));
      expect((await store.getRoom(r.id))!.visibility, RoomVisibility.private);
    });

    test('unlisted is refused — the rules cannot honor it', () {
      expect(
        () => store.createRoom(spec(visibility: RoomVisibility.unlisted)),
        throwsUnsupportedError,
      );
    });

    test('legacy isPublic:false doc reads as private', () async {
      final ref = await firestore.collection('rooms').add({
        'name': 'Legacy private',
        'ownerId': 'owner-1',
        'isPublic': false,
      });
      final fetched = await store.getRoom(RoomId(ref.id));
      expect(fetched!.visibility, RoomVisibility.private);
    });

    test('legacy doc missing isPublic defaults to public', () async {
      final ref = await firestore.collection('rooms').add({
        'name': 'Legacy',
        'ownerId': 'owner-1',
        'worldType': 'tech_world',
      });
      final fetched = await store.getRoom(RoomId(ref.id));
      expect(fetched!.visibility, RoomVisibility.public);
    });
  });

  group('worldType trust boundary', () {
    test('legacy doc with no worldType uses the default', () async {
      final ref = await firestore.collection('rooms').add({
        'name': 'Legacy',
        'ownerId': 'owner-1',
        'isPublic': true,
      });
      final fetched = await store.getRoom(RoomId(ref.id));
      expect(fetched!.worldType.value, 'tech_world');
    });

    test('a doc naming an unregistered worldType throws on read', () async {
      final ref = await firestore.collection('rooms').add({
        'name': 'Alien',
        'ownerId': 'owner-1',
        'isPublic': true,
        'worldType': 'repo_body', // not registered in this test's registry
      });
      expect(
        () => store.getRoom(RoomId(ref.id)),
        throwsA(isA<WorldTypeNotRegistered>()),
      );
    });
  });

  group('getRoom', () {
    test('returns null for a missing room', () async {
      expect(await store.getRoom(const RoomId('nope')), isNull);
    });
  });

  group('listRooms', () {
    setUp(() async {
      await store.createRoom(spec(name: 'Pub', visibility: RoomVisibility.public));
      await store
          .createRoom(spec(name: 'Priv', visibility: RoomVisibility.private));
    });

    test('no filter returns every room', () async {
      final rooms = await store.listRooms();
      expect(rooms, hasLength(2));
    });

    test('minVisibility public returns only public rooms', () async {
      final rooms = await store.listRooms(minVisibility: RoomVisibility.public);
      expect(rooms.map((r) => r.displayName), ['Pub']);
    });

    test('minVisibility unlisted excludes private (filters on isPublic)',
        () async {
      final rooms =
          await store.listRooms(minVisibility: RoomVisibility.unlisted);
      expect(rooms.map((r) => r.displayName), ['Pub']);
    });

    test('minVisibility private returns every room', () async {
      final rooms = await store.listRooms(minVisibility: RoomVisibility.private);
      expect(rooms, hasLength(2));
    });

    test('ownedBy filters to one owner', () async {
      final ref = await firestore.collection('rooms').add({
        'name': 'Other',
        'ownerId': 'owner-2',
        'isPublic': true,
        'worldType': 'tech_world',
      });
      addTearDown(() => firestore.collection('rooms').doc(ref.id).delete());
      final mine = await store.listRooms(ownedBy: const UserId('owner-1'));
      expect(mine.every((r) => r.ownerId.value == 'owner-1'), isTrue);
      expect(mine.map((r) => r.displayName), containsAll(['Pub', 'Priv']));
    });
  });

  group('updateRoomConfig', () {
    test('patches an opaque worldConfig key', () async {
      final r = await store.createRoom(spec(worldConfig: {'mapVersion': 'v1'}));
      await store.updateRoomConfig(r.id, {'mapVersion': 'v2'});
      final fetched = await store.getRoom(r.id);
      expect(fetched!.worldConfig['mapVersion'], 'v2');
    });

    test('rejects a patch touching an engine-owned metadata key', () async {
      final r = await store.createRoom(spec());
      expect(
        () => store.updateRoomConfig(r.id, {'isPublic': false}),
        throwsArgumentError,
      );
      expect(
        () => store.updateRoomConfig(r.id, {'name': 'sneaky rename'}),
        throwsArgumentError,
      );
    });
  });

  group('updateRoomMetadata', () {
    Future<Map<String, dynamic>> raw(RoomId id) async =>
        (await firestore.collection('rooms').doc(id.value).get()).data()!;

    test('renames the room', () async {
      final r = await store.createRoom(spec());
      await store.updateRoomMetadata(
          r.id, const RoomMetadataPatch(displayName: 'Renamed'));
      expect((await store.getRoom(r.id))!.displayName, 'Renamed');
    });

    test('changes visibility both ways', () async {
      final r = await store.createRoom(spec(visibility: RoomVisibility.public));
      await store.updateRoomMetadata(
          r.id, const RoomMetadataPatch(visibility: RoomVisibility.private));
      expect((await raw(r.id))['isPublic'], isFalse);
      await store.updateRoomMetadata(
          r.id, const RoomMetadataPatch(visibility: RoomVisibility.public));
      expect((await store.getRoom(r.id))!.visibility, RoomVisibility.public);
    });

    test('null fields are left unchanged', () async {
      final r = await store.createRoom(spec(visibility: RoomVisibility.public));
      await store.updateRoomMetadata(
          r.id, const RoomMetadataPatch(displayName: 'Only name'));
      final fetched = await store.getRoom(r.id);
      expect(fetched!.displayName, 'Only name');
      expect(fetched.visibility, RoomVisibility.public);
    });

    test('renames and patches worldConfig together', () async {
      final r = await store.createRoom(spec(worldConfig: {
        'mapData': {'v': 1},
        'mapVersion': 'v1',
      }));
      await store.updateRoomMetadata(
        r.id,
        const RoomMetadataPatch(displayName: 'Saved'),
        worldConfig: {
          'mapData': {'v': 2},
        },
      );
      final fetched = await store.getRoom(r.id);
      expect(fetched!.displayName, 'Saved');
      expect(fetched.worldConfig['mapData'], {'v': 2});
      expect(fetched.worldConfig['mapVersion'], 'v1'); // merged, not replaced
    });

    test('unlisted is refused and nothing is written', () async {
      final r = await store.createRoom(spec());
      await expectLater(
        store.updateRoomMetadata(
          r.id,
          const RoomMetadataPatch(
            displayName: 'Should not land',
            visibility: RoomVisibility.unlisted,
          ),
        ),
        throwsUnsupportedError,
      );
      expect((await store.getRoom(r.id))!.displayName, 'Imagination Center');
    });

    test('worldConfig touching an engine key is rejected', () async {
      final r = await store.createRoom(spec());
      await expectLater(
        store.updateRoomMetadata(r.id, const RoomMetadataPatch(),
            worldConfig: {'editorIds': <String>['sneaky']}),
        throwsArgumentError,
      );
      expect((await store.getRoom(r.id))!.editorIds, isEmpty);
    });
  });

  group('editors', () {
    test('addEditor grants, idempotently', () async {
      final r = await store.createRoom(spec());
      await store.addEditor(r.id, const UserId('ed-1'));
      await store.addEditor(r.id, const UserId('ed-1'));
      expect((await store.getRoom(r.id))!.editorIds.map((e) => e.value),
          ['ed-1']);
    });

    test('removeEditor revokes only that editor', () async {
      final r = await store.createRoom(
          spec(editorIds: const [UserId('ed-1'), UserId('ed-2')]));
      await store.removeEditor(r.id, const UserId('ed-1'));
      expect((await store.getRoom(r.id))!.editorIds.map((e) => e.value),
          ['ed-2']);
    });

    test('removing a non-editor is a no-op', () async {
      final r = await store.createRoom(spec(editorIds: const [UserId('ed-1')]));
      await store.removeEditor(r.id, const UserId('stranger'));
      expect((await store.getRoom(r.id))!.editorIds.map((e) => e.value),
          ['ed-1']);
    });
  });

  group('deleteRoom', () {
    test('deletes the room', () async {
      final r = await store.createRoom(spec());
      await store.deleteRoom(r.id);
      expect(await store.getRoom(r.id), isNull);
    });

    test('deleting a missing room is not an error', () async {
      await store.deleteRoom(const RoomId('nope'));
    });
  });

  group('watchRoom', () {
    test('emits the current descriptor and again after a config change',
        () async {
      final r = await store.createRoom(spec(worldConfig: {'mapVersion': 'v1'}));
      final emissions = <String?>[];
      final sub = store
          .watchRoom(r.id)
          .listen((d) => emissions.add(d.worldConfig['mapVersion'] as String?));

      await Future<void>.delayed(Duration.zero);
      await store.updateRoomConfig(r.id, {'mapVersion': 'v2'});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();

      expect(emissions, contains('v1'));
      expect(emissions.last, 'v2');
    });
  });
}
