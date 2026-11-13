"""Compare a scanned MusicXML against a ground-truth MusicXML, staff by staff.

Usage: python3 compare.py TRUTH.musicxml SCAN.musicxml [--pages N] [--json]
--pages N truncates the truth at the Nth printed page break (for trimmed PDFs).
"""
import json
import sys
import xml.etree.ElementTree as ET
from fractions import Fraction

STEP = {"C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11}


def load(path):
    root = ET.parse(path).getroot()
    if root.tag == "score-timewise":
        raise SystemExit("timewise not supported")
    return root


def staves_of(root, max_pages=None, only_page=None):
    """Return list of staves; each staff = dict(name, measures=[...]).

    A measure is dict(notes=[(onset, midi|'R', type)], clef, key, time, barline).
    """
    out = []
    for part in root.findall("part"):
        nstaves = 1
        for m in part.findall("measure"):
            s = m.find("attributes/staves")
            if s is not None:
                nstaves = max(nstaves, int(s.text))
        streams = [[] for _ in range(nstaves)]
        divisions = 1
        page = 1
        for m in part.findall("measure"):
            pr = m.find("print")
            if pr is not None and pr.get("new-page") == "yes":
                page += 1
            if max_pages and page > max_pages:
                break
            if only_page and page != only_page:
                continue
            meas = [dict(notes=[], clef=None, key=None, time=None) for _ in range(nstaves)]
            pos = Fraction(0)
            last_onset = Fraction(0)
            for el in m:
                if el.tag == "attributes":
                    d = el.find("divisions")
                    if d is not None:
                        divisions = int(d.text)
                    for c in el.findall("clef"):
                        n = int(c.get("number", "1")) - 1
                        if n < nstaves:
                            meas[n]["clef"] = (c.findtext("sign"), c.findtext("line"))
                    k = el.find("key/fifths")
                    if k is not None:
                        for x in meas:
                            x["key"] = int(k.text)
                    t = el.find("time")
                    if t is not None and t.find("beats") is not None:
                        for x in meas:
                            x["time"] = f"{t.findtext('beats')}/{t.findtext('beat-type')}"
                elif el.tag == "backup":
                    pos -= Fraction(int(el.findtext("duration")), divisions)
                elif el.tag == "forward":
                    pos += Fraction(int(el.findtext("duration")), divisions)
                elif el.tag == "note":
                    if el.find("grace") is not None:
                        continue
                    if el.find("print-object") is not None:
                        pass
                    if el.get("print-object") == "no":
                        # invisible padding rests: count time, skip token
                        if el.find("chord") is None:
                            pos += Fraction(int(el.findtext("duration") or 0), divisions)
                        continue
                    dur = Fraction(int(el.findtext("duration") or 0), divisions)
                    if el.find("chord") is not None:
                        onset = last_onset
                    else:
                        onset = pos
                        pos += dur
                        last_onset = onset
                    st = int(el.findtext("staff") or 1) - 1
                    if st >= nstaves:
                        st = nstaves - 1
                    p = el.find("pitch")
                    if p is not None:
                        midi = (int(p.findtext("octave")) + 1) * 12 + STEP[p.findtext("step")] + int(float(p.findtext("alter") or 0))
                    elif el.find("unpitched") is not None:
                        midi = "U"
                    else:
                        midi = "R"
                    typ = (el.findtext("type") or "?") + "." * len(el.findall("dot"))
                    meas[st]["notes"].append((onset, midi, typ))
            for i in range(nstaves):
                meas[i]["notes"].sort(key=lambda n: (n[0], str(n[1])))
                streams[i].append(meas[i])
        name = part.get("id")
        for i, s in enumerate(streams):
            out.append(dict(name=f"{name}/{i+1}", measures=s))
    return out


def edit(a, b):
    n, m = len(a), len(b)
    prev = list(range(m + 1))
    for i in range(1, n + 1):
        cur = [i] + [0] * m
        for j in range(1, m + 1):
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] != b[j - 1]))
        prev = cur
    return prev[m]


def ned(a, b):
    return edit(a, b) / max(1, len(a) + len(b)) if (a or b) else 0.0


def tokens(staff, kind):
    out = []
    for m in staff["measures"]:
        for _, midi, typ in m["notes"]:
            if kind == "pitch":
                out.append(midi)
            elif kind == "rhythm":
                out.append(typ)
            else:
                out.append((midi, typ))
        out.append("|")
    return out


def carry(staff, field):
    """Value of field (key/time/clef) in effect at each measure."""
    cur, out = None, []
    for m in staff["measures"]:
        if m[field] is not None:
            cur = m[field]
        out.append(cur)
    return out


def changes(staff, field):
    seq = carry(staff, field)
    return [v for i, v in enumerate(seq) if i == 0 or v != seq[i - 1]]


def compare(truth_path, scan_path, max_pages=None, only_page=None):
    t = staves_of(load(truth_path), max_pages, only_page)
    s = staves_of(load(scan_path))
    rep = dict(truth_staves=len(t), scan_staves=len(s), staves=[])
    for i in range(max(len(t), len(s))):
        if i >= len(t) or i >= len(s):
            continue
        a, b = t[i], s[i]
        rep["staves"].append(dict(
            staff=i + 1,
            truth_measures=len(a["measures"]),
            scan_measures=len(b["measures"]),
            truth_notes=sum(len(m["notes"]) for m in a["measures"]),
            scan_notes=sum(len(m["notes"]) for m in b["measures"]),
            ned=round(ned(tokens(a, "both"), tokens(b, "both")), 3),
            pitch_ned=round(ned(tokens(a, "pitch"), tokens(b, "pitch")), 3),
            rhythm_ned=round(ned(tokens(a, "rhythm"), tokens(b, "rhythm")), 3),
            truth_clefs=changes(a, "clef"), scan_clefs=changes(b, "clef"),
            truth_keys=changes(a, "key"), scan_keys=changes(b, "key"),
            truth_times=changes(a, "time"), scan_times=changes(b, "time"),
        ))
    return rep


if __name__ == "__main__":
    args = sys.argv[1:]
    pages = None
    if "--pages" in args:
        k = args.index("--pages")
        pages = int(args[k + 1])
        del args[k:k + 2]
    as_json = "--json" in args
    args = [a for a in args if a != "--json"]
    r = compare(args[0], args[1], pages)
    if as_json:
        print(json.dumps(r, default=str))
    else:
        print(f"staves truth={r['truth_staves']} scan={r['scan_staves']}")
        for st in r["staves"]:
            print(st)
