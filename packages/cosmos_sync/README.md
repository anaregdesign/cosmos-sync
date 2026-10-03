# cosmos_sync

Dart/Flutter offline documents through an OIDC BFF for Cosmos DB for NoSQL.
**MIT-licensed v0.2 preview.** Native SQLite and
Chromium IndexedDB preserve confirmed data, pending overlays and exact durable
operations. The BFF alone holds Cosmos credentials. This is a finite document API,
with [Firestore differences](doc/query.md). Essential protocol, query and security
documentation is included in this package; using it does not require repository access.

Apple and Google are the intended end-user login providers. The SDK accepts a
dedicated BFF API access token through `tokenProvider`; it does not implement a
provider login or turn a provider ID token into API authorization. The native
sample currently validates Entra OIDC/PKCE. Apple/Google adapters and explicit
account linking remain planned in the [social-login roadmap](https://github.com/anaregdesign/cosmos-sync/blob/main/docs/social-auth.md).

## Durable local writes

```dart
final client = await CosmosSyncClient.open(
  path: cacheIdentity, // app-private native path; origin-local database on web
  transport: HttpSyncTransport(
    baseUri: Uri.parse('https://your-bff.example'),
    tokenProvider: () => auth.currentAccessToken(),
    scopeMode: SyncScopeMode.user, // personal data; shared scopes shown below
  ),
);
await client.sync();
final watch = client.watch('note').listen((view) {
  print('${view?.data}; pending=${view?.hasPendingWrites}');
});
await client.put('note', {'text': 'Available offline', 'rank': 1});
final acknowledged = client.waitForPendingWrites();
await client.flush();
await acknowledged; // captures writes present when called; later edits excluded
client.startWatching(); // hints plus polling fallback while app is running
await watch.cancel();
await client.signOut();
await client.close();
```

Await put/delete/retryConflict/discard: success means the storage transaction
committed, not that the server accepted it. Loaded get/list/query reads are
synchronous. A new cache needs a server session; a verified cache can reopen
fully offline. IDs and data are bounded JSON, with exact safe integers. put
replaces the whole document; delete retains a tombstone, excluded from list/query.

## Personal and shared authorization

With `authorization.mode: builtin` on the BFF, a verified API identity gets its
own personal scope without an operator grant file. Authentication remains with
the OIDC provider; Cosmos Sync stores the account and data memberships. The fixed
creator of a shared scope can grant registered accounts `reader` or `writer`,
and revoke with `none`. Readers cannot write or edit memberships; members cannot
grant themselves a role. Provider emails, groups and self-claimed roles are not
data permissions. Legacy `tenant` scopes remain separate from built-in `shared`.

```dart
final account = await ownerTransport.account();
// The reader signs in separately and shares their own account().accountId.
final create = CreateSharedScopeRequest.create();
final shared = await ownerTransport.createSharedScope(create);
final edit = SetSharedScopeMemberRequest.create(
  accountId: registeredReaderAccountId,
  role: SharedScopeRole.reader,
  baseRevision: shared.revision,
);
await ownerTransport.setSharedScopeMember(shared.scopeId, edit);

final sharedClient = await CosmosSyncClient.open(
  path: sharedCacheIdentity, // dedicated to this principal/shared scope
  transport: HttpSyncTransport(
    baseUri: Uri.parse('https://your-bff.example'),
    tokenProvider: () => auth.currentAccessToken(),
    scopeMode: SyncScopeMode.shared,
    sharedScopeId: shared.scopeId,
  ),
);
await sharedClient.sync();
```

Management calls require a network connection and a fresh API token. They do not
enter the document outbox. Save the immutable request's `toJson()` before sending
if recovery must survive an application exit; restore with `fromJson()` and retry
the same request after an unknown outcome. An exact replay can return its recorded
older policy: fetch `sharedScopeMembers(scopeId)` before the next membership edit.
On `TransportException.membershipConflict`, read the current revision and obtain
an explicit new edit/request rather than overwriting a concurrent owner's change.
The owner is immutable; invitations, ownership transfer and account deletion are
not implemented. Preview policies retain revoked entries and support up to 128
member identities and 10,000 revisions per shared scope; capacity exhaustion
requires operator action, never silently reuses a revoked permission generation.
See the [authorization contract](doc/protocol.md).

The shared ID only selects a server-created scope; it grants no permission or
Cosmos credential. The SDK requires the server session to match that selected ID
and binds data requests to the current principal and member permission generation.
Selecting a different explicit mode/shared ID purges an incompatible offline
cache and pauses it before displaying old data. A token identity switch or remote
revocation still requires reconnecting to the BFF to be detected.

## Queries and coverage

```dart
final query = LocalQuery(limit: 20);
final result = client.query(query);
print(result.documents);
final subscription = client.watchQuery(query).listen((page) {
  print(page.metadata.completeAtCursor);
});
```

Queries scan local views, including pending overlays, with a finite immutable AST,
AND filters, explicit field segments, deterministic JSON order and ID tie-breaker.
Query cursors bind scope and definition, and differ from server sync cursors.
[Complete semantics](doc/query.md) cover null/missing/type boundaries,
pagination under edits and unsupported operators. Local filtering does not reduce
full-scope network/RU costs. Completed bootstrap establishes coverage through a
committed cursor; offline results still cannot promise current freshness/access.

## Conflicts, retry and bootstrap

The first edit preserves the version observed at enqueue; pulls never rebase it.
Later same-document edits depend on a predecessor's actual ACK. Pending requests
are durably locked before send, and retry/restart reuse the exact operation ID,
base and data. Late ACKs preserve newer overlays. Lost responses replay immutable
server receipts rather than create a second write.

A conflict remains in `pending`, blocks successors for that document, and permits
explicit awaited `retryConflict(operationId, data: mergedData)` or `discard`.
A queued attempted mutation with unknown outcome cannot be discarded safely.
ACK waits fail on conflict/discard/revocation/close. Network/429/5xx failures retain
operations with persisted backoff/Retry-After; observe `statuses` and flush results.

Bootstrap uses a bounded fixed-cutover snapshot where enabled and otherwise
retained-journal replay. Snapshot progress/page/data cursor commits are atomic;
interrupted coverage stays incomplete. 410 generation recovery clears confirmed
coverage while preserving exact outbox identities and observed bases. Receipts,
tombstones and journal are retained without TTL; server capacity exhaustion needs
operator action. Hints never advance the durable data cursor; polling recovers
missed events. No background-execution guarantee is implied.

## Identity, cache ownership and limits

Sessions bind principal, scope, mode and permission version. Fresh-token requests
assert that same identity; the server derives routing. 401/403 or a changed session
conservatively purges cache/outbox and pauses. `resume()` explicitly adopts a newly
verified session. `await signOut()` drains in-flight work before purge. Offline
revocation cannot be learned before reconnection, and purge may discard local edits.

Use one isolate/cache owner per principal/scope. Native SQLite guards duplicate
opens within an isolate and uses advisory file locks across processes; separate
isolates in one process must coordinate ownership at the application level.
Browser persistence requires IndexedDB and Web Locks, with strict transaction
commit and typed capability/busy failures. Do not substitute an in-memory fallback.
Browser storage remains subject to eviction/user deletion; other browsers are
unverified until measured. Native SQLite is plaintext; logical purge cannot erase
backups/WAL/snapshots forensically. Larger native caches should use a dedicated
isolate; queries scan and sort rather than use a server planner.

[Wire protocol](doc/protocol.md), [queries](doc/query.md) and
[security](doc/security.md) describe actual support. No Firestore compatibility, global order/cross-partition transaction,
automatic merge, external Cosmos writer ingestion or cloud RU/SLA is promised.

## Preview platform support

| Declared platform | Measured evidence | Remaining limits |
| --- | --- | --- |
| Android | Real SQLite SDK fixture on Android 14/API 34 arm64 emulator and physical Pixel 9a Android 17/API 37; physical app UI also passed actual Go HTTP/offline/conflict/purge | App authentication uses a signed-fixture adapter; real provider sign-in, suspension and Azure app flow remain unverified. |
| iOS | Flutter app + real SQLite on iOS 26.5 arm64 simulator | Physical device, suspension and production sign-in remain unverified. |
| macOS | Flutter app + real SQLite on macOS 26.7 arm64 | No x86_64 or minimum-OS support claim. |
| Web | Chromium IndexedDB/Web Locks, browser reload and actual BFF HTTP/SSE | Other browsers, persistent-storage eviction and mobile-browser behavior are unverified. |

Linux and Windows are not declared supported Flutter targets until app runtime
validation is completed. Linux CI verifies native Dart/SQLite contracts; this does
not establish Windows or Linux Flutter app support. Dart 3.12+ is required. Tested
Flutter 3.44.6 uses SQLite 3.5.x without dependency overrides. There is no continuous
background-sync guarantee or automatic secure-storage/encryption integration.

Local queries scan and sort the complete cache. At 10,000 documents, a measured
native SQLite query averaged about 132 ms on one Apple Silicon host; this is a
development benchmark, not a target-device latency guarantee. Measure on intended
devices and coordinate a dedicated isolate for large native caches.

## Development and release preparation

```sh
dart pub get
dart analyze --fatal-infos
dart test
dart test --platform chrome
dart run example/cosmos_sync_example.dart
dart pub publish --dry-run
```

The runnable native example uses a demo transport and a real reopened SQLite file.
The monorepo separately tests authenticated Go HTTP and the official Cosmos emulator.
Stable Flutter compatibility uses SQLite 3.5.x without dependency overrides;
newer SQLite package hooks currently conflict with stable Flutter's pinned meta.
The browser reload probe in `web/cache_reload_probe.dart` verifies exact outbox
identities, observed bases, overlays, scope, cursor and consistency envelope after
a full page reload. Publication
uses the owner's selected publishing account and reviewed version; no command
here publishes or creates Azure resources. The optional
[source release record](https://github.com/anaregdesign/cosmos-sync/blob/main/docs/release.md)
records registry and deployment evidence.

The package and BFF are distributed under the [MIT license](LICENSE), copyright
2026 anaregdesign. Dependency licenses remain with their respective owners.
Use [GitHub private vulnerability reporting](https://github.com/anaregdesign/cosmos-sync/security/advisories/new)
after the owner verifies activation during public-source setup; do not report
credentials or exploit details in public issues.
