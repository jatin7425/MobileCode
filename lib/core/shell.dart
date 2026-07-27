/// Helpers for building command lines that are sent to a remote POSIX shell.
library;

/// Wraps [value] in single quotes so a POSIX shell treats it as one literal
/// argument.
///
/// Inside single quotes the shell interprets nothing, so the only character
/// needing care is the single quote itself: close the quote, emit an escaped
/// quote, reopen. `it's` becomes `'it'\''s'`.
///
/// Everything interpolated into a remote command line goes through here. A
/// directory name with a space or a `$` in it is not an edge case worth
/// skipping — it is a Tuesday.
String shellQuote(String value) {
  if (value.isEmpty) return "''";
  return "'${value.replaceAll("'", r"'\''")}'";
}

/// Joins [parts] into a single shell command, quoting each part.
String shellJoin(Iterable<String> parts) => parts.map(shellQuote).join(' ');
