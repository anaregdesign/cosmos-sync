import 'dart:convert';

import 'models.dart';

/// A literal field-name path, without dot parsing or array indexes.
class QueryField {
  QueryField(List<String> segments) : segments = List.unmodifiable(segments) {
    if (segments.isEmpty ||
        segments.length > 16 ||
        segments.any(
          (part) => part.isEmpty || utf8.encode(part).length > 128,
        )) {
      throw ArgumentError(
        'Use 1..16 nonempty field names of at most 128 bytes.',
      );
    }
  }

  factory QueryField.named(String name) => QueryField([name]);

  final List<String> segments;

  Object? _read(Map<String, Object?> data) {
    Object? current = data;
    for (final segment in segments) {
      if (current is! Map || !current.containsKey(segment)) return _missing;
      current = current[segment];
    }
    return current;
  }
}

enum QueryOperator { eq, ne, lt, lte, gt, gte, arrayContains }

/// One predicate; multiple query predicates are combined with AND.
class QueryFilter {
  QueryFilter({
    required this.field,
    required this.operator,
    required Object? value,
  }) : value = _freezeValue(value) {
    if (_isRange && value is! num && value is! String) {
      throw ArgumentError('Range filter values must be numbers or strings.');
    }
  }

  factory QueryFilter.eq(QueryField field, Object? value) =>
      QueryFilter(field: field, operator: QueryOperator.eq, value: value);
  factory QueryFilter.ne(QueryField field, Object? value) =>
      QueryFilter(field: field, operator: QueryOperator.ne, value: value);
  factory QueryFilter.lt(QueryField field, Object value) =>
      QueryFilter(field: field, operator: QueryOperator.lt, value: value);
  factory QueryFilter.lte(QueryField field, Object value) =>
      QueryFilter(field: field, operator: QueryOperator.lte, value: value);
  factory QueryFilter.gt(QueryField field, Object value) =>
      QueryFilter(field: field, operator: QueryOperator.gt, value: value);
  factory QueryFilter.gte(QueryField field, Object value) =>
      QueryFilter(field: field, operator: QueryOperator.gte, value: value);
  factory QueryFilter.arrayContains(QueryField field, Object? value) =>
      QueryFilter(
        field: field,
        operator: QueryOperator.arrayContains,
        value: value,
      );

  final QueryField field;
  final QueryOperator operator;
  final Object? value;

  bool get _isRange => switch (operator) {
    QueryOperator.lt ||
    QueryOperator.lte ||
    QueryOperator.gt ||
    QueryOperator.gte => true,
    _ => false,
  };

  bool _matches(Map<String, Object?> data) {
    final actual = field._read(data);
    if (identical(actual, _missing)) return false;
    if (_isRange) {
      // Range comparisons do not coerce strings, booleans or null to numbers.
      if (!(actual is num && value is num) &&
          !(actual is String && value is String)) {
        return false;
      }
      final comparison = _compareJson(actual, value);
      return switch (operator) {
        QueryOperator.lt => comparison < 0,
        QueryOperator.lte => comparison <= 0,
        QueryOperator.gt => comparison > 0,
        QueryOperator.gte => comparison >= 0,
        _ => false,
      };
    }
    return switch (operator) {
      QueryOperator.eq => _equalJson(actual, value),
      QueryOperator.ne =>
        actual != null && value != null && !_equalJson(actual, value),
      QueryOperator.arrayContains =>
        actual is List && actual.any((element) => _equalJson(element, value)),
      _ => false,
    };
  }

  Map<String, Object?> toJson() => {
    'field': field.segments,
    'op': operator.name,
    'value': value,
  };
}

class QueryOrder {
  const QueryOrder(this.field, {this.descending = false});
  final QueryField field;
  final bool descending;

  Map<String, Object?> toJson() => {
    'field': field.segments,
    'descending': descending,
  };
}

/// Local pagination position. It is not a BFF sync cursor or capability.
class QueryCursor {
  QueryCursor._({
    required this.querySignature,
    required List<Object?> values,
    required this.documentId,
    this.scopeKey,
  }) : values = List.unmodifiable(values.map(_freezeValue)) {
    if (documentId.isEmpty || documentId.length > 128) {
      throw ArgumentError('Invalid cursor document ID.');
    }
  }

  final String querySignature;
  final List<Object?> values;
  final String documentId;
  final String? scopeKey;

