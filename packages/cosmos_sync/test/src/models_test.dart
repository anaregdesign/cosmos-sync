import 'package:cosmos_sync/cosmos_sync.dart';
import 'package:test/test.dart';

void main() {
  const maximum = 9007199254740991;

  test(
    'JSON keeps portable integer boundaries and finite fractional values',
    () {
      expect(
        immutableJson({
          'nested': [maximum, -maximum, 1.25],
        })['nested'],
        [maximum, -maximum, 1.25],
      );
    },
  );

  test('JSON rejects nested unsafe integers on every platform', () {
    for (final value in [maximum + 1, -maximum - 1, -9223372036854775808]) {
      expect(
        () => immutableJson({
          'nested': [
            {'number': value},
          ],
        }),
        throwsFormatException,
      );
    }
  });

  test('JSON rejects nonfinite or unsafe integral floating point values', () {
    for (final value in [double.infinity, double.nan, 1e20, -1e20]) {
      expect(() => immutableJson({'number': value}), throwsFormatException);
    }
  });

  test('server document versions have one native and browser range', () {
    expect(
      ServerDocument(
        id: 'note',
        data: {},
        version: maximum,
        deleted: false,
      ).version,
      maximum,
    );
    for (final version in [0, -1, maximum + 1]) {
      expect(
        () => ServerDocument(
          id: 'note',
          data: {},
          version: version,
          deleted: false,
        ),
        throwsFormatException,
      );
    }
  });

  test('mutation observed bases accept zero and reject unsafe versions', () {
    MutationRequest request(int version) => MutationRequest(
      operationId: 'operation',
      documentId: 'note',
      kind: MutationKind.put,
      data: {},
      baseVersion: version,
    );
    expect(request(0).baseVersion, 0);
    expect(request(maximum).baseVersion, maximum);
    expect(() => request(-1), throwsFormatException);
    expect(() => request(maximum + 1), throwsFormatException);
  });

  test('snapshot cutover versions use the same portable range', () {
    SnapshotPage page(int version) => SnapshotPage(
      documents: [],
      cursor: 'snapshot',
      syncCursor: 'sync',
      cutoverSequence: version,
      hasMore: false,
    );
    expect(page(0).cutoverSequence, 0);
    expect(page(maximum).cutoverSequence, maximum);
    expect(() => page(-1), throwsFormatException);
    expect(() => page(maximum + 1), throwsFormatException);
  });

  test('sync pages cannot claim an empty durable cursor', () {
    expect(
      () => SyncPage(changes: [], cursor: '', hasMore: false),
      throwsFormatException,
    );
  });
}
