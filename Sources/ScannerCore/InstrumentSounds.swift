import Foundation

/// The instrument a printed part name stands for, as a MusicXML `instrument-sound` ID (the standard list every
/// notation program reads; MuseScore picks its instrument and sound from it). A name counts only when it matches
/// the table exactly once a trailing part number is dropped ("Violin I", "Trumpet 2", "2nd Violin"): anything else
/// keeps the default sound, so an unusual name is never guessed.
///
/// A transposing instrument is transposed when its key is printed ("Clarinet in B♭", "Horn in F"), or when its key
/// signature stands a known interval from the parts that sound as written (`transposition(of:written:concert:)`):
/// the scanner reads the printed notes, and a plain "Clarinet" may be in B♭, A or C. A saxophone with nothing to
/// compare against is in its usual key, as saxophones nearly always are.
enum InstrumentSounds {
  struct Match: Equatable {
    var sound: String
    /// The base name written as the instrument's name ("Violin" for "Violin I").
    var name: String
    /// Written to sounding pitch: (diatonic steps, semitones).
    var transpose: (diatonic: Int, chromatic: Int)?

    static func == (a: Match, b: Match) -> Bool {
      a.sound == b.sound && a.name == b.name && a.transpose?.diatonic == b.transpose?.diatonic
        && a.transpose?.chromatic == b.transpose?.chromatic
    }
  }

  private static let names: [String: String] = [
    // strings
    "violin": "strings.violin", "vln": "strings.violin", "vn": "strings.violin", "vl": "strings.violin",
    "viola": "strings.viola", "vla": "strings.viola", "va": "strings.viola",
    "violoncello": "strings.cello", "cello": "strings.cello", "vc": "strings.cello", "vlc": "strings.cello",
    "contrabass": "strings.contrabass", "double bass": "strings.contrabass", "string bass": "strings.contrabass",
    "cb": "strings.contrabass", "db": "strings.contrabass",
    // woodwinds
    "flute": "wind.flutes.flute", "fl": "wind.flutes.flute", "piccolo": "wind.flutes.flute.piccolo",
    "picc": "wind.flutes.flute.piccolo", "alto flute": "wind.flutes.flute.alto",
    "oboe": "wind.reed.oboe", "ob": "wind.reed.oboe",
    "english horn": "wind.reed.english-horn", "cor anglais": "wind.reed.english-horn",
    "clarinet": "wind.reed.clarinet", "cl": "wind.reed.clarinet", "bass clarinet": "wind.reed.clarinet.bass",
    "b cl": "wind.reed.clarinet.bass", "bcl": "wind.reed.clarinet.bass", "contrabass clarinet": "wind.reed.clarinet.contrabass",
    "cb cl": "wind.reed.clarinet.contrabass",
    "bassoon": "wind.reed.bassoon", "bsn": "wind.reed.bassoon", "bn": "wind.reed.bassoon", "contrabassoon": "wind.reed.contrabassoon",
    "cbn": "wind.reed.contrabassoon", "cbsn": "wind.reed.contrabassoon",
    "saxophone": "wind.reed.saxophone", "sax": "wind.reed.saxophone",
    "soprano saxophone": "wind.reed.saxophone.soprano", "soprano sax": "wind.reed.saxophone.soprano",
    "alto saxophone": "wind.reed.saxophone.alto", "alto sax": "wind.reed.saxophone.alto",
    "a sax": "wind.reed.saxophone.alto",
    "tenor saxophone": "wind.reed.saxophone.tenor", "tenor sax": "wind.reed.saxophone.tenor",
    "t sax": "wind.reed.saxophone.tenor",
    "baritone saxophone": "wind.reed.saxophone.baritone", "baritone sax": "wind.reed.saxophone.baritone",
    "bari sax": "wind.reed.saxophone.baritone", "bar sax": "wind.reed.saxophone.baritone",
    "bari": "wind.reed.saxophone.baritone",
    // German and score shorthand ("Altsax 1", "Tensax", "E-Git.", "Psn.", "D. Kit")
    "altsax": "wind.reed.saxophone.alto", "altsaxophon": "wind.reed.saxophone.alto",
    "tensax": "wind.reed.saxophone.tenor", "tenorsax": "wind.reed.saxophone.tenor",
    "tenorsaxophon": "wind.reed.saxophone.tenor", "barsax": "wind.reed.saxophone.baritone",
    "baritonsax": "wind.reed.saxophone.baritone", "baritonsaxophon": "wind.reed.saxophone.baritone",
    "posaune": "brass.trombone", "pos": "brass.trombone", "psn": "brass.trombone", "trompete": "brass.trumpet",
    // brass
    "horn": "brass.french-horn", "french horn": "brass.french-horn", "hn": "brass.french-horn",
    "trumpet": "brass.trumpet", "tpt": "brass.trumpet", "cornet": "brass.cornet", "flugelhorn": "brass.flugelhorn",
    "trombone": "brass.trombone", "tbn": "brass.trombone", "bass trombone": "brass.trombone.bass",
    "tuba": "brass.tuba", "tba": "brass.tuba", "euphonium": "brass.euphonium",
    // voices
    "soprano": "voice.soprano", "mezzo-soprano": "voice.mezzo-soprano", "mezzo soprano": "voice.mezzo-soprano",
    "alto": "voice.alto", "contralto": "voice.alto", "tenor": "voice.tenor", "baritone": "voice.baritone",
    "voice": "voice.vocals", "vocals": "voice.vocals", "vocal": "voice.vocals",
    // keyboards
    "piano": "keyboard.piano", "pianoforte": "keyboard.piano", "pno": "keyboard.piano", "pf": "keyboard.piano",
    "organ": "keyboard.organ", "org": "keyboard.organ", "harpsichord": "keyboard.harpsichord",
    "celesta": "keyboard.celesta",
    // plucked
    "guitar": "pluck.guitar", "gtr": "pluck.guitar", "acoustic guitar": "pluck.guitar.acoustic",
    "electric guitar": "pluck.guitar.electric", "bass guitar": "pluck.bass.electric",
    "electric bass": "pluck.bass.electric", "el guitar": "pluck.guitar.electric", "e guitar": "pluck.guitar.electric",
    "e-git": "pluck.guitar.electric", "e-gitarre": "pluck.guitar.electric", "gitarre": "pluck.guitar",
    "e-bass": "pluck.bass.electric", "harp": "pluck.harp", "hp": "pluck.harp", "hrp": "pluck.harp", "banjo": "pluck.banjo",
    "mandolin": "pluck.mandolin", "ukulele": "pluck.ukulele",
    // pitched percussion
    "vibraphone": "mallet.vibraphone", "marimba": "mallet.marimba", "xylophone": "mallet.xylophone",
    "glockenspiel": "mallet.glockenspiel", "timpani": "drum.timpani", "timp": "drum.timpani",
    // drums
    "drums": "drum.group.set", "drum kit": "drum.group.set", "drum set": "drum.group.set", "drumset": "drum.group.set",
    "d kit": "drum.group.set", "schlagzeug": "drum.group.set",
  ]

