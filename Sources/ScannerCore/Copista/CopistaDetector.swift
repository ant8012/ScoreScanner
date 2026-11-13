import Foundation
import OnnxRuntimeBindings

// The copista-2m symbol detector (detect.py + detector/small arch9 obj-recall), run as two ONNX stages with the
// candidate picking between them done here, exactly as PeakRelational.decode_out does it.

extension Copista {
  /// The reader's fixed tables, exported beside the models (copista-meta.json).
  struct Meta: Decodable {
    let classes: [String]
    let attrs: [String]
    let attrVocab: [String: [String]]
    let attrOffsets: [String: Int]
    let links: [Double]
    let families: [String]

    static func load(_ models: URL) throws -> Meta {
      let d = JSONDecoder()
      d.keyDecodingStrategy = .convertFromSnakeCase
      return try d.decode(Meta.self, from: Data(contentsOf: models.appendingPathComponent("copista-meta.json")))
    }
  }

  /// One detection, as detect.Detector._records writes it (rounded the same way: the reader reads these).
  struct Det {
    var cls: String
    var conf: Double
    var xyxy: [Double]
    var attrs: [String: String]? = nil
    var attrP: [String: Double] = [:]
    var attrDist: [String: [String: Double]] = [:]
  }

  static let targetSp = 10.6
  static let attrClassPrefixes: Set<String> = ["note", "rest", "mRest", "multiRest"]

  static func imgsz(staffSpace: Double, longSide: Int) -> Int {
    if staffSpace <= 0 { return 2048 }
    let v = (Double(longSide) * targetSp / staffSpace / 32).rounded(.toNearestOrEven) * 32
    return Int(min(4096, max(640, v)))
  }

  static func measureSpace(_ dets: [Det]) -> Double {
    let hs = dets.filter { $0.cls == "measure" && $0.conf >= 0.5 }.map { $0.xyxy[3] - $0.xyxy[1] }.sorted()
    return hs.isEmpty ? 0 : hs[hs.count / 2] / 4
  }

  static func staffSpace(ink: Double, boxes: Double) -> Double {
    if ink <= 0 || (boxes > 0 && abs(ink / boxes - 1) > 0.25) { return boxes }
    return ink
  }

  final class Detector {
    private let env: ORTEnv
    private let stageA: ORTSession
    private let stageB: ORTSession
    let meta: Meta
    private let attrClass: [Bool]
    static let stride = 4, kInfer = 4000, conf = 0.05, nmsIoU: Float = 0.7

    init(models: URL, meta: Meta) throws {
      env = try ORTEnv(loggingLevel: .warning)
      let options = try RuntimePolicy.options()
      stageA = try ORTSession(env: env, modelPath: models.appendingPathComponent("copista_detector_a.onnx").path,
                              sessionOptions: options)
      stageB = try ORTSession(env: env, modelPath: models.appendingPathComponent("copista_detector_b.onnx").path,
                              sessionOptions: options)
      self.meta = meta
      attrClass = meta.classes.map { attrClassPrefixes.contains(String($0.split(separator: "_", maxSplits: 1)[0])) }
    }

    /// The page's detections, read at the size its staff space asks for (pipeline.detections).
    func detections(_ page: Gray, inkSpacing: Double) throws -> (dets: [Det], imgsz: Int) {
      let first = try run(page, imgsz: 2048)
      let size = imgsz(staffSpace: staffSpace(ink: inkSpacing, boxes: measureSpace(first)),
                       longSide: max(page.width, page.height))
      return size == 2048 ? (first, size) : (try run(page, imgsz: size), size)
    }

