import Foundation

/// Public validation for chord text produced outside ScannerCore, such as a
/// system language model. Keeping this at the ScannerCore boundary means every
/// recognizer is judged by the same grammar before its output reaches a score.
public enum ChordText {
  /// Returns one canonical chord symbol, or `nil` when the complete string is
  /// not a chord. This deliberately rejects strings that merely contain a
  /// chord-looking substring, such as `Fine C` or `Ending A`.
  /// Lead-sheet fonts print extensions raised (`C7ᵇ⁹`) and diminished as a
  /// degree sign (`B♭°`). Readers copy those glyphs faithfully, so they are
  /// mapped to the plain characters the chord grammar reads.
  static func plainGlyphs(_ text: String) -> String {
    let map: [Character: String] = [
      "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8",
      "⁹": "9", "ᵇ": "b", "⁺": "+", "⁻": "-", "⁽": "(", "⁾": ")", "°": "o", "º": "o",
    ]
    let plain = String(text.flatMap { map[$0] ?? String($0) })
    // German and hymnal books print a suspended fourth over its seventh as a fraction, D⁷⁄₄ (D7/4): a slash with
    // a 4 after a chord's number is the suspension, never a bass note (a bass is a letter)
    return suspendedFourth.stringByReplacingMatches(
      in: plain, range: NSRange(plain.startIndex..., in: plain), withTemplate: "sus4")
  }

