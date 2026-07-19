import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'config.dart';
import 'dump/log_dumper.dart';
import 'dump/share_log_dumper.dart';
import 'log_entry.dart';
import 'log_formatter.dart';
import 'log_level.dart';
import 'native_bridge.dart';
import 'sinks/console_sink.dart';
import 'sinks/file_sink.dart';
import 'sinks/log_sink.dart';
import 'sinks/ring_buffer_sink.dart';

/// Static facade for structured, retained, shareable app logging.
///
/// Call [init] once (typically in `main()`, before `runApp`); it is also
/// safe to call from background isolate entry points (workmanager,
/// FCM background handler, ...) — see [init] for the idempotency contract.
class LogVault {
  LogVault._();

  static LogVaultConfig? _config;
  static final List<LogSink> _sinks = [];
  static FileSink? _fileSink;
  static RingBufferSink? _ringBuffer;
  static Directory? _directory;
  static LogDumper? _dumper;
  static NativeLogBridge? _nativeBridge;
  static Future<void>? _initFuture;

  /// Initializes logging with [config].
  ///
  /// Idempotency contract: only the **first** call's [config] takes effect
  /// for the lifetime of this isolate — this avoids a background isolate
  /// entry point silently overriding the main isolate's configuration, or
  /// vice versa. Every subsequent call logs a warning and returns the
  /// **same `Future`** as the first call, resolving only once that first
  /// call's initialization has actually finished — a second caller that
  /// `await`s [init] is guaranteed logging is ready when it resolves, even
  /// if it raced the first caller.
  ///
  /// Note the ring buffer used by [recentEntries] / `LogViewerPage` is
  /// isolate-local: entries logged from a background isolate will not
  /// appear in the main isolate's buffer, though they are still written to
  /// disk (and therefore included in [dumpLogs]).
  ///
  /// Neither a missing platform binding (e.g. a bare `Isolate.spawn`/
  /// `Isolate.run` isolate with no Flutter binding, so no
  /// `getApplicationSupportDirectory()`/`MethodChannel` access) nor a
  /// failure to attach the native log bridge causes [init] to throw —
  /// logging degrades to console-only rather than taking the app down.
  /// [logFilesDirectory] / [dumpLogs] / [shareLogs] reflect the degraded
  /// state (see their docs).
  static Future<void> init(LogVaultConfig config) {
    final existing = _initFuture;
    if (existing != null) {
      developer.log(
        'LogVault.init() called more than once; keeping the first config.',
        name: 'log_vault',
        level: 900,
      );
      // Await the FIRST call's future, not a fresh no-op — a caller that
      // does `await LogVault.init(...)` must only see it resolve once
      // logging is actually ready, even if another call site raced it.
      return existing;
    }
    // Assigned before any `await` runs (the assignment itself is
    // synchronous), so two synchronous/near-simultaneous calls in this
    // isolate can't both read `null` above and both start their own init.
    final future = _initImpl(config);
    _initFuture = future;
    return future;
  }

