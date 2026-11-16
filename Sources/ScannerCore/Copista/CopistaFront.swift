import Foundation
#if canImport(Android)
import Android
#endif

// copisteria's front end (front.py, links.py): detector boxes -> symbols -> staves, bars and systems. Geometry only.

extension Copista {
  typealias Box = (Double, Double, Double, Double)

  static func family(_ cls: String) -> String {
    if let i = cls.firstIndex(of: "_") { return String(cls[..<i]) }
    return cls
  }

  static func iou(_ a: Box, _ b: Box) -> Double {
    let iw = min(a.2, b.2) - max(a.0, b.0), ih = min(a.3, b.3) - max(a.1, b.1)
    if iw <= 0 || ih <= 0 { return 0 }
    let inter = iw * ih
    return inter / ((a.2 - a.0) * (a.3 - a.1) + (b.2 - b.0) * (b.3 - b.1) - inter)
  }

  final class Sym {
    var i: Int
    var cls: String
    var post: [(Int, Double)]          // class id -> probability, in the order the boxes read them
    var p: Double
    var n: Int
    var box: Box
    var attrs: [String: String]
    var attrP: [String: Double]
    var attrDist: [String: [String: Double]]
    var staff = -1, bar = -1
    var synthetic = false
    var det = -1
    var cand = false

    init(i: Int, cls: String, post: [(Int, Double)], p: Double, n: Int, box: Box, attrs: [String: String] = [:],
         attrP: [String: Double] = [:], attrDist: [String: [String: Double]] = [:], synthetic: Bool = false, det: Int = -1) {
      self.i = i; self.cls = cls; self.post = post; self.p = p; self.n = n; self.box = box
      self.attrs = attrs; self.attrP = attrP; self.attrDist = attrDist; self.synthetic = synthetic; self.det = det
    }
    var fam: String { family(cls) }
    var cx: Double { (box.0 + box.2) / 2 }
    var cy: Double { (box.1 + box.3) / 2 }
  }

  final class Staff {
    var bars: [Int]
    var sp: Double
    var y0: Double, y1: Double, x0: Double, x1: Double
    var system = -1, pos = -1
    var lineX0: Double?
    init(bars: [Int], sp: Double, y0: Double, y1: Double, x0: Double, x1: Double) {
      self.bars = bars; self.sp = sp; self.y0 = y0; self.y1 = y1; self.x0 = x0; self.x1 = x1
    }
    var mid: Double { (y0 + y1) / 2 }
  }

  final class System {
    var staves: [Int]
    var columns: [[Int]] = []
    init(staves: [Int]) { self.staves = staves }
  }

  final class Layout {
    var syms: [Sym]
    var staves: [Staff]
    var systems: [System]
    var sp: Double
    let width: Double, height: Double
    var ink: Bool
    init(syms: [Sym], staves: [Staff], systems: [System], sp: Double, width: Double, height: Double, ink: Bool) {
      self.syms = syms; self.staves = staves; self.systems = systems; self.sp = sp
      self.width = width; self.height = height; self.ink = ink
    }
  }

  /// The page as the front end sees it: its grey levels (frame painted out) and its ink.
  struct PageInk {
    let gray: Gray
    let mask: Mask
    /// Where the sheet starts: left of it `unframe` painted the page the paper's tone (0 when it kept everything).
    var sheetLeft = 0
  }

  enum Front {
    static let mergeIoU = 0.5, measureMinP = 0.25, measureMinW = 2.0, measureLowP = 0.08, grpMinP = 0.3
    static let alignTolSp = 2.0, alignFrac = 0.7, assignMaxSp = 10.0, emptyBarMaxSp = 4.0
    static let inkLink = 0.85, inkSplit = 0.4, staffPaperTol = 0.04, pale = 0.12

    static func median<T: Comparable>(index values: [T]) -> T { values.sorted()[values.count / 2] }

    // MARK: merge
    static func merge(_ dets: [Det], classId: [String: Int], classes: [String], offset: Int = 0) -> [Sym] {
      let order = dets.indices.sorted { dets[$0].conf != dets[$1].conf ? dets[$0].conf > dets[$1].conf : $0 < $1 }
      var groups: [[Int]] = [], heads: [(String, Box)] = []
      for k in order {
        let d = dets[k]
        guard classId[d.cls] != nil else { continue }
        let fam = family(d.cls), box: Box = (d.xyxy[0], d.xyxy[1], d.xyxy[2], d.xyxy[3])
        if let g = heads.firstIndex(where: { $0.0 == fam && iou($0.1, box) >= mergeIoU }) {
          groups[g].append(k)
        } else {
          groups.append([k]); heads.append((fam, box))
        }
      }
      var syms: [Sym] = []
      for g in groups {
        let head = dets[g[0]]
        var mass: [(Int, Double)] = []
        var miss = 1.0
        for k in g {
          let c = dets[k].conf, id = classId[dets[k].cls]!
          if let at = mass.firstIndex(where: { $0.0 == id }) { mass[at].1 += c } else { mass.append((id, c)) }
          miss *= 1.0 - min(c, 0.999)
        }
        let tot = mass.reduce(0) { $0 + $1.1 }
        let post = mass.map { ($0.0, $0.1 / tot) }
        var best = post[0]
        for e in post.dropFirst() where e.1 > best.1 { best = e }
        syms.append(Sym(i: syms.count, cls: classes[best.0], post: post, p: 1.0 - miss, n: g.count,
                        box: (head.xyxy[0], head.xyxy[1], head.xyxy[2], head.xyxy[3]), attrs: head.attrs ?? [:],
                        attrP: head.attrP, attrDist: head.attrDist, det: g[0] + offset))
      }
      return syms
    }

