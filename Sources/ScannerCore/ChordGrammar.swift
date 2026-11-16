import Foundation

/// Turns what the recognizer read into chord names, or into nothing.
///
/// The band above a staff holds more than chords: tempo marks, bar numbers,
/// navigation text, the title. So a reading only becomes a chord when it can be
/// spelled as one, and confusions are repaired only where the alternative could
/// not exist as a chord in the first place.
enum ChordGrammar {
  /// Root, quality (the jazz triangle included), extension, alterations, bass.
  static let chord = expression(
    "[A-G][b#\u{266d}\u{266f}]?"
      // a minor quality may go on with maj (a minor-major seventh: Cminmaj7, C-maj7, Cmmaj7)
      + "(?:(?:min|mi|MI|Mi|m|-)maj|maj|min|dim|aug|sus|MA|Ma|ma|MI|Mi|mi|[\u{25b3}\u{0394}+\\-om\u{00f8}])?"
      + "(?:6/9|69|13|11|[5679])?"
      + "(?:\\((?:(?:no|omit|add)\\d{1,2}|(?:[b#\u{266d}\u{266f}+]?\\d{1,2}){1,2})\\)"
      + "|[b#+]\\d{1,2}){0,2}"
      + "(?:/[A-G][b#\u{266d}\u{266f}]?)?")
  private static let anchored = expression(
    "^(?:" + chord.pattern + ")$")
  private static let alteration = expression("\\((?:b|#)(?:5|9|11|13)\\)$")
  private static let flatConfusion = expression("\\(([6BS])(5|9|11|13)\\)")
  private static let contextFurniture = expression(
    "(?i)(?:FINE|CODA|SEGNO|ENDING|TAKE|CHORUS|COPYRIGHT|SWING|TEMPO|"
      + "CAPO|REHEARSAL|VERSE|BRIDGE|INTRO|OUTRO|TAG|ENTERS?|DRUM|SETS|"
      + "PIANO|ALONE|LOOP|UNTIL|CUE|BAS{1,2})")
  private static let bassFragment = expression("^B\\s*a(?:s|\\s|$)")

  /// Confusions repaired before tokenising, because they break the grammar
  /// itself: a later repair would never see the damaged part.
  private static let pre: [(NSRegularExpression, String)] = [
    // Read correctly, but folded to letters before the CJK filter runs, since
    // the jazz triangle sits in that range.
    (expression("[\u{25b3}\u{0394}\u{2206}]"), "maj"),
    // a jazz font's small triangle read as a letter a: no chord puts an a between the root and a number or a
    // bracket (aug, add and alt go on with letters), so there it is the triangle
    (expression("(?<=^[A-G])[aA](?=[0-9(])"), "maj"),
    (expression("(?<=^[A-G][b#])[aA](?=[0-9(])"), "maj"),
    // the same after "min" or "-": F#mina7 is F#min with the triangle (a minor-major seventh). Not after a bare
    // m: "ma7" is a major seventh as printed
    (expression("(?<=^[A-G][b#]?(?:min|-))[aA](?=[0-9(])"), "maj"),
    // a sharp read as a dollar sign, before a number or in a bracket
    (expression("\\$(?=[0-9])"), "#"),
    (expression("(?<=[A-G])M[13](?![0-9])"), "m"),
    (expression("(?<=[A-G][b#])M[13](?![0-9])"), "m"),
    (expression("(?<=[A-G])(?:MI|Mi)(?![a-z])"), "m"),
    (expression("(?<=[A-G])(?:MA|Ma)(?![a-z])"), "maj"),
    (expression("(?<=[A-G][b#])(?:MI|Mi)(?![a-z])"), "m"),
    (expression("(?<=[A-G][b#])(?:MA|Ma)(?![a-z])"), "maj"),
    (expression("[mM][ai][ij](?=\\d)"), "maj"),
    (expression("\\(([BS6])([S5])\\)"), "(b5)"),
    (expression("\\(([B6])(9|13|11)\\)"), "(b$2)"),
  ]

