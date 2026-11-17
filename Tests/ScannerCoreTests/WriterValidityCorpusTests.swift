import Foundation
import Testing
@testable import ScannerCore

/// Optional local corpus exercise. Point WRITER_VALIDITY_INPUT at a directory of MusicXML files and
/// WRITER_VALIDITY_OUTPUT at a scratch directory; private test music is never bundled with the tests.
struct WriterValidityCorpusTests {
  @Test(.enabled(if: ProcessInfo.processInfo.environment["WRITER_VALIDITY_INPUT"] != nil))
  func externalCorpusIsRetainedAndIdempotent() throws {
    let env = ProcessInfo.processInfo.environment
    let input = try #require(env["WRITER_VALIDITY_INPUT"])
    let output = try #require(env["WRITER_VALIDITY_OUTPUT"])
    let fm = FileManager.default, src = URL(fileURLWithPath: input), dst = URL(fileURLWithPath: output)
    var errors: [String: String] = [:], changed: [String] = [], nonidempotent: [String] = [], count = 0
    for case let url as URL in fm.enumerator(at: src, includingPropertiesForKeys: nil)! where url.pathExtension == "musicxml" {
      let rel = url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
      let target = dst.appendingPathComponent(rel)
      count += 1
      do {
        let original = try Data(contentsOf: url), fixed = try ScoreValidityMusicXML.apply(original)
        if fixed != original { changed.append(rel) }
        if try ScoreValidityMusicXML.apply(fixed) != fixed { nonidempotent.append(rel) }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fixed.write(to: target)
      } catch { errors[rel] = String(describing: error) }
    }
    try fm.createDirectory(at: dst, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: ["files": count, "errors": errors, "changed": changed,
      "nonidempotent": nonidempotent], options: [.prettyPrinted, .sortedKeys]).write(to: dst.appendingPathComponent("repairs.json"))
    #expect(count > 0); #expect(errors.isEmpty); #expect(nonidempotent.isEmpty)
  }
}
