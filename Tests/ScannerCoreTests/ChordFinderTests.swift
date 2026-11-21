import Foundation
import Testing

@testable import ScannerCore

/// The chord finder on small drawn pages: rectangles stand in for letters, and the layout is what copisteria would
/// report (staves, a timed note, the marks it found).
struct ChordFinderTests {
  private struct Page {
    let width: Int, height: Int
    var gray: [UInt8]
    init(_ width: Int, _ height: Int) {
      self.width = width; self.height = height
      gray = [UInt8](repeating: 255, count: width * height)
    }
    /// Ink from (x0, y0) up to, not including, (x1, y1).
    mutating func fill(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) {
      for y in y0..<y1 { for x in x0..<x1 { gray[y * width + x] = 0 } }
    }
    /// A flat: a stem with a closed loop at its foot (one piece with a hole).
    mutating func flat(_ x0: Int, _ y0: Int, _ y1: Int) {
      fill(x0, y0, x0 + 3, y1)
      fill(x0, y1 - 12, x0 + 10, y1 - 9)
      fill(x0 + 7, y1 - 12, x0 + 10, y1)
      fill(x0, y1 - 3, x0 + 10, y1)
    }
  }

  private func staff(_ y0: Double, sp: Double = 10) -> ChordFinder.Staff {
    ChordFinder.Staff(x0: 40, x1: 560, y0: y0, y1: y0 + 4 * sp, sp: sp, bars: [40])
  }

  private func texts(_ found: [ChordFinder.Proposal], staff: Int) -> [ChordFinder.Proposal] {
    found.filter { $0.staff == staff && $0.kind == .text }.sorted { $0.x0 < $1.x0 }
  }

  // MARK: a mark attached to a note

  /// A chord over a note with a fermata on it: copisteria reads the fermata confidently, centred over the note.
  private func fermataPage(fermataP: Double) -> (Page, ChordFinder.Layout) {
    var page = Page(600, 300)
    page.fill(100, 150, 112, 170)       // C
    page.fill(115, 157, 129, 170)       // a lowercase quality piece
    page.fill(100, 176, 120, 188)       // the fermata, between the chord and the staff
    page.fill(104, 205, 116, 213)       // its note
    let syms = [
      ChordFinder.Symbol(cls: "noteheadBlack", box: ChordFinder.Box(104, 205, 116, 213), staff: 0, bar: 0, p: 0.99),
      ChordFinder.Symbol(cls: "fermataAbove", box: ChordFinder.Box(100, 176, 120, 188), staff: 0, bar: 0,
                         p: fermataP),
    ]
    let layout = ChordFinder.Layout(staves: [staff(200)], syms: syms, sp: 10,
                                    tokens: [0: ChordFinder.Token(onset: 0, real: 1, time: nil)])
    return (page, layout)
  }

  @Test func aConfidentFermataOnANoteNoLongerPushesTheChordAboveIt() {
    let (page, layout) = fermataPage(fermataP: 0.95)
    var before = ChordFinder.Parameters()
    before.attachedMarks = false
    let old = ChordFinder.find(gray: page.gray, width: page.width, height: page.height, layout: layout,
                               parameters: before)
    // without the rule the fermata is a word of its own under the chord, and the chord counts as stacked text
    #expect(old.contains { $0.kind == .stacked && $0.x0 == 100 && $0.y0 == 150 })

    let found = ChordFinder.find(gray: page.gray, width: page.width, height: page.height, layout: layout)
    let words = texts(found, staff: 0)
    #expect(words.count == 1)
    #expect(words.first.map { ($0.x0, $0.y0, $0.x1, $0.y1) } ?? (0, 0, 0, 0) == (100, 150, 129, 170))
    #expect(!found.contains { $0.kind == .stacked })
  }

  @Test func anUnsureMarkIsLeftForTheReader() {
    // copisteria calls a handwritten chord letter a fermata, rarely with confidence: its ink stays
    let (page, layout) = fermataPage(fermataP: 0.5)
    let found = ChordFinder.find(gray: page.gray, width: page.width, height: page.height, layout: layout)
    #expect(found.contains { $0.x0 == 100 && $0.y0 == 176 })
  }

  // MARK: a loosely set font

