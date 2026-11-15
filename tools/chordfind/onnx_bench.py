"""Read exported chord crops with the ONNX chord reader (export_onnx.py), one crop at a time.

usage: data/tools/trainenv/bin/python onnx_bench.py MODEL_DIR CROPS_DIR ROUTE_NAME

MODEL_DIR holds chord_rec.onnx and chord_rec_dict.txt. The preprocessing is PaddleX's for PP-OCR recognisers: the crop
(as BGR) is resized to 48 px high keeping its shape, at least 320 px wide (zero padding on the right), scaled to
[-1, 1]; greedy CTC decoding with class 0 the blank and the last class a space. Writes CROPS_DIR/results-ROUTE.json
like ocr_bench.py, so score_reads.py scores it, and its readings can be checked against the Paddle model's
(ocr_bench.py --batch-size 1) crop by crop.
"""

import json
import math
import os
import re
import sys
import time

import cv2
import numpy as np
import onnxruntime as ort

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ocr_bench import clean  # noqa: E402
from score_reads import is_chord  # noqa: E402


def load_dict(model_dir):
    with open(os.path.join(model_dir, "chord_rec_dict.txt"), encoding="utf-8") as f:
        chars = f.read().split("\n")[:-1]
    return ["<blank>"] + chars + [" "]


def prepare(img):
    h, w = img.shape[:2]
    ratio = w / float(h)
    width = int(48 * max(320 / 48, ratio))
    resized_w = width if math.ceil(48 * ratio) > width else int(math.ceil(48 * ratio))
    x = cv2.resize(img, (resized_w, 48)).astype("float32").transpose((2, 0, 1)) / 255
    x = (x - 0.5) / 0.5
    out = np.zeros((3, 48, width), dtype=np.float32)
    out[:, :, :resized_w] = x
    return out[None]


def decode(probs, chars):
    idx, conf = probs.argmax(axis=1), probs.max(axis=1)
    text, scores, last = [], [], -1
    for t, i in enumerate(idx):
        if i != last and i != 0:
            text.append(chars[i])
            scores.append(conf[t])
        last = i
    return "".join(text), float(np.mean(scores)) if scores else 0.0


def main():
    model_dir, crops, route = sys.argv[1:4]
    chars = load_dict(model_dir)
    session = ort.InferenceSession(os.path.join(model_dir, "chord_rec.onnx"), providers=["CPUExecutionProvider"])
    name = session.get_inputs()[0].name
    items = json.load(open(f"{crops}/manifest.json"))
    start = time.time()
    results = []
    for item in items:
        img = cv2.imread(f"{crops}/{item['file']}", cv2.IMREAD_COLOR)
        probs = session.run(None, {name: prepare(img)})[0][0]
        text, score = decode(probs, chars)
        t = clean(text)
        chord = "N.C." if re.fullmatch(r"(?i)n\.?c\.?", t) else t
        ok = bool(chord) and (chord == "N.C." or is_chord(chord))
        results.append(dict(id=item["id"], isChord=ok, visibleText=text, chord=chord if ok else "", score=round(score, 4)))
    seconds = time.time() - start
    json.dump(dict(route=route, seconds=seconds, requests=len(items), failed=0, batchSeconds=[], results=results),
              open(f"{crops}/results-{route}.json", "w"), indent=1, ensure_ascii=False)
    print(f"{len(items)} crops, {1000 * seconds / max(1, len(items)):.1f} ms/crop")


if __name__ == "__main__":
    main()
