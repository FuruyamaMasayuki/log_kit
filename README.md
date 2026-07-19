# log_vault

Log retention (in-memory ring buffer + rotating file storage) and shared log
dump/export for Flutter apps, with an optional native (Kotlin/Swift) logging
bridge. Extracted from an existing app's ad-hoc logging implementation and
generalized for reuse across multiple Flutter apps.

See [DESIGN.md](DESIGN.md) for the full design rationale and the review
history. This README is the day-to-day usage reference; see
[REFERENCE.md](REFERENCE.md) for the complete API surface.

## What this gives you

- **Retention**: entries kept in an in-memory ring buffer (for a quick
  in-app viewer) and persisted to daily, size-rotated log files on disk,
  with age- and total-size-based pruning.
- **Shared dump**: zip the log directory (+ a `metadata.json`) and hand it
  to the platform share sheet, or just get the zip `File` back and upload
  it yourself.
- **Native bridge**: call `LogVaultNative.d(tag, message)` from Kotlin or
  Swift app code and have it flow through the same Dart-side retention/
  formatting/redaction pipeline.

## Install

Add a `path:` dependency (this package is not published to pub.dev):

```yaml
dependencies:
  log_vault:
    path: ../../flutter_plugin/log
```

## Quick start

```dart
import 'package:log_vault/log_vault.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await LogVault.init(
    const LogVaultConfig(
      appName: 'my_app',
      // Gate file logging on whatever your app considers "safe to log":
      // fileLoggingEnabled: () => !kReleaseMode || isInternalBuild,
    ),
  );

  runApp(const MyApp());
}
```

Then, anywhere in the app:

```dart
LogVault.d('screen shown', tag: 'Nav');
LogVault.e('token refresh failed', tag: 'Auth', error: e, stackTrace: st);
```

### Sharing logs from a settings screen

```dart
ElevatedButton(
  onPressed: () async {
    final directory = LogVault.logFilesDirectory;
    final hasLogs = directory != null &&
        await directory.exists() &&
        await directory.list().any((_) => true);
    if (!hasLogs) {
      // show a "no logs yet" dialog — see LogViewerPage for a ready-made one
      return;
    }
    await LogVault.shareLogs(context, subject: 'App logs');
  },
  child: const Text('ログを共有'),
)
```

Or use the ready-made in-app viewer + share button:

```dart
Navigator.of(context).push(
  MaterialPageRoute(builder: (_) => const LogViewerPage()),
);
```

### Using the zip without the share sheet

```dart
final zipFile = await LogVault.dumpLogs(
  metadata: {'appVersion': packageInfo.version},
);
await myUploadApi.upload(zipFile);
await LogVault.disposeLastDump(); // reclaim the temp zip once you're done
```

If you don't call `disposeLastDump()`, `log_vault` still cleans up
automatically — the *next* `dumpLogs()`/`shareLogs()` call deletes the
previous zip before building a new one. At most one stale zip can exist on
disk at a time.

## Configuration (`LogVaultConfig`)

| Field | Default | Purpose |
|---|---|---|
| `appName` | required | Tag prefix / dump metadata / zip filename prefix |
| `minLevel` | `LogLevel.debug` | Entries below this are dropped before reaching any sink |
| `fileLoggingEnabled` | always `true` | `bool Function()`, evaluated per log call — gate file writes on your app's own dev/internal-build/kill-switch logic |
| `retention` | 7 days / 50MB total / 5MB per file | See `LogRetentionPolicy` |
| `ringBufferCapacity` | 500 | In-memory entries kept for `LogViewerPage`/`recentEntries`. `0` disables the ring buffer sink |
| `directory` | `<applicationSupportDirectory>/logs` | Override the log file location |
| `formatter` | default `LogFormatter()` | Controls line format and redaction (see below) |
| `enableNativeBridge` | `true` | Registers the `log_vault` MethodChannel handler so native code can log through `LogVaultNative` |

## Redaction

Log dumps leave the device. `LogFormatter` applies a final masking pass
over every formatted line — nothing is redacted by default, so opt in for
anything sensitive your app logs (tokens, phone numbers, etc.):

```dart
LogVaultConfig(
  appName: 'my_app',
  formatter: LogFormatter(
    redactionRules: [
      RedactionRule(RegExp(r'Bearer [A-Za-z0-9._-]+'), replacement: 'Bearer ***'),
    ],
  ),
)
```

## Forwarding to Crashlytics/Sentry

`log_vault` has no dependency on any crash-reporting SDK. Wire it in with
`addSink`. Sinks receive the **raw, unredacted** `LogEntry` — always format
with `LogVault.formatter` (the configured one, redaction rules included), not
a bare `LogFormatter()`, when the formatted text leaves the device (as
Crashlytics/Sentry breadcrumbs do):

```dart
LogVault.addSink(CallbackLogSink((entry) {
  if (entry.level >= LogLevel.warn) {
    FirebaseCrashlytics.instance.log(LogVault.formatter.format(entry));
  }
}));
```

## Native logging (Kotlin/Swift)

`log_vault` is a real Flutter plugin (has `android/` and `ios/` native code).
Call from native app code once the Flutter engine is running:

```kotlin
// Android (Kotlin)
LogVaultNative.d("Auth", "token refreshed")
LogVaultNative.e("Push", "failed to register token", error = e.toString())
```

```swift
// iOS (Swift)
LogVaultNative.d(tag: "Auth", message: "token refreshed")
LogVaultNative.e(tag: "Push", message: "failed to register token", error: "\(error)")
```

These forward over a `MethodChannel` to the same Dart-side `LogVault`
pipeline (retention, formatting, redaction, dump/share) — nothing is
duplicated natively. **Constraint**: a native call can only reach Dart
after `LogVault.init()` has completed in a running Flutter engine. Calls
made before Flutter starts (e.g. `Application.onCreate()`) are dropped —
there is no Dart isolate listening yet. Set
`LogVaultConfig(enableNativeBridge: false)` to opt out entirely.

> This environment has no Android SDK / Xcode toolchain, so the native
> Kotlin/Swift code has been reviewed but not build-verified. Confirm it
> compiles in a real app project (Android Studio / Xcode) before shipping.

## Isolate notes

- `LogVault.init()` is idempotent: only the **first** call's config takes
  effect for the isolate's lifetime (later calls are ignored, with a
  warning logged). This matters because `init()` is safe — and often
  necessary — to call again from background isolate entry points
  (workmanager, FCM background handler).
- `LogVault.recentEntries` (the ring buffer) is isolate-local: entries logged
  from a background isolate won't show up in the main isolate's
  `LogViewerPage`, though they're still written to disk and therefore
  included in `dumpLogs()`/`shareLogs()`.

## Testing

```
flutter test
```

`FileSink` and `LogDumper` both accept enough injected state (a clock, an
explicit directory) to unit test rotation/retention/dump behavior without
touching the real filesystem clock. See `test/` for examples.