    func run(_ page: Gray, imgsz: Int) throws -> [Det] {
      let s = Double(imgsz) / Double(max(page.width, page.height))
      let w2 = max(32, pyRound(Double(page.width) * s)), h2 = max(32, pyRound(Double(page.height) * s))
      let small = resizeLanczos(page, width: w2, height: h2)
      let H = (h2 + 31) / 32 * 32, W = (w2 + 31) / 32 * 32
      var x = [Float](repeating: 1, count: H * W)
      for y in 0..<h2 { for xx in 0..<w2 { x[y * W + xx] = Float(small.pixels[y * w2 + xx]) / 255.0 } }
      let input = try tensor(x.withUnsafeBufferPointer { Data(buffer: $0) }, type: .float, shape: [1, 1, H, W])
      let a = try stageA.run(withInputs: ["image": input], outputNames: ["f", "obj", "reg"], runOptions: nil)
      let f = try require("f", in: a), reg = try require("reg", in: a), objV = try require("obj", in: a)
      let shape = try objV.tensorTypeAndShapeInfo().shape.map(\.intValue)
      let hh = shape[2], ww = shape[3]
      let obj = try floats(objV).map { 1 / (1 + exp(-$0)) }
      // 3x3 maxima of the objectness over half the threshold, the strongest kInfer
      var peaks: [(Float, Int)] = []
      for y in 0..<hh {
        for xx in 0..<ww {
          let v = obj[y * ww + xx]
          var top = true
          for dy in -1...1 where top {
            for dx in -1...1 {
              let yy = y + dy, xq = xx + dx
              if yy >= 0 && yy < hh && xq >= 0 && xq < ww && obj[yy * ww + xq] > v { top = false; break }
            }
          }
          if top && v > Float(Detector.conf * 0.5) { peaks.append((v, y * ww + xx)) }
        }
      }
      peaks.sort { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }
      if peaks.count > Detector.kInfer { peaks.removeLast(peaks.count - Detector.kInfer) }
      guard !peaks.isEmpty else { return [] }
      let n = peaks.count
      let cy = peaks.map { Int64($0.1 / ww) }, cx = peaks.map { Int64($0.1 % ww) }
      let b = try stageB.run(
        withInputs: ["f": f, "reg": reg,
                     "cy": tensor(cy.withUnsafeBufferPointer { Data(buffer: $0) }, type: .int64, shape: [1, n]),
                     "cx": tensor(cx.withUnsafeBufferPointer { Data(buffer: $0) }, type: .int64, shape: [1, n])],
        outputNames: ["cls", "ref", "attr", "r"], runOptions: nil)
      let clsL = try floats(require("cls", in: b)), ref = try floats(require("ref", in: b))
      let attr = try floats(require("attr", in: b)), r = try floats(require("r", in: b))
      let nc1 = clsL.count / n, nCls = nc1 - 1, nAttr = attr.count / n
      var cands: [(score: Float, cls: Int, box: [Float], i: Int)] = []
      for i in 0..<n {
        let row = clsL[(i * nc1)..<((i + 1) * nc1)]
        let mx = row.max()!
        var sum: Float = 0
        for v in row { sum += exp(v - mx) }
        var pc: Float = -1, c = 0
        for k in 0..<nCls {
          let p = exp(row[row.startIndex + k] - mx) / sum
          if p > pc { pc = p; c = k }
        }
        let score = peaks[i].0 * pc
        guard score > Float(Detector.conf) else { continue }
        let r0 = r[i * 4] + ref[i * 4 + 2], r1 = r[i * 4 + 1] + ref[i * 4 + 3]
        let r2 = r[i * 4 + 2] + ref[i * 4], r3 = r[i * 4 + 3] + ref[i * 4 + 1]
        let w = exp(r0) * Float(Detector.stride), h = exp(r1) * Float(Detector.stride)
        let bx = (Float(cx[i]) + r2) * Float(Detector.stride), by = (Float(cy[i]) + r3) * Float(Detector.stride)
        cands.append((score, c, [bx - w / 2, by - h / 2, bx + w / 2, by + h / 2], i))
      }
      // per-class greedy NMS, strongest first (torchvision batched_nms)
      let order = cands.indices.sorted { cands[$0].score != cands[$1].score ? cands[$0].score > cands[$1].score : $0 < $1 }
      var dead = [Bool](repeating: false, count: cands.count)
      var kept: [Int] = []
      for i in order where !dead[i] {
        kept.append(i)
        let a = cands[i].box, aa = (a[2] - a[0]) * (a[3] - a[1])
        for j in order where !dead[j] && j != i && cands[j].cls == cands[i].cls {
          let q = cands[j].box
          let iw = max(0, min(a[2], q[2]) - max(a[0], q[0])), ih = max(0, min(a[3], q[3]) - max(a[1], q[1]))
          let inter = iw * ih
          if inter / (aa + (q[2] - q[0]) * (q[3] - q[1]) - inter) > Detector.nmsIoU { dead[j] = true }
        }
      }
      return kept.map { k in
        let c = cands[k]
        var d = Det(cls: meta.classes[c.cls], conf: pyRound(Double(c.score), 3),
                    xyxy: c.box.map { pyRound(Double($0) / s, 1) })
        if attrClass[c.cls] {
          var attrs: [String: String] = [:], ap: [String: Double] = [:], ad: [String: [String: Double]] = [:]
          for a in meta.attrs {
            let voc = meta.attrVocab[a]!, off = meta.attrOffsets[a]!
            let lg = (0..<voc.count).map { attr[c.i * nAttr + off + $0] }
            let mx = lg.max()!
            let e = lg.map { exp($0 - mx) }
            let tot = e.reduce(0, +)
            let p = e.map { $0 / tot }
            var kk = 0
            for j in 1..<p.count where p[j] > p[kk] { kk = j }
            attrs[a] = voc[kk]
            ap[a] = pyRound(Double(p[kk]), 4)
            if voc.count <= 12 {
              var dist: [String: Double] = [:]
              for j in 0..<voc.count where p[j] >= 0.005 { dist[voc[j]] = pyRound(Double(p[j]), 4) }
              ad[a] = dist
            }
          }
          d.attrs = attrs; d.attrP = ap; d.attrDist = ad
        }
        return d
      }
    }
  }
}
