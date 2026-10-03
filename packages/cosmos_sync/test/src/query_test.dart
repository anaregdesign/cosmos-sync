import 'dart:convert';
import 'dart:math';

import 'package:cosmos_sync/src/models.dart';
import 'package:cosmos_sync/src/query.dart';
import 'package:test/test.dart';

const partial = QueryCacheMetadata(bootstrapComplete: false, cursor: null);
const covered = QueryCacheMetadata(
  bootstrapComplete: true,
  cursor: 'opaque:42',
);

DocumentSnapshot doc(
  String id,
  Map<String, Object?>? data, {
  bool deleted = false,
  bool pending = false,
  bool conflict = false,
  int version = 1,
}) => DocumentSnapshot(
  id: id,
  data: data,
  version: version,
  deleted: deleted,
  hasPendingWrites: pending,
  hasConflict: conflict,
);

List<String> ids(LocalQuery query, List<DocumentSnapshot> documents) => query
    .evaluate(documents, metadata: partial)
    .documents
    .map((document) => document.id)
    .toList();

void main() {
  final x = QueryField.named('x');
  final score = QueryField.named('score');

  group('field and predicate conformance', () {
    final fixtures = [
      doc('missing', {}),
      doc('null', {'x': null}),
      doc('zero', {'x': 0}),
      doc('one', {'x': 1}),
      doc('double', {'x': 1.0}),
      doc('string', {'x': '1'}),
      doc('false', {'x': false}),
      doc('array', {
        'x': [1, null, '1'],
      }),
      doc('map', {
        'x': {'a': 1},
      }),
    ];

    test('explicit null is distinct from absent for equality and ordering', () {
      expect(ids(LocalQuery(filters: [QueryFilter.eq(x, null)]), fixtures), [
        'null',
      ]);
      expect(ids(LocalQuery(orderBy: [QueryOrder(x)]), fixtures), [
        'null',
        'false',
        'zero',
        'double',
        'one',
        'string',
        'array',
        'map',
      ]);
    });

    test(
      'inequality excludes missing and explicit null; ne(null) matches none',
      () {
        expect(ids(LocalQuery(filters: [QueryFilter.ne(x, 1)]), fixtures), [
          'array',
          'false',
          'map',
          'string',
          'zero',
        ]);
        expect(
          ids(LocalQuery(filters: [QueryFilter.ne(x, null)]), fixtures),
          isEmpty,
        );
      },
    );

    test(
      'numeric equality compares ints and doubles without string coercion',
      () {
        expect(ids(LocalQuery(filters: [QueryFilter.eq(x, 1)]), fixtures), [
          'double',
          'one',
        ]);
        expect(ids(LocalQuery(filters: [QueryFilter.eq(x, '1')]), fixtures), [
          'string',
        ]);
      },
    );

    test(
      'negative zero has the same equality/range/order position as zero',
      () {
        final data = [
          doc('a', {'x': -0.0}),
          doc('b', {'x': 0}),
          doc('c', {'x': 0.0}),
        ];
        expect(ids(LocalQuery(filters: [QueryFilter.eq(x, 0)]), data), [
          'a',
          'b',
          'c',
        ]);
        expect(ids(LocalQuery(filters: [QueryFilter.lt(x, 0)]), data), isEmpty);
        expect(
          ids(LocalQuery(orderBy: [QueryOrder(x)]), data.reversed.toList()),
          ['a', 'b', 'c'],
        );
      },
    );

    test(
      'all numeric ranges exclude nonnumeric values and use correct bounds',
      () {
        final filters = [
          QueryFilter.lt(x, 1),
          QueryFilter.lte(x, 1),
          QueryFilter.gt(x, 0),
          QueryFilter.gte(x, 1),
        ];
        expect(
          filters.map((filter) => ids(LocalQuery(filters: [filter]), fixtures)),
          [
            ['zero'],
            ['double', 'one', 'zero'],
            ['double', 'one'],
            ['double', 'one'],
          ],
        );
      },
    );

    test('string ranges use Unicode scalar order with no numeric coercion', () {
      final strings = [
        doc('a', {'x': '10'}),
        doc('b', {'x': '2'}),
        doc('c', {'x': 3}),
      ];
      expect(ids(LocalQuery(filters: [QueryFilter.lt(x, '2')]), strings), [
        'a',
      ]);
      final unicode = [
        doc('supplementary', {'x': '𐀀'}),
        doc('bmp', {'x': '\uE000'}),
      ];
      expect(ids(LocalQuery(orderBy: [QueryOrder(x)]), unicode), [
        'bmp',
        'supplementary',
      ]);
    });

    test(
      'array membership uses deep JSON equality including numeric/null values',
      () {
        expect(
          ids(
            LocalQuery(filters: [QueryFilter.arrayContains(x, 1.0)]),
            fixtures,
          ),
          ['array'],
        );
        expect(
          ids(
            LocalQuery(filters: [QueryFilter.arrayContains(x, null)]),
            fixtures,
          ),
          ['array'],
        );
        expect(
          ids(
            LocalQuery(
              filters: [
                QueryFilter.arrayContains(x, {'a': 1}),
              ],
            ),
            [
              doc('nested', {
                'x': [
                  {'a': 1.0},
                ],
              }),
              doc('notarray', {
                'x': {'a': 1},
              }),
            ],
          ),
          ['nested'],
        );
      },
    );

    test(
      'deep equality ignores map insertion order and respects array order',
      () {
        final data = [
          doc('equal', {
            'x': {
              'b': [2, 3],
              'a': 1.0,
            },
          }),
          doc('different', {
            'x': {
              'a': 1,
              'b': [3, 2],
            },
          }),
        ];
        expect(
          ids(
            LocalQuery(
              filters: [
                QueryFilter.eq(x, {
                  'a': 1,
                  'b': [2, 3],
                }),
              ],
            ),
            data,
          ),
          ['equal'],
        );
      },
    );

    test('nested paths distinguish literal dotted fields and null parents', () {
      final data = [
        doc('nested', {
          'profile': {'city': 'Osaka'},
        }),
        doc('literal', {'profile.city': 'Osaka'}),
        doc('nullparent', {'profile': null}),
      ];
      expect(
        ids(
          LocalQuery(
            filters: [
              QueryFilter.eq(QueryField(['profile', 'city']), 'Osaka'),
            ],
          ),
          data,
        ),
        ['nested'],
      );
      expect(
        ids(
          LocalQuery(
            filters: [
              QueryFilter.eq(QueryField.named('profile.city'), 'Osaka'),
            ],
          ),
          data,
        ),
        ['literal'],
      );
    });

    test(
      'multiple filters are AND and missing ordered fields are excluded',
      () {
        final data = [
          doc('keep', {'x': 'open', 'score': 10}),
          doc('closed', {'x': 'closed', 'score': 10}),
          doc('small', {'x': 'open', 'score': 1}),
          doc('missing', {'x': 'open'}),
        ];
        expect(
          ids(
            LocalQuery(
              filters: [QueryFilter.eq(x, 'open'), QueryFilter.gte(score, 5)],
              orderBy: [QueryOrder(score)],
            ),
            data,
          ),
          ['keep'],
        );
      },
    );
  });

  group('ordering and cursor conformance', () {
    test(
      'default order is ID; descending fields still have ascending ID ties',
      () {
        final data = [
          doc('z', {'score': 1}),
          doc('c', {'score': 3}),
          doc('b', {'score': 3}),
          doc('a', {'score': 2}),
        ];
        expect(ids(LocalQuery(), data), ['a', 'b', 'c', 'z']);
        expect(
          ids(LocalQuery(orderBy: [QueryOrder(score, descending: true)]), data),
          ['b', 'c', 'a', 'z'],
        );
      },
    );

    test('mixed JSON values have deterministic recursive ordering', () {
      final values = <Object?>[
        null,
        false,
        true,
        -1,
        0.5,
        'a',
        'b',
        [],
        [1],
        [1, 0],
        [2],
        {},
        {'a': 1},
        {'a': 2},
        {'b': 1},
      ];
      final data = List.generate(
        values.length,
        (i) => doc(i.toString().padLeft(3, '0'), {'x': values[i]}),
      );
      expect(
        ids(LocalQuery(orderBy: [QueryOrder(x)]), data.reversed.toList()),
        data.map((d) => d.id),
      );
    });

    test(
      'random insertion order never changes sorted ties across multiple fields',
      () {
        final rng = Random(619);
        final data = List.generate(
          200,
          (i) => doc('d${i.toString().padLeft(3, '0')}', {
            'x': rng.nextInt(5),
            'score': rng.nextInt(5),
          }),
        );
        final query = LocalQuery(
          orderBy: [QueryOrder(x), QueryOrder(score, descending: true)],
        );
        final expected = ids(query, data);
        for (var run = 0; run < 20; run++) {
          final shuffled = [...data]..shuffle(rng);
          expect(ids(query, shuffled), expected);
        }
      },
    );

    test(
      'pagination includes every static document exactly once, even tied/null values',
      () {
        final data = List.generate(
          125,
          (i) => doc('d${i.toString().padLeft(3, '0')}', {
            'x': i % 9 == 0 ? null : i % 7,
            'score': i % 3,
          }),
        );
        final orders = [QueryOrder(x, descending: true), QueryOrder(score)];
        final expected = ids(LocalQuery(orderBy: orders), data);
        final actual = <String>[];
        QueryCursor? after;
        for (var pageNumber = 0; pageNumber < 30; pageNumber++) {
          final query = LocalQuery(
            orderBy: orders,
            limit: 7,
            startAfter: after,
          );
          final page = query.evaluate(data, metadata: covered);
          if (page.documents.isEmpty) break;
          actual.addAll(page.documents.map((d) => d.id));
          after = page.nextCursor;
        }
        expect(actual, expected);
        expect(actual.toSet(), hasLength(125));
      },
    );

    test(
      'cursor stores values and remains valid when its source document is deleted',
      () {
        final data = [
          doc('a', {'score': 1}),
          doc('b', {'score': 1}),
          doc('c', {'score': 2}),
        ];
        final first = LocalQuery(
          orderBy: [QueryOrder(score)],
          limit: 1,
        ).evaluate(data, metadata: covered);
        final next = LocalQuery(
          orderBy: [QueryOrder(score)],
          startAfter: first.nextCursor,
        );
        expect(ids(next, [data[1], data[2]]), ['b', 'c']);
      },
    );

    test(
      'cursor query binding rejects changed filters/direction and permits page size changes',
      () {
        final query = LocalQuery(
          filters: [QueryFilter.gte(score, 1)],
          orderBy: [QueryOrder(score)],
          limit: 1,
        );
        final cursor = query.cursorFor(doc('a', {'score': 1}));
        expect(
          () => LocalQuery(
            filters: [QueryFilter.gte(score, 2)],
            orderBy: query.orderBy,
            startAfter: cursor,
          ),
          throwsArgumentError,
        );
        expect(
          () => LocalQuery(
            filters: query.filters,
            orderBy: [QueryOrder(score, descending: true)],
            startAfter: cursor,
          ),
          throwsArgumentError,
        );
        expect(
          LocalQuery(
            filters: query.filters,
            orderBy: query.orderBy,
            limit: 2,
            startAfter: cursor,
          ).limit,
          2,
        );
      },
    );

    test(
      'snapshot cursor rejects use after an identity/scope/version change',
      () {
        const alice = QueryCacheMetadata(
          bootstrapComplete: true,
          cursor: 'a',
          scopeKey: 'alice-scope-v1',
        );
        const bob = QueryCacheMetadata(
          bootstrapComplete: true,
          cursor: 'b',
          scopeKey: 'bob-scope-v1',
        );
        final data = [doc('a', {}), doc('b', {})];
        final first = LocalQuery(limit: 1).evaluate(data, metadata: alice);
        final next = LocalQuery(startAfter: first.nextCursor);
        expect(next.evaluate(data, metadata: alice).documents.single.id, 'b');
        expect(() => next.evaluate(data, metadata: bob), throwsArgumentError);
        expect(
          () => next.evaluate(data, metadata: partial),
          throwsArgumentError,
        );
      },
    );

    test(
      'empty pages have no next cursor and nonmatching cursor source fails',
      () {
        expect(LocalQuery().evaluate([], metadata: partial).nextCursor, isNull);
        expect(
          () => LocalQuery(orderBy: [QueryOrder(x)]).cursorFor(doc('a', {})),
          throwsArgumentError,
        );
        expect(
          () => LocalQuery().cursorFor(doc('a', null, deleted: true)),
          throwsArgumentError,
        );
      },
    );
  });

  group('cache view metadata', () {
    test(
      'deleted documents stay absent; recreated pending documents enter results',
      () {
        final query = LocalQuery(filters: [QueryFilter.eq(x, 'open')]);
        expect(
          ids(query, [doc('note', null, deleted: true, pending: true)]),
          isEmpty,
        );
        expect(
          ids(query, [
            doc('note', {'x': 'open'}, version: 2, pending: true),
          ]),
          ['note'],
        );
      },
    );

    test(
      'pending overlays reorder/filter results and conflict metadata stays visible',
      () {
        final query = LocalQuery(
          filters: [QueryFilter.eq(x, 'open')],
          orderBy: [QueryOrder(score)],
        );
        final snapshot = query.evaluate([
          doc('base', {'x': 'open', 'score': 10}),
          doc(
            'edited',
            {'x': 'open', 'score': 1},
            pending: true,
            conflict: true,
          ),
          doc('moved', {'x': 'closed', 'score': 0}, pending: true),
        ], metadata: covered);
        expect(snapshot.documents.map((d) => d.id), ['edited', 'base']);
        expect(snapshot.hasPendingWrites, isTrue);
        expect(snapshot.hasConflicts, isTrue);
        expect(snapshot.documents.first.hasConflict, isTrue);
        expect(snapshot.fromCache, isTrue);
        expect(snapshot.completeAtCursor, 'opaque:42');
      },
    );

    test(
      'aggregate pending/conflict flags conservatively include invisible deletes/edits',
      () {
        final snapshot = LocalQuery(filters: [QueryFilter.eq(x, 'open')])
            .evaluate([
              doc(
                'deleted',
                null,
                deleted: true,
                pending: true,
                conflict: true,
              ),
              doc('other', {'x': 'closed'}, pending: true),
            ], metadata: covered);
        expect(snapshot.documents, isEmpty);
        expect(snapshot.hasPendingWrites, isTrue);
        expect(snapshot.hasConflicts, isTrue);
      },
    );

    test(
      'coverage requires finished bootstrap and cursor and always comes from cache',
      () {
        for (final metadata in [
          partial,
          const QueryCacheMetadata(bootstrapComplete: false, cursor: 'partial'),
          const QueryCacheMetadata(bootstrapComplete: true, cursor: null),
          const QueryCacheMetadata(bootstrapComplete: true, cursor: ''),
          const QueryCacheMetadata(
            bootstrapComplete: true,
            cursor: 'before-revoke',
            paused: true,
          ),
        ]) {
          final snapshot = LocalQuery().evaluate([], metadata: metadata);
          expect(snapshot.isIncomplete, isTrue);
          expect(snapshot.completeAtCursor, isNull);
          expect(snapshot.fromCache, isTrue);
        }
        expect(
          LocalQuery().evaluate([], metadata: covered).isIncomplete,
          isFalse,
        );
      },
    );
  });

  group('immutable bounded AST codec', () {
    test(
      'roundtrip cursor/filter/order definition survives JSON serialization',
      () {
        final query = LocalQuery(
          filters: [
            QueryFilter.arrayContains(x, {
              'b': 2,
              'a': [null, 1],
            }),
          ],
          orderBy: [QueryOrder(score)],
          limit: 1,
        );
        final data = [
          doc('a', {
            'x': [
              {
                'a': [null, 1.0],
                'b': 2,
              },
            ],
            'score': 2,
          }),
          doc('b', {
            'x': [
              {
                'b': 2,
                'a': [null, 1],
              },
            ],
            'score': 3,
          }),
        ];
        final first = query.evaluate(data, metadata: covered);
        final next = LocalQuery(
          filters: query.filters,
          orderBy: query.orderBy,
          startAfter: first.nextCursor,
        );
        final decoded = LocalQuery.fromJson(
          (jsonDecode(jsonEncode(next.toJson())) as Map)
              .cast<String, Object?>(),
        );
        expect(ids(decoded, data), ['b']);
        expect(decoded.toJson(), next.toJson());
      },
    );

    test(
      'constructor deeply freezes input, fields, AST lists and snapshot results',
      () {
        final segments = ['x'];
        final value = <Object?>[
          {'a': 1},
        ];
        final filters = [QueryFilter.eq(QueryField(segments), value)];
        final query = LocalQuery(filters: filters);
        segments[0] = 'bad';
        (value.first as Map)['a'] = 2;
        filters.clear();
        expect(
          ids(query, [
            doc('a', {
              'x': [
                {'a': 1},
              ],
            }),
          ]),
          ['a'],
        );
        expect(() => query.filters.clear(), throwsUnsupportedError);
        expect(
          () => query.filters.first.field.segments.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => (query.filters.first.value as List).clear(),
          throwsUnsupportedError,
        );
        expect(
          () => query.evaluate([], metadata: partial).documents.clear(),
          throwsUnsupportedError,
        );
      },
    );

    test(
      'codec rejects unknown fields/operators/schema, omitted values and malformed cursor',
      () {
        final good = LocalQuery().toJson();
        for (final malformed in [
          {...good, 'sql': 'SELECT * FROM c'},
          {...good, 'version': 2},
          {
            ...good,
            'filters': [
              {
                'field': ['x'],
                'op': 'eq',
              },
            ],
          },
          {
            ...good,
            'filters': [
              {
                'field': ['x'],
                'op': 'or',
                'value': 1,
              },
            ],
          },
          {
            ...good,
            'orderBy': [
              {
                'field': ['x'],
                'descending': 'false',
              },
            ],
          },
          {
            ...good,
            'startAfter': {
              'querySignature': 'bad',
              'values': <Object?>[],
              'documentId': 'a',
            },
          },
        ]) {
          expect(
            () => LocalQuery.fromJson(malformed),
            throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
          );
        }
      },
    );

    test(
      'rejects ambiguous fields, oversized ASTs and unsupported/expensive values',
      () {
        expect(() => QueryField([]), throwsArgumentError);
        expect(() => QueryField(['']), throwsArgumentError);
        expect(
          () => QueryField([List.filled(129, 'a').join()]),
          throwsArgumentError,
        );
        expect(() => LocalQuery(limit: 0), throwsArgumentError);
        expect(() => LocalQuery(limit: 1001), throwsArgumentError);
        expect(
          () => LocalQuery(
            filters: List.generate(17, (_) => QueryFilter.eq(x, 1)),
          ),
          throwsArgumentError,
        );
        expect(
          () => LocalQuery(orderBy: [QueryOrder(x), QueryOrder(x)]),
          throwsArgumentError,
        );
        expect(() => QueryFilter.eq(x, double.nan), throwsArgumentError);
        expect(() => QueryFilter.eq(x, double.infinity), throwsArgumentError);
        expect(() => QueryFilter.eq(x, DateTime.now()), throwsArgumentError);
        expect(() => QueryFilter.eq(x, {1: 'bad key'}), throwsArgumentError);
        expect(
          () => QueryFilter.eq(x, List.filled(257, 1)),
          throwsArgumentError,
        );
        expect(
          () => QueryFilter.eq(x, List.filled(8193, 'a').join()),
          throwsArgumentError,
        );
        expect(() => QueryFilter.lt(x, true), throwsArgumentError);
        expect(() => QueryFilter.lt(x, []), throwsArgumentError);
      },
    );

    test('duplicate cached IDs cannot produce unstable cursors or results', () {
      expect(
        () => LocalQuery().evaluate([
          doc('a', {}),
          doc('a', {}),
        ], metadata: partial),
        throwsArgumentError,
      );
    });
  });
}
