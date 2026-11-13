"""Fetch the 18-piece OpenScore set used since Nov 2026 (14 Lieder, 4 string quartets; CC0) and render it
with MuseScore 4: a PDF to read and a MusicXML to score against.

usage: python3 tools/eval/fetch.py WORKDIR
Writes WORKDIR/corpus/{src,pdf,truth}. Files are matched by name in the current OpenScore trees.
"""
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

PIECES = """Li_Brahms_2_Die_Mainacht Li_Brahms_6_Eine_gute__gute_Nacht Li_Butterworth_5_The_lads_in_their_hundreds
Li_Chaminade_Rosemonde Li_Coleridge-Taylor_6_Too_late_for_love Li_Cowen_Past_and_Future Li_Cowen_The_Better_Land
Li_Faisst_3_Sehnsucht Li_Gray_He_doesn_t_love_me Li_Schr_ter_25_Jugendlied Li_Schubert_2_Dithyrambe__D_801
Li_Schubert_4_Lachen_und_Weinen Li_Viardot_1_La_main Li_Viardot_Lamento__VWV_1139 St_Bridge_String_Quartet_No_1__H_70
St_Busoni_String_Quartet_No_1__Op_19__BV_208 St_Haydn_String_Quartet_in_E-flat_major__Hob_III64__Op_64_No
St_Mozart_String_Quartet_No_22_in_B-flat_major__K_589""".split()
MSCORE = "/Applications/MuseScore 4.app/Contents/MacOS/mscore"


def name_of(repo, path):
    parts = path.split("/")
    name = (repo[:2] + "_" + parts[1].split(",")[0] + "_" + parts[-2])[:60]
    return "".join(c if c.isascii() and (c.isalnum() or c in "_-") else "_" for c in name)


def main(work):
    corpus = os.path.join(work, "corpus")
    for d in ("src", "pdf", "truth"):
        os.makedirs(os.path.join(corpus, d), exist_ok=True)
    found = {}
    for repo in ("Lieder", "StringQuartets"):
        url = f"https://api.github.com/repos/OpenScore/{repo}/git/trees/main?recursive=1"
        tree = json.load(urllib.request.urlopen(url))
        for x in tree["tree"]:
            if x["path"].endswith(".mscx") and name_of(repo, x["path"]) in PIECES:
                found[name_of(repo, x["path"])] = (repo, x["path"])
    missing = [p for p in PIECES if p not in found]
    if missing:
        sys.exit(f"not found in OpenScore: {missing}")
    for name in PIECES:
        repo, path = found[name]
        src = os.path.join(corpus, "src", name + ".mscx")
        if not os.path.exists(src):
            raw = f"https://raw.githubusercontent.com/OpenScore/{repo}/main/" + urllib.parse.quote(path)
            urllib.request.urlretrieve(raw, src)
        for kind, ext in (("pdf", ".pdf"), ("truth", ".musicxml")):
            out = os.path.join(corpus, kind, name + ext)
            if not os.path.exists(out):
                subprocess.run([MSCORE, "-o", out, src], check=True, capture_output=True)
        print(name)


if __name__ == "__main__":
    main(sys.argv[1])
