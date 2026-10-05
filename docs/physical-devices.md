# Physical-device release verification

Issues: [physical-device gate #20](https://github.com/anaregdesign/cosmos-sync/issues/20),
[integrated live chain #24](https://github.com/anaregdesign/cosmos-sync/issues/24).

Physical-device results are a release gate separate from compilation, CI,
simulator execution and the earlier [native SDK fixture results](platforms.md).
The Flutter sample application is in `examples/flutter_app`; the deterministic
SDK fixture is in `examples/flutter_smoke`. A successful fixture run proves the
specified SDK scenario on real app-private SQLite. It does not prove a real
identity provider, deployed BFF, Azure account, app-store release signing or
background execution.

## Current verification order, 2026-10-05

The owner now defers real-device verification until development is complete.
Continue with local/native/browser tests and simulators first, then run the
final Android-only gate. Do not install or launch on a physical device during
that development phase. Previously recorded Android results remain historical
evidence; they do not establish unperformed OS process/relaunch, suspension or
integrated hosted acceptance. Physical iOS remains outside the selected scope.
Actual Google/Apple provider connections were separately cancelled as not
planned; common OIDC, authorization and offline safety are not waived.

The owner has now left the Android phone connected but cannot operate it for
the foreseeable period. Connection alone does not authorize unattended
provider login, physical installation or another browser-profile retry.
The requested browser-profile reopening was clarified to be Mac, not Android;
do not treat the uncorrelated AADSTS50020 report as an Android provider result.

Clean source `3214d0d` passed both the SDK SQLite fixture and ordinary local
signed-HTTP/SQLite/native-secure-storage application fixture on a newly owned
Android 14/API 34 emulator. Both runs returned zero and their exact platform
markers; the physical phone was not selected. The fixture's processes/reverse
mappings and owned emulator/AVD were removed, and the emulator ports released.
These debug fixtures prove neither actual CIAM authentication/Azure storage
nor OS process death, airplane mode or suspension. Exact source and additional
clean-checkout evidence are in [verification](verification.md#foreground-input-and-clean-source-simulator-evidence-2026-10-05).

## Current inventory and pending owner actions

Initial read-only discovery on 2026-10-03 found no attached Android device. Apple
CoreDevice remembers a paired iPhone 16 Pro and an iPad (`iPad17,2`): the iPhone
was booted with Developer Mode enabled but its local-network tunnel was
disconnected; the iPad was unavailable. Remembered pairing is not a usable
connection or permission to install. Four shutdown simulators were omitted from
the physical inventory.

After the owner selected the iPhone 16 Pro and Android phone, Flutter recognized
both supported physical targets: a Pixel 9a running Android 17 / API 37 and the
iPhone 16 Pro running iOS 26.7.1. Their exact identities were matched locally and
stored only in ignored `0600` files. The owner authorized test-app installation
and launch, then chose **unsigned iOS verification**. Consequently, no iOS
signing, Apple portal updates, profiles, certificate creation or physical iOS
installation is authorized. Android SDK and application runtime verification
passed on the selected phone; iOS physical runtime remains blocked by the operating system's
development-signing requirement.

## Current iOS verification choice: unsigned build

Respect the owner's current unsigned-only choice. A compilation check such as
the following can produce an unsigned device-target artifact without an Apple
team or provisioning operation:

```sh
cd examples/flutter_app
flutter build ios --release --no-codesign
```

This command is a build check, not an iPhone installation or runtime test. A
normal physical iOS device requires a signed development app and provisioning;
the generated unsigned `.app` cannot satisfy that requirement. Simulator
execution can provide separate iOS runtime evidence without Apple portal
provisioning, but it does not replace physical-device evidence. Do not attempt a
physical iOS install, invent a team, enable provisioning or treat an unsigned
build/Simulator pass as a physical-device pass.

The physical iOS gate can proceed only if the owner later explicitly changes
this decision and supplies the signing/provisioning authorization described
below. The Android gate is independent of that decision.

The normal unsigned iOS release build passed, and the iOS 26.5 simulator passed
the real HTTP/SQLite/native Keychain application fixture from core commit
`e7fa4ccb`. The simulator used only local ad-hoc signing, an empty team and a
temporary arm64 toolchain workaround; it was deleted afterwards. Reproducible
commands and the exact evidence limits are in [iOS validation](ios-validation.md).

The following prerequisites apply to any future authorized physical run. The
Android target/install grant is already supplied; iOS signing and provisioning
are currently declined:

| Gate | Required action |
| --- | --- |
| Android target | Identify one intended physical Android phone/tablet, unlock it, connect by USB and enable Developer options/USB debugging. Approve this Mac's RSA prompt on the device. Authorize installing and launching only the Cosmos Sync test/example app. |
| iOS target | Choose the intended iPhone or iPad, unlock it and connect by USB (or explicitly approve same-network testing). Trust this Mac if requested and enable Developer Mode when needed. Authorize installing and launching only the Cosmos Sync test/example app. |
| iOS development signing | Select the owner's existing Apple development team in Xcode for the fixture/example. The owner handles Apple sign-in, certificate/keychain prompts and any new agreement. Keep team selection local; do not commit credentials, profiles or device IDs. |
| Apple provisioning side effects | Explicitly permit Xcode to create/update profiles, app IDs and signing certificates and register the selected device under that team. Flutter's signed iOS build enables these Apple Developer portal operations; they can occur without a prompt. Ordinary app-install approval alone does not authorize them. |
| Real end-to-end access | Supply an approved HTTPS test BFF and native OIDC public-client configuration with registered callbacks. Sign into the provider in the system browser. Approve isolated test users/scopes and test-data writes in the chosen Azure environment. |
| Connectivity/lifecycle scenarios | Approve temporary manual airplane-mode/offline changes, swiping away the test app and reopening it. Avoid disconnecting the user's unrelated work. |

Passwords, refresh/access tokens, client secrets and signing keys must stay out
of chat, Issues, source, `--dart-define` and evidence files. Public issuer,
audience/client ID and callback settings are configuration, not credentials.
Do not create a new Apple account, accept SDK terms, pair a different device,
install a profile or publish an app as a shortcut around these gates.

Android's hardware guide requires developer options, USB debugging and device
authorization; use [Android's official connection procedure](https://developer.android.com/studio/run/device).
Flutter documents the [Android development setup](https://docs.flutter.dev/platform-integration/android/setup)
and [iOS trust, Developer Mode and development signing setup](https://docs.flutter.dev/platform-integration/ios/setup).
The owner can follow [Apple's Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).
App-store distribution is a separate workflow described by Flutter's
[Android release guide](https://docs.flutter.dev/deployment/android) and
[iOS release guide](https://docs.flutter.dev/deployment/ios); publishing this SDK
does not require releasing the sample app to either store.

## Read-only inventory

```sh
python3 tools/device_validation.py inventory
```

The script lists model, OS and connection status only. It omits user-assigned
device names, serials, UDIDs and hostnames. It reports discovery errors as
errors; an empty or failed inventory is never a passing runtime test. Normal
ADB/CoreDevice discovery may start their local discovery service, but does not
pair, install, sign, launch or change device connectivity. Sandbox access to
these local services may require an approved read-only tool escalation.

## Authorized SDK fixture

After the owner has selected and authorized a target, record its exact Flutter
device ID in an ignored local `.cache/devices/android.txt` or
`.cache/devices/ios.txt` file with permissions `0600`. Obtain the ID locally;
do not paste it into an Issue. Resolve the fixture's dependencies before the
run. The runner requires the explicit `--authorize-install` flag, rejects
simulators, unsupported/mismatched/ambiguous targets, and verifies a locally
configured, explicitly approved team before an iOS run. It does not answer
credential, license, trust or signing prompts.
The iOS preflight resolves `Runner`'s effective `Debug` settings using read-only
`xcodebuild -sdk iphoneos -showBuildSettings -json`, discards the raw output and requires its
resolved team to match the owner's exact selection. A literal team in an
unrelated configuration, an unresolved variable or missing setting is rejected.
The resolved platform/SDK must also be `iphoneos`, matching the signed physical
build rather than a simulator or a project's default SDK.
For iOS it additionally requires `--authorize-apple-provisioning`. The installed
Flutter 3.44.6 implementation adds Xcode's `-allowProvisioningUpdates` and
`-allowProvisioningDeviceRegistration` during signed builds (see the
[official Flutter source](https://github.com/flutter/flutter/blob/3.44.6/packages/flutter_tools/lib/src/ios/mac.dart#L382-L385)).
The installed `xcodebuild -help` explains that these flags allow profile,
app-ID/certificate updates and destination-device registration. Closing stdin
does not prevent those authenticated portal changes. Do not supply this flag
until the owner has explicitly authorized those effects for the chosen team and
device.

```sh
python3 tools/device_validation.py run-sdk \
  --platform android \
  --device-id-file .cache/devices/android.txt \
  --authorize-install \
  --output artifacts/physical-sdk-android.json

python3 tools/device_validation.py run-sdk \
  --platform ios \
  --device-id-file .cache/devices/ios.txt \
  --authorize-install \
  --authorize-apple-provisioning \
  --signing-team <owner-approved-existing-team> \
  --output artifacts/physical-sdk-ios.json
```

These commands install and run a debug test app and may leave the app installed;
uninstall it only with the owner's approval. They never create a signing team or
change its project settings. The explicitly authorized iOS signing step may
create/update provisioning profiles, app IDs and certificates and register the
selected device through the existing Xcode account. Do not run before these
authorizations. The documented iOS command is not authorized by the current
unsigned-only instruction. The fixture
uses a deterministic authorized transport and temporary app-private SQLite,
with no Azure connection. Passing evidence requires both a successful Flutter
test exit and the exact platform runtime marker. Evidence records commit,
toolchain, platform/runtime, fixture scope and pass/fail; raw logs and device identity
are discarded. Output stays in ignored `artifacts/` with permissions `0600`.
Attach only the redacted evidence to the relevant English Issue.
Evidence also marks whether the source tree differs from the recorded commit;
local signing edits or other active changes must not be represented as a clean,
exact-commit release test. An unknown dirty status is not a clean-tree assertion.
On interruption or timeout, the runner stops its own local tool process group;
this is not evidence that the device-side app was uninstalled or terminated.

## Acceptance matrix for the usable application

The selected Pixel 9a passed the ordinary application UI integration on
2026-10-03 with actual local Go HTTP, SQLite, pending writes, controller
close/reopen, reconnect ACK, explicit conflicts, tombstones and sign-out purge.
The isolated native secure-storage probe also passed. Authentication used the
signed-fixture adapter; this is not an Android Entra/Apple/Google login or Azure
storage result. Keyboard dismissal and tapping the checkbox tile fixed only the
integration test's small-screen interaction (`8500ad2`); no production workaround
was required. Four attempts are retained, including the initial failures, in
ignored private evidence. The passing marker is:

```text
COSMOS_SYNC_APP_PASS android realHttp=true realSqlite=true auth=test-adapter nativeSecureStorage=verified
```

To reproduce after selecting the same authorized physical target:

```sh
python3 tools/flutter_app_smoke.py --platform android \
  --device-id-file .cache/devices/android.txt --authorize-install \
  --output artifacts/physical-app-android-new-run.json
```

The runner prebuilds before starting the bounded Go fixture, reserves only its
two ADB reverse mappings, removes those mappings on completion and refuses an
existing evidence output. It never removes unrelated reverse mappings. This
test does not change airplane mode or force-kill the device app; close/reopen is
within one process.

| Scenario | Required observation on each selected physical Android/iOS target |
| --- | --- |
| Ordinary app launch and login | The owner runs the ordinary application, signs in through the configured provider and sees the correct account/scope. No test credentials are compiled into the app. |
| Online read/write/delete | Changes round-trip through the approved HTTPS BFF and isolated Cosmos partition; another authorized session sees changes and tombstones. |
| Offline restart | The owner disconnects networking, edits a test document, terminates/reopens the app and sees durable cached data, the same pending mutation identity and pending state. |
| Reconnection | Restoring networking preserves exact retry identity, reaches confirmed state without duplicate effects and resumes incremental synchronization. |
| Concurrent editing | Two authorized sessions produce a stale-version conflict; the app displays it and an explicit resolution reaches a confirmed result. |
| Permission/token loss | Test-token expiry and server grant loss trigger pause/re-authentication or learned-revocation purge as designed; late responses do not repopulate revoked data. An offline device cannot learn a server revocation immediately. |
| Sign-out/account switch | Pending-work policy is explicit; sign-out purges the selected local cache and a new account cannot read the prior account's cache. |
| Suspend/resume | Foreground resumption refreshes authentication and resumes synchronization. No continuously running background-sync guarantee is inferred. |
| Storage and reporting | App-private SQLite opens on the device; redacted runtime evidence identifies the OS/toolchain/build scope without serials, tokens or production data. Plain SQLite is not encryption. |

The fixture, app UI with a local HTTP fixture, physical app with real OIDC/BFF,
and real Azure storage are four distinct evidence scopes. Mark each accurately.
A release-quality build can later be tested with owner-approved distribution
signing; a debug SDK fixture is not equivalent to a signed production artifact.
Linux/Windows Flutter apps, alternate browsers, backup policy, encrypted cache
and long background execution remain outside the recorded physical matrix
unless separately exercised and documented.

## Recorded physical runtime evidence

| Target and scope | Actual result |
| --- | --- |
| Pixel 9a, Android 17 / API 37, physical arm64; SDK fixture | PASS on 2026-10-03 at 22:33 JST. Flutter 3.44.6 / Dart 3.12.2; test exit `0` and exact `COSMOS_SYNC_NATIVE_PASS android` marker. Real app-private SQLite, debug app, deterministic authorized transport. |
| Pixel 9a; usable app UI with local real HTTP BFF/signed-auth fixture | PASS on 2026-10-03, recorded above: real HTTP/SQLite, isolated native secure storage, explicit ACK/conflict/tombstone/sign-out behavior. This is not production provider or Azure evidence. |
| iPhone 16 Pro, iOS 26.7.1, physical device | Not run. The owner chose unsigned verification; physical installation requires signing/provisioning that is currently not authorized. |

The Android SDK fixture exercised offline writes, cache close/reopen, exact
replay after a lost response, explicit stale-version conflict resolution, query
watches, delete/recreate and learned-permission-loss purge. Cache close/reopen
occurred inside the test process; this was not an OS crash, power-loss test or
manual foreground/background lifecycle test. The test used no live BFF,
production OIDC provider or Azure resource.

Redacted local evidence is `artifacts/physical-sdk-android.json` with permissions
`0600`; it contains no device identity or raw logs. Its recorded HEAD was
`b4b87386de5cc06856620dbadccbae64179b42e1` and `source_tree_dirty: true` because
implementation/documentation work and local test edits were active. This is
actual runtime evidence for the tested workspace, not a claim that the entire
final release commit has been physically validated. The sample smoke app may
remain installed; no uninstallation or device connectivity change was made.

Close the physical-device gate only after the agreed matrix passes on the
selected platforms, or the owner explicitly approves a narrower release scope.
The unsigned-only iOS decision must remain visible in supported-platform claims.
