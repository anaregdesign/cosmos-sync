import 'cache_store.dart';
import 'indexed_db_cache.dart';

Future<CacheStore> openCache(String name) => IndexedDbCache.open(name);