    // MARK: staves from measure boxes (the box path)
    static func rows(_ bars: [Sym]) -> [Staff] {
      guard !bars.isEmpty else { return [] }
      var parent = Array(bars.indices)
      func find(_ a: Int) -> Int {
        var a = a
        while parent[a] != a { parent[a] = parent[parent[a]]; a = parent[a] }
        return a
      }
      for a in bars.indices {
        let A = bars[a].box
        for b in (a + 1)..<bars.count {
          let B = bars[b].box
          let ov = min(A.3, B.3) - max(A.1, B.1)
          if ov < 0.5 * min(A.3 - A.1, B.3 - B.1) { continue }
          let xov = min(A.2, B.2) - max(A.0, B.0)
          if xov < 0.5 * min(A.2 - A.0, B.2 - B.0) { parent[find(a)] = find(b) }
        }
      }
      var rowsOrder: [Int] = [], rows: [Int: [Sym]] = [:]
      for (a, s) in bars.enumerated() {
        let r = find(a)
        if rows[r] == nil { rowsOrder.append(r) }
        rows[r, default: []].append(s)
      }
      var staves: [Staff] = []
      for r in rowsOrder {
        let members = rows[r]!.enumerated().sorted { $0.element.cx != $1.element.cx ? $0.element.cx < $1.element.cx : $0.offset < $1.offset }.map(\.element)
        var kept: [Sym] = []
        for s in members {
          if let q = kept.last {
            let ov = min(q.box.2, s.box.2) - max(q.box.0, s.box.0)
            if ov > 0.5 * min(q.box.2 - q.box.0, s.box.2 - s.box.0) {
              if s.p > q.p { kept[kept.count - 1] = s }
              continue
            }
          }
          kept.append(s)
        }
        let y0 = median(index: kept.map(\.box.1)), y1 = median(index: kept.map(\.box.3))
        staves.append(Staff(bars: kept.map(\.i), sp: max(1.0, (y1 - y0) / 4), y0: y0, y1: y1, x0: kept[0].box.0,
                            x1: kept[kept.count - 1].box.2))
      }
      return stableSorted(staves) { $0.mid < $1.mid }
    }

    static func stableSorted<T>(_ a: [T], by less: (T, T) -> Bool) -> [T] {
      a.enumerated().sorted { less($0.element, $1.element) || (!less($1.element, $0.element) && $0.offset < $1.offset) }.map(\.element)
    }

    static func boxStaves(_ syms: [Sym]) -> [Staff] {
      func wide(_ s: Sym) -> Bool { s.box.2 - s.box.0 >= measureMinW * (s.box.3 - s.box.1) / 4 }
      var staves = rows(syms.filter { $0.fam == "measure" && $0.p >= measureMinP && wide($0) })
      let weak = syms.filter { s in
        s.fam == "measure" && measureLowP <= s.p && s.p < measureMinP && wide(s) &&
          !staves.contains { abs(s.cy - $0.mid) < 5 * $0.sp }
      }
      for st in rows(weak) {
        let held = syms.filter { s in
          ["note", "rest", "clef"].contains(s.fam) && s.p >= 0.3 && st.x0 <= s.cx && s.cx <= st.x1 &&
            st.y0 - 0.5 * st.sp <= s.cy && s.cy <= st.y1 + 0.5 * st.sp
        }.count
        if held >= 3 { staves.append(st) }
      }
      return stableSorted(staves) { $0.mid < $1.mid }
    }

    static func fillGaps(_ syms: inout [Sym], _ staves: [Staff], classId: [String: Int]) {
      assign(syms, staves)
      for (k, st) in staves.enumerated() {
        let boxes = st.bars.map { syms[$0].box }
        let loose = syms.filter { s in
          s.staff == k && (s.fam == "note" || s.fam == "rest") && s.p >= 0.25 &&
            !boxes.contains { $0.0 - 0.5 * st.sp <= s.cx && s.cx <= $0.2 + 0.5 * st.sp }
        }
        if loose.isEmpty { continue }
        var spans: [(Double, Double)] = []
        var edges: [(Double, Double)] = [(-.infinity, boxes[0].0)]
        for (a, b) in zip(boxes, boxes.dropFirst()) { edges.append((a.2, b.0)) }
        edges.append((boxes[boxes.count - 1].2, .infinity))
        for (e0, e1) in edges {
          var x0 = e0, x1 = e1
          let inside = loose.filter { x0 <= $0.cx && $0.cx <= x1 }
          if inside.isEmpty { continue }
          if x0 == -.infinity { x0 = inside.map(\.box.0).min()! - 1.5 * st.sp }
          if x1 == .infinity { x1 = inside.map(\.box.2).max()! + 1.5 * st.sp }
          let cuts = syms.filter { $0.staff == k && $0.fam == "barLine" && $0.p >= 0.5 && x0 + st.sp < $0.cx && $0.cx < x1 - st.sp }
            .map(\.cx).sorted()
          if x1 - x0 < 1.5 * st.sp { continue }
          let xs = [x0] + cuts + [x1]
          for (a, b) in zip(xs, xs.dropFirst()) where inside.contains(where: { a <= $0.cx && $0.cx <= b }) {
            spans.append((a, b))
          }
        }
        var new: [Int] = []
        for (x0, x1) in spans {
          let (_, y0, y1, _) = band(syms, st, (x0 + x1) / 2)
          let s = Sym(i: syms.count, cls: "measure", post: [(classId["measure"]!, 1.0)], p: 0, n: 0,
                      box: (x0, y0, x1, y1), synthetic: true)
          syms.append(s); new.append(s.i)
        }
        if !new.isEmpty {
          st.bars = stableSorted(st.bars + new) { syms[$0].cx < syms[$1].cx }
          st.x0 = min(st.x0, syms[st.bars[0]].box.0)
          st.x1 = max(st.x1, syms[st.bars[st.bars.count - 1]].box.2)
        }
      }
      for s in syms { s.staff = -1; s.bar = -1 }
    }

    static func snapBars(_ syms: [Sym], _ staves: [Staff]) {
      let lines = syms.filter { $0.fam == "barLine" && $0.p >= 0.4 }
      for st in staves {
        for (a, b) in zip(st.bars, st.bars.dropFirst()) {
          let A = syms[a], B = syms[b]
          let lo = min(A.box.2, B.box.0) - 4 * st.sp, hi = max(A.box.2, B.box.0) + 4 * st.sp
          let mid = (A.box.2 + B.box.0) / 2
          let near = lines.filter { lo <= $0.cx && $0.cx <= hi && st.y0 - st.sp <= $0.cy && $0.cy <= st.y1 + st.sp }
          var x: Double
          if !near.isEmpty {
            var best = near[0]
            for s in near.dropFirst() where abs(s.cx - mid) < abs(best.cx - mid) { best = s }
            x = best.cx
          } else if A.box.2 > B.box.0 { x = mid } else { continue }
          if A.box.0 < x && x < B.box.2 {
            A.box = (A.box.0, A.box.1, x, A.box.3)
            B.box = (x, B.box.1, B.box.2, B.box.3)
          }
        }
        var keep: [Int] = []
        for (k, i) in st.bars.enumerated() {
          let s = syms[i]
          if s.synthetic && s.box.2 - s.box.0 < 1.5 * st.sp && k + 1 < st.bars.count {
            let n = syms[st.bars[k + 1]]
            n.box = (s.box.0, n.box.1, n.box.2, n.box.3)
            continue
          }
          keep.append(i)
        }
        st.bars = keep
      }
    }

