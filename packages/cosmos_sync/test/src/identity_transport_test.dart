import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final _account = 'a' * 64;
final _scope = 'b' * 64;
final _identity = 'c' * 64;
const _callback = 'com.anaregdesign.cosmossync://auth/oauthredirect';
final _target = IdentityProofTarget(
  issuer:
      'https://11111111-1111-4111-8111-111111111111.ciamlogin.com/'
      '11111111-1111-4111-8111-111111111111/v2.0',
  provider: 'entra',
  namespace: 'customer-v1',
  clientId: '22222222-2222-4222-8222-222222222222',
  callback: _callback,
);

Map<String, Object?> _session(int generation) => {
  'scopeId': _scope,
  'principalId': _account,
  'permissionVersion': '1',
  'scopeMode': 'user',
  'identityGeneration': generation,
  'identityId': _identity,
};

Map<String, Object?> _result(int generation) => {
  'accountId': _account,
  'personalScopeId': _scope,
  'identityGeneration': generation,
  'currentIdentityId': _identity,
  'identities': [
    {'identityId': _identity, 'provider': 'entra'},
  ],
};

IdentityChallenge _challenge(IdentityOperation operation) => IdentityChallenge(
  challenge: 'f' * 64,
  operation: operation,
  expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
  target: _target,
);

FreshIdentityProof _proof(String kind) => FreshIdentityProof(
  accessToken: 'fixture.$kind.api',
  idToken: 'fixture.$kind.id',
);

void main() {
  group('dedicated identity HTTP transport', () {
    test(
      'management pins the discovered identity without a Cosmos envelope',
      () async {
        final transport = HttpSyncTransport(
          baseUri: Uri.parse('https://api.invalid'),
          tokenProvider: () async => 'current.api',
          client: MockClient((request) async {
            if (request.url.path.endsWith('/session')) {
              return http.Response(jsonEncode(_session(2)), 200);
            }
            expect(request.headers['X-Cosmos-Sync-Principal'], _account);
            expect(request.headers['X-Cosmos-Sync-Identity-Generation'], '2');
            expect(request.headers['X-Cosmos-Sync-Identity'], _identity);
            expect(request.headers['X-Cosmos-Sync-Session'], null);
            for (final header in [
              'X-Cosmos-Sync-Scope',
              'X-Cosmos-Sync-Scope-Mode',
              'X-Cosmos-Sync-Permission',
            ]) {
              expect(request.headers.containsKey(header), false);
            }
            return http.Response(jsonEncode(_result(2)), 200);
          }),
        );
        addTearDown(transport.close);
        await transport.sessionInfo();
        transport.consistencyToken = 'opaque.old.envelope';
        expect((await transport.account()).accountId, _account);
        expect((await transport.accountIdentities()).identityGeneration, 2);
      },
    );

    test(
      'identity listing rejects a result for another account or generation',
      () async {
        var response = _result(1);
        final transport = HttpSyncTransport(
          baseUri: Uri.parse('https://api.invalid'),
          tokenProvider: () async => 'ordinary.api',
          client: MockClient(
            (request) async => http.Response(
              jsonEncode(
                request.url.path.endsWith('/session') ? _session(1) : response,
              ),
              200,
            ),
          ),
        );
        addTearDown(transport.close);
        await transport.sessionInfo();
        for (final changed in [
          {..._result(1), 'accountId': 'd' * 64},
          _result(2),
          {..._result(1), 'currentIdentityId': null},
        ]) {
          response = changed;
          await expectLater(
            transport.accountIdentities(),
            throwsA(
              isA<TransportException>().having(
                (error) => error.code,
                'code',
                'invalid_response',
              ),
            ),
          );
        }
      },
    );

    test(
      'registration uses only its correlated fresh API/ID proof and clears old binding',
      () async {
        var providerCalls = 0;
        final transport = HttpSyncTransport(
          baseUri: Uri.parse('https://api.invalid'),
          tokenProvider: () async {
            providerCalls++;
            return 'ordinary.api';
          },
          client: MockClient((request) async {
            expect(request.url.path, '/v1/identity/register');
            expect(request.headers['Authorization'], 'Bearer fixture.new.api');
            expect(request.headers['X-Cosmos-Sync-Principal'], null);
            expect(request.headers['X-Cosmos-Sync-Identity'], null);
            expect(jsonDecode(request.body), {
              'challenge': 'f' * 64,
              'idToken': 'fixture.new.id',
            });
            return http.Response(jsonEncode(_result(1)), 200);
          }),
        );
        addTearDown(transport.close);
        transport.consistencyToken = 'old.envelope';
        expect(
          (await transport.registerIdentity(
            _challenge(IdentityOperation.register),
            _proof('new'),
          )).account.accountId,
          _account,
        );
        expect(providerCalls, 0);
        expect(transport.consistencyToken, null);
      },
    );

    test(
      'link and ambiguous unlink always require fresh session reverification',
      () async {
        for (final fail in [false, true]) {
          var generation = 1;
          final transport = HttpSyncTransport(
            baseUri: Uri.parse('https://api.invalid'),
            tokenProvider: () async => 'ordinary.api',
            client: MockClient((request) async {
              if (request.url.path.endsWith('/session')) {
                return http.Response(jsonEncode(_session(generation)), 200);
              }
              expect(request.headers['Authorization'], 'Bearer ordinary.api');
              expect(request.headers['X-Cosmos-Sync-Identity-Generation'], '1');
              expect(request.headers['X-Cosmos-Sync-Identity'], _identity);
              expect(jsonDecode(request.body), {
                'challenge': 'f' * 64,
                'reauthentication': _proof('current').toJson(),
                'identity': _proof('independent').toJson(),
              });
              generation = 2;
              if (fail) throw Exception('opaque network failure');
              return http.Response(jsonEncode(_result(2)), 200);
            }),
          );
          addTearDown(transport.close);
          await transport.sessionInfo();
          transport.consistencyToken = 'old.envelope';
          final action = fail
              ? transport.unlinkIdentity(
                  challenge: _challenge(IdentityOperation.unlink),
                  reauthentication: _proof('current'),
                  remainingIdentity: _proof('independent'),
                )
              : transport.linkIdentity(
                  challenge: _challenge(IdentityOperation.link),
                  reauthentication: _proof('current'),
                  identity: _proof('independent'),
                );
          if (fail) {
            await expectLater(action, throwsA(isA<TransportException>()));
          } else {
            expect((await action).identityGeneration, 2);
          }
          expect(transport.consistencyToken, null);
          await expectLater(
            transport.accountIdentities(),
            throwsA(
              isA<TransportException>().having(
                (error) => error.code,
                'code',
                'identity_session_required',
              ),
            ),
          );
          expect((await transport.sessionInfo()).identityGeneration, 2);
        }
      },
    );
  });
}
