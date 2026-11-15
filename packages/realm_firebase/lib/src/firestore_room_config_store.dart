import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:realm_core/realm_core.dart';

/// Firestore implementation of [RoomConfigStore].
///
/// Maps the live `rooms` collection ↔ engine [RoomDescriptor]. **No-leak**: the
/// public surface accepts and returns only engine value types; Firestore's
/// `DocumentSnapshot`, `QuerySnapshot`, `Timestamp` and `FieldValue` never
/// cross the boundary. (The injected `CollectionReference` is a DI seam, the
/// same convention [FirebaseStorageProvider] uses for `FirebaseStorage`.)
///
/// ## Schema mapping (tech-world-era Firestore)
///
/// Engine metadata maps to named top-level fields (`name` →
/// [RoomDescriptor.displayName], plus `ownerId`, `ownerDisplayName`,
/// `editorIds`, `isPublic`, `worldType`). **Every other key in the document is
/// the opaque [RoomDescriptor.worldConfig]** — copied through verbatim without
/// interpretation, so a tilemap (`mapData`), a `mapVersion`, or any future
/// world-authored key rides along and this plugin never depends on `tech_world`.
///
/// ## Visibility: `unlisted` is the level this backend cannot express
///
/// The engine's [RoomVisibility] is three-state, but the live schema stores a
/// two-state `isPublic` bool. The deployed security rules let a room document
/// be read only when `isPublic == true` or the caller is its owner or an
/// editor — so `isPublic: false` gates *reachability*, not just listing:
/// holding the id is not enough to load the room. That is
/// [RoomVisibility.private] (owner and editors are the explicit grant). The
/// mapping is therefore `true ↔ public`, `false ↔ private`.
/// **[RoomVisibility.unlisted] is deliberately unsupported here**: honouring
/// it needs a rule letting anyone holding the id read the document, and
/// accepting it while the rules deny that would make the interface lie. Writes
/// of `unlisted` throw rather than silently tightening to `private`.
///
/// ## `getRoom` is a pure read
///
/// Unlike `tech_world`'s `RoomData.fromFirestore` (which self-heals renames and
/// wall styles by *writing during the read*), this store never writes during a
/// read. A caller that wants those migrations performs them explicitly through
/// [updateRoomMetadata] / [updateRoomConfig].
class FirestoreRoomConfigStore implements RoomConfigStore {
  /// Creates a store over [collection] (defaults to the `rooms` collection).
  ///
  /// [worldTypeRegistry] validates each document's `worldType` wire string on
  /// read — the brand is forgeable and carries no registry watermark, so a
  /// stored value is re-`parse`d against this registry rather than trusted.
  /// [defaultWorldType] is used for legacy documents that carry no `worldType`
  /// field (every live room today is implicitly `tech_world`).
  FirestoreRoomConfigStore({
    required WorldTypeRegistry worldTypeRegistry,
    CollectionReference<Map<String, dynamic>>? collection,
    String defaultWorldType = 'tech_world',
  })  : _registry = worldTypeRegistry,
        _defaultWorldType = defaultWorldType,
        _collection =
            collection ?? FirebaseFirestore.instance.collection('rooms');

  final WorldTypeRegistry _registry;
  final String _defaultWorldType;
  final CollectionReference<Map<String, dynamic>> _collection;

  /// Keys the engine owns. Every other document key is opaque `worldConfig`.
  static const _engineKeys = {
    'name',
    'ownerId',
    'ownerDisplayName',
    'editorIds',
    'isPublic',
    'worldType',
    'createdAt',
    'updatedAt',
  };

  @override
  Future<List<RoomDescriptor>> listRooms({
    UserId? ownedBy,
    RoomVisibility? minVisibility,
  }) async {
    Query<Map<String, dynamic>> query = _collection;
    if (ownedBy != null) {
      query = query.where('ownerId', isEqualTo: ownedBy.value);
    }
    // Two-state backend (public / private; unlisted cannot exist), so any
    // threshold above private selects exactly the public rooms. Only
    // `minVisibility: private` (or null) leaves the query unfiltered — and
    // Firestore rejects a whole query that could return a document the caller
    // may not read, so an unfiltered, un-owner-scoped list is permission-denied
    // for anyone but an admin. Authorization stays in the security rules.
    if (minVisibility != null &&
        minVisibility.isAtLeast(RoomVisibility.unlisted)) {
      query = query.where('isPublic', isEqualTo: true);
    }
    final snap = await query.get();
    return snap.docs.map(_toDescriptor).toList();
  }

