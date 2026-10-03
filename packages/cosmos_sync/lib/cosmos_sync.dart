/// Native offline document synchronization with the Cosmos Sync BFF.
library;

export 'src/client.dart';
export 'src/cache_store.dart';
export 'src/http_transport.dart';
export 'src/models.dart';
export 'src/authorization.dart'
    show
        BuiltinAccount,
        SharedScope,
        SharedScopeMember,
        SharedScopeRole,
        CreateSharedScopeRequest,
        SetSharedScopeMemberRequest;
export 'src/query.dart';
export 'src/sqlite_cache.dart'
    if (dart.library.js_interop) 'src/indexed_db_cache.dart';