    static func aligned(_ syms: [Sym], _ a: Staff, _ b: Staff) -> Bool {
      let sp = (a.sp + b.sp) / 2
      let lo = max(a.x0, b.x0) - sp, hi = min(a.x1, b.x1) + sp
      func edges(_ st: Staff) -> [Double] {
        st.bars.dropLast().compactMap { k in
          let s = syms[k]
          return !s.synthetic && lo <= s.box.2 && s.box.2 <= hi ? s.box.2 : nil
        }
      }
      let ea = edges(a), eb = edges(b)
      if ea.isEmpty || eb.isEmpty { return false }
      let tol = alignTolSp * sp
      var diffs: [Double] = []
      for x in ea {
        var m = eb[0]
        for y in eb.dropFirst() where abs(x - y) < abs(x - m) { m = y }
        if abs(m - x) <= tol { diffs.append(m - x) }
      }
      let hit2 = eb.filter { y in ea.contains { abs($0 - y) <= tol } }.count
      if Double(diffs.count) < alignFrac * Double(ea.count) || Double(hit2) < alignFrac * Double(eb.count) { return false }
      if diffs.count == 1 { return abs(diffs[0]) <= 0.5 * sp }
      let med = median(index: diffs)
      return diffs.map { abs($0 - med) }.max()! <= 0.6 * sp
    }

    static func braced(_ syms: [Sym], _ a: Staff, _ b: Staff) -> Bool {
      for s in syms where s.fam == "grpSym" && s.p >= grpMinP {
        let (x0, y0, x1, y1) = s.box
        if y0 <= a.mid + a.sp && y1 >= b.mid - b.sp && x1 >= min(a.x0, b.x0) - 6 * a.sp && x0 <= min(a.x0, b.x0) + 3 * a.sp {
          return true
        }
      }
      return false
    }

    // MARK: links (links.py): a logistic model over a pair of staves
    static func pairFeatures(_ syms: [Sym], _ a: Staff, _ b: Staff, gapsMedian: Double, nStaves: Int, braced: Bool) -> [Double] {
      let sp = (a.sp + b.sp) / 2
      let lo = max(a.x0, b.x0) - sp, hi = min(a.x1, b.x1) + sp
      func edges(_ st: Staff) -> [Double] {
        st.bars.dropLast().compactMap { k in
          let s = syms[k]
          return !s.synthetic && lo <= s.box.2 && s.box.2 <= hi ? s.box.2 : nil
        }
      }
      let ea = edges(a), eb = edges(b)
      let tol = 2.0 * sp
      var hitAB = 0.0, hitBA = 0.0, spread = 3.0, offset = 3.0
      if !ea.isEmpty && !eb.isEmpty {
        var good: [Double] = []
        for x in ea {
          var m = eb[0]
          for y in eb.dropFirst() where abs(x - y) < abs(x - m) { m = y }
          if abs(m - x) <= tol { good.append(m - x) }
        }
        hitAB = Double(good.count) / Double(ea.count)
        hitBA = Double(eb.filter { y in ea.contains { abs($0 - y) <= tol } }.count) / Double(eb.count)
        if !good.isEmpty {
          let med = median(index: good)
          offset = min(3.0, abs(med) / sp)
          spread = good.count > 1 ? min(3.0, good.map { abs($0 - med) }.max()! / sp) : 1.5
        }
      }
      let gap = (b.y0 - a.y1) / sp
      return [braced ? 1 : 0, log1p(Double(ea.count)), log1p(Double(eb.count)), hitAB, hitBA, spread, offset,
              min(gap, 30) / 10, min(gap / max(gapsMedian, 1e-3), 5), min(abs(a.x0 - b.x0) / sp, 10) / 5,
              min(abs(a.x1 - b.x1) / sp, 10) / 5, a.bars.count == b.bars.count ? 1 : 0,
              (a.bars.count <= 2 || b.bars.count <= 2) ? 1 : 0, log(Double(nStaves)), aligned(syms, a, b) ? 1 : 0,
              spread <= 0.6 ? 1 : 0, min(hitAB, hitBA), 1.0]
    }

    static func decodeLinks(_ ps: [Double]) -> [Bool] {
      let free = ps.map { $0 >= 0.5 }
      let n = ps.count + 1
      func lp(_ links: [Bool]) -> Double {
        zip(ps, links).reduce(0) { $0 + log(max(1e-9, $1.1 ? $1.0 : 1 - $1.0)) }
      }
      var best = free, bestIsFree = true
      let bl = lp(free)
      for K in 1...n where n % K == 0 {
        let links = (0..<(n - 1)).map { ($0 + 1) % K != 0 }
        let v = lp(links)
        if v >= bl - 3.0 && (bestIsFree || v > lp(best)) {
          if v >= lp(free) - 3.0 { best = links; bestIsFree = false }
        }
      }
      return best
    }

    // MARK: ink between staves
    static func leftSpan(_ a: Staff, _ b: Staff, pageLeft: Double, lines: Bool = false) -> (Int, Int) {
      let sp = (a.sp + b.sp) / 2
      func start(_ st: Staff) -> Double { lines && st.lineX0 != nil ? max(st.x0, st.lineX0!) : st.x0 }
      return (Int(min(pageLeft, a.x0, b.x0) - 3 * sp), Int(min(start(a), start(b)) + sp))
    }

    /// Per row from `y0` to `y1`, the end of the run starting at the sheet's left edge (or 0 when there is none) of
    /// pixels that pass `on`: the page edge or the shadow beside it. The run may start past a bright sliver at the
    /// edge, but within `away` columns of it; no system starts that close to the edge of a page.
    static func edgeRuns(rows y0: Int, _ y1: Int, sheetLeft: Int, width W: Int, away: Int,
                         _ on: (Int, Int) -> Bool) -> [Int] {
      let edge = max(0, min(W, sheetLeft))
      return (y0..<max(y0, y1)).map { y -> Int in
        var x = edge
        while x < min(W, edge + away) && !on(y, x) { x += 1 }
        if x >= min(W, edge + away) { return 0 }
        while x < W && on(y, x) { x += 1 }
        return x
      }
    }

