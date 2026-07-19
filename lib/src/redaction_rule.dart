/// A rule that masks sensitive substrings (tokens, phone numbers, etc.)
/// before a formatted log line is handed to any [LogSink].
///
/// Log dumps leave the device (support/QA channels), so anything matched by
/// [pattern] is replaced with [replacement] in the final formatted string.
/// The default [LogFormatter] applies rules in the order they are provided.
class RedactionRule {
  const RedactionRule(this.pattern, {this.replacement = '***'});

  final RegExp pattern;
  final String replacement;

  String apply(String input) => input.replaceAll(pattern, replacement);
}
