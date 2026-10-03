# Native Flutter integration fixture

This unpublished app validates the local `cosmos_sync` SDK using real SQLite on
macOS, iOS Simulator and Android Emulator. It uses a deterministic test transport
and no Azure resources, accounts or secrets.

```sh
flutter pub get
flutter analyze
flutter test integration_test/offline_sync_test.dart -d macos
flutter test integration_test/offline_sync_test.dart -d <simulator-or-emulator-id>
```

The test taps the validation button, executes offline writes and cache reopen,
exact lost-ACK replay, conflict/retry, local query/watch, delete/recreate and
permission-loss purge, then asserts the app displays `Passed`. Each run creates
and removes its own cache directory under the application support directory.

See [recorded platform evidence](../../docs/platforms.md) for versions, commands,
results and the distinction between simulator, desktop and physical-device tests.
Use a dedicated disposable device; the iOS project deliberately has no signing
team. This fixture is not a production app or an authentication implementation.