  Map<String, Object?> toJson() => {
    'querySignature': querySignature,
    'values': values,
    'documentId': documentId,
    if (scopeKey != null) 'scopeKey': scopeKey,
  };
}

/// Cache coverage metadata; cache origin never implies server freshness.
class QueryCacheMetadata {
  const QueryCacheMetadata({
    required this.bootstrapComplete,
    required this.cursor,
    this.paused = false,
    this.scopeKey,
  });

  final bool bootstrapComplete;
  final String? cursor;
  final bool paused;

  /// Stable local identity/scope binding supplied by the client, not a secret.
  final String? scopeKey;

  bool get fromCache => true;

  /// The confirmed scope replay covered this cursor, before local overlays.
  /// This is null during bootstrap, resync, pause or after cache purge.
  String? get completeAtCursor =>
      !paused && bootstrapComplete && cursor != null && cursor!.isNotEmpty
      ? cursor
      : null;

  bool get isIncomplete => completeAtCursor == null;
}

class LocalQuerySnapshot {
  LocalQuerySnapshot._({
    required List<DocumentSnapshot> documents,
    required this.metadata,
    required this.hasPendingWrites,
    required this.hasConflicts,
    required this.query,
  }) : documents = List.unmodifiable(documents);

  final List<DocumentSnapshot> documents;
  final QueryCacheMetadata metadata;
  final LocalQuery query;

  /// Conservative scope-wide flag, including pending deletes/filtered-out edits.
  /// Per-document flags describe only the visible results.
  final bool hasPendingWrites;
  final bool hasConflicts;

  bool get fromCache => metadata.fromCache;
  bool get isIncomplete => metadata.isIncomplete;
  String? get completeAtCursor => metadata.completeAtCursor;

  /// A scope-bound cursor after the last visible document; null for an empty page.
  /// Its presence does not assert that another page exists.
  QueryCursor? get nextCursor => documents.isEmpty
      ? null
      : query.cursorFor(documents.last, scopeKey: metadata.scopeKey);
}

/// A bounded, immutable local query AST. No query is sent to Cosmos DB.
///
/// Evaluation scans the cache in O(N * filters + N log N * order fields) time.
/// At most 16 predicates and 8 sort fields are allowed. An explicit limit is
/// bounded to 1000; an omitted limit returns all matching cached views.
class LocalQuery {
  LocalQuery({
    List<QueryFilter> filters = const [],
    List<QueryOrder> orderBy = const [],
    this.limit,
    this.startAfter,
  }) : filters = List.unmodifiable(filters),
       orderBy = List.unmodifiable(orderBy) {
    if (filters.length > 16 || orderBy.length > 8) {
      throw ArgumentError(
        'Queries support at most 16 filters and 8 sort fields.',
      );
    }
    if (limit != null && (limit! < 1 || limit! > 1000)) {
      throw ArgumentError.value(limit, 'limit', 'Use a limit of 1..1000.');
    }
    final fields = orderBy.map((order) => jsonEncode(order.field.segments));
    if (fields.toSet().length != orderBy.length) {
      throw ArgumentError('Duplicate sort fields are not allowed.');
    }
    if (startAfter != null &&
        (startAfter!.querySignature != _signature ||
            startAfter!.values.length != orderBy.length)) {
      throw ArgumentError('Cursor belongs to a different query definition.');
    }
  }