    static func inkLinks(_ mask: Mask, _ syms: [Sym], _ a: Staff, _ b: Staff, pageLeft: Double,
                         sheetLeft: Int = 0) -> (Double, Double) {
      let sp = (a.sp + b.sp) / 2
      let y0 = a.y1 + 1, y1 = b.y0 - 1
      let (lo, hi) = leftSpan(a, b, pageLeft: pageLeft)
      // ink joined to the sheet's left edge (a page edge or binding shadow in a photo) links nothing: rows count
      // only ink a staff space beyond it
      let ra = max(0, pyRound(y0)), rb = min(mask.height, pyRound(y1))
      let away = max(3, pyRound(sp))
      let edge = edgeRuns(rows: ra, rb, sheetLeft: sheetLeft, width: mask.width, away: away) { mask[$0, $1] }
      func run(_ x: Int) -> Double {
        if !edge.contains(where: { $0 > 0 }) { return inkRun(mask, x: Double(x), y0: y0, y1: y1) }
        if rb - ra < 2 { return 1 }
        var hit = 0
        for y in ra..<rb {
          let from = max(0, x - 2, edge[y - ra] > 0 ? edge[y - ra] + away : 0), to = min(mask.width, x + 3)
          if from < to, (from..<to).contains(where: { mask[y, $0] }) { hit += 1 }
        }
        return Double(hit) / Double(rb - ra)
      }
      var left = 0.0
      for x in stride(from: max(0, lo), through: hi, by: 2) { left = max(left, run(x)) }
      let lines = syms.filter { s in
        s.fam == "barLine" && s.p >= 0.5 && s.staff < 0 && a.y0 - sp <= s.cy && s.cy <= a.y1 + sp &&
          max(a.x0, b.x0) <= s.cx && s.cx <= min(a.x1, b.x1)
      }
      let bars = lines.isEmpty ? 0.0 :
        Double(lines.filter { inkRun(mask, x: $0.cx, y0: y0, y1: y1) >= inkLink }.count) / Double(lines.count)
      return (left, bars)
    }

    /// Pale pixels joined to the image's left border are left out: they are the edge of the page or the shadow
    /// beside it (a phone photo of a book keeps a grey strip down its side, drifting as the page curls), while a
    /// faint opening line has paper between it and the border.
    static func paleLine(_ levels: Gray, paper: Double, dark: Double, _ a: Staff, _ b: Staff, pageLeft: Double,
                         sheetLeft: Int = 0) -> Double {
      let H = levels.height, W = levels.width
      let ya = max(0, pyRound(a.y1 + 1)), yb = min(H, pyRound(b.y0 - 1))
      if yb - ya < 2 { return 0 }
      let (lo, hi) = leftSpan(a, b, pageLeft: pageLeft, lines: true)
      let cut = paper - pale * max(1.0, paper - dark)
      // per row, where the pale run at the sheet's left edge ends (the image's border, or where unframe painted out
      // the frame)
      let away = max(3, pyRound((a.sp + b.sp) / 2))
      let border = edgeRuns(rows: ya, yb, sheetLeft: sheetLeft, width: W, away: away) { Double(levels[$0, $1]) < cut }
      func run(_ c0: Int, _ c1: Int) -> Double {      // share of rows with a pale pixel in columns c0..<c1
        var hit = 0
        for y in ya..<yb {
          // a pixel within a staff space of the edge's pale run belongs to it (its fading side, a broken strip)
          let lo = max(border[y - ya] > 0 ? border[y - ya] + away : 0, c0, 0), hi = min(W, c1)
          if lo >= hi { continue }
          for x in lo..<hi where Double(levels[y, x]) < cut { hit += 1; break }
        }
        return Double(hit) / Double(yb - ya)
      }
      var best = 0.0
      let from = max(away + 1, lo), to = min(W - away - 1, hi)
      if from <= to {
        for x in from...to {
          let r = run(x - 1, x + 2)
          if r > best && [x - away, x + away].allSatisfy({ run($0 - 1, $0 + 1) < 0.5 }) { best = r }
        }
      }
      return best
    }

    static func openingLine(_ mask: Mask, _ a: Staff, _ b: Staff, pageLeft: Double) -> Double {
      let (_, hi) = leftSpan(a, b, pageLeft: pageLeft)
      let (_, hi2) = leftSpan(a, b, pageLeft: pageLeft, lines: true)
      var v = 0.0
      for x in stride(from: hi + 1, through: hi2, by: 2) { v = max(v, inkRun(mask, x: Double(x), y0: a.y1 + 1, y1: b.y0 - 1)) }
      return v
    }

    static func systems(_ syms: inout [Sym], _ staves: [Staff], page: PageInk?, ink: Bool, links w: [Double],
                        forced: [Int: [Double]], classId: [String: Int]) -> [System] {
      var decided: [Bool] = []
      if staves.count > 1 {
        let gaps = (0..<(staves.count - 1)).map { (staves[$0 + 1].y0 - staves[$0].y1) / staves[$0].sp }
        let gm = median(index: gaps)
        let ps = (1..<staves.count).map { k -> Double in
          let f = pairFeatures(syms, staves[k - 1], staves[k], gapsMedian: gm, nStaves: staves.count,
                               braced: braced(syms, staves[k - 1], staves[k]))
          return 1 / (1 + exp(-zip(w, f).reduce(0) { $0 + $1.0 * $1.1 }))
        }
        decided = decodeLinks(ps)
      }
      if let page, staves.count > 1 {
        let pageLeft = staves.map(\.x0).min()!
        var tone: (Double, Double)?
        for k in 1..<staves.count {
          let a = staves[k - 1], b = staves[k]
          let (left, bars) = inkLinks(page.mask, syms, a, b, pageLeft: pageLeft, sheetLeft: page.sheetLeft)
          var line = 0.0
          if left < inkLink && bars < 0.5 {
            line = openingLine(page.mask, a, b, pageLeft: pageLeft)
            if line < inkLink {
              if tone == nil {
                let (h, n) = histogram(page.gray)
                tone = (percentile(h, count: n, 50), percentile(h, count: n, 1))
              }
              line = max(line, paleLine(page.gray, paper: tone!.0, dark: tone!.1, a, b, pageLeft: pageLeft,
                                        sheetLeft: page.sheetLeft))
            }
          }
          if left >= inkLink || line >= inkLink || bars >= 0.5 {
            decided[k - 1] = true
          } else if left < inkSplit && bars < 0.1 {
            decided[k - 1] = false
          } else if braced(syms, a, b) {
            decided[k - 1] = true
          }
        }
      }
      var systems: [System] = []
      for (k, _) in staves.enumerated() {
        if k > 0 && decided[k - 1] { systems[systems.count - 1].staves.append(k) } else { systems.append(System(staves: [k])) }
      }
      for (n, sy) in systems.enumerated() {
        for (pos, k) in sy.staves.enumerated() { staves[k].system = n; staves[k].pos = pos }
        func key(_ k: Int) -> (Int, Int) {
          (staves[k].bars.filter { !syms[$0].synthetic }.count, -staves[k].bars.filter { syms[$0].synthetic }.count)
        }
        var ref = sy.staves[0]
        for k in sy.staves.dropFirst() where key(k) > key(ref) { ref = k }
        if ink, let page {
          segment(&syms, staves, sy, page.mask, forced: forced, classId: classId)
        } else if let page, sy.staves.count > 1 {
          jointBars(&syms, staves, sy, page.mask, classId: classId)
        } else {
          reconcile(&syms, staves, sy, ref: ref, classId: classId)
        }
        let rb = staves[ref].bars.map { syms[$0].box }
        sy.columns = sy.staves.map { k in
          staves[k].bars.map { i in
            let b = syms[i].box
            var best = 0, bv = -Double.infinity
            for (j, r) in rb.enumerated() {
              let ov = min(b.2, r.2) - max(b.0, r.0)
              if ov > bv { bv = ov; best = j }
            }
            return best
          }
        }
      }
      return systems
    }

