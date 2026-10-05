import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:cosmos_sync_example/auth/auth_session_controller.dart';
import 'package:cosmos_sync_example/data/settings_store_native.dart';
import 'package:cosmos_sync_example/data/workspace_repository.dart';
import 'package:cosmos_sync_example/ui/app_controller.dart';
import 'package:cosmos_sync_example/ui/workspace_controller.dart';
import 'package:cosmos_sync_example/ui/workspace_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _issuer =
    'https://11111111-1111-4111-8111-111111111111.ciamlogin.com/'
    '11111111-1111-4111-8111-111111111111/v2.0';
const _client = '22222222-2222-4222-8222-222222222222';
const _callback = 'com.anaregdesign.cosmossync://auth/oauthredirect';
final _account = 'a' * 64;
final _scope = 'b' * 64;
final _primary = 'c' * 64;
final _secondary = 'd' * 64;

void main() {
  late Directory directory;
  late _DirectoryHTTP server;
  late _Oidc oidc;
  late _Store store;
  late AppController app;
  final settings = AppSettings(
    connection: ConnectionConfig(bffUri: Uri.parse('https://bff.example.test')),
    oidc: OidcConfig(
      issuer: _issuer,
      clientId: _client,
      redirectUrl: _callback,
      scopes: ['openid', 'offline_access', 'api://bff/Cosmos.Sync'],
    ),
  );
  Future<void> putAcknowledged(String title) async {
    await app.workspace.put('owned', {'title': title});
    expect(
      app.workspace.bootstrapComplete,
      true,
      reason: app.workspace.message,
    );
    expect(app.workspace.pending, isEmpty, reason: app.workspace.message);
    expect(server.documents['owned']!['data'], {'title': title});
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'cosmos-identity-lifecycle-',
    );
    server = _DirectoryHTTP();
    oidc = _Oidc();
    store = _Store();
    HttpSyncTransport transport(
      Future<String> Function() token,
      bool management,
    ) => HttpSyncTransport(
      baseUri: settings.connection.bffUri,
      tokenProvider: token,
      client: MockClient((request) => server.request(request, management)),
    );
    app = AppController(
      auth: AuthSessionController(oidc: oidc, tokenStore: store),
      workspace: WorkspaceController(
        repository: WorkspaceRepository(
          directory: Directory('${directory.path}/workspaces'),
          transportFactory: (_, token) => transport(token, false),
        ),
      ),
      settingsStore: FileSettingsStore(File('${directory.path}/settings.json')),
      identityTransportFactory: (_, token) => transport(token, true),
    );
  });
  tearDown(() async {
    await app.close();
    await directory.delete(recursive: true);
  });

  test(
    'unregistered identity offers explicit registration, never an implicit account',
    () async {
      server.registered = false;
      await app.signIn(settings);
      expect(app.workspace.connected, false);
      expect(app.registrationRequired, true);
      expect(app.canChangeIdentity, true);
      expect(server.identityPosts, isEmpty);
      expect(oidc.proofNonces, isEmpty);
      await app.registerAccount();
      expect(server.identityPosts, ['/v1/identity/register']);
      expect(oidc.proofNonces, [server.challenge]);
      expect(app.auth.isSignedIn, true);
      expect(await app.auth.accessToken(), 'main.api');
      expect(store.value, isNot(contains('fresh.')));
      expect(app.workspace.session!.principalId, _account);
      expect(app.workspace.session!.identityGeneration, 1);
      expect(app.identityAccount!.account.accountId, _account);
    },
  );

  test(
    'link drains and purges before two isolated proofs, then verifies before reopening SQLite',
    () async {
      await app.signIn(settings);
      await putAcknowledged('stable server owner');
      final credential = app.auth.credentialSessionId;
      final stored = store.value;
      oidc.proofAction = (nonce, number) async {
        expect(app.workspace.connected, false);
        expect(app.workspace.documents, isEmpty);
        expect(app.workspace.pending, isEmpty);
        expect(await Directory('${directory.path}/workspaces').exists(), false);
        expect(server.identityPosts, isEmpty);
        return _Oidc.proof(number);
      };
      await app.linkIdentity();
      expect(oidc.proofNonces, [server.challenge, server.challenge]);
      expect(server.identityPosts, ['/v1/identities/link']);
      expect(app.auth.credentialSessionId, credential);
      expect(store.value, stored);
      expect(app.workspace.session!.principalId, _account);
      expect(app.workspace.session!.identityGeneration, 2);
      expect(
        app.workspace.documents.single.data!['title'],
        'stable server owner',
      );
      expect(app.identityAccount!.identities.length, 2);
      expect(server.body!['reauthentication'], _Oidc.proof(1).toJson());
      expect(server.body!['identity'], _Oidc.proof(2).toJson());
    },
  );

  test(
    'remaining-credential unlink preserves ownership and last-credential removal is refused',
    () async {
      server.identities.add(_secondary);
      server.generation = 2;
      await app.signIn(settings);
      await putAcknowledged('retained');
      await app.unlinkIdentity(_secondary);
      expect(app.workspace.connected, true);
      expect(app.workspace.session!.identityGeneration, 3);
      expect(app.identityAccount!.identities.single.identityId, _primary);
      expect(app.workspace.documents.single.id, 'owned');
      final requests = server.identityPosts.length;
      await app.unlinkIdentity(_primary);
      expect(server.identityPosts.length, requests);
      expect(app.workspace.connected, true);
      expect(app.message, contains('Keep at least one'));
    },
  );

  test(
    'removing the active credential requires explicit remaining-identity sign-in',
    () async {
      server.identities.add(_secondary);
      server.generation = 2;
      await app.signIn(settings);
      await putAcknowledged('same account');
      await app.unlinkIdentity(_primary);
      expect(app.workspace.connected, false);
      expect(app.auth.isSignedIn, false);
      expect(store.value, null);
      expect(app.message, contains('current identity was removed'));
      expect(app.registrationRequired, false);
      oidc.mainAccess = 'remaining.api';
      await app.signIn(settings);
      expect(app.workspace.session!.principalId, _account);
      expect(app.workspace.session!.identityId, _secondary);
      expect(app.workspace.documents.single.id, 'owned');
      expect(server.identityPosts, ['/v1/identities/unlink']);
    },
  );

  test(
    'ambiguous committed response cannot replay proof or reopen an offline cache',
    () async {
      await app.signIn(settings);
      await putAcknowledged('retained in server fixture');
      server.failAfterCommit = true;
      await app.linkIdentity();
      expect(server.generation, 2);
      expect(app.auth.isSignedIn, false);
      expect(store.value, null);
      expect(app.workspace.connected, false);
      expect(app.workspace.documents, isEmpty);
      expect(app.message, contains('do not replay the old challenge'));
      await app.connect(offline: true);
      expect(app.workspace.connected, false);
      expect(server.identityPosts.length, 1);
      server.failAfterCommit = false;
      await app.signIn(settings);
      expect(app.workspace.session!.identityGeneration, 2);
      expect(app.workspace.documents.single.id, 'owned');
    },
  );

  test(
    'late cancelled proof cannot submit or replace the original credentials',
    () async {
      await app.signIn(settings);
      final stored = store.value;
      final launched = Completer<void>();
      final response = Completer<FreshIdentityProof>();
      oidc.proofAction = (_, _) {
        launched.complete();
        return response.future;
      };
      final linking = app.linkIdentity();
      await launched.future;
      await app.cancelIdentityProof();
      response.complete(_Oidc.proof(1));
      await linking;
      expect(server.identityPosts, isEmpty);
      expect(app.auth.isSignedIn, true);
      expect(store.value, stored);
      expect(app.workspace.connected, false);
      expect(app.workspace.documents, isEmpty);
      expect(app.message, contains('cancelled'));
    },
  );

  test(
    'pending-write disposal requires explicit confirmation before any challenge',
    () async {
      await app.signIn(settings);
      server.rejectMutations = true;
      await app.workspace.put('unacknowledged', {'title': 'local only'});
      expect(app.workspace.pending, isNotEmpty);
      await app.linkIdentity();
      expect(app.message, contains('explicitly confirm'));
      expect(app.workspace.pending, isNotEmpty);
      expect(server.challengeCount, 0);
      await app.linkIdentity(discardPending: true);
      expect(app.workspace.pending, isEmpty);
      expect(app.workspace.connected, true);
      expect(server.identityPosts, ['/v1/identities/link']);
    },
  );

  for (final closeApplication in [false, true]) {
    test(
      '${closeApplication ? 'application close' : 'credential signout'} fences an outstanding identity proof',
      () async {
        await app.signIn(settings);
        final launched = Completer<void>();
        final response = Completer<FreshIdentityProof>();
        oidc.proofAction = (_, _) {
          launched.complete();
          return response.future;
        };
        final linking = app.linkIdentity();
        await launched.future;
        if (closeApplication) {
          await app.close();
        } else {
          await app.auth.signOut();
        }
        response.complete(_Oidc.proof(1));
        await linking;
        expect(server.identityPosts, isEmpty);
        expect(app.workspace.connected, false);
        expect(app.workspace.documents, isEmpty);
        expect(app.identityAccount, null);
        expect(await Directory('${directory.path}/workspaces').exists(), false);
        if (!closeApplication) expect(store.value, null);
      },
    );
  }

  testWidgets(
    'ordinary view confirms pending loss and cancellation leaves exact local operations intact',
    (tester) async {
      await tester.runAsync(() async {
        await app.signIn(settings);
        server.rejectMutations = true;
        await app.workspace.put('unacknowledged', {'title': 'local only'});
      });
      final operation = app.workspace.pending.single.operationId;
      final stored = store.value;
      await tester.pumpWidget(
        MaterialApp(home: WorkspaceView(controller: app)),
      );
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('link-identity'))),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('1 pending operation(s)'), findsOneWidget);
      expect(find.textContaining('Unsent edits will be lost'), findsOneWidget);
      expect(server.challengeCount, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(app.workspace.pending.single.operationId, operation);
      expect(app.workspace.documents.single.id, 'unacknowledged');
      expect(store.value, stored);
      expect(oidc.proofNonces, isEmpty);
      await tester.runAsync(
        () => tester.tap(find.byKey(const Key('link-identity'))),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final finished = Completer<void>();
        var started = false;
        void observe() {
          started = started || app.busy;
          if (started && !app.busy && !finished.isCompleted) {
            finished.complete();
          }
        }

        app.addListener(observe);
        try {
          await tester.tap(find.byKey(const Key('confirm-link')));
          await finished.future.timeout(const Duration(seconds: 10));
        } finally {
          app.removeListener(observe);
        }
      });
      await tester.pumpAndSettle();
      expect(app.workspace.pending, isEmpty);
      expect(app.workspace.documents, isEmpty);
      expect(app.workspace.connected, true);
      expect(app.workspace.session!.identityGeneration, 2);
      expect(server.identityPosts, ['/v1/identities/link']);
      expect(store.value, stored);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'changed data identity after management verification is denied before cache open or sync',
    () async {
      await app.signIn(settings);
      final previousReads = server.syncCalls + server.snapshotCalls;
      server.tamperReopen = true;
      await app.linkIdentity();
      expect(app.auth.isSignedIn, false);
      expect(app.workspace.connected, false);
      expect(app.workspace.documents, isEmpty);
      expect(server.syncCalls + server.snapshotCalls, previousReads);
      expect(await Directory('${directory.path}/workspaces').exists(), false);
    },
  );

  test(
    'wrong callback capabilities and an out-of-band changed binding never offer registration',
    () async {
      server.wrongTarget = true;
      await app.signIn(settings);
      expect(app.identityCapabilities, null);
      expect(app.canChangeIdentity, false);
      expect(server.identityPosts, isEmpty);
      await app.signOut();
      server.wrongTarget = false;
      server.bindingChanged = true;
      await app.signIn(settings);
      expect(app.registrationRequired, false);
      expect(app.identityCapabilities, null);
      expect(app.workspace.connected, false);
      expect(oidc.proofNonces, isEmpty);
    },
  );

  test(
    'recovery clears local authority and never invokes a registration or email lookup',
    () async {
      await app.signIn(settings);
      await putAcknowledged('server fixture');
      await app.recoverWithRemainingIdentity();
      expect(app.auth.isSignedIn, false);
      expect(app.workspace.connected, false);
      expect(app.identityAccount, null);
      expect(store.value, null);
      expect(server.identityPosts, isEmpty);
      expect(app.message, contains('already linked'));
    },
  );
}

