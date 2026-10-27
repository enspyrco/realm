# Realm

A multiplayer worldbuilding engine. Realm hosts named *rooms*, and each room instantiates a
*World*. The engine provides the shared substrate (identity, presence, voice, room
transport, blob storage), so a World can be just its own vocabulary: its listeners, its
renderable substrate, its events. Backends are bring-your-own: Firebase, self-hosted, or
anything that satisfies the interfaces.

[Tech World](https://github.com/enspyrco/tech_world) is the first World built on Realm.

The architectural pin is [`packages/realm/DESIGN.md`](packages/realm/DESIGN.md): the engine
contract, the no-leak rule, the three tiers, and the migration plan.

## Packages

| Path | Package | What it is |
|---|---|---|
| [`packages/realm`](packages/realm) | `realm` | The engine. Five interfaces (`AuthProvider`, `RoomConfigStore`, `StorageProvider`, `LiveKitTokenEndpoint`, `PresenceService`), the `World` interface, and the registries. Interfaces only, with no runtime dependencies. Pure Dart. |
| [`packages/realm_firebase`](packages/realm_firebase) | `realm_firebase` | Provider plugin: `FirebaseAuthProvider`, `FirestoreRoomConfigStore`, `FirebaseStorageProvider`. A Flutter package. |
| [`examples/livekit-token-server`](examples/livekit-token-server) | `livekit_token_server` | Server-side reference for the Realm credential (ES256 issue and verify). It imports the engine; the engine never imports it. Production minting runs in [`enspyrco/realm-token-server`](https://github.com/enspyrco/realm-token-server), whose parity test verifies a credential minted by this code. |

## The guards

The engine's claims are enforced by tests in `packages/realm/test/`, not by prose:

- **`no_leak_test`**: no engine source imports a backend, Flutter, `dart:ui`, `dart:io` or a
  crypto library, and the engine's `pubspec.yaml` declares no runtime dependencies.
- **`engine_deps_whitelist_test`**: no signing or crypto primitive anywhere in the engine's
  shipped transitive dependencies.
- **`design_doc_sync_test`**: every member that DESIGN.md's code samples show actually exists
  on the live type.

CI ([`ci.yml`](.github/workflows/ci.yml)) runs the tests of every package declared in the
root `pubspec.yaml` workspace, and fails if a declared member has no tests.

## Using Realm from a World

Depend on it with git, pinned to a **full commit SHA**, and use the same SHA for both
packages:

```yaml
dependencies:
  realm:
    git:
      url: https://github.com/enspyrco/realm.git
      ref: <40-character commit SHA>
      path: packages/realm
  realm_firebase:
    git:
      url: https://github.com/enspyrco/realm.git
      ref: <the same SHA>
      path: packages/realm_firebase
```

Why not a tag or branch: `realm_firebase` depends on `realm` through `path: ../realm`. Inside
a git dependency, pub rewrites that into "realm from this repo, at the commit it resolved",
then compares it with your own `ref:` as text. Only a full SHA equals its own resolution; a
tag or branch makes pub report a version conflict. The same mechanism keeps the pair honest,
because bumping one SHA without the other fails `pub get`.

To work on Realm and a World side by side, put a `pubspec_overrides.yaml` in the World (keep
it out of git) pointing at a local checkout:

```yaml
dependency_overrides:
  realm:
    path: ../realm/packages/realm
  realm_firebase:
    path: ../realm/packages/realm_firebase
```

## Development

The Flutter version is pinned in [`.fvmrc`](.fvmrc), and CI reads its version from the same
file. Use [fvm](https://fvm.app), because `pubspec.lock` only reproduces on the Flutter that
wrote it, and CI runs `pub get --enforce-lockfile`.

```bash
fvm flutter pub get
fvm flutter analyze --fatal-infos               # covers every member

(cd packages/realm && fvm dart test)
(cd packages/realm_firebase && fvm flutter test)  # Flutter package
(cd examples/livekit-token-server && fvm dart test)

git config core.hooksPath .githooks             # secret scan + analyzer before each commit
```

## History

This repo was extracted from `enspyrco/tech_world` on 2026-10-27 with `git filter-repo`,
keeping the eight commits that touched these paths, with their authors and dates. Their
subject lines link to the tech_world pull requests. Bare `#NNN` references inside those
messages belong to tech_world or to internal trackers, not to this repo.

## License

No license has been granted for this repository yet; the terms are being settled. The history
imported from `enspyrco/tech_world` was published there under that repository's `LICENSE`.

External code contributions can't be accepted until the terms and a contributor agreement are
in place. Issues are welcome.
