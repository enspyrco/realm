/// Firebase-backed implementations of Realm engine interfaces.
///
/// `FirebaseStorageProvider`, `FirestoreRoomConfigStore`, and
/// `FirebaseAuthProvider` implement the engine interfaces from `package:realm`
/// (migration step 4). See `packages/realm_core/DESIGN.md`.
///
/// Dependency direction is load-bearing: this package depends on `realm_core` and
/// `firebase_*`; `realm_core` must NEVER depend on `firebase_core`. That direction
/// is enforced structurally by the engine transitive-deps whitelist in
/// `packages/realm_core/test/engine_deps_whitelist_test.dart`.
///
/// No-leak: these classes translate Firebase SDK types (`User`,
/// `DocumentSnapshot`, `Reference`, `FirebaseException`) into engine value types
/// ([RealmUser], [RoomDescriptor], [BlobRef], …) at the boundary. A Firebase
/// type appearing in this library's public surface is a bug.
library;

export 'src/firebase_auth_provider.dart';
export 'src/firebase_storage_provider.dart';
export 'src/firestore_room_config_store.dart';
