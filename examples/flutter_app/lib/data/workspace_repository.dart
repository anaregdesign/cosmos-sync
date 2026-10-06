export 'workspace_repository_base.dart' show ConnectionConfig;
export 'workspace_repository_native.dart'
    if (dart.library.js_interop) 'workspace_repository_web.dart';
