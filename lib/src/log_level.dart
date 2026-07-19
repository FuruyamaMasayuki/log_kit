/// Severity of a [LogEntry], ordered from least to most severe.
///
/// Comparison operators (`<`, `<=`, `>`, `>=`) are defined via [Comparable]
/// so callers can write `entry.level >= LogLevel.warn`.
enum LogLevel implements Comparable<LogLevel> {
  verbose(0, 'V'),
  debug(1, 'D'),
  info(2, 'I'),
  warn(3, 'W'),
  error(4, 'E');

  const LogLevel(this.severity, this.shortName);

  /// Numeric severity, higher is more severe. Safe to compare across
  /// isolates/serialized forms since it is a fixed integer, not enum index.
  final int severity;

  /// Single-letter label used in the default log line format (e.g. `D`).
  final String shortName;

  @override
  int compareTo(LogLevel other) => severity.compareTo(other.severity);

  bool operator <(LogLevel other) => compareTo(other) < 0;

  bool operator <=(LogLevel other) => compareTo(other) <= 0;

  bool operator >(LogLevel other) => compareTo(other) > 0;

  bool operator >=(LogLevel other) => compareTo(other) >= 0;
}
