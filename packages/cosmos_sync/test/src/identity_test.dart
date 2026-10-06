import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:test/test.dart';

final _account = 'a' * 64;
final _scope = 'b' * 64;
final _identity = 'c' * 64;
const _issuer =
    'https://11111111-1111-4111-8111-111111111111.ciamlogin.com/'
    '11111111-1111-4111-8111-111111111111/v2.0';
const _client = '22222222-2222-4222-8222-222222222222';
const _callback = 'com.anaregdesign.cosmossync://auth/oauthredirect';

Map<String, Object?> _target() => {
  'issuer': _issuer,
  'provider': 'entra',
  'namespace': 'customer-v1',
  'clientId': _client,
  'callback': _callback,
};

Map<String, Object?> _capabilities() => {
  'version': 1,
  'targets': [_target()],
  'freshAuthenticationSeconds': 300,
  'maximumIdentities': 8,
  'recovery': 'remaining-identity-only',
  'deletion': 'operator-review-required',
  'migration': 'operator-review-required',
};

Map<String, Object?> _result() => {
  'accountId': _account,
  'personalScopeId': _scope,
  'identityGeneration': 1,
  'currentIdentityId': _identity,
  'identities': [
    {'identityId': _identity, 'provider': 'entra'},
  ],
};

void main() {
  group('identity proof and server metadata', () {
    test(
      'proof and challenge diagnostics never expose credential material',
      () {
        final proof = FreshIdentityProof(
          accessToken: 'fixture.api.token',
          idToken: 'fixture.id.token',
        );
        expect(proof.toJson(), {
          'accessToken': 'fixture.api.token',
          'idToken': 'fixture.id.token',
        });
        expect(proof.toString(), isNot(contains('fixture')));
        for (final token in ['', 'with space', 'x' * 32769, 'unsafe\nvalue']) {
          expect(
            () => FreshIdentityProof(accessToken: token, idToken: 'id.token'),
            throwsFormatException,
          );
        }
        expect(
          () => FreshIdentityProof(
            accessToken: 'api.token',
            idToken: 'x' * 16385,
          ),
          throwsFormatException,
        );
        final challenge = IdentityChallenge.fromJson({
          'challenge': 'f' * 64,
          'operation': 'register',
          'expiresAt': '2030-01-01T00:00:00Z',
          'target': _target(),
        });
        expect(challenge.toString(), isNot(contains('f' * 64)));
        expect(challenge.expiresAt.isUtc, true);
      },
    );

    test('capabilities require the exact client and registered callback', () {
      final capability = IdentityCapabilities.fromJson(_capabilities());
      final target = capability.targetFor(
        issuer: _issuer,
        clientId: _client,
        callback: _callback,
      );
      expect(target.provider, 'entra');
      expect(
        () => capability.targetFor(
          issuer: _issuer,
          clientId: _client,
          callback: 'com.other://auth/oauthredirect',
        ),
        throwsFormatException,
      );
      expect(() => capability.targets.clear(), throwsUnsupportedError);
      for (final overrides in [
        {'version': 2},
        {'targets': <Object?>[]},
        {
          'targets': [_target(), _target()],
        },
        {'freshAuthenticationSeconds': 301},
        {'maximumIdentities': 9},
        {'deletion': 'automatic'},
        {'migration': 'email-match'},
        {'recovery': 'administrator-role'},
      ]) {
        expect(
          () =>
              IdentityCapabilities.fromJson({..._capabilities(), ...overrides}),
          throwsFormatException,
        );
      }
    });

    test('account result is bounded, immutable and not a data session', () {
      final account = IdentityAccount.fromJson(_result());
      expect(account.account.accountId, _account);
      expect(account.currentIdentityId, _identity);
      expect(account.identityGeneration, 1);
      expect(() => account.identities.clear(), throwsUnsupportedError);
      expect(
        IdentityAccount.fromJson(
          _result()..remove('currentIdentityId'),
        ).currentIdentityId,
        null,
      );
      for (final overrides in [
        {'identityGeneration': 0},
        {'identityGeneration': 10001},
        {'currentIdentityId': null},
        {'currentIdentityId': 'e' * 64},
        {'identities': <Object?>[]},
        {
          'identities': [
            {'identityId': _identity, 'provider': 'entra'},
            {'identityId': _identity, 'provider': 'entra'},
          ],
        },
      ]) {
        expect(
          () => IdentityAccount.fromJson({..._result(), ...overrides}),
          throwsFormatException,
        );
      }
    });
  });
}
