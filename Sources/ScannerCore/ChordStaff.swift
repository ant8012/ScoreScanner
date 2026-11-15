import Foundation

/// One chord symbol, read from the page and located on it.
public struct ChordLabel: Sendable {
  public let text: String            // as the recognizer read it
  public var chord: String           // after the grammar tidied it
  public let confidence: Float
  public let x0: Double, x1: Double  // page columns the symbol spans
  public var bar: Int?               // index within the staff, when it sits in one
  public var measureNumber: String?
  public var partID: String?
  public var beat: Double?
  public var beatUnit: Int?
  public var timingSource: String?
  public var timingStatus: String?
  /// The finder word it was read from ("x0,y0,x1,y1"), for the on-device text pass.
  var word: String? = nil
}

public struct ChordBar: Sendable {
  public let index: Int
  public let left: Double, right: Double
  public var text: String
  public var labels: [ChordLabel]
  public var measureNumber: String?
  public var partID: String?
}

public struct ChordStaff: Sendable {
  public let staff: Int
  public let voice: Int?
  public var system: Int?
  public let top: Int, bottom: Int
  public var bars: [ChordBar]
  public var mappingStatus: String
}
