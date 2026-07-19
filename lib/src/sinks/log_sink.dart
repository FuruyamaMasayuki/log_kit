import '../log_entry.dart';

/// A destination that receives every [LogEntry] that passes the configured
/// `minLevel` filter.
///
/// Implementations must not throw — `LogKit` does not catch sink errors,
/// since a broken sink should be loud during development rather than
/// silently swallowed.
abstract class LogSink {
  void write(LogEntry entry);

  /// Called by `LogKit` on app shutdown / hot restart cleanup, if the
  /// concrete sink needs to flush or release resources. No-op by default.
  Future<void> dispose() async {}
}