/// Protocol responses only: not a signed OIDC, Graph or live Cosmos fixture.
class _DirectoryHTTP {
  bool registered = true;
  bool failAfterCommit = false;
  bool rejectMutations = false;
  bool tamperReopen = false;
  bool wrongTarget = false;
  bool bindingChanged = false;
  bool _tamperNextDataSession = false;
  int generation = 1;
  int challengeCount = 0;
  int syncCalls = 0;
  int snapshotCalls = 0;
  int sequence = 0;
  String challenge = '';
  String? removed;
  final identities = [_primary];
  final identityPosts = <String>[];
  final documents = <String, Map<String, Object?>>{};
  Map<String, Object?>? body;

  Map<String, Object?> target() => {
    'issuer': _issuer,
    'provider': 'entra',
    'namespace': 'fixture-v1',
    'clientId': _client,
    'callback': wrongTarget ? 'com.unapproved://auth/callback' : _callback,
  };
  Map<String, Object?> result(String current) => {
    'accountId': _account,
    'personalScopeId': _scope,
    'identityGeneration': generation,
    if (identities.contains(current)) 'currentIdentityId': current,
    'identities': [
      for (final id in identities) {'identityId': id, 'provider': 'entra'},
    ],
  };
  http.Response json(Map<String, Object?> value, [int status = 200]) =>
      http.Response(jsonEncode(value), status);

