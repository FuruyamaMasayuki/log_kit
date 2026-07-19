import '../log_entry.dart';
import 'log_sink.dart';

/// Forwards entries to an arbitrary callback — the escape hatch for wiring
/// log_vault into Crashlytics/Sentry breadcrumbs, analytics, etc. without
/// log_vault itself depending on those packages.
class CallbackLogSink implements LogSink {
  CallbackLogSink(this._onEntry);

  final void Function(LogEntry entry) _onEntry;

  @override
  void write(LogEntry entry) => _onEntry(entry);

  @override
  Future<void> dispose() async {}
}
