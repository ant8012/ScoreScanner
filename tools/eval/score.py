"""Score per-page ScannerCheck --copista output against MuseScore truth, as in the Nov 2026 eval.
usage: python3 score.py CORPUS OUT   (OUT/<piece>_pNN/{score.musicxml,layout.json})"""
import json, os, sys, glob
import xml.etree.ElementTree as ET
from collections import Counter
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare

def truth_layout(path, page):
    """(systems on page, staffs per system) from MuseScore's print breaks; same as analyze.py."""
    r = ET.parse(path).getroot()
    staves = 0
    for part in r.findall("part"):
        n = 1
        for m in part.findall("measure"):
            s = m.find("attributes/staves")
            if s is not None:
                n = max(n, int(s.text))
        staves += n
    first = r.find("part")
    p, systems = 1, 0
    for i, m in enumerate(first.findall("measure")):
        pr = m.find("print")
        if pr is not None and pr.get("new-page") == "yes":
            p += 1
        if p != page:
            continue
        if i == 0 or (pr is not None and (pr.get("new-system") == "yes" or pr.get("new-page") == "yes")):
            systems += 1
    return systems, staves



corpus, out = sys.argv[1], sys.argv[2]
rows = []
for png in sorted(glob.glob(os.path.join(corpus, "pages", "*.png"))):
    key = os.path.basename(png)[:-4]
    name, page = key.rsplit("_p", 1); page = int(page)
    truth = os.path.join(corpus, "truth", name + ".musicxml")
    sys_n, per_sys = truth_layout(truth, page)
    row = dict(piece=name, page=page, truth_systems=sys_n, truth_staffs=sys_n * per_sys)
    xml, lay = os.path.join(out, key, "score.musicxml"), os.path.join(out, key, "layout.json")
    if not os.path.exists(xml):
        row["status"] = "scan-error"; rows.append(row); continue
    L = json.load(open(lay))
    st_n, sy_n = len(L["staves"]), len(L["systems"])
    row.update(found_staffs=st_n, found_systems=sy_n)
    row["status"] = ("missed-staffs" if st_n < row["truth_staffs"] else "extra-staffs" if st_n > row["truth_staffs"]
                     else "wrong-grouping" if sy_n != sys_n else "layout-ok")
    try:
        c = compare.compare(truth, xml, only_page=page)
        row["scan_staves"], row["truth_staves"] = c["scan_staves"], c["truth_staves"]
        if c["scan_staves"] == c["truth_staves"]:
            st = c["staves"]
            row["ned"] = round(sum(x["ned"] for x in st) / len(st), 3)
            row["pitch_ned"] = round(sum(x["pitch_ned"] for x in st) / len(st), 3)
            row["rhythm_ned"] = round(sum(x["rhythm_ned"] for x in st) / len(st), 3)
            row["measures_off"] = sum(abs(x["truth_measures"] - x["scan_measures"]) for x in st)
            row["notes"] = [(x["truth_notes"], x["scan_notes"]) for x in st]
            row["clef_wrong"] = sum(1 for x in st if x["truth_clefs"][0] is not None and x["scan_clefs"][:1] != x["truth_clefs"][:1])
    except Exception as e:
        row["compare_error"] = str(e)
    rows.append(row)
json.dump(rows, open(os.path.join(out, "pages.json"), "w"), indent=1, default=str)
print("pages:", len(rows), Counter(r["status"] for r in rows))
ok = [r for r in rows if "ned" in r]
print("comparable pages:", len(ok), "mean NED", round(sum(r["ned"] for r in ok) / len(ok), 3),
      "measure count off", sum(r["measures_off"] for r in ok), "clef wrong", sum(r["clef_wrong"] for r in ok))
by = Counter()
for r in ok: by[r["piece"][:28]] += r["measures_off"]
print("measures off by piece:", [(k, v) for k, v in by.most_common() if v])
