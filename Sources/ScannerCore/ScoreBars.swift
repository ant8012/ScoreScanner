import Foundation

/// Where one bar of the score is printed: its outline on the page image it was read from, so an app can show what
/// is playing on the original scan or photo.
///
/// The outline spans every staff of the bar's system, from the top line of its first staff to the bottom line of
/// its last, and from the bar's start to its end. It is given on the page as the reader received it (a photo upright,
/// a PDF page as rendered), before any straightening, so on a tilted or curled photo the outline tilts with the
/// printed bar.
public struct ScoreBar: Sendable, Codable, Equatable {
  /// The bar's measure in the score, 0 for its first measure (the same in every part).
  public let measure: Int
  /// The page it is printed on, 0 for the first.
  public let page: Int
  /// Its line of music on that page, 0 for the top one.
  public let system: Int
  /// The outline's corners, top left, top right, bottom right, bottom left, as x and y pairs: x as a fraction of the
  /// page's width, y as a fraction of its height (0, 0 the top left corner).
  public let corners: [Double]

  public init(measure: Int, page: Int, system: Int, corners: [Double]) {
    self.measure = measure; self.page = page; self.system = system; self.corners = corners
  }

  /// The same bar moved to another place in the score (pages joined into one).
  func shifted(measures: Int, page: Int) -> ScoreBar {
    ScoreBar(measure: measure + measures, page: page, system: system, corners: corners)
  }
}

enum ScoreBars {
  /// The bars of one read page, measured from the first measure of its score. Empty when the layout and the
  /// written score do not agree system for system on how many bars there are: a highlight on the wrong bar is
  /// worse than none.
  static func read(
    _ staves: [Copista.Writer.PlacedStaff], xml: String, width: Int, height: Int, map: Copista.StraightenMap
  ) -> [ScoreBar] {
    guard width > 0, height > 0, let starts = systemStarts(xml) else { return [] }
    let systems = Dictionary(grouping: staves, by: \.system).sorted { $0.key < $1.key }
    guard systems.count == starts.count - 1 else { return [] }
    var bars: [ScoreBar] = []
    for (index, (_, placed)) in systems.enumerated() {
      // the staff with the most bars marks them (all staves of a system share their bar lines)
      guard let marker = placed.max(by: { a, b in
        a.measureStarts.count != b.measureStarts.count ? a.measureStarts.count < b.measureStarts.count : a.y0 > b.y0
      }) else { return [] }
      let edges = [marker.x0] + marker.measureStarts + [marker.x1]
      guard edges.count - 1 == starts[index + 1] - starts[index], zip(edges, edges.dropFirst()).allSatisfy({ $0 < $1 })
      else { return [] }
      let top = placed.map(\.y0).min()!, bottom = placed.map(\.y1).max()!
      for column in 0..<(edges.count - 1) {
        let left = edges[column], right = edges[column + 1]
        let corners = [(left, top), (right, top), (right, bottom), (left, bottom)].flatMap { x, y -> [Double] in
          let p = map.original(x: x, y: y)
          return [clamp(p.x / Double(width)), clamp(p.y / Double(height))]
        }
        bars.append(ScoreBar(measure: starts[index] + column, page: 0, system: index, corners: corners))
      }
    }
    return bars
  }

  /// The first measure of each system in a page's score, then the measure count: system breaks are the measures
  /// printing a new system (or page) in the first part.
  static func systemStarts(_ xml: String) -> [Int]? {
    guard let root = try? XMLNode.parse(Data(xml.utf8)), let part = root.first("part") else { return nil }
    let measures = part.all("measure")
    guard !measures.isEmpty else { return nil }
    var starts = [0]
    for (index, measure) in measures.enumerated() where index > 0 {
      if let print = measure.first("print"),
         print.attributes["new-system"] == "yes" || print.attributes["new-page"] == "yes" {
        starts.append(index)
      }
    }
    return starts + [measures.count]
  }

  /// The pages' bars in the joined score: each page's measures follow the pages before it. Empty when the joined
  /// score's measure count is not the pages' counts added up.
  static func joined(_ pages: [(bars: [ScoreBar], xml: Data)], into xml: Data) -> [ScoreBar] {
    guard let total = measureCount(xml) else { return [] }
    var offset = 0, bars: [ScoreBar] = []
    for (page, item) in pages.enumerated() {
      guard let count = measureCount(item.xml) else { return [] }
      bars += item.bars.map { $0.shifted(measures: offset, page: page) }
      offset += count
    }
    return offset == total ? bars : []
  }

  /// The bars still in `xml`'s first part: a later pass that changed how many measures there are drops them all.
  static func checked(_ bars: [ScoreBar], against xml: Data) -> [ScoreBar] {
    guard let count = measureCount(xml), bars.allSatisfy({ $0.measure < count }) else { return [] }
    return bars
  }

  static func measureCount(_ xml: Data) -> Int? {
    guard let root = try? XMLNode.parse(xml), let part = root.first("part") else { return nil }
    return part.all("measure").count
  }

  private static func clamp(_ v: Double) -> Double { max(0, min(1, v)) }
}