  static Future<void> _initImpl(LogVaultConfig config) async {
    _config = config;

    _sinks.add(ConsoleSink(config.formatter));

    try {
      final directory = config.directory != null
          ? Directory(config.directory!)
          : Directory(
              p.join((await getApplicationSupportDirectory()).path, 'logs'),
            );

      final fileSink = FileSink(
        directory: directory,
        formatter: config.formatter,
        retention: config.retention,
        fileLoggingEnabled: config.fileLoggingEnabled,
      );
      await fileSink.init();

      _directory = directory;
      _fileSink = fileSink;
      _sinks.add(fileSink);

      // A single reused LogDumper (rather than one per dumpLogs()/
      // shareLogs() call) so it can delete the previous call's zip before
      // building a new one — see LogDumper's doc comment.
      _dumper = LogDumper(
        directory: directory,
        appName: config.appName,
        flush: fileSink.flush,
      );
    } catch (error, stackTrace) {
      // Most commonly: no Flutter binding in this isolate, so
      // getApplicationSupportDirectory()/path_provider's platform channel
      // is unavailable. File logging/dump/share are unavailable for the
      // rest of this isolate's lifetime; console + ring buffer still work.
      developer.log(
        'log_vault: file logging unavailable in this isolate, continuing '
        'with console/ring-buffer only: $error',
        name: 'log_vault',
        level: 1000,
        stackTrace: stackTrace,
      );
    }

    if (config.ringBufferCapacity > 0) {
      final ringBuffer = RingBufferSink(config.ringBufferCapacity);
      _ringBuffer = ringBuffer;
      _sinks.add(ringBuffer);
    }

    if (config.enableNativeBridge) {
      try {
        final bridge = NativeLogBridge(onEntry: _dispatch);
        bridge.attach();
        _nativeBridge = bridge;
      } catch (error, stackTrace) {
        // Most commonly: no Flutter binding in this isolate, so
        // MethodChannel.setMethodCallHandler has no binary messenger to
        // register against.
        developer.log(
          'log_vault: native log bridge unavailable in this isolate: $error',
          name: 'log_vault',
          level: 1000,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// Registers an additional [LogSink], e.g. to forward entries to
  /// Crashlytics/Sentry breadcrumbs via `CallbackLogSink`.
  ///
  /// A [LogSink] receives the raw [LogEntry] — [LogFormatter] (and
  /// therefore any configured [RedactionRule]s) has NOT been applied yet.
  /// If the sink forwards formatted text anywhere outside the device (as
  /// Crashlytics/Sentry breadcrumbs do), format it with [formatter] — not
  /// a fresh unconfigured `LogFormatter()` — so redaction still applies.
  static void addSink(LogSink sink) => _sinks.add(sink);

  /// The [LogFormatter] configured via [LogVaultConfig.formatter], including
  /// any redaction rules. Falls back to an unconfigured default before
  /// [init] completes. Use this — not a bare `LogFormatter()` — when
  /// formatting entries for a custom [LogSink] that leaves the device.
  static LogFormatter get formatter => _config?.formatter ?? const LogFormatter();

  static void v(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const {},
  }) => _log(
    LogLevel.verbose,
    message,
    tag: tag,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );

  static void d(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const {},
  }) => _log(
    LogLevel.debug,
    message,
    tag: tag,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );

  static void i(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const {},
  }) => _log(
    LogLevel.info,
    message,
    tag: tag,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );

  static void w(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const {},
  }) => _log(
    LogLevel.warn,
    message,
    tag: tag,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );

  static void e(
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const {},
  }) => _log(
    LogLevel.error,
    message,
    tag: tag,
    error: error,
    stackTrace: stackTrace,
    context: context,
  );

  static void _log(
    LogLevel level,
    String message, {
    String? tag,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> context = const {},
  }) {
    if (_config == null) {
      // assert() is stripped in release builds, so this call — and any
      // entry logged before LogVault.init() completes — would otherwise be
      // silently dropped with zero signal in production.
      developer.log(
        'log_vault: log call dropped, LogVault.init() has not completed yet: '
        '$message',
        name: 'log_vault',
        level: 900,
      );
      assert(false, 'LogVault.init() must be called before logging.');
      return;
    }

    _dispatch(
      LogEntry(
        timestamp: DateTime.now(),
        level: level,
        message: message,
        tag: tag,
        error: error,
        stackTrace: stackTrace,
        context: context,
      ),
    );
  }

  /// Applies the `minLevel` filter and fans [entry] out to every registered
  /// sink. Shared by [_log] (Dart call sites) and [NativeLogBridge] (native
  /// call sites arriving over the `log_vault` MethodChannel).
  ///
  /// Each sink is isolated: [LogSink.write] must not throw (per its own
  /// contract), but a caller-supplied sink (most commonly `CallbackLogSink`
  /// forwarding to Crashlytics/Sentry/analytics) can still misbehave. A
  /// single `LogVault.e(...)` call must never crash the code that called it
  /// just because one downstream sink had a bad moment — that would make
  /// logging itself a source of production incidents.
  static void _dispatch(LogEntry entry) {
    final config = _config;
    if (config == null || entry.level < config.minLevel) return;
    for (final sink in _sinks) {
      try {
        sink.write(entry);
      } catch (error, stackTrace) {
        // Deliberately NOT `assert(false, ...)` here: asserts throw in
        // debug/test builds too, which would defeat the entire point of
        // this try/catch (never propagate a sink failure to the log call
        // site) in exactly the builds where a broken sink is most likely
        // to be exercised, e.g. by a test. developer.log is loud enough
        // to be seen without being able to crash the caller.
        developer.log(
          'log_vault: sink ${sink.runtimeType} threw on write(), entry '
          'dropped for that sink only: $error',
          name: 'log_vault',
          level: 1000,
          stackTrace: stackTrace,
        );
      }
    }
  }

  /// The directory log files are written to. `null` until [init] completes,
  /// or permanently for an isolate where [init] could not resolve a
  /// directory (see [init]'s doc comment on degraded initialization).
  static Directory? get logFilesDirectory => _directory;

  /// Flushes pending writes, snapshots the current log files, and zips
  /// them (+ `metadata.json`) into a temp file. Does not require a
  /// [BuildContext] or `share_plus` UI — use this directly if the app has
  /// its own upload/support flow, or use [shareLogs] to also invoke the
  /// platform share sheet.
  ///
  /// Throws [StateError] if [init] has not been called, or if it was
  /// called but file logging could not be set up in this isolate (see
  /// [init]'s doc comment on degraded initialization).
  static Future<File> dumpLogs({Map<String, Object?> metadata = const {}}) {
    final dumper = _dumper;
    if (dumper == null) {
      throw StateError(
        _initFuture != null
            ? 'LogVault: file logging is unavailable in this isolate '
                  '(see the warning logged during init()); dumpLogs() has '
                  'nothing to export.'
            : 'LogVault.init() must be called before dumpLogs().',
      );
    }
    return dumper.dumpLogs(metadata: metadata);
  }

  /// Deletes the zip produced by the last [dumpLogs]/[shareLogs] call, if
  /// it still exists. Call this once the caller is done with the file
  /// (e.g. after an upload completes) to reclaim it immediately rather
  /// than waiting for the next dump to evict it.
  static Future<void> disposeLastDump() async {
    await _dumper?.disposeLastDump();
  }

  /// [dumpLogs] followed by the platform share sheet via `share_plus`.
  /// See [ShareLogDumper.share] for parameter details.
  static Future<ShareResult> shareLogs(
    BuildContext context, {
    String subject = 'App logs',
    Map<String, Object?> metadata = const {},
    List<XFile> extraFiles = const [],
    Rect? sharePositionOrigin,
  }) {
    final dumper = _dumper;
    if (dumper == null) {
      throw StateError(
        _initFuture != null
            ? 'LogVault: file logging is unavailable in this isolate '
                  '(see the warning logged during init()); shareLogs() has '
                  'nothing to export.'
            : 'LogVault.init() must be called before shareLogs().',
      );
    }
    return ShareLogDumper(dumper).share(
      context,
      subject: subject,
      metadata: metadata,
      extraFiles: extraFiles,
      sharePositionOrigin: sharePositionOrigin,
    );
  }

  /// Snapshot of the in-memory ring buffer (empty if `ringBufferCapacity`
  /// was 0 or [init] hasn't completed).
  static List<LogEntry> get recentEntries => _ringBuffer?.entries ?? const [];

  static LogVaultConfig? get configForTesting => _config;

  static FileSink? get fileSinkForTesting => _fileSink;

  /// Resets all static state. Test-only — production code has no legitimate
  /// reason to un-initialize logging mid-process.
  static Future<void> resetForTesting() async {
    for (final sink in _sinks) {
      await sink.dispose();
    }
    _sinks.clear();
    await _dumper?.disposeLastDump();
    await _nativeBridge?.detach();
    _config = null;
    _fileSink = null;
    _ringBuffer = null;
    _directory = null;
    _dumper = null;
    _nativeBridge = null;
    _initFuture = null;
  }
}