  factory LocalQuery.fromJson(Map<String, Object?> json) {
    _keys(json, {'version', 'filters', 'orderBy', 'limit', 'startAfter'});
    if (json['version'] is! int ||
        json['version'] != 1 ||
        json['filters'] is! List ||
        json['orderBy'] is! List) {
      throw FormatException('Invalid local query schema.');
    }
    if ((json['filters'] as List).length > 16 ||
        (json['orderBy'] as List).length > 8) {
      throw FormatException('Local query exceeds predicate/order bounds.');
    }
    final filters = (json['filters'] as List).map((raw) {
      final entry = _object(raw);
      _keys(entry, {'field', 'op', 'value'});
      if (!entry.containsKey('value')) {
        throw FormatException('A filter must contain a value, including null.');
      }
      final op = QueryOperator.values.where((op) => op.name == entry['op']);
      if (op.isEmpty) throw FormatException('Unsupported query operator.');
      return QueryFilter(
        field: _field(entry['field']),
        operator: op.single,
        value: entry['value'],
      );
    }).toList();
    final orders = (json['orderBy'] as List).map((raw) {
      final entry = _object(raw);
      _keys(entry, {'field', 'descending'});
      if (entry['descending'] is! bool) {
        throw FormatException('Sort direction must be a boolean.');
      }
      return QueryOrder(
        _field(entry['field']),
        descending: entry['descending'] as bool,
      );
    }).toList();
    final rawLimit = json['limit'];
    if (rawLimit != null && rawLimit is! int) {
      throw FormatException('Query limit must be an integer.');
    }
    QueryCursor? cursor;
    if (json['startAfter'] != null) {
      final entry = _object(json['startAfter']);
      _keys(entry, {'querySignature', 'values', 'documentId', 'scopeKey'});
      if (entry['querySignature'] is! String ||
          entry['documentId'] is! String ||
          entry['values'] is! List ||
          (entry['values'] as List).length != orders.length ||
          (entry['scopeKey'] != null && entry['scopeKey'] is! String)) {
        throw FormatException('Invalid local query cursor.');
      }
      cursor = QueryCursor._(
        querySignature: entry['querySignature'] as String,
        values: (entry['values'] as List).cast<Object?>(),
        documentId: entry['documentId'] as String,
        scopeKey: entry['scopeKey'] as String?,
      );
    }
    return LocalQuery(
      filters: filters,
      orderBy: orders,
      limit: rawLimit as int?,
      startAfter: cursor,
    );
  }

  final List<QueryFilter> filters;
  final List<QueryOrder> orderBy;
  final int? limit;
  final QueryCursor? startAfter;

  String get _signature => jsonEncode(
    _canonical({
      'version': 1,
      'filters': filters.map((filter) => filter.toJson()).toList(),
      'orderBy': orderBy.map((order) => order.toJson()).toList(),
    }),
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'filters': filters.map((filter) => filter.toJson()).toList(),
    'orderBy': orderBy.map((order) => order.toJson()).toList(),
    if (limit != null) 'limit': limit,
    if (startAfter != null) 'startAfter': startAfter!.toJson(),
  };

  /// Uses all ordered values and ID, so equal field values cannot skip siblings.
  QueryCursor cursorFor(DocumentSnapshot document, {String? scopeKey}) {
    if (!_matches(document)) {
      throw ArgumentError('Cursor document does not match this query.');
    }
    return QueryCursor._(
      querySignature: _signature,
      values: orderBy
          .map((order) => order.field._read(document.data!))
          .toList(),
      documentId: document.id,
      scopeKey: scopeKey,
    );
  }

  LocalQuerySnapshot evaluate(
    Iterable<DocumentSnapshot> cachedDocuments, {
    required QueryCacheMetadata metadata,
  }) {
    if (startAfter != null && startAfter!.scopeKey != metadata.scopeKey) {
      throw ArgumentError('Cursor belongs to a different local scope.');
    }
    final documents = <DocumentSnapshot>[];
    final ids = <String>{};
    var pending = false;
    var conflicts = false;
    for (final document in cachedDocuments) {
      if (!ids.add(document.id)) {
        throw ArgumentError('Duplicate document ID in cached views.');
      }
      pending |= document.hasPendingWrites;
      conflicts |= document.hasConflict;
      if (_matches(document) &&
          (startAfter == null || _compareCursor(document, startAfter!) > 0)) {
        documents.add(document);
      }
    }
    documents.sort(_compareDocuments);
    return LocalQuerySnapshot._(
      documents: limit == null ? documents : documents.take(limit!).toList(),
      metadata: metadata,
      hasPendingWrites: pending,
      hasConflicts: conflicts,
      query: this,
    );
  }

  bool _matches(DocumentSnapshot document) =>
      !document.deleted &&
      document.data != null &&
      filters.every((filter) => filter._matches(document.data!)) &&
      orderBy.every(
        (order) => !identical(order.field._read(document.data!), _missing),
      );

  int _compareDocuments(DocumentSnapshot left, DocumentSnapshot right) {
    for (final order in orderBy) {
      final comparison = _compareJson(
        order.field._read(left.data!),
        order.field._read(right.data!),
      );
      if (comparison != 0) return order.descending ? -comparison : comparison;
    }
    return _compareStrings(left.id, right.id);
  }

