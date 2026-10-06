@TestOn('vm')
library;

import 'dart:convert';

import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/recorded_data_journey.dart';

const _issuer =
    'https://11111111-1111-4111-8111-111111111111.ciamlogin.com/'
    '11111111-1111-4111-8111-111111111111/v2.0';
const _clientId = '22222222-2222-4222-8222-222222222222';
const _callback = 'com.anaregdesign.cosmossync://auth/oauthredirect';
final _account = 'a' * 64;
final _scope = 'b' * 64;
final _identity = 'c' * 64;

void main() {
  for (final scenario in ['matching', 'wrong-namespace', 'wrong-account']) {
    test('recorded directory preflight: $scenario', () async {
      final requests = <String>[];
      final stages = <String>[];
      final transport = HttpSyncTransport(
        baseUri: Uri.parse('https://api.invalid'),
        tokenProvider: () async => 'recorded.api.credential',
        client: MockClient((request) async {
          requests.add(request.url.path);
          final Map<String, Object?> response;
          switch (request.url.path) {
            case '/v1/identity/capabilities':
              response = {
                'version': 1,
                'freshAuthenticationSeconds': 300,
                'maximumIdentities': 8,
                'recovery': 'remaining-identity-only',
                'deletion': 'operator-review-required',
                'migration': 'operator-review-required',
                'targets': [
                  {
                    'issuer': _issuer,
                    'clientId': _clientId,
                    'provider': 'entra',
                    'namespace': 'approved-candidate',
                    'callback': _callback,
                  },
                ],
              };
            case '/v1/session':
              response = {
                'scopeId': _scope,
                'principalId': _account,
                'permissionVersion': '1',
                'scopeMode': 'user',
                'identityGeneration': 3,
                'identityId': _identity,
              };
            case '/v1/identities':
              expect(request.headers['X-Cosmos-Sync-Principal'], _account);
              expect(request.headers['X-Cosmos-Sync-Identity-Generation'], '3');
              expect(request.headers['X-Cosmos-Sync-Identity'], _identity);
              response = {
                'accountId': scenario == 'wrong-account' ? 'd' * 64 : _account,
                'personalScopeId': _scope,
                'identityGeneration': 3,
                'currentIdentityId': _identity,
                'identities': [
                  {'identityId': _identity, 'provider': 'entra'},
                ],
              };
            default:
              fail('An unplanned request escaped the recorded preflight.');
          }
          return http.Response(jsonEncode(response), 200);
        }),
      );
      addTearDown(transport.close);
      final result = verifyDirectoryIdentity(
        transport: transport,
        issuer: _issuer,
        clientId: _clientId,
        callback: _callback,
        namespace: scenario == 'wrong-namespace'
            ? 'another-candidate'
            : 'approved-candidate',
        stage: (value) async => stages.add(value),
      );
      if (scenario == 'matching') {
        final session = await result;
        expect(session.principalId, _account);
        expect(session.identityGeneration, 3);
        expect(stages, [
          'directory_capabilities_verified',
          'directory_registered_session_verified',
        ]);
      } else {
        await expectLater(
          result,
          throwsA(
            scenario == 'wrong-namespace'
                ? isA<StateError>()
                : isA<TransportException>(),
          ),
        );
        expect(
          stages,
          scenario == 'wrong-namespace'
              ? isEmpty
              : ['directory_capabilities_verified'],
        );
      }
      expect(
        requests,
        scenario == 'wrong-namespace'
            ? ['/v1/identity/capabilities']
            : ['/v1/identity/capabilities', '/v1/session', '/v1/identities'],
      );
    });
  }
}
