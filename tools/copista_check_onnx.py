"""Check the ONNX export against PyTorch on real pages, and spell out (in NumPy) the glue the Swift port must copy:
peak picking between the detector stages, scoring, box decoding, threshold and per-class NMS.

Run from the copisteria repository root: python check_onnx.py ONNX_DIR PAGE.png [...]
"""
import json
import sys
from pathlib import Path

import numpy as np
import onnxruntime as ort
from PIL import Image

sys.path.insert(0, "src")
from copisteria.detect import Detector                       # noqa: E402
from copisteria.detector.small.data import ATTR_OFFSETS, ATTR_SIZES  # noqa: E402
from copisteria.detector.small.export import ATTR_VOCAB, ATTRS      # noqa: E402

onnx_dir = Path(sys.argv[1])
A = ort.InferenceSession(str(onnx_dir / "detector_a.onnx"))
B = ort.InferenceSession(str(onnx_dir / "detector_b.onnx"))
STRIDE, K_INFER, CONF, NMS_IOU = 4, 4000, 0.05, 0.7


def maxpool3(m):
    p = np.pad(m, 1, constant_values=-np.inf)
    return np.max([p[i:i + m.shape[0], j:j + m.shape[1]] for i in range(3) for j in range(3)], 0)


def nms(boxes, scores, cls, iou):
    """torchvision batched_nms: per class, greedy by score; result sorted by score, highest first."""
    order = np.argsort(-scores, kind="stable")
    keep = []
    area = (boxes[:, 2] - boxes[:, 0]) * (boxes[:, 3] - boxes[:, 1])
    suppressed = np.zeros(len(boxes), bool)
    for i in order:
        if suppressed[i]:
            continue
        keep.append(i)
        same = (cls == cls[i]) & ~suppressed
        xx1 = np.maximum(boxes[i, 0], boxes[:, 0]); yy1 = np.maximum(boxes[i, 1], boxes[:, 1])
        xx2 = np.minimum(boxes[i, 2], boxes[:, 2]); yy2 = np.minimum(boxes[i, 3], boxes[:, 3])
        inter = np.clip(xx2 - xx1, 0, None) * np.clip(yy2 - yy1, 0, None)
        o = inter / (area[i] + area - inter)
        suppressed |= same & (o > iou)
    return np.array(keep, int)