  Future<http.Response> request(http.Request request, bool management) async {
    final path = request.url.path;
    final current = request.headers['Authorization']!.contains('remaining.api')
        ? _secondary
        : _primary;
    if (path == '/v1/session') {
      if (bindingChanged) {
        return json({'code': 'identity_binding_changed'}, 401);
      }
      if (!registered) {
        return json({'code': 'identity_registration_required'}, 401);
      }
      if (!identities.contains(current)) {
        return json({'code': 'identity_session_invalid'}, 401);
      }
      final changed = !management && _tamperNextDataSession;
      if (changed) _tamperNextDataSession = false;
      return json({
        'scopeId': _scope,
        'principalId': changed ? 'e' * 64 : _account,
        'permissionVersion': '1',
        'scopeMode': 'user',
        'identityGeneration': generation,
        'identityId': current,
      });
    }
    if (path == '/v1/identity/capabilities') {
      return json({
        'version': 1,
        'targets': [target()],
        'freshAuthenticationSeconds': 300,
        'maximumIdentities': 8,
        'recovery': 'remaining-identity-only',
        'deletion': 'operator-review-required',
        'migration': 'operator-review-required',
      });
    }
    if (path == '/v1/identities' ||
        path == '/v1/identities/link' ||
        path == '/v1/identities/unlink' ||
        path == '/v1/identity/challenges' && registered) {
      expect(request.headers['X-Cosmos-Sync-Principal'], _account);
      expect(
        request.headers['X-Cosmos-Sync-Identity-Generation'],
        '$generation',
      );
      expect(request.headers['X-Cosmos-Sync-Identity'], current);
      for (final header in [
        'X-Cosmos-Sync-Scope',
        'X-Cosmos-Sync-Permission',
        'X-Cosmos-Sync-Scope-Mode',
        'X-Cosmos-Sync-Session',
      ]) {
        expect(request.headers.containsKey(header), false);
      }
    }
    if (path == '/v1/identities') return json(result(current));
    if (path == '/v1/identity/challenges') {
      final value = (jsonDecode(request.body) as Map).cast<String, Object?>();
      expect(value['callback'], _callback);
      removed = value['removeIdentityId'] as String?;
      challenge = (++challengeCount).toRadixString(16).padLeft(64, '0');
      return json({
        'challenge': challenge,
        'operation': value['operation'],
        'target': target(),
        'expiresAt': DateTime.now()
            .toUtc()
            .add(const Duration(minutes: 5))
            .toIso8601String(),
      });
    }
    if (path == '/v1/identity/register' ||
        path == '/v1/identities/link' ||
        path == '/v1/identities/unlink') {
      identityPosts.add(path);
      body = (jsonDecode(request.body) as Map).cast<String, Object?>();
      expect(body!['challenge'], challenge);
      if (path.endsWith('/register')) {
        expect(request.headers['Authorization'], 'Bearer fresh.1.api');
        expect(body!['idToken'], 'fresh.1.id');
        registered = true;
      } else {
        generation++;
        if (path.endsWith('/link')) {
          identities.add(_secondary);
        } else {
          identities.remove(removed);
        }
      }
      _tamperNextDataSession = tamperReopen;
      if (failAfterCommit) throw Exception('fixture-private-unknown-response');
      return json(result(current));
    }
    if (path == '/v1/events') return json({'code': 'not_found'}, 404);
    if (path == '/v1/snapshot') {
      snapshotCalls++;
      return json({
        'documents': documents.values.toList(),
        'cursor': 'fixture.snapshot.$sequence',
        'syncCursor': 'fixture.cursor.$sequence',
        'cutoverSequence': sequence,
        'hasMore': false,
      });
    }
    if (path == '/v1/sync') {
      syncCalls++;
      return json({
        'changes': documents.values.toList(),
        'cursor': 'fixture.cursor.$sequence',
        'hasMore': false,
      });
    }
    if (path == '/v1/mutations') {
      if (rejectMutations) {
        return json({'code': 'scope_capacity_exceeded'}, 507);
      }
      final value = (jsonDecode(request.body) as Map).cast<String, Object?>();
      final id = value['documentId'] as String;
      final document = <String, Object?>{
        'id': id,
        'data': value['data'],
        'version': ++sequence,
        'deleted': value['kind'] == 'delete',
      };
      documents[id] = document;
      return json({'document': document});
    }
    throw StateError('Unexpected protocol fixture route: $path');
  }
}

class _Oidc implements FreshOidcClient {
  String mainAccess = 'main.api';
  final proofNonces = <String>[];
  Future<FreshIdentityProof> Function(String, int)? proofAction;
  static FreshIdentityProof proof(int number) => FreshIdentityProof(
    accessToken: 'fresh.$number.api',
    idToken: 'fresh.$number.id',
  );
  OidcTokens tokens() => OidcTokens(
    accessToken: mainAccess,
    refreshToken: 'main.refresh',
    idToken: 'main.logout.id',
    tokenType: 'Bearer',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
  );
  @override
  Future<OidcTokens> signIn(OidcConfig config) async => tokens();
  @override
  Future<OidcTokens> refresh(OidcConfig config, String refreshToken) async =>
      tokens();
  @override
  Future<void> endSession(OidcConfig config, String? idToken) async {}
  @override
  Future<FreshIdentityProof> freshIdentityProof(
    OidcConfig config,
    String nonce,
  ) {
    proofNonces.add(nonce);
    return proofAction?.call(nonce, proofNonces.length) ??
        Future.value(proof(proofNonces.length));
  }
}

class _Store implements RefreshTokenStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String value) async => this.value = value;
  @override
  Future<void> clear() async => value = null;
}
