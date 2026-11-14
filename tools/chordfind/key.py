"""Decode the coloured answer-key render into one exact box per chord symbol.

gen.py paints chord i as (r, g, 0) with r = ((i+1) % 9) * 25 and g = ((i+1) // 9) * 25. An antialiased pixel is
a*colour + (1-a)*white; blue is 0 in every chord colour, so a = 1 - blue/255 and the colour comes back exactly.
"""

import numpy as np
from PIL import Image


def chord_boxes(key_png, min_alpha=0.55):
    rgb = np.asarray(Image.open(key_png).convert("RGB")).astype(np.float64)
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    a = 1 - b / 255
    ok = a > min_alpha
    with np.errstate(divide="ignore", invalid="ignore"):
        rr = np.where(ok, (r - (1 - a) * 255) / a, 0)
        gg = np.where(ok, (g - (1 - a) * 255) / a, 0)
    ri, gi = np.rint(rr / 25).astype(int), np.rint(gg / 25).astype(int)
    code = ri + 9 * gi                          # 0 = black ink (not a chord)
    coloured = ok & (code > 0) & (np.abs(rr - ri * 25) < 9) & (np.abs(gg - gi * 25) < 9)
    boxes = {}
    ys, xs = np.nonzero(coloured)
    for y, x, c in zip(ys, xs, code[ys, xs]):
        i = int(c) - 1
        x0, y0, x1, y1 = boxes.get(i, (x, y, x, y))
        boxes[i] = (min(x0, x), min(y0, y), max(x1, x), max(y1, y))
    # Drop stray antialiasing pixels: a real chord has at least a handful of pixels.
    counts = {}
    for c in code[coloured]:
        counts[int(c) - 1] = counts.get(int(c) - 1, 0) + 1
    mask = np.where(coloured, code - 1, -1)
    return {i: (x0, y0, x1 + 1, y1 + 1) for i, (x0, y0, x1, y1) in boxes.items() if counts[i] >= 8}, mask
