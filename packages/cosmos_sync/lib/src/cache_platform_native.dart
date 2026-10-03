import 'dart:async';

import 'cache_store.dart';
import 'sqlite_cache.dart';

FutureOr<CacheStore> openCache(String name) => SqliteCache(name);