  /// Three lines, each "B m7 b5" then "F m7" in a loosely set font (Real Book 3): 5 px between letters within a
  /// chord and 5 px before the next root. One line has too few letter gaps to measure; the page has enough.
  private func loosePage() -> (Page, ChordFinder.Layout) {
    var page = Page(600, 700)
    var staves: [ChordFinder.Staff] = []
    for y0 in [200, 400, 600] {
      let base = y0 - 20                    // chords stand two spaces over the staff
      page.fill(100, base - 20, 112, base)  // B
      page.fill(121, base - 13, 135, base)  // m, 9 px after the root
      page.fill(140, base - 17, 148, base - 5)  // raised 7, 5 px on
      page.flat(152, base - 24, base)       // flat, 4 px on
      page.fill(164, base - 13, 173, base)  // 5, 2 px on
      page.fill(178, base - 20, 190, base)  // F: the next chord's root, 5 px on
      page.fill(199, base - 13, 213, base)  // m
      page.fill(218, base - 17, 226, base - 5)  // raised 7
      staves.append(staff(Double(y0)))
    }
    return (page, ChordFinder.Layout(staves: staves, syms: [], sp: 10, tokens: [:]))
  }

  @Test func aLooselySetChordStaysOneWordAndTheNextRootStaysApart() {
    let (page, layout) = loosePage()
    let found = ChordFinder.find(gray: page.gray, width: page.width, height: page.height, layout: layout)
    for k in 0..<3 {
      let words = texts(found, staff: k)
      #expect(words.map { [$0.x0, $0.x1] } == [[100, 173], [178, 226]], "line \(k)")
    }
  }

  @Test func aRootJoinsAnExtensionWrittenRaised() {
    // "C" then "9(#11)" set raised and tight: the extension is one word that sits higher than the root, but its
    // first glyph is level enough with it (a MuseScore sheet split this into "C" and "9(#11)")
    var page = Page(600, 400)
    page.fill(300, 222, 312, 246)       // G, G: two other chords setting the line's letter height
    page.fill(350, 222, 362, 246)
    page.fill(437, 222, 456, 246)       // C
    page.fill(463, 213, 474, 232)       // 9, 7 px on
    page.fill(478, 207, 486, 225)       // the raised rest, 4 px apart
    page.fill(490, 210, 499, 225)
    page.fill(503, 210, 513, 225)
    let layout = ChordFinder.Layout(staves: [ChordFinder.Staff(x0: 40, x1: 560, y0: 280, y1: 344, sp: 16, bars: [40])],
                                    syms: [], sp: 16, tokens: [:])
    let found = ChordFinder.find(gray: page.gray, width: page.width, height: page.height, layout: layout)
    #expect(texts(found, staff: 0).map { [$0.x0, $0.x1] } == [[300, 312], [350, 362], [437, 513]])
  }

  @Test func withoutPageSpacingTheLooseChordSplits() {
    let (page, layout) = loosePage()
    var before = ChordFinder.Parameters()
    before.pageGap = false
    let found = ChordFinder.find(gray: page.gray, width: page.width, height: page.height, layout: layout,
                                 parameters: before)
    #expect(texts(found, staff: 0).count > 2)
  }

  // MARK: chord diagrams

  /// A piano-vocal-guitar page: a guitar chord diagram over the voice staff with its name touching the diagram's top
  /// line, the diagram lifting the name close to the staff above.
  @Test func aChordNameOnADiagramIsFoundForTheStaffBelow() {
    var page = Page(600, 400)
    page.fill(220, 198, 232, 225)                                     // D, touching the nut
    for i in 0..<6 { page.fill(200 + 12 * i, 225, 202 + 12 * i, 276) }  // six strings
    page.fill(200, 225, 262, 228)                                     // the nut
    for y in [237, 249, 261, 273] { page.fill(200, y, 262, y + 2) }    // four frets
    page.fill(222, 305, 232, 313)                                     // a note on the voice staff
    page.fill(222, 165, 232, 173)                                     // and one on the staff above
    let syms = [
      ChordFinder.Symbol(cls: "noteheadBlack", box: ChordFinder.Box(222, 165, 232, 173), staff: 0, bar: 0, p: 0.99),
      ChordFinder.Symbol(cls: "noteheadBlack", box: ChordFinder.Box(222, 305, 232, 313), staff: 1, bar: 0, p: 0.99),
    ]
    let layout = ChordFinder.Layout(staves: [staff(150), staff(300)], syms: syms, sp: 10,
                                    tokens: [0: ChordFinder.Token(onset: 0, real: 1, time: nil),
                                             1: ChordFinder.Token(onset: 0, real: 1, time: nil)])
    let found = ChordFinder.find(gray: page.gray, width: page.width, height: page.height, layout: layout)
    let words = texts(found, staff: 1)
    #expect(words.count == 1)
    #expect(words.first.map { ($0.x0, $0.y0, $0.x1, $0.y1) } ?? (0, 0, 0, 0) == (220, 198, 232, 224))   // less the row that touches the nut
    // the diagram itself is never a word
    #expect(!found.contains { $0.x1 - $0.x0 > 40 })
  }
}
