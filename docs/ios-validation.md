# iOS validation

On 2026-10-03, the normal Flutter application and simulator integration were
verified from an isolated archive of commit
`e7fa4ccb39873c84a1ff6ccc10e2bbe6ba89ec4f`. The installed tools were Flutter
3.44.6, Dart 3.12.2 and Xcode 27.0 (27A266a) on macOS arm64. Shared application,
SDK, BFF and native project sources were not changed during validation.

## Unsigned normal application

From `examples/flutter_app`:

```sh
flutter build ios --release --no-codesign
codesign --verify build/ios/iphoneos/Runner.app
```

The release build passed in 98.4 seconds and produced an arm64 application with
minimum iOS version 15.0. `codesign --verify` exited 1 specifically because the
code object was not signed. Its executable hash remained unchanged after the
simulator test. This proves compilation; an unsigned artifact cannot be
installed on a physical iPhone through the normal development workflow.

## Simulator application integration

A dedicated disposable iPhone 16 Pro simulator on the already installed iOS
26.5 runtime passed the native application integration test and Go
`TestDartFixture`. The test used actual local HTTP and SQLite, a disposable signed
JWT/JWKS issuer, and a test-only OIDC adapter. It covered offline pending writes,
controller close/reopen preserving the operation ID, reconnect ACK, both explicit
conflict choices, deletion tombstones and sign-out cache/pending/credential purge.
An isolated native Keychain key passed write/read/delete. The test's
credential-session store was an in-memory adapter; the native storage probe was
separate. The pass marker was:

```text
COSMOS_SYNC_APP_PASS ios realHttp=true realSqlite=true auth=test-adapter nativeSecureStorage=verified
```

Generic simulator prebuild first failed when Xcode 27's `lipo -verify_arch`
rejected Flutter's multiple architecture arguments. The installed SDK source
and verbose build log matched
[Flutter issue #188461](https://github.com/flutter/flutter/issues/188461).
An ephemeral arm64-only Xcode configuration resolved that failure. With signing
disabled, the simulator app launched but native Keychain operations failed.
Simulator-local ad-hoc signing resolved the storage failure. No Apple
Development Team, certificate, provisioning profile, portal operation or
`-allowProvisioningUpdates` flag was used.

To reproduce with this toolchain, create a disposable simulator and privately
retain its selected ID. Set `XCODE_XCCONFIG_FILE` to a temporary file containing:

```xcconfig
ARCHS[sdk=iphonesimulator*] = arm64
ONLY_ACTIVE_ARCH[sdk=iphonesimulator*] = YES
CODE_SIGNING_ALLOWED[sdk=iphonesimulator*] = YES
CODE_SIGNING_REQUIRED[sdk=iphonesimulator*] = YES
CODE_SIGN_IDENTITY[sdk=iphonesimulator*] = -
DEVELOPMENT_TEAM[sdk=iphonesimulator*] =
```

The documented `xcodebuild` environment variable applies those settings to the
build without editing the installed SDK or shared project. At the verified
commit, `tools/flutter_app_smoke.py` prebuilt only macOS. Its isolated archive
received this temporary branch after the macOS prebuild, before the bounded Go
fixture starts, so the same generated control URL is used during both builds:

```python
else:
    subprocess.run(
        [flutter, "build", "ios", "--simulator", "--debug",
         f"--target={target}", define],
        cwd=app, check=True, timeout=600,
    )
```

Run from that isolated snapshot's repository root, capturing output in a private
log:

```sh
FLUTTER_BIN=/path/to/flutter \
XCODE_XCCONFIG_FILE=/private/temp/simulator-arm64-adhoc.xcconfig \
python3 tools/flutter_app_smoke.py --device <selected-disposable-simulator-id>
```

The passing run took 105.5 seconds including prebuild. Only the private runner
branch and temporary build configuration differed from the committed source.
The selected simulator was shut down, deleted and verified absent afterwards;
existing simulators and physical devices were unchanged. Sanitized local
evidence is retained in ignored, mode-0600
`artifacts/unsigned-ios-release.json` and `artifacts/ios-simulator-app.json`.

This verification does not establish real Entra browser login, consent or
refresh, live Azure Cosmos/RBAC, physical iPhone runtime, OS process-death
durability, or x86_64 simulator compatibility. Controller close/reopen occurs
within one process. The separate release artifact remains unsigned.
