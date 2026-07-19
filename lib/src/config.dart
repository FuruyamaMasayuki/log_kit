import 'log_formatter.dart';
import 'log_level.dart';
import 'log_retention_policy.dart';

/// Configuration passed to `LogVault.init`.
///
/// Only the first successful `LogVault.init` call's config is used for the
/// lifetime of the isolate — see `LogVault.init` for the idempotency contract.
class LogVaultConfig {
  const LogVaultConfig({
    required this.appName,
    this.minLevel = LogLevel.debug,
    this.fileLoggingEnabled = _alwaysTrue,
    this.retention = const LogRetentionPolicy(),
    this.ringBufferCapacity = 500,
    this.directory,
    this.formatter = const LogFormatter(),
    this.enableNativeBridge = true,
  });

  /// Used as the default tag prefix and in dump metadata.
  final String appName;

  /// Entries below this level are dropped before reaching any sink.
  final LogLevel minLevel;

  /// Evaluated once per log call. Lets callers gate file writes on
  /// app-specific conditions (debug build, internal test build flag, a
  /// remote-config kill switch, ...) without baking that logic into
  /// log_vault itself.
  final bool Function() fileLoggingEnabled;

  final LogRetentionPolicy retention;

  /// Number of recent entries kept in memory for `LogViewerPage` /
  /// programmatic inspection. Set to 0 to disable the ring buffer sink.
  final int ringBufferCapacity;

  /// Overrides the log file directory. Defaults to
  /// `<applicationSupportDirectory>/logs`.
  final String? directory;

  final LogFormatter formatter;

  /// When true (default), registers a `log_vault` `MethodChannel` handler so
  /// native (Kotlin/Swift) app code can log through `LogVaultNative` — see
  /// `NativeLogBridge`. Set to false to opt out (e.g. in isolates that
  /// should not own the channel, or in tests that don't stub platform
  /// channels).
  final bool enableNativeBridge;

  static bool _alwaysTrue() => true;
}