  /// Instruments in a printed key: name with its key → (sound, diatonic, chromatic), written to sounding pitch.
  private static let keyed: [String: (String, Int, Int)] = [
    "clarinet in bb": ("wind.reed.clarinet.bflat", -1, -2), "clarinet in a": ("wind.reed.clarinet.a", -2, -3),
    "clarinet in eb": ("wind.reed.clarinet.eflat", 2, 3), "bass clarinet in bb": ("wind.reed.clarinet.bass", -8, -14),
    "bb clarinet": ("wind.reed.clarinet.bflat", -1, -2), "a clarinet": ("wind.reed.clarinet.a", -2, -3),
    "eb clarinet": ("wind.reed.clarinet.eflat", 2, 3),
    "trumpet in bb": ("brass.trumpet.bflat", -1, -2), "bb trumpet": ("brass.trumpet.bflat", -1, -2),
    "trumpet in c": ("brass.trumpet.c", 0, 0), "c trumpet": ("brass.trumpet.c", 0, 0),
    "cornet in bb": ("brass.cornet", -1, -2), "flugelhorn in bb": ("brass.flugelhorn", -1, -2),
    "horn in f": ("brass.french-horn", -4, -7), "f horn": ("brass.french-horn", -4, -7),
    "horn in eb": ("brass.french-horn", -5, -9),
    "soprano saxophone in bb": ("wind.reed.saxophone.soprano", -1, -2),
    "alto saxophone in eb": ("wind.reed.saxophone.alto", -5, -9), "eb alto saxophone": ("wind.reed.saxophone.alto", -5, -9),
    "tenor saxophone in bb": ("wind.reed.saxophone.tenor", -8, -14), "bb tenor saxophone": ("wind.reed.saxophone.tenor", -8, -14),
    "baritone saxophone in eb": ("wind.reed.saxophone.baritone", -12, -21),
    // German names B for B♭ ("Tpt. in B")
    "trumpet in b": ("brass.trumpet.bflat", -1, -2), "tpt in b": ("brass.trumpet.bflat", -1, -2),
    "trompete in b": ("brass.trumpet.bflat", -1, -2), "clarinet in b": ("wind.reed.clarinet.bflat", -1, -2),
    "klarinette in b": ("wind.reed.clarinet.bflat", -1, -2),
  ]