def detect_onnx(arr, s, classes, attr_cls):
    h2, w2 = arr.shape
    H, W = -(-h2 // 32) * 32, -(-w2 // 32) * 32
    x = np.ones((1, 1, H, W), np.float32)
    x[0, 0, :h2, :w2] = arr
    f, obj, reg = A.run(None, {"image": x})
    hm = 1 / (1 + np.exp(-obj[0, 0].astype(np.float64)))
    hm = hm.astype(np.float32)
    peaks = hm * (maxpool3(hm) == hm)
    flat = peaks.reshape(-1)
    k = min(K_INFER, flat.size)
    idx = np.argsort(-flat, kind="stable")[:k]
    s_ = flat[idx]
    keep = s_ > CONF * 0.5
    s_, idx = s_[keep], idx[keep]
    Wf = obj.shape[3]
    cy, cx = idx // Wf, idx % Wf
    cls_logit, ref, attr, r = B.run(None, {"f": f, "reg": reg, "cy": cy[None].astype(np.int64),
                                           "cx": cx[None].astype(np.int64)})
    z = cls_logit[0] - cls_logit[0].max(-1, keepdims=True)
    p = np.exp(z); p /= p.sum(-1, keepdims=True)
    n_cls = p.shape[1] - 1
    pc, cls = p[:, :n_cls].max(-1), p[:, :n_cls].argmax(-1)
    score = s_ * pc
    rr = r[0] + ref[0][:, [2, 3, 0, 1]]
    w = np.exp(rr[:, 0]) * STRIDE; h = np.exp(rr[:, 1]) * STRIDE
    bx = (cx + rr[:, 2]) * STRIDE; by = (cy + rr[:, 3]) * STRIDE
    boxes = np.stack([bx - w / 2, by - h / 2, bx + w / 2, by + h / 2], 1)
    keep = score > CONF
    boxes, score, cls, attrs = boxes[keep], score[keep], cls[keep], attr[0][keep]
    k = nms(boxes, score, cls, NMS_IOU)
    out = []
    for i in k:
        b = boxes[i] / s
        rec = {"cls": classes[cls[i]], "conf": round(float(score[i]), 3), "xyxy": [round(float(v), 1) for v in b]}
        if attr_cls[cls[i]]:
            rec["attrs"] = {}
            for a in ATTRS:
                lg = attrs[i, ATTR_OFFSETS[a]:ATTR_OFFSETS[a] + ATTR_SIZES[a]]
                rec["attrs"][a] = ATTR_VOCAB[a][int(np.argmax(lg))]
        out.append(rec)
    return out


det = Detector(device="cpu")
for page in sys.argv[2:]:
    png = Path(page)
    im = Image.open(png)
    imgsz = int(next(png.parent.glob(png.stem + ".dets_v7small_*.json")).stem.rsplit("_", 1)[1])
    arr, s = det.prepare(im, imgsz)
    ref = det.run_array(arr, s)
    got = detect_onnx(arr, s, det.classes, det.attr_cls)
    # match each torch detection to the ONNX one of the same class with the highest IoU
    def iou(a, b):
        ix = max(0, min(a[2], b[2]) - max(a[0], b[0])); iy = max(0, min(a[3], b[3]) - max(a[1], b[1]))
        u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - ix * iy
        return ix * iy / u if u > 0 else 0
    matched, attr_same, attr_n, dconf = 0, 0, 0, []
    for r_ in ref:
        cands = [g for g in got if g["cls"] == r_["cls"]]
        best = max(cands, key=lambda g: iou(g["xyxy"], r_["xyxy"]), default=None)
        if best and iou(best["xyxy"], r_["xyxy"]) > 0.95:
            matched += 1
            dconf.append(abs(best["conf"] - r_["conf"]))
            if "attrs" in r_:
                attr_n += 1
                attr_same += best.get("attrs") == r_["attrs"]
    print(f"{png.stem}: torch {len(ref)} onnx {len(got)} matched {matched} "
          f"attrs same {attr_same}/{attr_n} max conf diff {max(dconf, default=0):.4f}")

# the evidence model on the saved window
import torch                                                   # noqa: E402
from copisteria import read                                    # noqa: E402
from copisteria.model import PRIOR_HEADS                       # noqa: E402
from copisteria.paths import EVIDENCE                          # noqa: E402
z = np.load(onnx_dir.parent / "window.npz")
E = ort.InferenceSession(str(onnx_dir / "evidence.onnx"))
names = [o.name for o in E.get_outputs()]
res = dict(zip(names, E.run(None, {i.name: (z[i.name].astype(np.int64) if "int" in i.type else z[i.name]) for i in E.get_inputs()})))
m = read.load_model(EVIDENCE)
from copisteria.train import collate                           # noqa: E402
x = {k: z[k][0] for k in z.files}
x["cls_mask"] = np.zeros(len(x["fam"]), np.int8); x["attr_mask"] = np.zeros(len(x["fam"]), np.int8)
with torch.no_grad():
    b = collate([x], torch.device("cpu"))
    o = m(b); pri = m.priors(b)
worst = max(float(np.abs(res[k] - o[k].numpy()).max()) for k in m.heads)
worst_p = max(float(np.abs(res[f"prior_{k}"] - pri[k].numpy()).max()) for k in PRIOR_HEADS)
argmax_same = all((res[k].argmax(-1) == o[k].numpy().argmax(-1)).all() for k in m.heads)
print(f"evidence: max logit diff {worst:.2e}, prior diff {worst_p:.2e}, every argmax the same: {argmax_same}")
