"""Outline each staff in its system's colour, label system/pos, mark bar boxes. usage: sysov.py IMG DIR OUT"""
import json, sys
from PIL import Image, ImageDraw
img = Image.open(sys.argv[1]).convert("RGB")
L = json.load(open(sys.argv[2] + "/layout.json"))
W = max(img.size); s = 1.0
xs = [st["x1"] for st in L["staves"]]
if max(xs) > img.width * 1.2: s = img.width / (L["imgsz"] * img.width / W)  # layout in model pixels
d = ImageDraw.Draw(img)
cols = [(230, 25, 75), (0, 130, 200), (60, 180, 75), (245, 130, 48), (145, 30, 180)]
for k, st in enumerate(L["staves"]):
    c = cols[st["system"] % len(cols)]
    d.rectangle([st["x0"] * s, st["y0"] * s, st["x1"] * s, st["y1"] * s], outline=c, width=2)
    d.text((st["x1"] * s - 60, st["y0"] * s - 12), f"sys{st['system']} pos{st['pos']}", fill=c)
for sy in L["syms"]:
    if sy["cls"].startswith("grpSym"):
        x0, y0, x1, y1 = [v * s for v in sy["box"]]
        d.rectangle([x0, y0, x1, y1], outline=(0, 0, 0), width=3)
img.save(sys.argv[3])
print("scale", s, "img", img.size, "max staff x1", max(xs))