  /// Furniture that shares the band with the chords.
  private static let noise: [NSRegularExpression] = [
    // OCR can glue a root-like letter to a navigation word: CTAKE used to
    // emit C, A and E, while ENDING7 emitted D and G7. Discard that complete
    // token but preserve chord tokens separated from it by whitespace.
    expression(
      "(?i)\\S*(?:FINE|CODA|SEGNO|ENDING|TAKE|CHORUS|COPYRIGHT|SWING|TEMPO|"
        + "CAPO|REHEARSAL|VERSE|BRIDGE|INTRO|OUTRO|TAG|ENTERS?|DRUM|SETS|"
        + "PIANO|ALONE|LOOP|UNTIL|CUE)\\S*"),
    expression("\\S*=\\s*\\d+"),                       // J=80, A= 120
    expression("^\\s*\\d+"),                            // leading bar number
    expression("(?i)D\\.?\\s?[SC]\\.?.*$"),             // D.S. al Coda
    expression("(?i)(al\\s*)?Coda|To\\s*Coda|\\bda\\b|FINE|N\\.?C\\.?"),
    expression("(?i)\\b(TAKE|ENDING|CHORUS|COPYRIGHT|Swing|CHET|BAKER|ALL)\\b.*"),
    expression("[_\u{2500}-\u{9fff}]"),                 // rules and CJK misreads
    // a bracket that is not an alteration, omission, or addition
    expression("\\((?![b#\u{266d}\u{266f}]?\\d|(?:no|omit|add)\\d)[^)]*\\)?"),
  ]

  private static func expression(_ pattern: String) -> NSRegularExpression {
    // Every pattern here is a literal in this file; a failure is a build error.
    try! NSRegularExpression(pattern: pattern)
  }

  static func isChord(_ token: String) -> Bool {
    let range = NSRange(token.startIndex..., in: token)
    return anchored.firstMatch(in: token, range: range) != nil
  }

  /// Fix confusions that produce a chord which cannot exist, and only those.
  static func repair(_ token: String) -> String {
    var token = token
    for (wrong, right) in [("mai", "maj"), ("mri", "maj"), ("moj", "maj"), ("ma7", "maj7")]
    where token.contains(wrong) && !token.contains("maj") {
      let candidate = token.replacingOccurrences(of: wrong, with: right)
      if isChord(candidate) { token = candidate }
    }
    // A flat read as 6 / B / S inside an alteration: (65) -> (b5), (69) -> (b9).
    let range = NSRange(token.startIndex..., in: token)
    if alteration.firstMatch(in: token, range: range) == nil,
      let match = flatConfusion.firstMatch(in: token, range: range),
      let whole = Range(match.range, in: token),
      let digits = Range(match.range(at: 2), in: token)
    {
      let candidate = token.replacingCharacters(in: whole, with: "(b\(token[digits]))")
      if isChord(candidate) { return candidate }
    }
    return token
  }

  /// Apply only repairs which are safe for a complete, isolated chord symbol.
  /// Unlike `normalise`, this never deletes surrounding prose or bar numbers.
  static func normaliseSymbol(_ text: String) -> String {
    var text = text
    for (pattern, replacement) in pre {
      text = pattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  static func normalise(_ text: String) -> String {
    var text = normaliseSymbol(text)
    for pattern in noise {
      text = pattern.stringByReplacingMatches(
        in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }
    return text.trimmingCharacters(in: .whitespaces)
  }

  static func chords(in text: String) -> [String] {
    let clean = normalise(text)
    let range = NSRange(clean.startIndex..., in: clean)
    return chord.matches(in: clean, range: range).compactMap { match in
      Range(match.range, in: clean).map { repair(String(clean[$0])) }
    }
  }

  /// Map a normalized match back to its character positions in the OCR token.
  /// Only a leading measure number has an unambiguous reverse mapping; other
  /// length-changing repairs retain the conservative token-wide location.
  static func rawMatchOffsets(
    raw: String, clean: String, lower: Int, upper: Int
  ) -> (lower: Int, upper: Int) {
    if clean == raw { return (lower, upper) }
    let characters = Array(raw)
    let prefix = characters.prefix(while: \.isNumber).count
    if prefix > 0 {
      let tail = String(characters.dropFirst(prefix))
      if normalise(tail) == tail, tail == clean { return (prefix + lower, prefix + upper) }
    }
    return (0, characters.count)
  }

  /// A deliberately narrow prose-cue rejection. A real B- chord can sit under
  /// "Bass Enters", so only a weak, narrow, bare root at the system margin is
  /// rejected, and only when a local reread exposes cue vocabulary.
  static func looksLikeLeftMarginStaffText(
    chord: String, confidence: Float, x0: Double, width: Double,
    minX: Double, unit: Double, context: String
  ) -> Bool {
    guard chord.range(of: "^[A-G]$", options: .regularExpression) != nil,
      confidence < 0.8, width <= 1.5 * unit, x0 < minX + 2.5 * unit
    else { return false }
    let compact = context.filter { !$0.isWhitespace }
    let compactRange = NSRange(compact.startIndex..., in: compact)
    let contextRange = NSRange(context.startIndex..., in: context)
    return contextFurniture.firstMatch(in: compact, range: compactRange) != nil
      || bassFragment.firstMatch(in: context, range: contextRange) != nil
  }
}