  /// Transposing instruments by the interval their key signature stands from the parts that sound as written, in
  /// fifths (a B♭ instrument is written two sharps up) → (sound, diatonic, chromatic) written to sounding pitch.
  /// The first entry is a saxophone's usual key.
  private static let byKey: [String: [(fifths: Int, sound: String, diatonic: Int, chromatic: Int)]] = [
    "wind.reed.saxophone.soprano": [(2, "wind.reed.saxophone.soprano", -1, -2)],
    "wind.reed.saxophone.alto": [(3, "wind.reed.saxophone.alto", -5, -9)],
    "wind.reed.saxophone.tenor": [(2, "wind.reed.saxophone.tenor", -8, -14)],
    "wind.reed.saxophone.baritone": [(3, "wind.reed.saxophone.baritone", -12, -21)],
    "wind.reed.clarinet": [(2, "wind.reed.clarinet.bflat", -1, -2), (-3, "wind.reed.clarinet.a", -2, -3),
                           (3, "wind.reed.clarinet.eflat", 2, 3)],
    "wind.reed.clarinet.bass": [(2, "wind.reed.clarinet.bass", -8, -14)],
    "brass.trumpet": [(2, "brass.trumpet.bflat", -1, -2)],
    "brass.cornet": [(2, "brass.cornet", -1, -2)],
    "brass.flugelhorn": [(2, "brass.flugelhorn", -1, -2)],
    "brass.french-horn": [(1, "brass.french-horn", -4, -7), (3, "brass.french-horn", -5, -9)],
  ]

  /// The transposition of an instrument not known by name, from how many fifths its key is written above the
  /// concert key: a B♭ instrument (2) as a trumpet, an E♭ one (3) as an alto sax, an F one (1) as a horn. Any other
  /// interval is no transposition the scanner can tell.
  static func transposition(writtenAgainstConcert fifths: Int) -> (diatonic: Int, chromatic: Int)? {
    switch ((fifths % 12 + 18) % 12) - 6 {
    case 2: return (-1, -2)
    case 3: return (-5, -9)
    case 1: return (-4, -7)
    default: return nil
    }
  }

  /// Whether a part playing `sound` sounds as written, so its key signature is the score's concert key.
  static func soundsAsWritten(_ sound: String) -> Bool {
    !sound.hasPrefix("drum.") && byKey[sound] == nil && sound != "wind.reed.saxophone"
      && !keyed.values.contains { $0.0 == sound && ($0.1, $0.2) != (0, 0) }
  }

  /// A part's instrument corrected by its key signature (`written`, in fifths) against the score's concert key
  /// (`concert`; nil when no part sounds as written). Key signatures tell only when one of the two has sharps or
  /// flats: a score without any (atonal, or in C throughout) keeps the name's reading. Equal keys mean a score
  /// printed at concert pitch, played as written.
  static func transposition(of match: Match, written: Int, concert: Int?) -> Match {
    let family = byKey.first { family, keys in
      match.sound == family || keys.contains { $0.sound == match.sound }
    }
    guard let (_, keys) = family else { return match }
    guard let concert, written != 0 || concert != 0 else {
      // nothing to compare: a saxophone is in its usual key, anything else as its name says
      guard match.transpose == nil, match.sound.hasPrefix("wind.reed.saxophone."), let k = keys.first else { return match }
      return Match(sound: k.sound, name: match.name, transpose: (k.diatonic, k.chromatic))
    }
    let fifths = ((written - concert) % 12 + 18) % 12 - 6   // -6...5
    if fifths == 0 { return Match(sound: match.sound, name: match.name, transpose: nil) }
    guard let k = keys.first(where: { $0.fifths == fifths }) else { return match }
    return Match(sound: k.sound, name: match.name, transpose: (k.diatonic, k.chromatic))
  }