    static func jointBars(_ syms: inout [Sym], _ staves: [Staff], _ sy: System, _ mask: Mask, classId: [String: Int]) {
      let S = sy.staves.map { staves[$0] }
      let sp = S.reduce(0) { $0 + $1.sp } / Double(S.count)
      let left = S.map { syms[$0.bars[0]].box.0 }.min()!, right = S.map { syms[$0.bars[$0.bars.count - 1]].box.2 }.max()!
      var cand: [(Double, Int)] = []
      for (j, st) in S.enumerated() {
        for i in st.bars.dropLast() where !syms[i].synthetic { cand.append((syms[i].box.2, j)) }
        for b in syms where b.fam == "barLine" && b.p >= 0.4 && st.y0 - sp <= b.cy && b.cy <= st.y1 + sp { cand.append((b.cx, j)) }
      }
      cand = cand.filter { left + 3 * sp < $0.0 && $0.0 < right - 1.5 * sp }.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
      var clusters: [[(Double, Int)]] = []
      for c in cand {
        if let last = clusters.last?.last, c.0 - last.0 <= sp { clusters[clusters.count - 1].append(c) } else { clusters.append([c]) }
      }
      var cuts: [Double] = []
      for cl in clusters {
        let x = median(index: cl.map(\.0))
        let seen = Set(cl.map(\.1))
        var ev = 0
        for (j, st) in S.enumerated() where seen.contains(j) || inkRun(mask, x: x, y0: st.y0 + 1, y1: st.y1 - 1, reach: 1) >= 0.9 { ev += 1 }
        if Double(ev) >= max(2, 0.75 * Double(S.count)) { cuts.append(x) }
      }
      let xs = [left] + cuts + [right]
      for st in S {
        let old = st.bars.map { syms[$0] }
        var new: [Int] = []
        for (a, b) in zip(xs, xs.dropFirst()) {
          if let o = old.first(where: { !$0.synthetic && abs($0.box.0 - a) < 1.5 * sp && abs($0.box.2 - b) < 1.5 * sp }) {
            o.box = (a, o.box.1, b, o.box.3)
            new.append(o.i)
          } else {
            var bandSyms = old.filter { $0.box.0 < b && $0.box.2 > a }
            if bandSyms.isEmpty { bandSyms = old }
            let yy0 = median(index: bandSyms.map(\.box.1)), yy1 = median(index: bandSyms.map(\.box.3))
            let t = Sym(i: syms.count, cls: "measure", post: [(classId["measure"]!, 1.0)], p: 0, n: 0, box: (a, yy0, b, yy1), synthetic: true)
            syms.append(t); new.append(t.i)
          }
        }
        st.bars = new
        st.x0 = left; st.x1 = right
      }
    }

    static func reconcile(_ syms: inout [Sym], _ staves: [Staff], _ sy: System, ref: Int, classId: [String: Int]) {
      let rb = staves[ref].bars.map { syms[$0].box }
      for k in sy.staves {
        let st = staves[k]
        if k == ref || !st.bars.contains(where: { syms[$0].synthetic }) { continue }
        var new: [Int] = []
        for i in st.bars {
          let s = syms[i]
          if !s.synthetic { new.append(i); continue }
          let (x0, y0, x1, y1) = s.box
          let cuts = [x0] + rb.map(\.2).filter { x0 + st.sp < $0 && $0 < x1 - st.sp } + [x1]
          var first = true
          for (a, b) in zip(cuts, cuts.dropFirst()) {
            if first { s.box = (a, y0, b, y1); new.append(i); first = false } else {
              let t = Sym(i: syms.count, cls: "measure", post: [(classId["measure"]!, 1.0)], p: 0, n: 0, box: (a, y0, b, y1), synthetic: true)
              syms.append(t); new.append(t.i)
            }
          }
        }
        st.bars = stableSorted(new) { syms[$0].cx < syms[$1].cx }
      }
      for k in sy.staves where k != ref {
        let st = staves[k]
        var keep: [Int] = []
        for i in st.bars {
          let s = syms[i]
          if let lastI = keep.last, s.synthetic || syms[lastI].synthetic {
            let prev = syms[lastI]
            let midPrev = (prev.box.0 + prev.box.2) / 2, mid = (s.box.0 + s.box.2) / 2
            if rb.contains(where: { $0.0 <= midPrev && midPrev <= $0.2 && $0.0 <= mid && mid <= $0.2 }) {
              let a = (!prev.synthetic || s.synthetic) ? prev : s
              a.box = (min(prev.box.0, s.box.0), a.box.1, max(prev.box.2, s.box.2), a.box.3)
              keep[keep.count - 1] = a.i
              continue
            }
          }
          keep.append(i)
        }
        st.bars = keep
      }
    }