  int _compareCursor(DocumentSnapshot document, QueryCursor cursor) {
    for (var index = 0; index < orderBy.length; index++) {
      final order = orderBy[index];
      final comparison = _compareJson(
        order.field._read(document.data!),
        cursor.values[index],
      );
      if (comparison != 0) return order.descending ? -comparison : comparison;
    }
    return _compareStrings(document.id, cursor.documentId);
  }
}

final Object _missing = Object();

Object? _freezeValue(Object? value) {
  void validate(Object? item, int depth) {
    if (depth > 16) {
      throw ArgumentError('Query values exceed 16 nesting levels.');
    }
    switch (item) {
      case null || bool() || String():
        return;
      case num():
        if (!item.isFinite) {
          throw ArgumentError('Query numbers must be finite.');
        }
      case List():
        if (item.length > 256) {
          throw ArgumentError('Query arrays exceed 256 items.');
        }
        for (final child in item) {
          validate(child, depth + 1);
        }
      case Map():
        if (item.length > 256 || item.keys.any((key) => key is! String)) {
          throw ArgumentError('Query maps require at most 256 string keys.');
        }
        for (final child in item.values) {
          validate(child, depth + 1);
        }
      default:
        throw ArgumentError('Only JSON values are supported in queries.');
    }
  }

  validate(value, 0);
  if (utf8.encode(jsonEncode(value)).length > 8192) {
    throw ArgumentError('Query values exceed 8 KiB.');
  }
  return immutableJson({'value': value})['value'];
}

Map<String, Object?> _object(Object? raw) {
  if (raw is! Map || raw.keys.any((key) => key is! String)) {
    throw FormatException('Expected a query object.');
  }
  return raw.cast<String, Object?>();
}

void _keys(Map<String, Object?> value, Set<String> allowed) {
  if (value.keys.any((key) => !allowed.contains(key))) {
    throw FormatException('Unknown query object field.');
  }
}

QueryField _field(Object? raw) {
  if (raw is! List || raw.any((part) => part is! String)) {
    throw FormatException('A query field must be a list of names.');
  }
  return QueryField(raw.cast<String>());
}

Object? _canonical(Object? value) => switch (value) {
  Map() => {
    for (final key
        in (value.keys.cast<String>().toList()..sort(_compareStrings)))
      key: _canonical(value[key]),
  },
  List() => value.map(_canonical).toList(),
  _ => value,
};

bool _equalJson(Object? left, Object? right) => _compareJson(left, right) == 0;

int _typeOrder(Object? value) => switch (value) {
  null => 0,
  bool() => 1,
  num() => 2,
  String() => 3,
  List() => 4,
  Map() => 5,
  _ => throw ArgumentError('Unsupported JSON value.'),
};

int _compareJson(Object? left, Object? right) {
  final typeComparison = _typeOrder(left).compareTo(_typeOrder(right));
  if (typeComparison != 0) return typeComparison;
  if (left == null) return 0;
  if (left is bool) return (left ? 1 : 0).compareTo((right as bool) ? 1 : 0);
  if (left is num) {
    // Dart compareTo distinguishes -0.0; JSON numeric equality does not.
    if (left == right) return 0;
    return left.compareTo(right as num);
  }
  if (left is String) return _compareStrings(left, right as String);
  if (left is List) {
    final other = right as List;
    for (var index = 0; index < left.length && index < other.length; index++) {
      final comparison = _compareJson(left[index], other[index]);
      if (comparison != 0) return comparison;
    }
    return left.length.compareTo(other.length);
  }
  final map = left as Map;
  final other = right as Map;
  final keys = map.keys.cast<String>().toList()..sort(_compareStrings);
  final otherKeys = other.keys.cast<String>().toList()..sort(_compareStrings);
  for (
    var index = 0;
    index < keys.length && index < otherKeys.length;
    index++
  ) {
    final keyComparison = _compareStrings(keys[index], otherKeys[index]);
    if (keyComparison != 0) return keyComparison;
    final valueComparison = _compareJson(
      map[keys[index]],
      other[otherKeys[index]],
    );
    if (valueComparison != 0) return valueComparison;
  }
  return keys.length.compareTo(otherKeys.length);
}

int _compareStrings(String left, String right) {
  final a = left.runes.iterator;
  final b = right.runes.iterator;
  while (true) {
    final hasA = a.moveNext();
    final hasB = b.moveNext();
    if (!hasA || !hasB) return (hasA ? 1 : 0).compareTo(hasB ? 1 : 0);
    final comparison = a.current.compareTo(b.current);
    if (comparison != 0) return comparison;
  }
}