  @override
  Future<RoomDescriptor?> getRoom(RoomId roomId) async {
    final doc = await _collection.doc(roomId.value).get();
    if (!doc.exists || doc.data() == null) return null;
    return _toDescriptor(doc);
  }

  @override
  Stream<RoomDescriptor> watchRoom(RoomId roomId) => _collection
      .doc(roomId.value)
      .snapshots()
      .where((doc) => doc.exists && doc.data() != null)
      .map(_toDescriptor);

  @override
  Future<RoomDescriptor> createRoom(NewRoomSpec spec) async {
    final data = <String, dynamic>{
      'name': spec.displayName,
      'ownerId': spec.ownerId.value,
      'editorIds': spec.editorIds.map((e) => e.value).toList(),
      'isPublic': _isPublicFor(spec.visibility),
      'worldType': spec.worldType.value,
      ...spec.worldConfig, // opaque world keys, stored at top level
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
    final ref = await _collection.add(data);
    return RoomDescriptor(
      id: RoomId(ref.id),
      displayName: spec.displayName,
      worldType: spec.worldType,
      visibility: spec.visibility,
      ownerId: spec.ownerId,
      worldConfig: spec.worldConfig,
      editorIds: spec.editorIds,
    );
  }

  @override
  Future<void> updateRoomConfig(
    RoomId roomId,
    Map<String, Object?> patch,
  ) async {
    _rejectEngineKeys(patch, 'patch');
    await _collection.doc(roomId.value).update({
      ...patch,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<void> updateRoomMetadata(
    RoomId roomId,
    RoomMetadataPatch patch, {
    Map<String, Object?> worldConfig = const {},
  }) async {
    _rejectEngineKeys(worldConfig, 'worldConfig');
    await _collection.doc(roomId.value).update({
      ...worldConfig,
      if (patch.displayName case final name?) 'name': name,
      if (patch.visibility case final v?) 'isPublic': _isPublicFor(v),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<void> addEditor(RoomId roomId, UserId editor) =>
      _collection.doc(roomId.value).update({
        'editorIds': FieldValue.arrayUnion([editor.value]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  @override
  Future<void> removeEditor(RoomId roomId, UserId editor) =>
      _collection.doc(roomId.value).update({
        'editorIds': FieldValue.arrayRemove([editor.value]),
        'updatedAt': FieldValue.serverTimestamp(),
      });

  @override
  Future<void> deleteRoom(RoomId roomId) =>
      _collection.doc(roomId.value).delete();

  /// A worldConfig key colliding with an engine-metadata field would smuggle a
  /// rename/visibility/owner change past the metadata door's typed fields.
  void _rejectEngineKeys(Map<String, Object?> config, String name) {
    final collisions = config.keys.where(_engineKeys.contains).toList();
    if (collisions.isNotEmpty) {
      throw ArgumentError.value(
        collisions,
        name,
        'worldConfig is opaque world data; these engine-owned metadata keys '
            'must go through updateRoomMetadata / addEditor / removeEditor',
      );
    }
  }

  bool _isPublicFor(RoomVisibility v) => switch (v) {
        RoomVisibility.public => true,
        RoomVisibility.private => false,
        RoomVisibility.unlisted => throw UnsupportedError(
            'FirestoreRoomConfigStore does not support RoomVisibility.unlisted: '
            'the security rules deny reading an isPublic:false room to anyone '
            'but its owner and editors, so "reachable by anyone holding the id" '
            'cannot be honoured. Use public or private, or change the rules '
            'first.',
          ),
      };

  RoomDescriptor _toDescriptor(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data()!;
    final worldConfig = <String, Object?>{
      for (final e in data.entries)
        if (!_engineKeys.contains(e.key)) e.key: e.value,
    };
    return RoomDescriptor(
      id: RoomId(doc.id),
      displayName: data['name'] as String,
      // Re-parse the wire against our own registry — a stored brand is not
      // proof of registration (see WorldTypeId's forgeability contract).
      worldType: WorldTypeId.parse(
        data['worldType'] as String? ?? _defaultWorldType,
        _registry,
      ),
      visibility: (data['isPublic'] as bool? ?? true)
          ? RoomVisibility.public
          : RoomVisibility.private,
      ownerId: UserId(data['ownerId'] as String),
      ownerDisplayName: data['ownerDisplayName'] as String?,
      editorIds: (data['editorIds'] as List<dynamic>?)
              ?.map((e) => UserId(e as String))
              .toList() ??
          const [],
      worldConfig: worldConfig,
    );
  }
}