  private static let suspendedFourth = try! NSRegularExpression(
    pattern: #"(?<=[A-G][b#♭♯]?[0-9]{1,2})[/⁄]4(?![0-9])"#)

  /// Lead sheets bracket an optional turnaround, `(Fm7 Bb13)`, so its first
  /// chord opens a parenthesis and its last one closes it. Those brackets are
  /// dropped; a bracketed alteration such as `C7(b9)` is balanced and kept.
  static func withoutTurnaroundBrackets(_ text: String) -> String {
    var text = Substring(text)
    if text.first == "(" { text = text.dropFirst() }
    if text.last == ")", text.filter({ $0 == ")" }).count > text.filter({ $0 == "(" }).count {
      text = text.dropLast()
    }
    return String(text)
  }

  public static func normalizedSymbol(_ text: String) -> String? {
    var candidate = ChordGrammar.normaliseSymbol(withoutTurnaroundBrackets(plainGlyphs(text)))
      .replacingOccurrences(of: "♭", with: "b")
      .replacingOccurrences(of: "♯", with: "#")
    candidate = ChordGrammar.repair(candidate)
    guard ChordGrammar.isChord(candidate) else { return nil }
    return candidate
  }

  /// Splits one reading that holds several chords, such as `F#sus F#` or
  /// `11 G D`, into canonical symbols. Bare numbers (printed measure numbers)
  /// and trailing punctuation are skipped; any other token that is not a chord
  /// rejects the whole reading, so `Fine C` is still refused.
  public static func normalizedSymbols(_ text: String) -> [String]? {
    if let single = normalizedSymbol(text) { return [single] }
    var chords: [String] = []
    for token in text.split(whereSeparator: \.isWhitespace) {
      if token.allSatisfy(\.isNumber) { continue }
      let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
      guard let chord = normalizedSymbol(trimmed) else { return nil }
      chords.append(chord)
    }
    return chords.isEmpty ? nil : chords
  }

  /// Chooses what to accept from a reader that reports both the printed text
  /// and its own tidied chord. The printed text wins whenever it is a chord,
  /// so a diminished `Fo` is never swapped for a model's `F#`. Otherwise every
  /// tidied chord must be printed as its own token, as `Db-7` is in
  /// `Db-7 Solo Over Form`, or be the whole text with its spaces closed.
  public static func acceptedSymbols(visibleText: String, proposedChord: String) -> [String]? {
    if let printed = normalizedSymbols(visibleText) { return printed }
    guard let proposed = normalizedSymbols(proposedChord) else { return nil }
    let tokens = visibleText.split(whereSeparator: \.isWhitespace).map { printedForm(String($0)) }
    if proposed.allSatisfy(tokens.contains) { return proposed }
    return tokens.joined() == proposed.joined() ? proposed : nil
  }

  /// How a cloud model's reading was judged.
  public enum Verdict: String, Codable, Sendable {
    /// A chord the grammar knows.
    case accepted
    /// A root, an optional slash bass and a suffix the grammar does not know,
    /// such as `C7sus4(b9)` or `Ebm(maj7)`. The model is trusted to have read
    /// it, and it is written with the suffix exactly as printed.
    case unusual
    /// Not a chord: a word, a number, or text with no root.
    case blocked
  }

  /// Judges a reading from the cloud model, which is trusted on what the chord
  /// is. The only question asked is whether the printed text is a chord at all:
  /// a known chord is accepted as before, and otherwise every token must be a
  /// root followed by chord characters, so `Fine`, `Coda`, `Piano Intro` and
  /// bar numbers stay out while unfamiliar suffixes come in.
  public static func modelSymbols(visibleText: String, proposedChord: String) -> (
    chords: [String], verdict: Verdict
  ) {
    if let known = acceptedSymbols(visibleText: visibleText, proposedChord: proposedChord) {
      return (known, .accepted)
    }
    let text = plainGlyphs(visibleText).trimmingCharacters(in: .whitespaces)
    if let single = looseSymbol(text.filter { !$0.isWhitespace }) { return ([single], .unusual) }
    var chords: [String] = []
    for token in text.split(whereSeparator: \.isWhitespace) {
      if token.allSatisfy(\.isNumber) { continue }
      let trimmed = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
      guard let chord = looseSymbol(trimmed) else { return ([], .blocked) }
      chords.append(chord)
    }
    return chords.isEmpty ? ([], .blocked) : (chords, .unusual)
  }

  private static let looseRoot = try! NSRegularExpression(
    pattern: #"^([A-G][b#]?)(.*?)(?:/([A-G][b#]?))?$"#)
  /// Everything a chord suffix is made of. Anything left over, such as the
  /// `oda` of `Coda` or the `ine` of `Fine`, makes the token a word.
  private static let looseSuffix = try! NSRegularExpression(
    pattern: #"^(?:maj|Maj|MAJ|min|Min|MIN|dim|aug|sus|add|alt|omit|no|MA|Ma|ma|MI|Mi|mi|m|M|[0-9]|[b#+\-()\[\],Δ∆^øØo/])*$"#)

  /// One token as a root, a trusted suffix and an optional slash bass, with
  /// ASCII accidentals; `nil` when it is not shaped like a chord.
  static func looseSymbol(_ token: String) -> String? {
    let text = withoutTurnaroundBrackets(token)
      .replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
    let range = NSRange(text.startIndex..., in: text)
    guard let match = looseRoot.firstMatch(in: text, range: range),
      let suffixRange = Range(match.range(at: 2), in: text)
    else { return nil }
    let suffix = String(text[suffixRange])
    guard !suffix.isEmpty || match.range(at: 3).location != NSNotFound,
      looseSuffix.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)) != nil,
      // A slash left in the suffix is only allowed as 6/9.
      !suffix.contains("/") || suffix.contains("6/9")
    else { return nil }
    return text
  }

  private static func printedForm(_ text: String) -> String {
    ChordGrammar.normaliseSymbol(withoutTurnaroundBrackets(text))
      .replacingOccurrences(of: "♭", with: "b")
      .replacingOccurrences(of: "♯", with: "#")
  }

  /// Recovers only strong chord-shaped tokens from text an external model put
  /// on its ignored list. Bare roots stay ignored because they are ambiguous
  /// with rehearsal marks; any prose token rejects the complete reading.
  public static func recoverableIgnoredSymbols(_ text: String) -> [String]? {
    guard let chords = normalizedSymbols(text),
      chords.allSatisfy({ $0.range(of: "^[A-G]$", options: .regularExpression) == nil })
    else { return nil }
    return chords
  }
}
