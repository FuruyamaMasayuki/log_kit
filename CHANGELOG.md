## 0.1.0

Initial release.

* Log retention: in-memory ring buffer (`RingBufferSink`) + daily/size-rotated
  file storage (`FileSink`) with age- and total-size-based pruning.
* Shared log dump/export: `LogVault.dumpLogs()` (zip + `metadata.json`, no UI
  dependency) and `LogVault.shareLogs()` (adds the platform share sheet via
  `share_plus`), with automatic cleanup of the previous dump.
* Pluggable `LogSink`s, including `CallbackLogSink` for Crashlytics/Sentry
  breadcrumb forwarding.
* Opt-in redaction (`RedactionRule`) applied by `LogFormatter` before any
  line reaches a sink.
* Native (Kotlin/Swift) logging bridge: `LogVaultNative` on Android/iOS
  forwards to the same Dart-side pipeline over a `log_vault` `MethodChannel`.
* `LogViewerPage`, a minimal in-app log viewer over the ring buffer.
