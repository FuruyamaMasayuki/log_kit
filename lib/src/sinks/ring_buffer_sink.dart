import 'dart:collection';

import '../log_entry.dart';
import 'log_sink.dart';

/// Keeps the most recent [capacity] entries in memory for `LogViewerPage`
/// or programmatic inspection (e.g. attaching recent logs to a bug report
/// dialog without touching disk).
///
/// Isolate-local: entries logged from a background isolate (workmanager,
/// FCM background handler, ...) do not appear in the main isolate's ring
/// buffer, since each isolate runs its own `LogKit` instance. They are
/// still written to disk by `FileSink` and therefore included in dumps.
class RingBufferSink implements LogSink {
  RingBufferSink(this.capacity) : assert(capacity >= 0);

  final int capacity;
  final Queue<LogEntry> _entries = Queue<LogEntry>();

  List<LogEntry> get entries => List.unmodifiable(_entries);

  @override
  void write(LogEntry entry) {
    if (capacity == 0) return;
    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
  }

  void clear() => _entries.clear();

  @override
  Future<void> dispose() async {}
}
