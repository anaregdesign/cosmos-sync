import 'dart:io';

import 'settings_store.dart';

class FileSettingsStore implements SettingsStore {
  const FileSettingsStore(this.file);
  final File file;

  @override
  Future<String?> read() async =>
      await file.exists() ? file.readAsString() : null;

  @override
  Future<void> write(String value) async {
    await file.parent.create(recursive: true);
    final temporary = File('${file.path}.tmp');
    await temporary.writeAsString(value, flush: true);
    await temporary.rename(file.path);
  }
}
