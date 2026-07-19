import 'log_entry.dart';
import 'redaction_rule.dart';

/// Turns a [LogEntry] into the single-line string written to sinks.
///
/// The default implementation renders
/// `2026-07-18T12:34:56.000 D [Auth] token refresh failed | flowId=abc123`
/// followed by the error/stack trace on subsequent lines when present, then
/// applies [redactionRules] to the whole result.
class LogFormatter {
  const LogFormatter({this.redactionRules = const []});

  /// Applied, in order, as a final masking pass over the formatted line.
  /// Empty by default — callers must opt in (see README "Redaction").
  final List<RedactionRule> redactionRules;

  String format(LogEntry entry) {
    final buffer = StringBuffer()
      ..write(entry.timestamp.toIso8601String())
      ..write(' ')
      ..write(entry.level.shortName);

    if (entry.tag != null) {
      buffer
        ..write(' [')
        ..write(entry.tag)
        ..write(']');
    }

    buffer
      ..write(' ')
      ..write(entry.message);

    if (entry.context.isNotEmpty) {
      final pairs = entry.context.entries.map((e) => '${e.key}=${e.value}');
      buffer
        ..write(' | ')
        ..write(pairs.join(' '));
    }

    if (entry.error != null) {
      buffer
        ..writeln()
        ..write(entry.error);
    }
    if (entry.stackTrace != null) {
      buffer
        ..writeln()
        ..write(entry.stackTrace);
    }

    var result = buffer.toString();
    for (final rule in redactionRules) {
      result = rule.apply(result);
    }
    return result;
  }
}
