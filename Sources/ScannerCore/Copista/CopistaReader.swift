import Foundation
#if canImport(Android)
import Android
#endif
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#else
import OnnxRuntimeAndroid
#endif

// copisteria's reading (features.py, read.py, revise.py, vocab.py): every symbol's final reading from the evidence
// model, run over each system with its neighbours.

extension Copista {
  /// An exact rational (Python's fractions.Fraction, as far as the reader needs it).
  struct Q: Hashable, Comparable, CustomStringConvertible {
    let n: Int, d: Int
    init(_ n: Int, _ d: Int = 1) {
      precondition(d != 0)
      func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? max(a, 1) : gcd(b, a % b) }
      let g = gcd(abs(n), abs(d))
      self.n = n / g * (d < 0 ? -1 : 1)
      self.d = abs(d) / g
    }
    static let zero = Q(0)
    static func + (a: Q, b: Q) -> Q { Q(a.n * b.d + b.n * a.d, a.d * b.d) }
    static func - (a: Q, b: Q) -> Q { Q(a.n * b.d - b.n * a.d, a.d * b.d) }
    static func * (a: Q, b: Q) -> Q { Q(a.n * b.n, a.d * b.d) }
    static func / (a: Q, b: Q) -> Q { Q(a.n * b.d, a.d * b.n) }
    static func < (a: Q, b: Q) -> Bool { a.n * b.d < b.n * a.d }
    static func += (a: inout Q, b: Q) { a = a + b }
    static func -= (a: inout Q, b: Q) { a = a - b }
    var double: Double { Double(n) / Double(d) }
    var isZero: Bool { n == 0 }
    var description: String { d == 1 ? "\(n)" : "\(n)/\(d)" }
    /// Whether self is a whole multiple of `b` (Python: not cum % blen).
    func isMultiple(of b: Q) -> Bool { (self / b).d == 1 }
  }

  enum Vocab {
    static let posMax = 24
    static let alters: [Int?] = [nil, -2, -1, 0, 1, 2]           // nil: "key"
    static let grace = ["none", "acc", "unacc"]
    static let tuplets = ["none", "3/2", "2/3", "5/4", "6/4", "4/3", "7/4", "other"]
    static let keys: [Int?] = Array(-7...7) + [nil]
    static let times: [String?] = ["2/2", "3/2", "4/2", "2/4", "3/4", "4/4", "5/4", "6/4", "7/4", "3/8", "5/8", "6/8",
                                   "7/8", "9/8", "12/8", "1/4", "1/8", "2/8", "4/8", "8/8", "9/4", "12/16", "other", nil]
    static let clefs: [String?] = ["G2", "F4", "C3", "C4", "C1", "C2", "C5", "G1", "F3", "F5", "G2_8b", "G2_8a",
                                   "G2_15b", "G2_15a", "F4_8b", "F4_8a", "F4_15b", "F4_15a", "perc", "other", nil]
    static let typeQuarters: [(String, Q)] = [
      ("long", Q(16)), ("breve", Q(8)), ("whole", Q(4)), ("half", Q(2)), ("quarter", Q(1)), ("eighth", Q(1, 2)),
      ("16th", Q(1, 4)), ("32nd", Q(1, 8)), ("64th", Q(1, 16)), ("128th", Q(1, 32)), ("256", Q(1, 64)),
      ("512", Q(1, 128))]
    static let typeQ: [String: Q] = Dictionary(uniqueKeysWithValues: typeQuarters)

    static func keyAlter(_ step: String, _ fifths: Int) -> Int {
      if fifths > 0 { return "FCGDAEB".prefix(fifths).contains(step) ? 1 : 0 }
      if fifths < 0 { return "BEADGCF".prefix(-fifths).contains(step) ? -1 : 0 }
      return 0
    }

    /// write._duration
    static func duration(_ typ: String, _ dots: Int, _ tup: String) -> Q {
      var d = typeQ[typ] ?? Q(1)
      d = d * (Q(2) - Q(1, 1 << dots))
      if tup != "none" && tup != "other" {
        let parts = tup.split(separator: "/").compactMap { Int($0) }
        d = d * Q(parts[1]) / Q(parts[0])
      }
      return d
    }

    /// write._type_of
    static func typeOf(_ cls: String) -> String {
      guard let i = cls.firstIndex(of: "_") else { return "quarter" }
      let t = String(cls[cls.index(after: i)...])
      return typeQ[t] != nil ? t : "quarter"
    }
  }

  /// One head's reading: the final choice (a vocabulary index), its probability, and where the detector had a
  /// reading, its choice and the evidence (nats) the context added for the final one over it.
  struct Head {
    var v: Int
    var p: Double
    var det: Int?
    var ev: Double?
  }

  /// A symbol's final reading (read.read's per-symbol dict).
  struct Tok {
    var realDet = 0.0, realP = 0.0, realEv = 0.0
    var heads: [String: Head] = [:]
    var timeP: [Double]?
    var chord: Double?, tie: Double?
    var onset: Double?, onsetP: Double?
    var onsetBeatP: [Double]?, onsetFracP: [Double]?, tupP: [Double]?
    /// A note's or rest's value as the model weighs it: each value of the read class's family ("quarter",
    /// "eighth", ...) with its probability. And the probability of each dot count. Runner-up readings the writer
    /// tries when a bar runs past its end.
    var valueP: [String: Double]?, dotsP: [Double]?

    var cls: Int { heads["cls"]!.v }
    var real: Bool { realP >= 0.5 }
    func int(_ k: String) -> Int { heads[k]!.v }
    var pos: Int { heads["pos"]!.v - Vocab.posMax }
    var voice: Int { heads["voice"]!.v + 1 }
    var dots: Int { heads["dots"]!.v }
    var tup: String { Vocab.tuplets[heads["tup"]!.v] }
    var grace: String { Vocab.grace[heads["grace"]!.v] }
    var alter: Int? { Vocab.alters[heads["alter"]!.v] }          // nil: "key"
    var key: Int? { heads["key"].flatMap { Vocab.keys[$0.v] } }
    var time: String? { heads["time"].flatMap { Vocab.times[$0.v] } }
    var clef: String? { heads["clef"].flatMap { Vocab.clefs[$0.v] } }
    var hasBarHeads: Bool { heads["key"] != nil }
  }

  final class Reading {
    let layout: Layout
    var tok: [Int: Tok]
    let classes: [String]
    var revised: [Int: [Double]] = [:]
    /// Bars filled with rhythm slashes (`Slashes.bars`), by layout staff and bar: how many slashes were found.
    var slashBars: [Int: [Int: Int]] = [:]
    init(layout: Layout, tok: [Int: Tok], classes: [String]) { self.layout = layout; self.tok = tok; self.classes = classes }
  }

  // MARK: token arrays (features.page_arrays)
  struct Tokens {
    var sym: [Int] = []
    var fam: [Int64] = [], clsIds: [Int64] = [], clsP: [Float] = [], p: [Float] = [], geo: [Float] = []
    var staffpos: [Int64] = [], nstaves: [Int64] = [], sys: [Int64] = [], col: [Int64] = []
    var posV: [Int64] = [], posP: [Float] = []
    var dotsP: [Float] = [], voiceP: [Float] = [], graceP: [Float] = [], stemP: [Float] = []
    var count: Int { sym.count }
  }

  static let kCls = 3, nGeo = 13, maxStaves = 16, posSaturated = 22, nVoice = 4

  static func pageArrays(_ L: Layout, families: [String]) -> Tokens {
    let famId = Dictionary(uniqueKeysWithValues: families.enumerated().map { ($1, $0) })
    var sysOff: [Int] = [], off = 0
    for sy in L.systems {
      sysOff.append(off)
      off += 1 + (sy.columns.filter { !$0.isEmpty }.map { $0.max()! }.max() ?? 0)
    }
    let syms = Front.stableSorted(L.syms.filter { $0.staff >= 0 }) { a, b in
      let sa = L.staves[a.staff], sb = L.staves[b.staff]
      let ka = (sa.system, sa.pos, a.bar, a.fam != "measure" ? 1 : 0), kb = (sb.system, sb.pos, b.bar, b.fam != "measure" ? 1 : 0)
      if ka != kb { return ka < kb }
      if a.cx != b.cx { return a.cx < b.cx }
      return a.cy < b.cy
    }
    var barCount: [[Int]: Int] = [:]
    for s in syms { barCount[[s.staff, s.bar], default: 0] += 1 }
    var t = Tokens()
    func dist(_ d: [String: Double]?, _ fallback: String, vocab: [String], fold: [String: Int], size: Int) -> [Float] {
      var src: [(String, Double)]
      if let d, !d.isEmpty { src = vocab.compactMap { k in d[k].map { (k, $0) } } } else { src = [(fallback, 1.0)] }
      var out = [Double](repeating: 0, count: size)
      for (k, v) in src { if let slot = fold[k] { out[slot] += v } }
      let s = out.reduce(0, +)
      return (s > 0 ? out.map { $0 / s } : out).map(Float.init)
    }
    let dotsIn = ["<na>", "1", "2", "3", "4"], voiceIn = ["<na>"] + (1...8).map(String.init)
    let graceIn = ["<na>", "acc", "unacc"], stemIn = ["<na>", "down", "up", "both"]
    let dotsFold = ["<na>": 0, "1": 1, "2": 2, "3": 3, "4": 3]
    var voiceFold: [String: Int] = [:]
    for v in 1...8 { voiceFold[String(v)] = min(nVoice, v) - 1 }
    let graceFold = ["<na>": 0, "acc": 1, "unacc": 2], stemFold = ["down": 0, "up": 1, "both": 2]
    for s in syms {
      let st = L.staves[s.staff], sy = L.systems[st.system]
      let bar = L.syms[st.bars[s.bar]]
      let (bx0, by0, bx1, by1) = bar.box
      let sp = bar.synthetic ? st.sp : max(1.0, (by1 - by0) / 4)
      let mid = bar.synthetic ? st.mid : (by0 + by1) / 2
      let sx0 = sy.staves.map { L.staves[$0].x0 }.min()!, sx1 = sy.staves.map { L.staves[$0].x1 }.max()!
      let sy0 = sy.staves.map { L.staves[$0].y0 }.min()!, sy1 = sy.staves.map { L.staves[$0].y1 }.max()!
      t.sym.append(s.i)
      t.fam.append(Int64(famId[s.fam]!))
      let top = s.post.enumerated().sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
        .prefix(kCls).map(\.element)
      for k in 0..<kCls {
        t.clsIds.append(k < top.count ? Int64(top[k].0) : 0)
        t.clsP.append(k < top.count ? Float(top[k].1) : 0)
      }
      t.p.append(Float(s.synthetic ? 0.5 : s.p))
      let (x0, y0, x1, y1) = s.box
      let geo: [Double] = [
        (s.cx - bx0) / sp / 10, (s.cx - bx0) / max(1.0, bx1 - bx0), (mid - s.cy) / (sp / 2) / 10,
        (x1 - x0) / sp / 10, (y1 - y0) / sp / 10, (bx1 - bx0) / sp / 50,
        (s.cx - sx0) / max(1.0, sx1 - sx0), sy1 > sy0 ? (s.cy - sy0) / max(1.0, sy1 - sy0) : 0,
        s.bar == 0 ? 1 : 0, s.bar == st.bars.count - 1 ? 1 : 0, s.synthetic ? 1 : 0,
        Double(min(s.n, 4)) / 4, Double(min(barCount[[s.staff, s.bar]]!, 64)) / 64]
      t.geo += geo.map(Float.init)
      t.staffpos.append(Int64(min(st.pos, maxStaves - 1)))
      t.nstaves.append(Int64(min(sy.staves.count, maxStaves)))
      t.sys.append(Int64(st.system))
      t.col.append(Int64(sysOff[st.system] + sy.columns[st.pos][s.bar]))
      var pv: Int64 = -99, pp: Float = 0
      var dp = [Float](repeating: 0, count: 4), vp = [Float](repeating: 0, count: nVoice)
      var gp = [Float](repeating: 0, count: 3), sp3 = [Float](repeating: 0, count: 3)
      if s.fam == "note" || s.fam == "rest" {
        if let v = s.attrs["staff_position"], v != "<na>", let iv = Int(v), abs(iv) < posSaturated {
          pv = Int64(iv); pp = Float(s.attrP["staff_position"] ?? 1.0)
        }
        dp = dist(s.attrDist["dots"], s.attrs["dots"] ?? "<na>", vocab: dotsIn, fold: dotsFold, size: 4)
        vp = dist(s.attrDist["voice_slot"], s.attrs["voice_slot"] ?? "1", vocab: voiceIn, fold: voiceFold, size: nVoice)
        gp = dist(s.attrDist["grace"], s.attrs["grace"] ?? "<na>", vocab: graceIn, fold: graceFold, size: 3)
        sp3 = dist(s.attrDist["stem_dir"], s.attrs["stem_dir"] ?? "<na>", vocab: stemIn, fold: stemFold, size: 3)
      }
      t.posV.append(pv); t.posP.append(pp)
      t.dotsP += dp; t.voiceP += vp; t.graceP += gp; t.stemP += sp3
    }
    return t
  }

  // MARK: the evidence model
  final class Evidence {
    private let env: ORTEnv
    private let session: ORTSession
    static let heads = ["real", "cls", "dots", "pos", "voice", "grace", "alter", "chord", "tie", "tup", "key", "time",
                        "clef", "onset_beat", "onset_frac"]
    static let priorHeads = ["real", "cls", "dots", "pos", "voice", "grace"]
    static let maxTok = 1024
    let families: [String]
    let classes: [String]

    init(models: URL, meta: Meta) throws {
      env = try ORTEnv(loggingLevel: .warning)
      session = try ORTSession(env: env, modelPath: models.appendingPathComponent("copista_evidence.onnx").path,
                               sessionOptions: RuntimePolicy.options())
      families = meta.families
      classes = meta.classes
    }

    private func run(_ t: Tokens, _ sel: [Int], sysLo: Int) throws -> [String: [Float]] {
      let L = sel.count
      func i64(_ a: [Int64], _ w: Int) throws -> ORTValue {
        var out: [Int64] = []
        out.reserveCapacity(L * w)
        for j in sel { out += a[(j * w)..<((j + 1) * w)] }
        return try tensor(out.withUnsafeBufferPointer { Data(buffer: $0) }, type: .int64, shape: w == 1 ? [1, L] : [1, L, w])
      }
      func f32(_ a: [Float], _ w: Int, keep1: Bool = false) throws -> ORTValue {
        var out: [Float] = []
        out.reserveCapacity(L * w)
        for j in sel { out += a[(j * w)..<((j + 1) * w)] }
        return try tensor(out.withUnsafeBufferPointer { Data(buffer: $0) }, type: .float, shape: w == 1 && !keep1 ? [1, L] : [1, L, w])
      }
      let minCol = sel.map { t.col[$0] }.min()!
      var sysA = sel.map { t.sys[$0] - Int64(sysLo) }, colA = sel.map { t.col[$0] - minCol }
      let inputs: [String: ORTValue] = [
        "fam": try i64(t.fam, 1), "cls_ids": try i64(t.clsIds, kCls), "cls_p": try f32(t.clsP, kCls),
        "p": try f32(t.p, 1), "geo": try f32(t.geo, nGeo), "staffpos": try i64(t.staffpos, 1),
        "nstaves": try i64(t.nstaves, 1),
        "sys": try tensor(sysA.withUnsafeMutableBufferPointer { Data(buffer: $0) }, type: .int64, shape: [1, L]),
        "col": try tensor(colA.withUnsafeMutableBufferPointer { Data(buffer: $0) }, type: .int64, shape: [1, L]),
        "pos_v": try i64(t.posV, 1), "pos_p": try f32(t.posP, 1), "dots_p": try f32(t.dotsP, 4),
        "voice_p": try f32(t.voiceP, nVoice), "grace_p": try f32(t.graceP, 3), "stem_p": try f32(t.stemP, 3)]
      let names = Evidence.heads + Evidence.priorHeads.map { "prior_\($0)" } + Evidence.priorHeads.map { "ev_\($0)" }
      let out = try session.run(withInputs: inputs, outputNames: Set(names), runOptions: nil)
      var res: [String: [Float]] = [:]
      for n in names { res[n] = try floats(require(n, in: out)) }
      return res
    }

    static func softmax(_ z: ArraySlice<Float>) -> [Float] {
      let m = z.max()!
      let e = z.map { exp($0 - m) }
      let s = e.reduce(0, +)
      return e.map { $0 / s }
    }

    static func argmax(_ z: ArraySlice<Float>) -> Int {
      var k = z.startIndex
      for i in z.indices where z[i] > z[k] { k = i }
      return k - z.startIndex
    }

    func read(_ L: Layout) throws -> [Int: Tok] {
      let t = pageArrays(L, families: families)
      let nSys = L.systems.count
      var tok: [Int: Tok] = [:]
      for s in 0..<nSys {
        var lo = max(0, s - 1), hi = min(nSys - 1, s + 1)
        var sel = (0..<t.count).filter { lo <= t.sys[$0] && t.sys[$0] <= hi }
        if sel.count > Evidence.maxTok {
          lo = s; hi = s
          sel = (0..<t.count).filter { t.sys[$0] == s }
        }
        let chunks = sel.count <= Evidence.maxTok ? [sel] :
          stride(from: 0, to: sel.count, by: Evidence.maxTok).map { Array(sel[$0..<min($0 + Evidence.maxTok, sel.count)]) }
        for chunk in chunks where !chunk.isEmpty {
          let out = try run(t, chunk, sysLo: lo)
          for (j, idx) in chunk.enumerated() where t.sys[idx] == s {
            tok[t.sym[idx]] = reading(out, j, L.syms[t.sym[idx]].cls)
          }
        }
      }
      return tok
    }

    private func reading(_ out: [String: [Float]], _ j: Int, _ detCls: String) -> Tok {
      func row(_ k: String) -> ArraySlice<Float> {
        let a = out[k]!, w = a.count / (out["real"]!.count)
        return a[(j * w)..<((j + 1) * w)]
      }
      func sig(_ x: Float) -> Double { 1 / (1 + exp(-Double(x))) }
      var r = Tok()
      let clsZ = row("cls")
      let fams: Set<String> = [family(detCls), family(classes[Evidence.argmax(clsZ)])]
      r.realP = pyRound(sig(row("real").first!), 4)
      r.realDet = pyRound(sig(row("prior_real").first!), 4)
      r.realEv = pyRound(Double(row("ev_real").first!), 3)
      var heads = ["cls"]
      if !fams.isDisjoint(with: ["note", "rest"]) { heads += ["dots", "pos", "voice", "tup"] }
      if fams.contains("note") { heads += ["alter", "grace"] }
      if fams.contains("measure") { heads += ["key", "time", "clef"] }
      for k in heads {
        let z = row(k)
        let p = Evidence.softmax(z)
        var h = Head(v: Evidence.argmax(z), p: pyRound(Double(p.max()!), 4))
        if Evidence.priorHeads.contains(k) {
          let zp = row("prior_\(k)"), ev = row("ev_\(k)")
          if zp.contains(where: { $0 != 0 }) {
            let dp = Evidence.argmax(zp)
            h.det = dp
            h.ev = pyRound(Double(ev[ev.startIndex + h.v] - ev[ev.startIndex + dp]), 3)
          }
        }
        r.heads[k] = h
        if k == "cls" && !fams.isDisjoint(with: ["note", "rest"]) {
          let fam = family(classes[h.v])
          var vp: [String: Double] = [:]
          for (i, c) in classes.enumerated() where family(c) == fam {
            guard let u = c.firstIndex(of: "_"), Vocab.typeQ[String(c[c.index(after: u)...])] != nil else { continue }
            vp[String(c[c.index(after: u)...]), default: 0] += Double(p[p.startIndex + i])
          }
          r.valueP = vp
        }
        if k == "dots" { r.dotsP = p.map(Double.init) }
      }
      if fams.contains("measure") { r.timeP = Evidence.softmax(row("time")).map { pyRound(Double($0), 5) } }
      if fams.contains("note") {
        r.chord = pyRound(sig(row("chord").first!), 4)
        r.tie = pyRound(sig(row("tie").first!), 4)
      }
      if !fams.isDisjoint(with: ["note", "rest"]) {
        let zb = row("onset_beat"), zf = row("onset_frac")
        let pb = Evidence.softmax(zb), pf = Evidence.softmax(zf)
        r.onset = pyRound(Double(Evidence.argmax(zb)) + Double(Evidence.argmax(zf)) / Double(zf.count), 4)
        r.onsetP = pyRound(Double(pb.max()! * pf.max()!), 4)
        r.onsetBeatP = pb.map { pyRound(Double($0), 5) }
        r.onsetFracP = pf.map { pyRound(Double($0), 5) }
        r.tupP = Evidence.softmax(row("tup")).map { pyRound(Double($0), 5) }
      }
      return r
    }
  }

  // MARK: bar lines the readings show were missed (revise.py)
  static func missedBarLines(_ rd: Reading, mask: Mask) -> [Int: [Double]] {
    let L = rd.layout
    guard L.ink else { return [:] }
    let tok = rd.tok
    var timeAt: [[Int]: String?] = [:]
    var cur: String?
    for (n, sy) in L.systems.enumerated() {
      let ncol = 1 + (sy.columns.filter { !$0.isEmpty }.map { $0.max()! }.max() ?? 0)
      for col in 0..<ncol {
        for (pos, k) in sy.staves.enumerated() {
          for (j, i) in L.staves[k].bars.enumerated() where sy.columns[pos][j] == col {
            if let r = tok[i], let v = r.time, v != "other" { cur = v }
          }
        }
        timeAt[[n, col]] = cur
      }
    }
    func barLen(_ t: String?) -> Q? {
      guard let t else { return nil }
      let p = t.split(separator: "/").compactMap { Int($0) }
      guard p.count == 2, p[1] != 0 else { return nil }
      return Q(4 * p[0], p[1])
    }
    var out: [Int: [Double]] = [:]
    for (n, sy) in L.systems.enumerated() {
      let S = sy.staves.map { L.staves[$0] }
      for (pos, k) in sy.staves.enumerated() {
        let st = L.staves[k], sp = st.sp
        for (j, _) in st.bars.enumerated() {
          guard let blen = barLen(timeAt[[n, sy.columns[pos][j]]] ?? nil) else { continue }
          var evs: [Int: [(Double, Box, Q)]] = [:], order: [Int] = []
          var heads: [Box] = []
          for s in L.syms where s.staff == k && s.bar == j {
            guard let r = tok[s.i], r.realP >= 0.5 else { continue }
            let c = rd.classes[r.cls], fam = family(c)
            guard fam == "note" || fam == "rest" else { continue }
            if fam == "note" {
              heads.append(s.box)
              if (r.chord ?? 0) > 0.5 || r.grace != "none" { continue }
            }
            let d = Vocab.duration(Vocab.typeOf(c), r.dots, r.tup)
            if evs[r.voice] == nil { order.append(r.voice) }
            evs[r.voice, default: []].append((s.cx, s.box, d))
          }
          for v in order {
            let es = Front.stableSorted(evs[v]!) { $0.0 < $1.0 }
            if es.reduce(Q.zero, { $0 + $1.2 }) < Q(7, 4) * blen { continue }
            var cum = Q.zero
            for (a, b) in zip(es, es.dropFirst()) {
              cum += a.2
              if !cum.isMultiple(of: blen) { continue }
              let lo = Int(a.1.2), hi = Int(b.1.0)
              guard lo <= hi else { continue }
              let xs = (lo...hi).filter { x in
                inkRun(mask, x: Double(x), y0: st.y0 + 1, y1: st.y1 - 1, reach: 1) >= 0.9 &&
                  !heads.contains { $0.0 - 0.4 * sp <= Double(x) && Double(x) <= $0.2 + 0.4 * sp }
              }
              if xs.isEmpty { continue }
              let x = xs.sorted()[xs.count / 2]
              let others = S.filter { $0 !== st }
              if others.isEmpty || Double(others.filter { inkRun(mask, x: Double(x), y0: $0.y0 + 1, y1: $0.y1 - 1, reach: 2) >= 0.9 }.count)
                >= Double(others.count) / 2 {
                out[sy.staves[0], default: []].append(Double(x))
              }
            }
          }
        }
      }
    }
    return out.mapValues { Array(Set($0)).sorted() }
  }
}