    // MARK: a page edge in the left margin
    static let edgeRuleReachSp = 4.0, edgeRuleAspect = 6.0

    /// A dark stroke in the margin left of every staff: its rows (y -> leftmost and rightmost x).
    struct EdgeRule {
      var rows: [Int: (Int, Int)]
      /// Whether a detection box lies on the stroke for at least half its height.
      func covers(_ b: [Double]) -> Bool {
        let y0 = Int(b[1]), y1 = Int(b[3])
        guard y1 > y0 else { return false }
        let on = (y0...y1).filter { y in rows[y].map { Double($0.0 - 2) <= b[2] && b[0] <= Double($0.1 + 2) } ?? false }.count
        return Double(on) >= 0.5 * Double(y1 - y0 + 1)
      }
    }

    /// Long strokes left of every staff that run on well above the first staff or below the last: the edge
    /// of a book page or a binding shadow on a photocopy, often slanted. A bracket or a system's opening line
    /// stays with the staves it joins, so a stroke that reaches into the empty margin is neither. Left in,
    /// one of these reads as a bracket and as an opening line, and joins every system it passes into one.
    /// `sheet`: the rows `unframe` kept (top..<bottom); a stroke cut off at either end ran on past it.
    static func edgeRules(_ mask: Mask, _ staves: [Staff], sheet: Range<Int>? = nil) -> [EdgeRule] {
      guard staves.count >= 2 else { return [] }
      let sp = median(index: staves.map(\.sp))
      let left = min(mask.width, Int(staves.map(\.x0).min()!))
      let top = staves.map(\.y0).min()!, bottom = staves.map(\.y1).max()!
      guard left > 0 else { return [] }
      let H = mask.height
      var seen = [Bool](repeating: false, count: H * left)
      var rules: [EdgeRule] = []
      for y in 0..<H {
        for x in 0..<left where mask[y, x] && !seen[y * left + x] {
          // one 8-connected stroke inside the margin
          var stack = [(y, x)], rows: [Int: (Int, Int)] = [:]
          seen[y * left + x] = true
          while let (cy, cx) = stack.popLast() {
            let r = rows[cy] ?? (cx, cx)
            rows[cy] = (min(r.0, cx), max(r.1, cx))
            for dy in -1...1 {
              for dx in -1...1 {
                let ny = cy + dy, nx = cx + dx
                if ny < 0 || ny >= H || nx < 0 || nx >= left || seen[ny * left + nx] || !mask[ny, nx] { continue }
                seen[ny * left + nx] = true
                stack.append((ny, nx))
              }
            }
          }
          let ys = rows.keys, a = Double(ys.min()!), b = Double(ys.max()!)
          let wide = Double(rows.values.map { $0.1 }.max()! - rows.values.map { $0.0 }.min()! + 1)
          let spans = staves.filter { a <= $0.y0 && $0.y1 <= b }.count
          let kept = sheet ?? 0..<H
          let offSheet = a <= Double(kept.lowerBound + 1) || b >= Double(kept.upperBound - 2)
          if spans >= 2 && (b - a) >= edgeRuleAspect * min(wide, Double(left)) / 2 &&
            (a < top - edgeRuleReachSp * sp || b > bottom + edgeRuleReachSp * sp || offSheet) {
            rules.append(EdgeRule(rows: rows))
          }
        }
      }
      return rules
    }

    // MARK: the ink path
    static func inkStaves(_ gray: Gray, _ syms: [Sym]) -> [Staff]? {
      var staves = inkStavesFrom(gray, syms)
      let other = inkStavesFrom(cleanPage(gray), syms)
      if let other, staves == nil || stavesScore(other, syms) > 1.02 * stavesScore(staves!, syms) { staves = other }
      staves = staves.map { joinSplit($0, syms) }
      if let staves {
        let found = findStaves(gray, paperTol: staffPaperTol).staves
        for st in staves {
          if let f = found.first(where: { abs(($0.top + $0.bottom) / 2 - st.mid) < st.sp }) { st.lineX0 = Double(f.x0) }
        }
      }
      return staves
    }

    static let splitGapSp = 1.0

    /// One staff traced as two: on a curled page a staff bends away from its straight start, and the bent
    /// part is found as a staff of its own just below (or above) it, closer than any two real staves sit.
    /// Left apart, that system has a staff too many and the whole page gets an extra part.
    static func joinSplit(_ staves: [Staff], _ syms: [Sym]) -> [Staff] {
      var out: [Staff] = []
      for st in staves {          // in page order
        if let a = out.last, st.y0 - a.y1 < splitGapSp * min(a.sp, st.sp) {
          a.bars = stableSorted(a.bars + st.bars) { syms[$0].cx < syms[$1].cx }
          a.sp = (a.sp + st.sp) / 2
          a.y0 = min(a.y0, st.y0); a.y1 = max(a.y1, st.y1)
          a.x0 = min(a.x0, st.x0); a.x1 = max(a.x1, st.x1)
        } else {
          out.append(st)
        }
      }
      return out
    }

    static func stavesScore(_ staves: [Staff], _ syms: [Sym]) -> Double {
      let held = syms.filter { ($0.fam == "measure" || $0.fam == "note" || $0.fam == "rest") && $0.p >= 0.5 }
      return Double(held.filter { b in
        staves.contains { st in st.y0 - 0.5 * st.sp <= b.cy && b.cy <= st.y1 + 0.5 * st.sp && st.x0 - st.sp <= b.cx && b.cx <= st.x1 + st.sp }
      }.count)
    }