  /// Lower case, flats and sharps as "b" and "#", no dots, single spaces: "Clarinet in B♭" → "clarinet in bb".
  static func key(_ name: String) -> String {
    name.lowercased().replacingOccurrences(of: "♭", with: "b").replacingOccurrences(of: "♯", with: "#")
      .replacingOccurrences(of: ".", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  /// The name without the part's number: a trailing Roman numeral or number ("Violin II", "Horn 3") or a
  /// leading ordinal ("2nd Violin"). Left alone when nothing would be left.
  static func base(_ name: String) -> String {
    // "TPT.1": the number after a dot is a word of its own
    var words = name.replacingOccurrences(of: ".", with: ". ").split(whereSeparator: \.isWhitespace).map(String.init)
    let trailing: Set<String> = ["i", "ii", "iii", "iv", "v", "vi", "1", "2", "3", "4", "5", "6"]
    let leading: Set<String> = ["1st", "2nd", "3rd", "4th", "first", "second", "third", "fourth"]
    if words.count > 1, let w = words.last, trailing.contains(w.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
      words.removeLast()
    }
    if words.count > 1, leading.contains(words[0].lowercased()) { words.removeFirst() }
    return words.joined(separator: " ")
  }

  /// The instrument a name misread by a letter or two stands for ("larinet", "Ti impani"), for matching parts
  /// between pages; never for choosing a sound. Long names only, so a short abbreviation is not stretched.
  static func nearest(_ name: String) -> String? {
    let k = key(base(name)).replacingOccurrences(of: " ", with: "")
    guard k.count >= 6 else { return nil }
    func distance(_ a: [Character], _ b: [Character]) -> Int {
      var row = Array(0...b.count)
      for i in 1...a.count {
        var prev = row[0]; row[0] = i
        for j in 1...b.count {
          let cur = row[j]
          row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
          prev = cur
        }
      }
      return row[b.count]
    }
    let a = Array(k)
    var best: (String, Int)?
    for (n, sound) in names where n.count >= 6 {
      let d = distance(a, Array(n.replacingOccurrences(of: " ", with: "")))
      if d <= (n.count >= 9 ? 2 : 1), best == nil || d < best!.1 { best = (sound, d) }
    }
    return best?.0
  }

  /// Whether a name is an instrument's at all (a part label), "Bass" included, whatever its sound.
  static func isInstrument(_ name: String) -> Bool {
    let k = key(base(name))
    return names[k] != nil || keyed[k] != nil || k == "bass"
  }

  /// Names found inside a longer one, longest first ("2ND TROMBONE" cut to "NO TROMBONE", "E♭ ALTO SAXOPHONE" read
  /// as "E ALTO SAXOPHONE"): instruments and their abbreviations of three letters or more, not voices ("Alto",
  /// "Tenor" and "Bass" alone are choir parts or anything) nor a bare "sax".
  private static let contained: [(words: [String], sound: String)] = names
    .filter { name, sound in !sound.hasPrefix("voice.") && name.count >= 3 && name != "sax" && name != "saxophone" }
    .map { (words: $0.key.split(separator: " ").map(String.init), sound: $0.value) }
    .sorted { ($0.words.count, $0.words.joined().count) > ($1.words.count, $1.words.joined().count) }

  /// The instrument whose name stands as whole words inside `printed`, the longest such name, and the earliest of
  /// equals (a doubling part, "Tenor Sax / Flute", is the instrument printed first). The printed key is not used:
  /// transposition comes from the key signatures.
  static func containedMatch(_ printed: String) -> Match? {
    let words = key(printed).split { !$0.isLetter && !$0.isNumber && $0 != "#" }.map(String.init)
    guard !words.isEmpty else { return nil }
    var best: (at: Int, length: Int, sound: String, name: [String])?
    for c in contained {
      guard c.words.count <= words.count else { continue }
      for at in 0...(words.count - c.words.count) where Array(words[at..<at + c.words.count]) == c.words {
        let better = best == nil || c.words.count > best!.length || c.words.count == best!.length && at < best!.at
        if better { best = (at, c.words.count, c.sound, c.words) }
        break
      }
    }
    guard let best else { return nil }
    return Match(sound: best.sound, name: best.name.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " "),
                 transpose: nil)
  }

  /// The instrument for a part from its printed long name, else its short name, else an instrument's name found
  /// inside either. "Bass" is a voice beside other voices and a double bass beside other strings, otherwise unknown.
  /// `contained` false: exact names only (for matching parts across pages, where a label holding two staves' names,
  /// "Clarinet 2 Bass Clarinet 3", would name the wrong one).
  static func match(long: String, short: String, others: [String] = [], contained: Bool = true) -> Match? {
    if let exact = exactMatch(long: long, short: short, others: others) { return exact }
    guard contained else { return nil }
    for printed in [long, short] where !printed.trimmingCharacters(in: .whitespaces).isEmpty {
      if let found = containedMatch(printed) { return found }
    }
    return nil
  }

  private static func exactMatch(long: String, short: String, others: [String]) -> Match? {
    for printed in [long, short] where !printed.trimmingCharacters(in: .whitespaces).isEmpty {
      let name = base(printed)
      let k = key(name)
      if let (sound, d, c) = keyed[k] { return Match(sound: sound, name: name, transpose: (d, c)) }
      if let sound = names[k] { return Match(sound: sound, name: name, transpose: nil) }
      if k == "bass" || k == "b" {
        let kinds = others.compactMap { names[key(base($0))] }
        if kinds.contains(where: { $0.hasPrefix("voice.") }) { return Match(sound: "voice.bass", name: name, transpose: nil) }
        if kinds.contains(where: { $0.hasPrefix("strings.") }) {
          return Match(sound: "strings.contrabass", name: name, transpose: nil)
        }
      }
    }
    return nil
  }
}
