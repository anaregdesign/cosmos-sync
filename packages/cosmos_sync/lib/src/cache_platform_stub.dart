import 'dart:async';

import 'cache_store.dart';

FutureOr<CacheStore> openCache(String name) => throw UnsupportedError(
  'No durable Cosmos Sync cache adapter is available on this platform.',
);
