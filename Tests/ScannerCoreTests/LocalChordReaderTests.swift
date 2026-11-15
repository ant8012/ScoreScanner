import Foundation
import Testing

@testable import ScannerCore

struct LocalChordReaderTests {
  @Test func greedyDecodingCollapsesRepeatsAndDropsBlanks() {
    // classes: blank, "C", "7", space; steps read C C blank 7 7 blank C
    let characters = ["", "C", "7", " "]
    let best = [1, 1, 0, 2, 2, 0, 1]
    var probs = [Float](repeating: 0.01, count: best.count * characters.count)
    for (t, c) in best.enumerated() { probs[t * characters.count + c] = 0.9 }
    let data = probs.withUnsafeBufferPointer { Data(buffer: $0) }
    let reading = LocalChordReader.decode(data, steps: best.count, classes: characters.count, characters: characters)
    #expect(reading.text == "C7C")
    #expect(abs(reading.score - 0.9) < 1e-6)
  }

  @Test func readingsAreJudgedLikeTheCloudReader() {
    #expect(LocalChordReader.judged("■").verdict == .blocked)
    #expect(LocalChordReader.judged("■1").chords.isEmpty)
    #expect(LocalChordReader.judged("Fine").chords.isEmpty)
    #expect(LocalChordReader.judged("Abma7").chords == ["Abmaj7"])
    #expect(LocalChordReader.judged("(Dbmi7").chords == ["Dbmi7"])
    #expect(LocalChordReader.judged("C7sus4") == (["C7sus4"], .unusual))
  }

  @Test func theModelInputIsFortyEightHighAndAtLeast320Wide() {
    let small = LocalChordReader.Image(width: 30, height: 20, pixels: [UInt8](repeating: 255, count: 600))
    let (data, width) = LocalChordReader.modelInput(small)
    #expect(width == 320)
    #expect(data.count == 3 * 48 * 320 * 4)
    // white maps to 1, padding past the resized width (ceil(48 * 1.5) = 72) stays 0
    let values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    #expect(values[0] == 1)
    #expect(values[71] == 1)
    #expect(values[72] == 0)
    let wide = LocalChordReader.Image(width: 400, height: 20, pixels: [UInt8](repeating: 0, count: 8000))
    #expect(LocalChordReader.modelInput(wide).1 == 960)
  }

  @Test func resizingKeepsAFlatImageFlat() {
    let grey = LocalChordReader.Image(width: 37, height: 23, pixels: [UInt8](repeating: 77, count: 37 * 23))
    #expect(LocalChordReader.lanczos(grey, width: 74, height: 46).pixels.allSatisfy { $0 == 77 })
    #expect(LocalChordReader.bilinear(grey, width: 50, height: 48).pixels.allSatisfy { $0 == 77 })
  }

  @Test func cropsArePaddedAndEnlargedLikeTheBenchmark() {
    let page = LocalChordReader.Image(width: 200, height: 100, pixels: [UInt8](repeating: 255, count: 20_000))
    let word = ChordFinder.Proposal(x0: 50, y0: 40, x1: 80, y1: 60, staff: 0, order: 0, kind: .text)
    let cut = LocalChordReader.crop(page: page, word: word, sp: 10)
    // padded by 3.5 px (truncated), then enlarged 96 / 27 times
    #expect(cut.map { [$0.box.0, $0.box.1, $0.box.2, $0.box.3] } == [46, 36, 83, 63])
    #expect(cut.map { [$0.image.width, $0.image.height] } == [132, 96])
    // a speck under 0.6 staff spaces is not read
    let speck = ChordFinder.Proposal(x0: 10, y0: 10, x1: 14, y1: 15, staff: 0, order: 0, kind: .text)
    #expect(LocalChordReader.crop(page: page, word: speck, sp: 10) == nil)
  }

  @Test func theBundledModelLoadsAndRejectsABlankCrop() throws {
    #expect(ScoreReader.localChordReadingAvailable())
    let model = try LocalChordReader.Model(models: Scanner.bundledModels)
    #expect(model.characters.count == 18_710)
    let blank = LocalChordReader.Image(width: 120, height: 96, pixels: [UInt8](repeating: 255, count: 120 * 96))
    #expect(LocalChordReader.accepted(try model.read(blank).text).isEmpty)
  }

  @Test func beatsFromTheFinderAreKept() {
    func label(_ beat: Double?, _ source: String?) -> ChordLabel {
      ChordLabel(
        text: "C", chord: "C", confidence: 1, x0: 0, x1: 1, bar: 0, measureNumber: "1", partID: "P1", beat: beat,
        beatUnit: nil, timingSource: source, timingStatus: nil)
    }
    var bar = ChordBar(
      index: 0, left: 0, right: 100, text: "", labels: [label(1, "finder"), label(2.5, "finder")],
      measureNumber: "1", partID: "P1")
    ChordTiming.place(bar: &bar, signature: ChordMeter(beats: 4, beatType: 4))
    #expect(bar.labels.map(\.beat) == [1, 2.5])
    #expect(bar.labels.map(\.beatUnit) == [4, 4])
    // without the finder's beats the metre defaults still apply (two chords in 4/4: beats 1 and 3)
    var plain = ChordBar(
      index: 0, left: 0, right: 100, text: "", labels: [label(nil, nil), label(nil, nil)], measureNumber: "1",
      partID: "P1")
    ChordTiming.place(bar: &plain, signature: ChordMeter(beats: 4, beatType: 4))
    #expect(plain.labels.map(\.beat) == [1, 3])
  }

  @Test func onlyTheAppleRoutesUseApplesModel() {
    #expect(!ScoreReadOptions(readStaffText: false).usesAppleModel)
    #expect(ScoreReadOptions(readStaffText: true).usesAppleModel)
    #expect(ScoreReadOptions(readChordNames: true, readStaffText: false, chordReader: .appleModel).usesAppleModel)
    #expect(!ScoreReadOptions(readChordNames: false, readStaffText: false, chordReader: .appleModel).usesAppleModel)
    #expect(ScoreReadOptions().chordReader == .onDevice)
  }
}
