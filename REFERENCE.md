# log_kit API reference

Full public API surface, grouped by file. All types are exported from
`package:log_kit/log_kit.dart`. See [README.md](README.md) for usage
examples and [DESIGN.md](DESIGN.md) for rationale.

## `LogKit` (`lib/src/log_kit.dart`)

Static facade — the main entry point for almost all usage.

| Member | Signature | Notes |
|---|---|---|
| `init` | `static Future<void> init(LogKitConfig config)` | Idempotent — only the first call's config takes effect for the isolate's lifetime; later calls log a warning and no-op. Sets up `ConsoleSink`, `FileSink`, optionally `RingBufferSink`, `LogDumper`, and (if `config.enableNativeBridge`) `NativeLogBridge`. Never throws: if this isolate has no Flutter binding (e.g. a bare `Isolate.spawn`/`Isolate.run`), directory resolution and native-bridge attach failures are caught and logged, and logging degrades to console/ring-buffer only — see `logFilesDirectory`/`dumpLogs`/`shareLogs`. |
| `v` / `d` / `i` / `w` / `e` | `static void x(String message, {String? tag, Object? error, StackTrace? stackTrace, Map<String, Object?> context = const {}})` | Logs at the corresponding `LogLevel`. Dropped (with a `developer.log` warning + assert) if called before `init()` completes. |
| `addSink` | `static void addSink(LogSink sink)` | Registers an additional sink, e.g. `CallbackLogSink` for Crashlytics/Sentry breadcrumb forwarding. Sinks receive the raw, unredacted `LogEntry` — format with `LogKit.formatter`, not a bare `LogFormatter()`, before sending text off-device. |
| `formatter` | `static LogFormatter get` | The configured `LogFormatter` (including redaction rules), or an unconfigured default before `init()` completes. |
| `logFilesDirectory` | `static Directory? get` | `null` until `init()` completes, or permanently if this isolate's `init()` couldn't resolve a directory (degraded init, see `init`). |
| `recentEntries` | `static List<LogEntry> get` | Snapshot of the in-memory ring buffer. Isolate-local — see README "Isolate notes". |
| `dumpLogs` | `static Future<File> dumpLogs({Map<String, Object?> metadata = const {}})` | Flushes pending writes, zips current log files + `metadata.json`. Throws `StateError` if called before `init()`, or if `init()` ran but file logging is unavailable in this isolate (degraded init). Deletes the *previous* dump automatically before building a new one. Concurrent calls are queued and run one at a time in call order — a second call never deletes a first call's in-progress temp files. |
| `shareLogs` | `static Future<ShareResult> shareLogs(BuildContext context, {String subject = 'App logs', Map<String, Object?> metadata = const {}, List<XFile> extraFiles = const [], Rect? sharePositionOrigin})` | `dumpLogs()` + platform share sheet via `share_plus`. Pass `sharePositionOrigin` explicitly on iPad if the default `context`-derived resolution might fail (e.g. calling from a context with no attached `RenderBox`). Same degraded-init `StateError` behavior as `dumpLogs`. |
| `disposeLastDump` | `static Future<void> disposeLastDump()` | Deletes the most recent dump's zip immediately (e.g. after an upload completes) instead of waiting for the next `dumpLogs()` call to evict it. |
| `resetForTesting` | `static Future<void> resetForTesting()` | Test-only. Disposes all sinks/dumper/native bridge and clears static state. |

## `LogKitConfig` (`lib/src/config.dart`)

Immutable config passed to `LogKit.init`.

| Field | Type | Default |
|---|---|---|
| `appName` | `String` (required) | — |
| `minLevel` | `LogLevel` | `LogLevel.debug` |
| `fileLoggingEnabled` | `bool Function()` | always `true` |
| `retention` | `LogRetentionPolicy` | `LogRetentionPolicy()` defaults |
| `ringBufferCapacity` | `int` | `500` (`0` disables the ring buffer sink) |
| `directory` | `String?` | `null` → `<applicationSupportDirectory>/logs` |
| `formatter` | `LogFormatter` | `LogFormatter()` defaults (no redaction) |
| `enableNativeBridge` | `bool` | `true` |

## `LogLevel` (`lib/src/log_level.dart`)

`enum LogLevel implements Comparable<LogLevel> { verbose, debug, info, warn, error }`

- `severity` (`int`, 0–4) and `shortName` (`String`, e.g. `'D'`) are public fields.
- Supports `<`, `<=`, `>`, `>=` via `Comparable` — e.g. `entry.level >= LogLevel.warn`.

## `LogEntry` (`lib/src/log_entry.dart`)

Immutable record built by `LogKit` for every log call (Dart or native).

```dart
LogEntry({
  required DateTime timestamp,
  required LogLevel level,
  required String message,
  String? tag,
  Object? error,
  StackTrace? stackTrace,
  Map<String, Object?> context = const {},
})
```

`context` carries structured metadata (e.g. `{'flowId': '...'}` or, for
native-originated entries, `{'platform': 'android'}`).

## `LogFormatter` (`lib/src/log_formatter.dart`)

```dart
class LogFormatter {
  const LogFormatter({List<RedactionRule> redactionRules = const []});
  String format(LogEntry entry);
}
```

Default line shape:
`2026-07-18T12:34:56.000 D [Auth] token refresh failed | flowId=abc123`,
followed by `error`/`stackTrace` on their own lines when present. Applies
`redactionRules` (in order) as a final pass over the whole formatted
string. Used by every sink for its line format, and by `LogViewerPage` for
display.

## `RedactionRule` (`lib/src/redaction_rule.dart`)

```dart
class RedactionRule {
  const RedactionRule(RegExp pattern, {String replacement = '***'});
}
```