    static func inkStavesFrom(_ page: Gray, _ syms: [Sym]) -> [Staff]? {
      let m = findStaves(page)
      if m.staves.isEmpty || m.spacing <= 0 { return nil }
      let hs = syms.filter { $0.fam == "measure" && $0.p >= 0.5 }.map { $0.box.3 - $0.box.1 }.sorted()
      let boxSp: Double? = hs.isEmpty ? nil : hs[hs.count / 2] / 4
      let found = m.staves.filter { boxSp == nil || (0.6 * boxSp! <= $0.spacing && $0.spacing <= 1.6 * boxSp!) }
      if found.isEmpty { return nil }
      if !hs.isEmpty && Double(found.count) < 0.8 * Double(rows(syms.filter { $0.fam == "measure" && $0.p >= measureMinP }).count) {
        return nil
      }
      var staves = found.map { Staff(bars: [], sp: max(1.0, $0.spacing), y0: $0.top, y1: $0.bottom, x0: Double($0.x0), x1: Double($0.x1)) }
      var claimed = Set<Int>()
      for s in syms where s.fam == "measure" && s.p >= measureLowP {
        let h = s.box.3 - s.box.1
        var k = 0, bv = -Double.infinity
        for (j, st) in staves.enumerated() {
          let ov = min(s.box.3, st.y1) - max(s.box.1, st.y0)
          if ov > bv { bv = ov; k = j }
        }
        if bv >= 0.5 * min(h, staves[k].y1 - staves[k].y0) { staves[k].bars.append(s.i); claimed.insert(s.i) }
      }
      let rest = syms.filter { $0.fam == "measure" && $0.p >= 0.5 && !claimed.contains($0.i) &&
        $0.box.2 - $0.box.0 >= measureMinW * ($0.box.3 - $0.box.1) / 4 }
      for st in rows(rest) where !staves.contains(where: { abs(st.mid - $0.mid) < 6 * $0.sp }) { staves.append(st) }
      let notes = syms.filter { ($0.fam == "note" || $0.fam == "rest") && $0.p >= 0.5 }
      staves = staves.filter { st in
        !st.bars.isEmpty || notes.filter { st.y0 - st.sp <= $0.cy && $0.cy <= st.y1 + st.sp && st.x0 <= $0.cx && $0.cx <= st.x1 }.count >= 2
      }
      if staves.isEmpty { return nil }
      for st in staves { st.bars = stableSorted(st.bars) { syms[$0].cx < syms[$1].cx } }
      return stableSorted(staves) { $0.mid < $1.mid }
    }

    static func segment(_ syms: inout [Sym], _ staves: [Staff], _ sy: System, _ mask: Mask, forced: [Int: [Double]],
                        classId: [String: Int]) {
      let S = sy.staves.map { staves[$0] }
      let n = S.count
      let sp = S.reduce(0) { $0 + $1.sp } / Double(n)
      let left = S.map(\.x0).min()!, right = S.map(\.x1).max()!
      // (x, staff index, kind, p); kind sorts edge < ink < line as in Python
      var cand: [(Double, Int, String, Double)] = []
      for (j, st) in S.enumerated() {
        for i in st.bars {
          let b = syms[i]
          if b.p >= 0.6 && !b.synthetic { cand += [(b.box.0, j, "edge", b.p), (b.box.2, j, "edge", b.p)] }
        }
        for b in syms where b.fam == "barLine" && b.p >= 0.3 && st.y0 - sp <= b.cy && b.cy <= st.y1 + sp {
          cand.append((b.cx, j, "line", b.p))
        }
      }
      if n >= 2 {
        let xa = Int(left + 2 * sp), xb = Int(right - 1.5 * sp)
        if xb > xa {
          func colMeans(_ r0: Int, _ r1: Int) -> [Double] {
            (xa..<xb).map { x in
              var c = 0
              for y in r0..<r1 where mask.bits[y * mask.width + x] { c += 1 }
              return r1 > r0 ? Double(c) / Double(r1 - r0) : .nan
            }
          }
          var rowsMeans = S.map { colMeans(Int($0.y0) + 1, Int($0.y1)) }
          if n == 2 { rowsMeans.append(colMeans(Int(S[0].y1) + 1, Int(S[1].y0))) }
          let cover = (0..<(xb - xa)).map { x in rowsMeans.map { $0[x] }.min()! }
          var run: Int?
          for (x, c) in cover.enumerated() {
            let v = c >= 0.97
            if v && run == nil { run = x }
            if (!v || x == cover.count - 1), let r = run {
              cand.append((Double(xa) + Double(r + x - 1) / 2, -1, "ink", 1.0))
              run = nil
            }
          }
        }
      }
      cand = cand.filter { left + 2 * sp < $0.0 && $0.0 < right - 1.5 * sp }.sorted {
        if $0.0 != $1.0 { return $0.0 < $1.0 }
        if $0.1 != $1.1 { return $0.1 < $1.1 }
        if $0.2 != $1.2 { return $0.2 < $1.2 }
        return $0.3 < $1.3
      }
      var clusters: [[(Double, Int, String, Double)]] = []
      for c in cand {
        if let last = clusters.last?.last, c.0 - last.0 <= sp { clusters[clusters.count - 1].append(c) } else { clusters.append([c]) }
      }
      var cuts: [Double] = []
      for cl in clusters {
        let lines = cl.filter { $0.2 == "line" }
        let use = lines.isEmpty ? cl : lines
        let x = median(index: use.map(\.0))
        let span = use.map(\.0)
        let xr = Array(stride(from: Int(span.min()! - 0.5 * sp), through: Int(span.max()! + 0.5 * sp), by: 2))
        let ink = S.map { st in xr.map { inkRun(mask, x: Double($0), y0: st.y0 + 1, y1: st.y1 - 1, reach: 2) }.max()! >= 0.9 }
        let withLine = Set(lines.map(\.1))
        let firm = lines.map(\.3).max() ?? 0
        let ok: Bool
        if n >= 2 {
          let inkCount = Double(ink.filter { $0 }.count)
          ok = (Double(withLine.count) >= max(1, Double(n) / 2) && inkCount >= 0.75 * Double(n)) ||
            Double(withLine.count) >= 0.75 * Double(n) || cl.contains { $0.2 == "ink" }
        } else {
          let edges = cl.filter { $0.2 == "edge" }
          ok = (ink[0] && (firm >= 0.5 || edges.count >= 2)) || firm >= 0.85
        }
        if ok { cuts.append(x) }
      }
      cuts = (cuts + (forced[sy.staves[0]] ?? [])).sorted()
      var xs = [left] + cuts + [right]
      while xs.count > 2 {
        let w = zip(xs, xs.dropFirst()).map { $1 - $0 }
        var k = 0
        for j in 1..<w.count where w[j] < w[k] { k = j }
        if w[k] >= measureMinW * sp { break }
        xs.remove(at: k == 0 ? k + 1 : k)
      }
      let musicFams: Set<String> = ["note", "rest", "mRest", "multiRest", "mRpt", "multiRpt"]
      let music = syms.filter { musicFams.contains($0.fam) && $0.p >= 0.4 && S[0].y0 - 4 * sp <= $0.cy && $0.cy <= S[n - 1].y1 + 4 * sp }
      func empty(_ a: Double, _ b: Double) -> Bool { !music.contains { a <= $0.cx && $0.cx <= b } }
      while xs.count > 2 && empty(xs[xs.count - 2], xs[xs.count - 1]) { xs.remove(at: xs.count - 2) }
      while xs.count > 2 && empty(xs[0], xs[1]) { xs.remove(at: 1) }
      var k = 1
      while k < xs.count - 2 {
        let a = xs[k], b = xs[k + 1]
        if b - a < emptyBarMaxSp * sp && empty(a, b) { xs.replaceSubrange(k..<(k + 2), with: [(a + b) / 2]) } else { k += 1 }
      }
      for st in S {
        let old = st.bars.map { syms[$0] }
        var new: [Int] = []
        for (a, b) in zip(xs, xs.dropFirst()) {
          let match = old.filter { !$0.synthetic && abs($0.box.0 - a) < 1.5 * sp && abs($0.box.2 - b) < 1.5 * sp }
          if var o = match.first {
            for m in match.dropFirst() where m.p > o.p { o = m }
            o.box = (a, o.box.1, b, o.box.3)
            new.append(o.i)
          } else {
            let t = Sym(i: syms.count, cls: "measure", post: [(classId["measure"]!, 1.0)], p: 0, n: 0, box: (a, st.y0, b, st.y1), synthetic: true)
            syms.append(t); new.append(t.i)
          }
        }
        st.bars = new
        st.x0 = left; st.x1 = right
      }
    }

