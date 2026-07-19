import 'log_level.dart';

/// A single structured log record produced by [LogKit].
class LogEntry {
  LogEntry({
    required this.timestamp,
    required this.level,
    required this.message,
    this.tag,
    this.error,
    this.stackTrace,
    this.context = const {},
  });

  final DateTime timestamp;
  final LogLevel level;
  final String message;

  /// Free-form category label, e.g. `'Auth'`, `'Chat'`.
  final String? tag;

  final Object? error;
  final StackTrace? stackTrace;

  /// Arbitrary structured metadata, e.g. `{'flowId': '...'}`. Kept as a
  /// separate map (rather than string-concatenated into [message]) so a
  /// custom [LogFormatter] or [LogSink] can consume it programmatically.
  final Map<String, Object?> context;
}
