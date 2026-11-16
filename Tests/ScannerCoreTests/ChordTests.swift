import Foundation
import Testing
@testable import ScannerCore

struct ChordTests {
  @Test func raisedExtensionsAndDegreeSignAreRead() {
    #expect(ChordText.normalizedSymbol("C7ᵇ⁹") == ChordText.normalizedSymbol("C7b9"))
    #expect(ChordText.normalizedSymbol("A-7ᵇ⁵") == ChordText.normalizedSymbol("A-7b5"))
    #expect(ChordText.normalizedSymbol("B♭°") == ChordText.normalizedSymbol("Bbo"))
    #expect(ChordText.normalizedSymbol("C7ᵇ⁹") != nil)
    #expect(ChordText.normalizedSymbol("B♭°") != nil)
  }

  @Test func publicChordTextValidationRequiresTheWholeString() {
    #expect(ChordText.normalizedSymbol("B♭maj7") == "Bbmaj7")
    #expect(ChordText.normalizedSymbol(" C♯7(b9) ") == "C#7(b9)")
    #expect(ChordText.normalizedSymbol("F6/9") == "F6/9")
    #expect(ChordText.normalizedSymbol("D.C. al Fine") == nil)
    #expect(ChordText.normalizedSymbol("Ending A") == nil)
    #expect(ChordText.normalizedSymbol("C7 G7") == nil)
  }

  @Test func publicChordTextValidationSafelySplitsMultiChordReadings() {
    #expect(ChordText.normalizedSymbols("F#sus F#") == ["F#sus", "F#"])
    #expect(ChordText.normalizedSymbols("11 G D") == ["G", "D"])
    #expect(ChordText.normalizedSymbols("13 E- A") == ["E-", "A"])
    #expect(ChordText.normalizedSymbols("D.C. G7") == nil)
    #expect(ChordText.normalizedSymbols("Fine C") == nil)
  }

  @Test func ignoredTextRecoveryRequiresMoreThanABareRoot() {
    #expect(ChordText.recoverableIgnoredSymbols("B-") == ["B-"])
    #expect(ChordText.recoverableIgnoredSymbols("F#7 Cmaj7") == ["F#7", "Cmaj7"])
    #expect(ChordText.recoverableIgnoredSymbols("B- 9") == ["B-"])
    #expect(ChordText.recoverableIgnoredSymbols("B") == nil)
    #expect(ChordText.recoverableIgnoredSymbols("A C7") == nil)
    #expect(ChordText.recoverableIgnoredSymbols("Fine C7") == nil)
    #expect(ChordText.recoverableIgnoredSymbols("D.C. B-") == nil)
  }

  @Test func navigationWordsCannotLeakChordSubstrings() {
    #expect(ChordGrammar.chords(in: "C7 CTAKE ENDING7 Dm7") == ["C7", "Dm7"])
    #expect(ChordGrammar.chords(in: "CFINE D.S.alCoda G7") == ["G7"])
    #expect(ChordGrammar.chords(in: "INTRO8 Am7 BRIDGE") == ["Am7"])
    #expect(ChordGrammar.chords(in: "9Bas Enters F#sus") == ["B", "F#sus"])
    #expect(ChordGrammar.chords(in: "42Drum Sets Tempo") == [])
  }

