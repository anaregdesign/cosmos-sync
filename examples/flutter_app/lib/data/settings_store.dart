abstract interface class SettingsStore {
  Future<String?> read();
  Future<void> write(String value);
}