    // MARK: assignment
    static func band(_ syms: [Sym], _ st: Staff, _ x: Double) -> (Int, Double, Double, Double) {
      var best = 0, bd = Double.infinity
      for (j, i) in st.bars.enumerated() {
        let b = syms[i].box
        let d = (b.0 <= x && x <= b.2) ? 0 : min(abs(x - b.0), abs(x - b.2))
        if d < bd { best = j; bd = d }
      }
      let s = syms[st.bars[best]]
      if s.synthetic { return (best, st.y0, st.y1, st.sp) }
      return (best, s.box.1, s.box.3, max(1.0, (s.box.3 - s.box.1) / 4))
    }

    static func assign(_ syms: [Sym], _ staves: [Staff], only: [Sym]? = nil) {
      let left = staves.map(\.x0).min() ?? 0, right = staves.map(\.x1).max() ?? 0
      for (k, st) in staves.enumerated() { for (j, i) in st.bars.enumerated() { syms[i].staff = k; syms[i].bar = j } }
      for s in only ?? syms {
        if s.staff >= 0 || s.fam == "measure" { continue }
        let x = s.cls == "barLine_repeat_start" ? s.box.2 : s.cx
        var best = -1, bc = Double.infinity, bbar = -1
        var pos: Int?
        if (s.fam == "note" || s.fam == "rest"), let v = s.attrs["staff_position"], v != "<na>" {
          pos = Int(v)
          if let p = pos, abs(p) >= 20 || (s.attrP["staff_position"] ?? 1.0) < 0.5 { pos = nil }
        }
        for (k, st) in staves.enumerated() {
          if !(left - 4 * st.sp <= x && x <= right + 4 * st.sp) { continue }
          let (j, y0, y1, sp) = band(syms, st, x)
          var d = max(0.0, y0 - s.cy, s.cy - y1) / sp
          if let pos, s.fam == "note" {
            let implied = ((y0 + y1) / 2 - s.cy) / (sp / 2)
            d = d > 0 ? min(d + 1.0, abs(implied - Double(pos)) / 2) : abs(implied - Double(pos)) / 2
          }
          if d < bc { best = k; bc = d; bbar = j }
        }
        if best >= 0 && bc <= assignMaxSp { s.staff = best; s.bar = bbar }
      }
    }

    /// front.build: ``cuts`` are bar lines to add per system (its top staff), from a first reading (revise).
    static func build(_ dets: [Det], width: Double, height: Double, page: Gray?, meta: Meta, classId: [String: Int],
                      cuts: [Int: [Double]] = [:]) -> Layout {
      var gray: Gray?, sheetLeft = 0, sheetRows: Range<Int>?
      if let page {
        let u = unframed(page.pixels.map(Float.init), width: page.width, height: page.height, integral: true)
        gray = Gray(width: page.width, height: page.height, pixels: u.pixels.map { UInt8($0) })
        let (x0, y0, x1, y1) = u.frame
        if x0 < x1 && y0 < y1 { sheetLeft = x0; sheetRows = y0..<y1 }
      }
      var syms = merge(dets, classId: classId, classes: meta.classes)
      var staves = gray.map { inkStaves($0, syms) } ?? nil
      var mask = gray.map { g in inkMask(g.pixels.map(Float.init), width: g.width, height: g.height, integral: true) }
      if var g = gray, var m = mask, let st = staves {
        let rules = edgeRules(m, st, sheet: sheetRows)
        if !rules.isEmpty {
          // Painted out and not taken as brackets, then the staves are found again on the cleaned page.
          for r in rules {
            for (y, (x0, x1)) in r.rows {
              for x in max(0, x0 - 2)...min(g.width - 1, x1 + 2) { g.pixels[y * g.width + x] = 255; m.bits[y * g.width + x] = false }
            }
          }
          gray = g
          mask = m
          let kept = dets.filter { d in
            family(d.cls) != "grpSym" || !rules.contains { $0.covers(d.xyxy) }
          }
          syms = merge(kept, classId: classId, classes: meta.classes)
          staves = inkStaves(g, syms)
        }
      }
      let pageInk = gray.map { g in PageInk(gray: g, mask: mask!, sheetLeft: sheetLeft) }
      let inkPath = !(staves ?? []).isEmpty
      let systems: [System]
      if let st = staves, !st.isEmpty {
        systems = Front.systems(&syms, st, page: pageInk, ink: true, links: meta.links, forced: cuts, classId: classId)
      } else {
        let st = joinSplit(boxStaves(syms), syms)
        staves = st
        fillGaps(&syms, st, classId: classId)
        snapBars(syms, st)
        systems = Front.systems(&syms, st, page: pageInk, ink: false, links: meta.links, forced: cuts, classId: classId)
      }
      assign(syms, staves!)
      let sps = staves!.map(\.sp).sorted()
      return Layout(syms: syms, staves: staves!, systems: systems, sp: sps.isEmpty ? 10 : sps[sps.count / 2],
                    width: width, height: height, ink: inkPath)
    }
  }
}