## `LogRetentionPolicy` (`lib/src/log_retention_policy.dart`)

```dart
class LogRetentionPolicy {
  const LogRetentionPolicy({
    int maxAgeDays = 7,
    int maxTotalBytes = 50 * 1024 * 1024,
    int maxFileBytes = 5 * 1024 * 1024,
  });
}
```

## Sinks (`lib/src/sinks/`)

All implement:

```dart
abstract class LogSink {
  void write(LogEntry entry);
  Future<void> dispose() async {}
}
```

- **`ConsoleSink`** — `dart:developer` `log()`, debug/profile builds only.
- **`RingBufferSink(int capacity)`** — keeps the last `capacity` entries in memory. `entries` (`List<LogEntry>`, unmodifiable snapshot), `clear()`.
- **`CallbackLogSink(void Function(LogEntry) onEntry)`** — forwards to an arbitrary callback (Crashlytics/Sentry/analytics bridging).
- **`FileSink`** — the retention engine:
  ```dart
  FileSink({
    required Directory directory,
    required LogFormatter formatter,
    required LogRetentionPolicy retention,
    required bool Function() fileLoggingEnabled,
    DateTime Function() now = DateTime.now, // injectable clock, tests only
  })
  ```
  - `Future<void> init()` — creates the directory, runs startup cleanup. Must be called before the first `write()` (handled internally by `LogKit.init`).
  - `Future<void> flush()` — awaits all writes issued so far on this isolate.
  - `static final RegExp fileNamePattern` — matches `log_YYYYMMDD.log` / `log_YYYYMMDD_N.log`; also used by `LogDumper` to avoid picking up unrelated files.
  - Rotates to a new file when the day changes, or when the current file would exceed `retention.maxFileBytes` (sized by UTF-8 byte length, not `String.length`). Startup cleanup deletes files older than `maxAgeDays`, then deletes oldest-by-`mtime` files until under `maxTotalBytes` — **never** by filename lexical order (breaks once a day has a double-digit suffix).

## Dump/share (`lib/src/dump/`)

- **`LogDumper`** — zip-building only, no UI/`share_plus` dependency:
  ```dart
  LogDumper({required Directory directory, required String appName, Future<void> Function()? flush})
  Future<File> dumpLogs({Map<String, Object?> metadata = const {}})
  Future<void> disposeLastDump()
  ```
  Flushes → copies matching log files into a temp snapshot dir → writes
  `metadata.json` (merges `appName`, `generatedAt`, and caller-supplied
  `metadata`) → zips on a background isolate via `Isolate.run` (only
  primitive path strings cross the isolate boundary). Deletes the
  *previous* dump it produced at the start of each `dumpLogs()` call.
  `metadata` values that aren't natively JSON-encodable (e.g. `DateTime`)
  are best-effort stringified via `toString()` rather than throwing.

- **`ShareLogDumper`** — thin `share_plus` wrapper over a `LogDumper`:
  ```dart
  ShareLogDumper(LogDumper dumper)
  Future<ShareResult> share(BuildContext context, {String subject, Map<String, Object?> metadata, List<XFile> extraFiles, Rect? sharePositionOrigin})
  ```
  Resolves `sharePositionOrigin` from the context's `RenderBox` when not
  passed explicitly (required to avoid a share-sheet issue on iPad); logs
  a warning if that resolution fails.

## `NativeLogBridge` (`lib/src/native_bridge.dart`)

```dart
NativeLogBridge({
  MethodChannel channel = const MethodChannel('log_kit'),
  required void Function(LogEntry entry) onEntry,
})
void attach();
Future<void> detach();
```

Listens for `'log'` method calls on the `log_kit` channel (sent by the
native `LogKitNative` in `android/`/`ios/`) and turns each into a
`LogEntry` for `onEntry`. Expects the call arguments map to contain
`level`, `tag`, `message`, optional `error`, optional `platform`, optional
`timestampMillis` (falls back to `DateTime.now()` if absent). An
unrecognized `level` string falls back to `LogLevel.info`.

## `LogViewerPage` (`lib/src/viewer/log_viewer_page.dart`)

```dart
const LogViewerPage({Key? key, LogFormatter formatter = const LogFormatter()})
```

A minimal `StatelessWidget` listing `LogKit.recentEntries` (most recent
first) with a share button that calls `LogKit.shareLogs`, and a "no log
files" dialog if `LogKit.logFilesDirectory` is empty. Shows only the
current isolate's ring buffer — not a substitute for the full on-disk
files that `shareLogs()` exports (see README "Isolate notes").

## Native platform API

### Android — `com.flutterplugin.log_kit.LogKitNative` (Kotlin)

```kotlin
object LogKitNative {
    fun v(tag: String, message: String, error: String? = null)
    fun d(tag: String, message: String, error: String? = null)
    fun i(tag: String, message: String, error: String? = null)
    fun w(tag: String, message: String, error: String? = null)
    fun e(tag: String, message: String, error: String? = null)
}
```

Registered by `LogKitPlugin` (`FlutterPlugin`) via
`onAttachedToEngine`/`onDetachedFromEngine`. Calls made before the engine
attaches (or after it detaches) are silently dropped.

### iOS — `LogKitNative` (Swift)

```swift
public enum LogKitNative {
    static func v(tag: String, message: String, error: String? = nil)
    static func d(tag: String, message: String, error: String? = nil)
    static func i(tag: String, message: String, error: String? = nil)
    static func w(tag: String, message: String, error: String? = nil)
    static func e(tag: String, message: String, error: String? = nil)
}
```

Registered by `LogKitPlugin` (`FlutterPlugin`) via `register(with:)`.
