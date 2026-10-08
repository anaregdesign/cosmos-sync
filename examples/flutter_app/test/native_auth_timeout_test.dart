import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/native_auth_timeout.dart';

void main() {
  group('native auth test timeout', () {
    test('matches the host bounds and default', () {
      for (final seconds in [60, 480, 600, 900]) {
        expect(nativeAuthTimeout('$seconds'), Duration(seconds: seconds));
      }
    });

    test('rejects malformed and out-of-bound values without echoing them', () {
      for (final value in [
        '',
        '59',
        '901',
        '0',
        '-60',
        '+60',
        '600.0',
        '10m',
        ' 600',
        '600 ',
        'AUTH_CODE_MUST_NOT_LEAK',
      ]) {
        expect(
          () => nativeAuthTimeout(value),
          throwsA(
            isA<ArgumentError>().having(
              (error) => error.toString(),
              'sanitized error',
              allOf(
                contains('60-900 integer seconds'),
                isNot(contains('AUTH_CODE_MUST_NOT_LEAK')),
              ),
            ),
          ),
        );
      }
    });
  });
}
