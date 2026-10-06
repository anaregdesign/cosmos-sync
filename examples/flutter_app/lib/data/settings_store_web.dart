import 'package:web/web.dart' as web;

import 'settings_store.dart';

/// Only public connection settings, never tokens or cache authority.
class BrowserSettingsStore implements SettingsStore {
  const BrowserSettingsStore({this.key = 'cosmos-sync-example-v1.connection'});

  final String key;

  @override
  Future<String?> read() async => web.window.localStorage.getItem(key);

  @override
  Future<void> write(String value) async {
    if (value.length > 65536) {
      throw StateError('Public browser settings are too large.');
    }
    web.window.localStorage.setItem(key, value);
  }
}
