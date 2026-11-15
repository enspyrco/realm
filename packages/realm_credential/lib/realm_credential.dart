import 'package:realm_core/realm_core.dart';

export 'src/realm_credential_jwt.dart';

/// Reference Realm credential implementation skeleton (migration step 2).
///
/// This file exists to pin the engine-vs-server dependency direction: the
/// credential server depends on the engine (`import 'package:realm_core/realm_core.dart'`),
/// and the engine never depends on the server. Server-side auth strategies
/// (HMAC-signed request, mTLS) live HERE, never in `packages/realm_core/`, because
/// the engine package ships to every client. The real HTTP implementation
/// lands in a later migration step.
String credentialServerBanner() =>
    'realm_credential reference impl for realm $realmEngineVersion';
