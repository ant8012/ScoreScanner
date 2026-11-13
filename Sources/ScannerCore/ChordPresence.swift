import Foundation

/// Decides, before the chord pass, whether a page prints chord names at all.
///
/// Missing a chord chart loses every chord, while reading a page without chord
/// names only costs time, so chord reading is skipped only on a clear "none".
public enum ChordPresence {
  /// Most staff strips sent in the single check, spread from top to bottom.
  public static let stripLimit = 4

  /// Asks about written chord names, never about notes sounding together, and
  /// names no example symbols: the text reader has been seen copying phrases from
  /// its prompt as if they were printed.
  public static let prompt = """
    Each attached image is the strip of a music page directly above one staff. Decide whether \
    written chord names are printed as text in these strips, the letters a guitarist or pianist \
    reads to know which harmony to play: a capital letter root from A to G, often followed by an \
    accidental, a quality word or sign, extension numbers, or a slash and bass letter. Notes \
    stacked together on the staff are not chord names, even though they sound as chords. A \
    letter inside a box is a rehearsal mark, not a chord name. Dynamics such as mf or f, tempo \
    and metronome marks, expression words, bar numbers, multi-rest counts, lyrics, fingerings, \
    tuplet numbers, and pedal marks are not chord names. List up to four chord names exactly as \
    printed, or return an empty list when no chord names are printed.
    """

  /// The staff-text strips to check, evenly spread down the page.
  public static func strips(from crops: [ScoreTextImageCrop]) -> [ScoreTextImageCrop] {
    let systems = crops.filter { $0.kind == .system }.sorted { $0.pageY < $1.pageY }
    guard systems.count > stripLimit else { return systems }
    let step = Double(systems.count - 1) / Double(stripLimit - 1)
    return (0..<stripLimit).map { systems[Int((Double($0) * step).rounded())] }
  }

  /// Whether to read chords given the model's answer. A listed name that is a
  /// real chord outweighs a contradictory "none printed".
  public static func shouldReadChords(printed: Bool, examples: [String]) -> Bool {
    printed || examples.contains { ChordText.normalizedSymbols($0) != nil }
  }
}