extension Copista {
  /// The most staves the evidence model reads together: it was trained on systems of up to `maxStaves`, and every
  /// staff past that would share one position.
  static let windowStaves = 12

  /// The layout as the evidence model should see it: a system taller than `windowStaves` (a full orchestra) cut into
  /// windows of staves, each read as a system of its own with its neighbours as context. Each cut goes at the widest
  /// gap near an even split, where one instrument family ends, so a grand staff stays whole. The symbols are the
  /// same objects, so the readings map straight back; the page's own layout is left as it is.
  static func windowed(_ L: Layout) -> Layout {
    guard L.systems.contains(where: { $0.staves.count > windowStaves }) else { return L }
    let staves = L.staves.map { s -> Staff in
      let c = Staff(bars: s.bars, sp: s.sp, y0: s.y0, y1: s.y1, x0: s.x0, x1: s.x1)
      c.lineX0 = s.lineX0
      return c
    }
    var systems: [System] = []
    for sy in L.systems {
      let n = sy.staves.count
      var cuts: [Int] = []          // window starts after the first
      if n > windowStaves {
        let parts = (n + windowStaves - 1) / windowStaves
        var last = 0
        for w in 1..<parts {
          let target = w * n / parts
          var best = target, gap = -Double.infinity
          for c in max(last + 2, target - 2)...min(n - 2, target + 2) where c - last <= windowStaves {
            let g = L.staves[sy.staves[c]].y0 - L.staves[sy.staves[c - 1]].y1
            if g > gap { gap = g; best = c }
          }
          cuts.append(best)
          last = best
        }
      }
      let bounds = [0] + cuts + [n]
      for (a, b) in zip(bounds, bounds.dropFirst()) {
        let w = System(staves: Array(sy.staves[a..<b]))
        w.columns = Array(sy.columns[a..<b])
        for (pos, k) in w.staves.enumerated() { staves[k].system = systems.count; staves[k].pos = pos }
        systems.append(w)
      }
    }
    return Layout(syms: L.syms, staves: staves, systems: systems, sp: L.sp, width: L.width, height: L.height, ink: L.ink)
  }
}