  @Test func onlyWeakLeftMarginRootsCanBecomeStaffText() {
    #expect(ChordGrammar.looksLikeLeftMarginStaffText(
      chord: "B", confidence: 0.63, x0: 149, width: 19,
      minX: 130, unit: 23, context: "B as n-"))
    #expect(ChordGrammar.looksLikeLeftMarginStaffText(
      chord: "B", confidence: 0.63, x0: 149, width: 19,
      minX: 130, unit: 23, context: "Ba E"))
    #expect(!ChordGrammar.looksLikeLeftMarginStaffText(
      chord: "B-", confidence: 0.63, x0: 149, width: 19,
      minX: 130, unit: 23, context: "Bass"))
    #expect(!ChordGrammar.looksLikeLeftMarginStaffText(
      chord: "B", confidence: 0.95, x0: 149, width: 19,
      minX: 130, unit: 23, context: "Bass"))
    #expect(!ChordGrammar.looksLikeLeftMarginStaffText(
      chord: "B", confidence: 0.63, x0: 149, width: 50,
      minX: 130, unit: 23, context: "Bass"))
    #expect(!ChordGrammar.looksLikeLeftMarginStaffText(
      chord: "B", confidence: 0.63, x0: 400, width: 19,
      minX: 130, unit: 23, context: "Bass"))
    #expect(!ChordGrammar.looksLikeLeftMarginStaffText(
      chord: "B", confidence: 0.63, x0: 149, width: 19,
      minX: 130, unit: 23, context: "B"))
  }

  @Test func rehearsalFrameDetectionIsGeometricAndConservative() {
    var pixels = [UInt8](repeating: 255, count: 180 * 100)
    drawFrame(&pixels, pageWidth: 180, x: 20, y: 15, width: 56, height: 53, stroke: 3)
    // Interior text does not have to be recognized for the frame to be found.
    for y in 35..<55 { pixels[y * 180 + 45] = 0 }
    let band = Band(pixels: pixels, width: 180, height: 100)
    let frames = band.rehearsalFrames(unit: 15)
    #expect(frames == [Band.Rectangle(x: 20, y: 15, width: 56, height: 53)])
    let cleaned = band.erasing(frames)
    #expect((14..<69).allSatisfy { y in
      (19..<77).allSatisfy { x in cleaned.pixels[y * 180 + x] == 255 }
    })

    var glyphPixels = [UInt8](repeating: 255, count: 120 * 100)
    drawFrame(&glyphPixels, pageWidth: 120, x: 43, y: 35, width: 24, height: 31, stroke: 3)
    let glyph = Band(pixels: glyphPixels, width: 120, height: 100)
    #expect(glyph.rehearsalFrames(unit: 15).isEmpty)

    var antialiasedPixels = [UInt8](repeating: 255, count: 180 * 100)
    drawFrame(
      &antialiasedPixels, pageWidth: 180, x: 20, y: 15,
      width: 78, height: 53, stroke: 3)
    let antialiased = Band(pixels: antialiasedPixels, width: 180, height: 100)
    #expect(antialiased.rehearsalFrames(unit: 15.4).count == 1)
  }

  @Test func scoreTextCropsUseHeaderAndNativeSystemGeometry() throws {
    let pageWidth = 220, pageHeight = 180
    let page = Data(repeating: 255, count: pageWidth * pageHeight)
    let geometry = Data(
      """
      {"unit":10,"minx":20,"miny":100,"maxx":180,"maxy":140,
       "barlines":[{"x":100}],"barlineSource":"homr-native-staff-detection",
       "voice":2,"system":3}
      """.utf8)

    let crops = try ScoreTextImageCrops.from(
      page: page, pageWidth: pageWidth, pageHeight: pageHeight,
      geometry: [geometry])

    #expect(crops.count == 3)
    #expect(crops[0].kind == .header)
    #expect(crops[0].width == 220)
    #expect(crops[0].height == 54)
    #expect(crops[1].kind == .initialMeter)
    #expect(crops[1].pageX == 0)
    #expect(crops[1].pageY == 80)
    #expect(crops[1].width == 180)
    #expect(crops[1].height == 80)
    #expect(crops[2].kind == .system)
    #expect(crops[2].pageX == 10)
    #expect(crops[2].pageY == 40)
    #expect(crops[2].width == 180)
    #expect(crops[2].height == 55)
    #expect(crops[2].voice == 2)
    #expect(crops[2].system == 3)
    #expect(crops[2].barCount == 2)
    #expect(crops[2].barBoundaryFractions == [1.0 / 18.0, 0.5, 17.0 / 18.0])
  }

  @Test func openingMeterChangesEveryPartButPreservesLaterChanges() throws {
    let raw = Data(
      """
      <score-partwise><part id="P1"><measure number="1"><attributes>
      <time><beats>4</beats><beat-type>4</beat-type></time></attributes></measure>
      <measure number="2"><attributes><time><beats>2</beats>
      <beat-type>4</beat-type></time></attributes></measure></part>
      <part id="P2"><measure number="1"><attributes><divisions>4</divisions>
      </attributes></measure></part></score-partwise>
      """.utf8)
    let output = try ScoreTimeSignatureMusicXML.replacingInitialMeter(
      ScoreTimeSignature(beats: 6, beatType: 8), in: raw)
    let parts = try XMLNode.parse(output).all("part")
    #expect(parts[0].all("measure")[0].first("attributes")?.first("time")?
      .first("beats")?.text == "6")
    #expect(parts[0].all("measure")[1].first("attributes")?.first("time")?
      .first("beats")?.text == "2")
    #expect(parts[1].all("measure")[0].first("attributes")?.first("time")?
      .first("beat-type")?.text == "8")
  }

  @Test func detectedTitleFillsBlankMusicXMLButNeverOverridesUserTitle() throws {
    let blank = DocumentScanResult(
      xml: Data("<score-partwise><work><work-title></work-title></work></score-partwise>".utf8),
      rawXML: Data("<score-partwise></score-partwise>".utf8), seconds: 2,
      staffCount: 1, repairedMeasures: 0, pageCount: 1)
    let filled = try ScoreMetadataMusicXML.insertingDetectedTitle("  Stars & Sky  ", into: blank)
    #expect(try XMLNode.parse(filled.xml).first("work")?.first("work-title")?.text == "Stars & Sky")
    #expect(try XMLNode.parse(filled.rawXML).first("work")?.first("work-title")?.text == "Stars & Sky")

    let explicit = DocumentScanResult(
      xml: Data("<score-partwise><work><work-title>My Title</work-title></work></score-partwise>".utf8),
      rawXML: Data("<score-partwise><work><work-title>My Title</work-title></work></score-partwise>".utf8),
      seconds: 2, staffCount: 1, repairedMeasures: 0, pageCount: 1)
    let preserved = try ScoreMetadataMusicXML.insertingDetectedTitle("Other", into: explicit)
    #expect(try XMLNode.parse(preserved.xml).first("work")?.first("work-title")?.text == "My Title")
  }

  @Test func headerTempoBecomesMetronomeAndUserTitleKeepsItsCredit() throws {
    let xml = Data(
      """
      <score-partwise><work><work-title>My Title</work-title></work>
      <identification><encoding><software>homr</software></encoding></identification>
      <defaults></defaults>
      <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
      <part id="P1"><measure number="1"><attributes><divisions>1</divisions></attributes>
      <note><duration>4</duration></note></measure></part>
      </score-partwise>
      """.utf8)
    let source = DocumentScanResult(
      xml: xml, rawXML: xml, seconds: 1, staffCount: 1,
      repairedMeasures: 0, pageCount: 1)
    let result = try ScoreMetadataMusicXML.insertingRecognizedContent(
      title: "Detected", composer: "A Composer", arranger: nil,
      tempo: ScoreHeaderTempo(text: "Swing (♩. = 96)", beatUnit: "dotted-quarter", bpm: 96),
      staffText: [
        ScoreTextDirection(
          voice: 0, system: 0, bar: 0, barCount: 1,
          text: "Swing", category: "tempo")
      ], into: source)

    let root = try XMLNode.parse(result.xml)
    let titleCredit = root.all("credit").first { $0.first("credit-type")?.text == "title" }
    #expect(titleCredit?.first("credit-words")?.text == "My Title")
    let directions = root.first("part")?.first("measure")?.all("direction") ?? []
    #expect(directions.count == 1)
    let types = directions.first?.all("direction-type") ?? []
    #expect(types.first?.first("words")?.text == "Swing")
    let metronome = types.last?.first("metronome")
    #expect(metronome?.first("beat-unit")?.text == "quarter")
    #expect(metronome?.first("beat-unit-dot") != nil)
    #expect(metronome?.first("per-minute")?.text == "96")
    #expect(directions.first?.first("sound")?.attributes["tempo"] == "144")
  }

  @Test func headerCueIsNotTempoAndStaysStaffText() throws {
    let xml = Data(
      """
      <score-partwise><work><work-title></work-title></work>
      <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
      <part id="P1"><measure number="1"><note><duration>4</duration></note></measure>
      <measure number="2"><note><duration>4</duration></note></measure></part>
      </score-partwise>
      """.utf8)
    let source = DocumentScanResult(
      xml: xml, rawXML: xml, seconds: 1, staffCount: 1,
      repairedMeasures: 0, pageCount: 1)
    let result = try ScoreMetadataMusicXML.insertingRecognizedContent(
      title: nil, composer: nil, arranger: nil,
      tempo: ScoreHeaderTempo(text: "Piano Intro \u{1D15E} = 60", beatUnit: "quarter", bpm: 0),
      staffText: [
        ScoreTextDirection(
          voice: 0, system: 0, bar: 0, barCount: 2,
          text: "Piano Intro", category: "instrument-cue")
      ], into: source)

    let directions = try XMLNode.parse(result.xml).first("part")?.first("measure")?
      .all("direction") ?? []
    let words = directions.flatMap { $0.all("direction-type") }.compactMap { $0.first("words")?.text }
    #expect(words == ["Piano Intro"])
    let tempo = directions.first { $0.first("sound") != nil }
    let metronome = tempo?.first("direction-type")?.first("metronome")
    #expect(metronome?.first("beat-unit")?.text == "half")
    #expect(metronome?.first("beat-unit-dot") == nil)
    #expect(metronome?.first("per-minute")?.text == "60")
    #expect(tempo?.first("sound")?.attributes["tempo"] == "120")
  }

  @Test func sixNineSurvivesGrammarAndMusicXMLWriting() throws {
    #expect(ChordGrammar.chords(in: "F6/9") == ["F6/9"])
    let xml = Data("""
      <score-partwise><part id="P1"><measure number="1">
      <attributes><divisions>4</divisions></attributes><note><duration>16</duration></note>
      </measure></part></score-partwise>
      """.utf8)
    var chord = label("F6/9", 10)
    chord.bar = 0
    chord.measureNumber = "1"
    chord.partID = "P1"
    chord.beat = 1
    chord.beatUnit = 4
    let staff = ChordStaff(
      staff: 0, voice: 0, system: 0, top: 0, bottom: 20,
      bars: [ChordBar(
        index: 0, left: 0, right: 100, text: "F6/9", labels: [chord],
        measureNumber: "1", partID: "P1")], mappingStatus: "count-matched")
    let output = try ChordMusicXML.insertMapped(xml, staffs: [staff])
    let harmony = try XMLNode.parse(output.xml).all("part")[0].all("measure")[0].all("harmony")[0]
    #expect(harmony.first("kind")?.text == "major-sixth")
    #expect(harmony.first("kind")?.attributes["text"] == "6/9")
    #expect(harmony.first("degree")?.first("degree-value")?.text == "9")
  }

  /// A strip ten pixels to a staff space, with ink in the given column ranges.
  private func strip(_ inked: [Range<Int>], width: Int = 300) -> Band {
    var pixels = [UInt8](repeating: 255, count: width * 20)
    for range in inked { for row in 5..<15 { for column in range { pixels[row * width + column] = 0 } } }
    return Band(pixels: pixels, width: width, height: 20)
  }

  @Test func aSystemsLastBarTakesInTheLabelHangingPastIt() {
    // `Am7` runs 30 pixels past the bar line at 100, with a narrow gap
    // inside the name; the page number further out is a real gap away.
    let band = strip([80..<112, 115..<130, 200..<210])
    #expect(band.systemEndCut(from: 100, unit: 10) == 130)
    // Nothing past the bar line: the cut does not move.
    #expect(strip([60..<90]).systemEndCut(from: 100, unit: 10) == 100)
    // Ink that runs on without a gap is a dark page edge, not a label.
    #expect(strip([90..<300]).systemEndCut(from: 100, unit: 10) == 100)
  }

  @Test func timingDefaultsMatchTheProductRules() {
    #expect(ChordTiming.defaults(meter: ChordMeter(beats: 2, beatType: 4), count: 4)
      == [1, 1.5, 2, 2.5])
    #expect(ChordTiming.defaults(meter: ChordMeter(beats: 6, beatType: 8), count: 4)
      == [1, 2.5, 4, 5.5])
    #expect(ChordTiming.defaults(meter: ChordMeter(beats: 12, beatType: 8), count: 4)
      == [1, 4, 7, 10])
    #expect(ChordTiming.defaults(meter: ChordMeter(beats: 9, beatType: 8), count: 4) == nil)
  }

  @Test func mappedChordsBecomeTimedMusicXMLHarmony() throws {
    let xml = Data("""
      <score-partwise><part id="P1">
      <measure number="1"><attributes><divisions>4</divisions></attributes>
      <attributes><time><beats>4</beats><beat-type>4</beat-type></time></attributes>
      <note><duration>16</duration></note></measure>
      <measure number="2"><note><duration>16</duration></note></measure>
      <measure number="3"><note><duration>16</duration></note></measure>
      <measure number="4"><note><duration>16</duration></note></measure>
      </part></score-partwise>
      """.utf8)
    var first = ChordBar(
      index: 0, left: 0, right: 100, text: "C Bb-7",
      labels: [label("C", 10), label("Bb-7", 70)])
    first.labels[0].bar = 0
    first.labels[1].bar = 0
    var staffs = [ChordStaff(
      staff: 0, voice: 0, system: 0, top: 0, bottom: 20,
      bars: [first, emptyBar(1), emptyBar(2), emptyBar(3)], mappingStatus: "unresolved")]
    try ChordMusicXML.map(&staffs, score: xml)
    #expect(staffs[0].mappingStatus == "count-matched")
    #expect(staffs[0].bars[0].labels.map(\.beat) == [1, 3])
    let output = try ChordMusicXML.insertMapped(xml, staffs: staffs)
    #expect(output.written == 2)
    let measure = try XMLNode.parse(output.xml).all("part")[0].all("measure")[0]
    let harmony = measure.all("harmony")
    #expect(harmony.count == 2)
    #expect(harmony[0].first("kind")?.attributes["text"] == "")
    #expect(harmony[1].first("root")?.first("root-alter")?.text == "-1")
    #expect(harmony[1].first("offset")?.text == "8")
  }

  @Test func repeatStrokesAndEdgeSliversDoNotBecomeBars() throws {
    // Tide, page 1: an opening repeat bracket (257, 275) and an end repeat's
    // thin stroke one staff space inside the bracket (1764).
    func boundaries(_ bars: [Double]) throws -> [Double] {
      let lines = bars.map { "{\"x\": \($0)}" }.joined(separator: ",")
      return try StaffGeometry.decode(Data("""
        {"unit": 15.4, "minx": 120, "miny": 300, "maxx": 1780, "maxy": 360,
         "barlineSource": "homr-native-staff-detection", "voice": 0, "system": 0,
         "barlines": [\(lines)]}
        """.utf8)).musicalBoundaries
    }
    #expect(try boundaries([257, 275, 636, 1042, 1482]) == [120, 266, 636, 1042, 1482, 1780])
    #expect(try boundaries([596, 1058, 1449, 1764]) == [120, 596, 1058, 1449, 1780])
  }

  @Test func emptyClefPieceIsTrimmedWithoutMovingChords() throws {
    let xml = Data("""
      <score-partwise><part id="P1">
      <measure number="1"><attributes><divisions>2</divisions></attributes>
      <attributes><time><beats>3</beats><beat-type>4</beat-type></time></attributes>
      <note><duration>6</duration></note></measure>
      <measure number="2"><note><duration>6</duration></note></measure>
      <measure number="3"><note><duration>6</duration></note></measure>
      <measure number="4"><note><duration>6</duration></note></measure>
      </part></score-partwise>
      """.utf8)
    func bar(_ index: Int, _ left: Double, _ right: Double, _ chord: String?) -> ChordBar {
      var labels: [ChordLabel] = []
      if let chord {
        var chordLabel = label(chord, left + 20)
        chordLabel.bar = index
        labels = [chordLabel]
      }
      return ChordBar(
        index: index, left: left, right: right, text: chord ?? "", labels: labels,
        measureNumber: nil, partID: nil)
    }
    func staff(_ bars: [ChordBar]) -> [ChordStaff] {
      [ChordStaff(
        staff: 0, voice: 0, system: 0, top: 0, bottom: 20, bars: bars, mappingStatus: "unresolved")]
    }

    var tide = staff([
      bar(0, 120, 266, nil), bar(1, 266, 636, "Emaj7(no3)"), bar(2, 636, 1042, "B/F#"),
      bar(3, 1042, 1482, "Ab-7"), bar(4, 1482, 1780, nil),
    ])
    try ChordMusicXML.map(&tide, score: xml)
    #expect(tide[0].mappingStatus == "edge-trimmed")
    #expect(tide[0].bars.map(\.measureNumber) == [nil, "1", "2", "3", "4"])
    #expect(tide[0].bars[2].labels[0].measureNumber == "2")

    // A wide empty piece may be a real bar the note reader dropped.
    var wide = staff([
      bar(0, 0, 400, nil), bar(1, 400, 800, "C"), bar(2, 800, 1200, "F"),
      bar(3, 1200, 1600, "G"), bar(4, 1600, 2000, "C"),
    ])
    try ChordMusicXML.map(&wide, score: xml)
    #expect(wide[0].mappingStatus == "unresolved")

    // A narrow piece that holds a chord is never discarded.
    var labelled = staff([
      bar(0, 0, 100, "F#"), bar(1, 100, 500, "C"), bar(2, 500, 900, "F"),
      bar(3, 900, 1300, "G"), bar(4, 1300, 1700, "C"),
    ])
    try ChordMusicXML.map(&labelled, score: xml)
    #expect(labelled[0].mappingStatus == "unresolved")
  }

  @Test func omittedAndAddedTonesAreChords() throws {
    for chord in ["Emaj7(no3)", "A-9(no3)", "Emaj9(no3)", "C(add9)", "G7(omit5)"] {
      #expect(ChordText.normalizedSymbol(chord) == chord, "\(chord)")
      #expect(ChordGrammar.chords(in: chord) == [chord], "\(chord)")
    }
    #expect(ChordText.normalizedSymbol("Emaj7(nope)") == nil)

    let xml = Data("""
      <score-partwise><part id="P1"><measure number="1">
      <attributes><divisions>4</divisions></attributes><note><duration>16</duration></note>
      </measure></part></score-partwise>
      """.utf8)
    var labels: [ChordLabel] = []
    for (index, chord) in ["Emaj7(no3)", "C(add9)"].enumerated() {
      var chordLabel = label(chord, Double(10 + index * 50))
      chordLabel.bar = 0
      chordLabel.measureNumber = "1"
      chordLabel.partID = "P1"
      chordLabel.beat = Double(1 + index * 2)
      chordLabel.beatUnit = 4
      labels.append(chordLabel)
    }
    let staff = ChordStaff(
      staff: 0, voice: 0, system: 0, top: 0, bottom: 20,
      bars: [ChordBar(
        index: 0, left: 0, right: 100, text: "", labels: labels,
        measureNumber: "1", partID: "P1")], mappingStatus: "count-matched")
    let output = try ChordMusicXML.insertMapped(xml, staffs: [staff])
    let harmony = try XMLNode.parse(output.xml).all("part")[0].all("measure")[0].all("harmony")
    #expect(harmony.count == 2)
    #expect(harmony[0].first("kind")?.text == "major-seventh")
    #expect(harmony[0].first("degree")?.first("degree-value")?.text == "3")
    #expect(harmony[0].first("degree")?.first("degree-type")?.text == "subtract")
    #expect(harmony[1].first("kind")?.text == "major")
    #expect(harmony[1].first("degree")?.first("degree-value")?.text == "9")
    #expect(harmony[1].first("degree")?.first("degree-type")?.text == "add")
  }

  @Test func printedChordTextWinsOverAReaderRewrite() {
    #expect(ChordText.acceptedSymbols(visibleText: "Fo", proposedChord: "F#") == ["Fo"])
    #expect(ChordText.acceptedSymbols(visibleText: "A♭ -", proposedChord: "A♭") == ["Ab"])
    #expect(
      ChordText.acceptedSymbols(visibleText: "Db-7 Solo Over F D.S. After", proposedChord: "Db-7")
        == ["Db-7"])
    #expect(ChordText.acceptedSymbols(visibleText: "G m7", proposedChord: "Gm7") == ["Gm7"])
    #expect(ChordText.acceptedSymbols(visibleText: "Solo Over Form", proposedChord: "F") == nil)
    #expect(ChordText.acceptedSymbols(visibleText: "r", proposedChord: "r") == nil)
    #expect(ChordText.acceptedSymbols(visibleText: "Cmaj7", proposedChord: "C7") == ["Cmaj7"])
  }

  @Test func aBracketedTurnaroundIsReadAsItsChords() {
    #expect(ChordText.acceptedSymbols(visibleText: "(Fm7", proposedChord: "Fm7") == ["Fm7"])
    #expect(ChordText.acceptedSymbols(visibleText: "Bb13)", proposedChord: "Bb13") == ["Bb13"])
    #expect(ChordText.acceptedSymbols(visibleText: "(D-7", proposedChord: "(D-7") == ["D-7"])
    #expect(ChordText.acceptedSymbols(visibleText: "C7)", proposedChord: "C7)") == ["C7"])
    #expect(ChordText.normalizedSymbols("(Fm7 Bb13)") == ["Fm7", "Bb13"])
    #expect(ChordText.normalizedSymbol("C7(b9)") != nil)
  }

  private func label(_ chord: String, _ x: Double) -> ChordLabel {
    ChordLabel(
      text: chord, chord: chord, confidence: 1, x0: x, x1: x + 10, bar: nil,
      measureNumber: nil, partID: nil, beat: nil, beatUnit: nil, timingSource: nil,
      timingStatus: nil)
  }

  private func emptyBar(_ index: Int) -> ChordBar {
    ChordBar(index: index, left: Double(index * 100), right: Double((index + 1) * 100),
             text: "", labels: [])
  }

  private func drawFrame(
    _ pixels: inout [UInt8], pageWidth: Int, x: Int, y: Int,
    width: Int, height: Int, stroke: Int
  ) {
    for row in y..<(y + height) {
      for column in x..<(x + width)
      where row < y + stroke || row >= y + height - stroke
        || column < x + stroke || column >= x + width - stroke
      {
        pixels[row * pageWidth + column] = 0
      }
    }
  }

  /// Chords the grammar rejected although they were read correctly.
  private let unfamiliar = [
    "C7sus4", "Cadd9", "Csus2", "C2", "Ebm(maj7)", "C-Δ7", "C7alt", "Bb13sus", "A7(b9,#5)",
    "D7sus4(b9)", "Ebmi(maj7)",
  ]

  @Test func cloudReadingsWithUnfamiliarSuffixesAreTrusted() {
    for chord in unfamiliar {
      let judged = ChordText.modelSymbols(visibleText: chord, proposedChord: chord)
      #expect(judged.chords.count == 1, "\(chord)")
      #expect(judged.verdict != .blocked, "\(chord)")
    }
    let slash = ChordText.modelSymbols(visibleText: "C7sus4/G", proposedChord: "C7sus4/G")
    #expect(slash.chords == ["C7sus4/G"])
    let pair = ChordText.modelSymbols(visibleText: "C7alt Fm(maj7)", proposedChord: "")
    #expect(pair.chords == ["C7alt", "Fm(maj7)"])
    #expect(pair.verdict == .unusual)
  }

  /// Text that is not a chord stays out however the model tidied it: these
  /// are readings the check blocked in earlier scans. A chord printed beside
  /// words, as in `Fine C`, is still kept, as it was before.
  @Test func wordsAndNumbersStayBlocked() {
    let text = [
      ("Piano Intro", "Piano Intro"), ("♩ = 90", "♩ = 90"), ("42 Drum Sets Tempo", "42"),
      ("43", "43"), ("", ""), ("b", "b"), ("Fine", "F"), ("Coda", "C"), ("D.S. al Coda", "D"),
      ("Bsas Enters", "B"), ("Loop Until Cue", ""), ("rit.", ""), ("To Coda", "C"),
      ("Bass", "B"), ("Bridge", "B"), ("Dr", "D"),
    ]
    for (visible, proposed) in text {
      let judged = ChordText.modelSymbols(visibleText: visible, proposedChord: proposed)
      #expect(judged.chords.isEmpty, "\(visible)")
      #expect(judged.verdict == .blocked, "\(visible)")
    }
  }

  @Test func knownChordsKeepTheirVerdict() {
    let judged = ChordText.modelSymbols(visibleText: "B♭maj7", proposedChord: "Bbmaj7")
    #expect(judged.chords == ["Bbmaj7"])
    #expect(judged.verdict == .accepted)
  }

  @Test func unfamiliarChordsAreWrittenWithTheirPrintedSuffix() throws {
    for chord in unfamiliar {
      let node = try #require(
        ChordMusicXML.harmony(chord, offset: 0) ?? ChordMusicXML.looseHarmony(chord, offset: 0),
        "\(chord)")
      let kind = try #require(node.first("kind"))
      #expect(chord.hasSuffix(kind.attributes["text"] ?? "?"), "\(chord)")
    }
  }

  @Test func capitalMIsMajorAndSmallMIsMinor() {
    let kinds: [(String, String)] = [
      ("M", "major"), ("M6", "major-sixth"), ("M7", "major-seventh"), ("M9", "major-ninth"),
      ("maj", "major"), ("maj6", "major-sixth"), ("maj7", "major-seventh"), ("MA7", "major-seventh"),
      ("Ma7", "major-seventh"), ("Δ", "major-seventh"), ("Δ7", "major-seventh"),
      ("m", "minor"), ("m6", "minor-sixth"), ("m7", "minor-seventh"), ("mi7", "minor-seventh"),
      ("MI7", "minor-seventh"), ("min7", "minor-seventh"), ("-7", "minor-seventh"), ("m9", "minor-ninth"),
    ]
    for (suffix, kind) in kinds { #expect(ChordMusicXML.nearestKind(suffix).kind == kind, "\(suffix)") }
  }

  @Test func sus2IsASuspendedSecond() {
    func kind(_ chord: String) -> (String, [String])? {
      guard let h = ChordMusicXML.harmony(chord, offset: 0) ?? ChordMusicXML.looseHarmony(chord, offset: 0) else {
        return nil
      }
      return (h.first("kind")!.text, h.all("degree").map {
        "\($0.first("degree-type")!.text) \($0.first("degree-value")!.text) \($0.first("degree-alter")!.text)"
      })
    }
    #expect(kind("Dsus2")?.0 == "suspended-second")
    #expect(kind("D7sus2")?.0 == "suspended-second" && kind("D7sus2")?.1 == ["add 7 0"])
    #expect(kind("Dsus2/F#")?.0 == "suspended-second")
    #expect(kind("Dsus2(add9)")?.0 == "suspended-second" && kind("Dsus2(add9)")?.1 == ["add 9 0"])
    // the fourth stays the fourth
    #expect(kind("Dsus4")?.0 == "suspended-fourth")
    #expect(kind("Dsus")?.0 == "suspended-fourth")
    #expect(kind("D7sus4")?.1 == ["add 7 0"])
    // added seconds and ninths are major chords with the note added
    #expect(kind("Dadd9")?.0 == "major" && kind("Dadd9")?.1 == ["add 9 0"])
    #expect(kind("D2")?.0 == "major" && kind("D2")?.1 == ["add 2 0"])
  }

  /// Spellings a chord audit through MuseScore found misnamed: each must give the kind and degrees MuseScore names
  /// as the printed chord.
  @Test func auditedSpellingsGiveTheirChord() {
    func written(_ chord: String) -> String {
      guard let h = ChordMusicXML.harmony(chord, offset: 0) ?? ChordMusicXML.looseHarmony(chord, offset: 0) else {
        return "none"
      }
      let degrees = h.all("degree").map {
        "\($0.first("degree-type")!.text)\($0.first("degree-value")!.text)\($0.first("degree-alter")!.text)"
      }
      return ([h.first("kind")!.text] + degrees).joined(separator: " ")
    }
    #expect(written("Cmadd9") == "minor add90")        // was major
    #expect(written("C-add9") == "minor add90")
    #expect(written("C7+") == "augmented-seventh")     // was a plain seventh
    #expect(written("C9+") == "dominant-ninth alter51")
    #expect(written("C+maj7") == "major-seventh alter51")   // was augmented-seventh (a flat seventh)
    #expect(written("Caugmaj7") == "major-seventh alter51")
    #expect(written("Cmaj7+") == "major-seventh alter51")
    #expect(written("Cmaj7#5") == "major-seventh alter51")
    #expect(written("Cmaj7sus4") == "suspended-fourth add71")   // the sus was lost
    #expect(written("Cmaj7sus2") == "suspended-second add71")
    #expect(written("Cadd#11") == "major add111")
    // unchanged
    #expect(written("C+") == "augmented")
    #expect(written("C+7") == "augmented-seventh")
    #expect(written("Cm(add9)") == "minor add90")
    #expect(written("Cdim7") == "diminished-seventh")
    #expect(written("Co7") == "diminished-seventh")
  }

  @Test func aJazzFontTriangleReadAsAnAIsTheTriangle() {
    #expect(LocalChordReader.accepted("Dba7(#11)") == ["Dbmaj7(#11)"])
    #expect(LocalChordReader.accepted("GA9/B") == ["Gmaj9/B"])
    #expect(LocalChordReader.accepted("Gba9($11)") == ["Gbmaj9(#11)"])
    // a, aug, add and alt where they belong are left alone
    #expect(LocalChordReader.accepted("Caug") == ["Caug"])
    #expect(LocalChordReader.accepted("Cadd9") == ["Cadd9"])
    #expect(LocalChordReader.accepted("Am7") == ["Am7"])
    #expect(LocalChordReader.accepted("A7") == ["A7"])
    // after a minor quality too: minor-major
    #expect(LocalChordReader.accepted("F#mina7") == ["F#minmaj7"])
    #expect(LocalChordReader.accepted("C-a7") == ["C-maj7"])
    #expect(LocalChordReader.accepted("Ama9") == ["Ama9"])   // "ma9" is a major ninth as printed, untouched
    // still not a chord: left out, not guessed
    #expect(LocalChordReader.accepted("Bbamj7").isEmpty)
  }

  @Test func unreadableChordsAreNotStaffText() {
    #expect(LocalTextReader.chordShaped("Dba7(#11)Ba9"))
    #expect(LocalTextReader.chordShaped("Ebamj7"))
    #expect(!LocalTextReader.chordShaped("Bass Enters"))
    #expect(!LocalTextReader.chordShaped("Coda 2"))
    #expect(!LocalTextReader.chordShaped("A2"))
  }

  @Test func unfamiliarSuffixesPlayAsTheNearestKind() {
    func degrees(_ suffix: String) -> [String] {
      ChordMusicXML.nearestKind(suffix).degrees.map { "\($0.2) \($0.0) \($0.1)" }
    }
    #expect(ChordMusicXML.nearestKind("7sus4(b9)").kind == "suspended-fourth")
    // MuseScore's chord list spells 7susb9 as add7 addb9: on a sus chord an altered ninth is an added degree
    #expect(degrees("7sus4(b9)") == ["add 7 0", "add 9 -1"])
    #expect(ChordMusicXML.nearestKind("add9").kind == "major")
    #expect(degrees("add9") == ["add 9 0"])
    #expect(ChordMusicXML.nearestKind("m(maj7)").kind == "major-minor")
    #expect(ChordMusicXML.nearestKind("-Δ7").kind == "major-minor")
    #expect(ChordMusicXML.nearestKind("7alt").kind == "dominant")
    #expect(ChordMusicXML.nearestKind("sus2").kind == "suspended-second")
    #expect(ChordMusicXML.nearestKind("2").kind == "major")
    #expect(degrees("2") == ["add 2 0"])
    #expect(ChordMusicXML.nearestKind("7(b9,#5)").kind == "dominant")
    #expect(degrees("7(b9,#5)") == ["alter 9 -1", "alter 5 1"])
    #expect(ChordMusicXML.nearestKind("13sus").kind == "suspended-fourth")
  }

  /// A lead-sheet "Piano Solo" line: the page prints four bars after a
  /// clef piece cut off by the opening repeat, but the notation read three.
  private func pianoSoloLine() -> [ChordStaff] {
    func bar(_ index: Int, _ left: Double, _ right: Double, _ chords: [String]) -> ChordBar {
      let labels = chords.enumerated().map { offset, chord in
        var item = label(chord, left + (Double(offset) + 0.5) * (right - left) / Double(chords.count) - 5)
        item.bar = index
        return item
      }
      return ChordBar(
        index: index, left: left, right: right, text: chords.joined(separator: " "),
        labels: labels, measureNumber: nil, partID: nil)
    }
    return [ChordStaff(
      staff: 0, voice: 0, system: 0, top: 0, bottom: 20,
      bars: [
        bar(0, 130, 269, []), bar(1, 269, 599, ["D/F#", "G"]), bar(2, 599, 995, ["C#-7b5b9", "F#7b9"]),
        bar(3, 995, 1390, ["B-", "A"]), bar(4, 1390, 1780, ["G6"]),
      ], mappingStatus: "unresolved")]
  }

  private let threeBars = Data("""
    <score-partwise><part id="P1">
    <measure number="1"><attributes><divisions>1</divisions>
    <time><beats>4</beats><beat-type>4</beat-type></time></attributes>
    <note><duration>4</duration></note></measure>
    <measure number="2"><note><duration>4</duration></note></measure>
    <measure number="3"><note><duration>4</duration></note></measure>
    </part></score-partwise>
    """.utf8)

  @Test func unmatchedLineKeepsEveryChordInOrder() throws {
    var staffs = pianoSoloLine()
    try ChordMusicXML.map(
      &staffs, score: threeBars, fallbackMeter: ChordMeter(beats: 4, beatType: 4),
      fitUnmatched: true)
    #expect(staffs[0].mappingStatus == "position-fitted")
    let labels = staffs[0].bars.flatMap(\.labels)
    #expect(labels.map(\.chord) == ["D/F#", "G", "C#-7b5b9", "F#7b9", "B-", "A", "G6"])
    #expect(labels.allSatisfy { $0.measureNumber != nil && $0.beat != nil })
    let numbers = labels.compactMap { $0.measureNumber.flatMap(Int.init) }
    #expect(numbers == numbers.sorted())
    #expect(numbers.first == 1 && numbers.last == 3)

    let output = try ChordMusicXML.insertMapped(threeBars, staffs: staffs)
    #expect(output.written == 7)
  }

  @Test func unmatchedLineIsStillDroppedUnlessFittingIsAskedFor() throws {
    var staffs = pianoSoloLine()
    try ChordMusicXML.map(&staffs, score: threeBars)
    #expect(staffs[0].mappingStatus == "unresolved")
  }

  @Test func fittingLeavesMatchedLinesAlone() throws {
    var staffs = pianoSoloLine()
    staffs[0].bars.removeLast()
    let fourBars = Data(String(decoding: threeBars, as: UTF8.self).replacingOccurrences(
      of: "</part>", with: "<measure number=\"4\"><note><duration>4</duration></note></measure></part>").utf8)
    var plain = staffs
    try ChordMusicXML.map(&plain, score: fourBars)
    try ChordMusicXML.map(&staffs, score: fourBars, fitUnmatched: true)
    #expect(staffs[0].mappingStatus == plain[0].mappingStatus)
    #expect(staffs[0].bars.map(\.measureNumber) == plain[0].bars.map(\.measureNumber))
  }

  @Test func grammarAcceptsJazzChordsAndRejectsImpossibleOrder() {
    for chord in ["Bb-7", "F6/9", "C7(b9#11)", "F#o7"] {
      #expect(ChordGrammar.isChord(chord), "\(chord)")
    }
    #expect(!ChordGrammar.isChord("B6-"))
  }

  @Test func recognizedMetadataAndStaffTextUseStandardMusicXMLElements() throws {
    let xml = Data(
      """
      <score-partwise><work><work-title></work-title></work>
      <identification><encoding><software>homr</software></encoding></identification>
      <part-list><score-part id="P1"><part-name>Piano</part-name></score-part></part-list>
      <part id="P1"><measure number="1"><note><duration>4</duration></note></measure>
      <measure number="2"><note><duration>4</duration></note></measure></part>
      </score-partwise>
      """.utf8)
    let source = DocumentScanResult(
      xml: xml, rawXML: xml, seconds: 1, staffCount: 1,
      repairedMeasures: 0, pageCount: 1)
    let result = try ScoreMetadataMusicXML.insertingRecognizedContent(
      title: "The Tune", composer: "A Composer", arranger: "An Arranger",
      staffText: [
        ScoreTextDirection(
          voice: 0, system: 0, bar: 0, barCount: 2,
          text: "A", category: "rehearsal"),
        ScoreTextDirection(
          voice: 0, system: 0, bar: 0, barCount: 2,
          text: "17", category: "other"),
        ScoreTextDirection(
          voice: 0, system: 0, bar: 1, barCount: 2,
          text: "D.C. al Fine", category: "navigation"),
      ], into: source)

    let root = try XMLNode.parse(result.xml)
    #expect(root.first("work")?.first("work-title")?.text == "The Tune")
    let creators = root.first("identification")?.all("creator") ?? []
    #expect(creators.first { $0.attributes["type"] == "composer" }?.text == "A Composer")
    #expect(creators.first { $0.attributes["type"] == "arranger" }?.text == "An Arranger")
    #expect(Set(root.all("credit").compactMap { $0.first("credit-type")?.text })
      == Set(["title", "composer", "arranger"]))
    #expect(root.first("defaults")?.first("page-layout")?.first("page-height")?.text == "1584")
    #expect(root.all("credit").allSatisfy {
      (Double($0.first("credit-words")?.attributes["default-y"] ?? "") ?? 0) > 1584 / 2
    })
    let measures = root.first("part")?.all("measure") ?? []
    #expect(measures[0].first("direction")?.first("direction-type")?.first("rehearsal")?.text == "A")
    #expect(measures[1].first("direction")?.first("direction-type")?.first("words")?.text
      == "D.C. al Fine")
    #expect(root.serialized().contains(">17<") == false)
    #expect(try XMLNode.parse(result.xml).serialized() == XMLNode.parse(result.rawXML).serialized())
  }}
