import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../log_entry.dart';
import '../log_formatter.dart';
import '../log_level.dart';
import 'log_sink.dart';

/// Prints entries via `dart:developer`'s `log()` (visible in DevTools/IDE
/// consoles with proper log-level coloring). Only active in debug/profile
/// builds — release builds never pay for console formatting.
class ConsoleSink implements LogSink {
  ConsoleSink(this._formatter);

  final LogFormatter _formatter;

  /// `dart:developer`'s conventional severity scale (see `log()`'s `level`
  /// parameter doc): FINEST=300, FINE=500, INFO=800, WARNING=900,
  /// SEVERE=1000. A naive `severity * 200` maps error to 800 (= INFO) and
  /// warn to 600 (between CONFIG and FINE), which breaks DevTools/IDE
  /// level filtering and color-coding — map explicitly instead.
  ///
  /// Exposed (not private) so tests can assert against the real mapping
  /// table rather than a duplicated copy of it.
  static const Map<LogLevel, int> developerLevels = {
    LogLevel.verbose: 300,
    LogLevel.debug: 500,
    LogLevel.info: 800,
    LogLevel.warn: 900,
    LogLevel.error: 1000,
  };

  @override
  void write(LogEntry entry) {
    if (kReleaseMode) return;
    developer.log(
      _formatter.format(entry),
      name: entry.tag ?? 'log_kit',
      level: developerLevels[entry.level] ?? 800,
      error: entry.error,
      stackTrace: entry.stackTrace,
    );
  }

  @override
  Future<void> dispose() async {}
}
