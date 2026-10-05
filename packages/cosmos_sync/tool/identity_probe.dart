import 'dart:convert';
import 'dart:io';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

// Accept only the private disposable Go fixture, never real provider inputs.
Future<void> main(List<String> args) async {
  if (args.length != 1) {
    throw ArgumentError('Pass the private signed local fixture input.');
  }
  final fixture = (jsonDecode(File(args.single).readAsStringSync()) as Map)
      .cast<String, Object?>();
  Uri endpoint(String key) {
    final result = Uri.parse(fixture[key] as String);
    if (result.scheme != 'https' ||
        !{'localhost', '127.0.0.1', '::1'}.contains(result.host) ||
        result.userInfo.isNotEmpty ||
        result.path.isNotEmpty ||
        result.hasQuery ||
        result.hasFragment) {
      throw ArgumentError('The identity fixture requires loopback HTTPS.');
    }
    return result;
  }

  final first = endpoint('url');
  final second = endpoint('replica');
  final proofEndpoint = endpoint('proofs').resolve('/proof');
  final tokens = (fixture['tokens'] as Map).cast<String, String>();
  final certificate = File(fixture['certificate'] as String).readAsBytesSync();
  IOClient httpClient() => IOClient(
    HttpClient(
      context: SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(certificate),
    )..connectionTimeout = const Duration(seconds: 4),
  );
  final proofClient = httpClient();
  final transports = <HttpSyncTransport>[];
  final clients = <CosmosSyncClient>[];
  final directory = Directory.systemTemp.createTempSync(
    'cosmos-sync-identity-cache-',
  );
  HttpSyncTransport transport(String credential, Uri url) {
    final result = HttpSyncTransport(
      baseUri: url,
      tokenProvider: () async => tokens[credential]!,
      client: httpClient(),
      requestTimeout: const Duration(seconds: 4),
    );
    transports.add(result);
    return result;
  }

  Future<FreshIdentityProof> proof(
    IdentityChallenge challenge,
    String credential,
  ) async {
    final request = http.Request('POST', proofEndpoint)
      ..followRedirects = false
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({
        'nonce': challenge.challenge,
        'credential': credential,
      });
    final response = await http.Response.fromStream(
      await proofClient.send(request),
    ).timeout(const Duration(seconds: 4));
    check(response.statusCode == 200, 'The signed fixture proof failed.');
    final body = (jsonDecode(response.body) as Map).cast<String, Object?>();
    return FreshIdentityProof(
      accessToken: body['accessToken'] as String,
      idToken: body['idToken'] as String,
    );
  }

  Future<CosmosSyncClient> open(
    String name,
    HttpSyncTransport transport,
  ) async {
    final result = await CosmosSyncClient.open(
      path: '${directory.path}/$name.db',
      transport: transport,
    );
    clients.add(result);
    return result;
  }

  try {
    final primary = transport('primary', first);
    final capabilities = await primary.identityCapabilities();
    final target = capabilities.targetFor(
      issuer: fixture['issuer'] as String,
      clientId: fixture['clientId'] as String,
      callback: fixture['callback'] as String,
    );
    final register = await primary.createIdentityChallenge(
      operation: IdentityOperation.register,
      callback: target.callback,
    );
    final account = await primary.registerIdentity(
      register,
      await proof(register, 'primary'),
    );
    final original = await open('original', primary);
    check(
      original.session.principalId == account.account.accountId &&
          original.session.scopeId == account.account.personalScopeId &&
          original.session.identityGeneration == 1,
      'The real session must match the explicit registration.',
    );
    await original.sync();
    await original.put('owned', {'value': 'before-link'});
    check((await original.flush()).acknowledged == 1, 'Original server ACK.');
    await original.put('owned', {'value': 'must-not-cross-generation'});
    check(
      original.pending.length == 1,
      'The offline operation was not queued.',
    );
    final waiting = original.waitForPendingWrites().then<bool>(
      (_) => false,
      onError: (Object error) =>
          error is PendingWritesException &&
          error.reason == 'authorization_changed',
    );
    final shared = await primary.createSharedScope(
      CreateSharedScopeRequest.create(),
    );
    final management = transport('primary', second);
    await management.sessionInfo();
    final link = await management.createIdentityChallenge(
      operation: IdentityOperation.link,
      callback: target.callback,
    );
    final linked = await management.linkIdentity(
      challenge: link,
      reauthentication: await proof(link, 'primary'),
      identity: await proof(link, 'secondary'),
    );
    check(
      linked.account.accountId == account.account.accountId &&
          linked.account.personalScopeId == account.account.personalScopeId &&
          linked.identityGeneration == 2 &&
          linked.identities.length == 2,
      'Link moved ownership or lost the generation.',
    );
    await expectScopeChange(original.sync);
    check(
      await waiting &&
          original.status.paused &&
          original.pending.isEmpty &&
          original.list().isEmpty,
      'Learning a new identity generation did not purge before pending delivery.',
    );
    final secondary = transport('secondary', first);
    final remaining = await open('linked', secondary);
    await remaining.sync();
    final secondaryId = remaining.session.identityId!;
    check(
      remaining.session.principalId == account.account.accountId &&
          remaining.session.identityGeneration == 2 &&
          remaining.session.permissionVersion == '1' &&
          remaining.get('owned')?.data?['value'] == 'before-link',
      'The independent linked credential lost stable ownership/data.',
    );
    await remaining.put('owned', {'value': 'after-link'});
    check((await remaining.flush()).acknowledged == 1, 'Linked server ACK.');
    await management.sessionInfo();
    final retainedPolicy = await management.sharedScopeMembers(shared.scopeId);
    check(
      retainedPolicy.ownerAccountId == account.account.accountId &&
          retainedPolicy.revision == 1,
      'Identity linking moved shared ownership or changed its policy revision.',
    );
    final unlink = await management.createIdentityChallenge(
      operation: IdentityOperation.unlink,
      callback: target.callback,
      removeIdentityId: secondaryId,
    );
    final retained = await proof(unlink, 'primary');
    final unlinked = await management.unlinkIdentity(
      challenge: unlink,
      reauthentication: retained,
      remainingIdentity: retained,
    );
    check(
      unlinked.account.accountId == account.account.accountId &&
          unlinked.identityGeneration == 3 &&
          unlinked.identities.length == 1,
      'Unlink lost the retained random account.',
    );
    await expectAuthorization(remaining.sync);
    check(
      remaining.status.paused &&
          remaining.pending.isEmpty &&
          remaining.list().isEmpty,
      'The removed credential retained SDK data authority.',
    );
    await original.resume();
    await original.sync();
    check(
      original.session.identityGeneration == 3 &&
          original.session.principalId == account.account.accountId &&
          original.get('owned')?.version == 2 &&
          original.get('owned')?.data?['value'] == 'after-link',
      'Fresh remaining-credential recovery changed data or sent an old outbox.',
    );
    await original.signOut();
    check(
      original.pending.isEmpty && original.list().isEmpty,
      'Explicit signout did not purge.',
    );
    print(
      'Signed local TLS/Go/Dart/SQLite identity lifecycle passed: '
      'register/link/unlink, stable ownership, generation and outbox fences, '
      'removed-credential denial, explicit recovery and purge.',
    );
  } finally {
    for (final client in clients) {
      await client.close();
    }
    for (final transport in transports) {
      transport.close();
    }
    proofClient.close();
    directory.deleteSync(recursive: true);
  }
}

Future<void> expectAuthorization(Future<Object?> Function() action) async {
  try {
    await action();
  } on TransportException catch (error) {
    if (error.authorizationFailure) return;
    rethrow;
  }
  throw StateError('The obsolete credential/session was not denied.');
}

Future<void> expectScopeChange(Future<Object?> Function() action) async {
  try {
    await action();
  } on StateError catch (error) {
    if (error.message ==
        'Authorization scope changed. Cache purged; call resume() explicitly.') {
      return;
    }
    rethrow;
  }
  throw StateError('The obsolete SDK identity generation was not denied.');
}

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}
