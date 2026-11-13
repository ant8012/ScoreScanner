"""Export copista-2m to ONNX for ScoreScanner: the detector as two stages, and the evidence model.

  detector_a.onnx  image [1,1,H,W] (H, W multiples of 32, 1 = white)   -> f [1,64,H/4,W/4], obj [1,1,..], reg [1,4,..]
  detector_b.onnx  f, reg, cy [1,n] int64, cx [1,n] int64               -> cls [1,n,C+1], ref [1,n,4], attr [1,n,70], r [1,n,4]
  evidence.onnx    one window of tokens (batch 1, no padding)          -> per head: final logits; per prior head:
                                                                          prior logits and evidence

Between the stages the caller picks the objectness peaks (3x3 maxima over half the threshold, top 4000), exactly
as PeakRelational.decode_out does, so the verifier sees the same candidates.
Run from the copisteria repository root: python export_onnx.py OUT_DIR
"""
import sys
from pathlib import Path

import torch
import torch.nn as nn

sys.path.insert(0, "src")
from copisteria import read                                   # noqa: E402
from copisteria.detector.small import models as M             # noqa: E402
from copisteria.model import PRIOR_HEADS                      # noqa: E402
from copisteria.paths import DETECTORS, EVIDENCE             # noqa: E402

out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
OPSET = 17

ck = torch.load(DETECTORS["2m"][0], map_location="cpu", weights_only=False)
det = M.build(ck["arch"], ck["classes"]).eval()
det.load_state_dict(ck["ema"])


class StageA(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, x):
        o = self.m(x)
        return o["f"], o["obj"], o["reg"]


def encoder_layer(layer, x):
    """nn.TransformerEncoderLayer (norm_first, gelu, batch_first, no padding) without nn.MultiheadAttention, whose
    traced reshapes keep the example's sequence length."""
    sa = layer.self_attn
    d, h = sa.embed_dim, sa.num_heads
    y = layer.norm1(x)
    q, k, v = torch.nn.functional.linear(y, sa.in_proj_weight, sa.in_proj_bias).chunk(3, -1)
    split = lambda t: t.reshape(1, -1, h, d // h).transpose(1, 2)             # noqa: E731
    a = torch.nn.functional.scaled_dot_product_attention(split(q), split(k), split(v))
    x = x + sa.out_proj(a.transpose(1, 2).reshape(1, -1, d))
    return x + layer.linear2(torch.nn.functional.gelu(layer.linear1(layer.norm2(x))))


class StageB(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, f, reg, cy, cx):
        tok, r = self.m._tokens(f, reg, cy, cx)
        for layer in self.m.dec.enc.layers:
            tok = encoder_layer(layer, tok)
        return self.m.cls(tok), self.m.refine(tok), self.m.attr(tok), r


x = torch.ones(1, 1, 640, 480)
torch.onnx.export(StageA(det), (x,), out / "detector_a.onnx", opset_version=OPSET, dynamo=False,
                  input_names=["image"], output_names=["f", "obj", "reg"],
                  dynamic_axes={"image": {2: "H", 3: "W"}, "f": {2: "h", 3: "w"}, "obj": {2: "h", 3: "w"},
                                "reg": {2: "h", 3: "w"}})
with torch.no_grad():
    f, obj, reg = StageA(det)(x)
cy = torch.randint(0, f.shape[2], (1, 50)); cx = torch.randint(0, f.shape[3], (1, 50))
def roi_align_exact(inp, boxes, output_size, spatial_scale=1.0, sampling_ratio=-1, aligned=False):
    """torchvision.ops.roi_align (batch 1, fixed sampling_ratio) from gathers, so it exports to plain ONNX: the same
    sample points, the same bilinear rule and the same edge handling (zero beyond one pixel out, clamped inside)."""
    ph, pw = output_size
    g = sampling_ratio
    _, C, H, W = inp.shape
    off = 0.5 if aligned else 0.0
    x1 = boxes[:, 1] * spatial_scale - off; y1 = boxes[:, 2] * spatial_scale - off
    x2 = boxes[:, 3] * spatial_scale - off; y2 = boxes[:, 4] * spatial_scale - off
    rw, rh = x2 - x1, y2 - y1
    if not aligned:
        rw, rh = rw.clamp(min=1.0), rh.clamp(min=1.0)
    t = (torch.arange(ph * g, dtype=inp.dtype) // g).to(inp.dtype) + ((torch.arange(ph * g) % g).to(inp.dtype) + 0.5) / g
    u = (torch.arange(pw * g, dtype=inp.dtype) // g).to(inp.dtype) + ((torch.arange(pw * g) % g).to(inp.dtype) + 0.5) / g
    ys = y1[:, None] + t[None] * (rh / ph)[:, None]                    # [n, ph*g]
    xs = x1[:, None] + u[None] * (rw / pw)[:, None]                    # [n, pw*g]

    def axis(v, size):
        ok = (v >= -1.0) & (v <= size)
        v = v.clamp(min=0.0)
        lo = v.floor()
        top = lo >= size - 1
        lo = torch.where(top, torch.full_like(lo, size - 1), lo)
        hi = torch.where(top, lo, lo + 1)
        v = torch.where(top, lo, v)
        frac = v - lo
        return lo.long(), hi.long(), 1 - frac, frac, ok

    yl, yh, wyl, wyh, oky = axis(ys, H)
    xl, xh, wxl, wxh, okx = axis(xs, W)
    flat = inp[0].reshape(C, H * W)
    n = boxes.shape[0]

    def pick(yi, xi):
        idx = (yi[:, :, None] * W + xi[:, None, :]).reshape(-1)        # [n*Y*X]
        return flat[:, idx].reshape(C, n, ph * g, pw * g)

    v = (pick(yl, xl) * (wyl[:, :, None] * wxl[:, None, :]) + pick(yl, xh) * (wyl[:, :, None] * wxh[:, None, :])
         + pick(yh, xl) * (wyh[:, :, None] * wxl[:, None, :]) + pick(yh, xh) * (wyh[:, :, None] * wxh[:, None, :]))
    v = v * (oky[:, :, None] & okx[:, None, :]).to(v.dtype)
    v = v.reshape(C, n, ph, g, pw, g).mean((3, 5))                     # [C, n, ph, pw]
    return v.permute(1, 0, 2, 3)


import torchvision.ops                                               # noqa: E402
from torchvision.ops import roi_align as roi_align_tv                # noqa: E402
with torch.no_grad():                                                # the copy must match torchvision before it stands in
    fb = torch.randn(1, 64, 37, 29)
    bb = torch.cat([torch.zeros(300, 1), torch.rand(300, 4) * torch.tensor([140., 160., 140., 160.]) - 12], 1)
    bb[:, 3:] = bb[:, 1:3] + (bb[:, 3:] - bb[:, 1:3]).abs() + 0.5
    want = roi_align_tv(fb, bb, (3, 3), spatial_scale=0.25, sampling_ratio=2, aligned=True)
    got = roi_align_exact(fb, bb, (3, 3), spatial_scale=0.25, sampling_ratio=2, aligned=True)
    print("roi_align copy max diff", float((want - got).abs().max()))
torchvision.ops.roi_align = roi_align_exact
torch.onnx.export(StageB(det), (f, reg, cy, cx), out / "detector_b.onnx", opset_version=OPSET, dynamo=False,
                  input_names=["f", "reg", "cy", "cx"], output_names=["cls", "ref", "attr", "r"],
                  dynamic_axes={"f": {2: "h", 3: "w"}, "reg": {2: "h", 3: "w"}, "cy": {1: "n"}, "cx": {1: "n"},
                                "cls": {1: "n"}, "ref": {1: "n"}, "attr": {1: "n"}, "r": {1: "n"}})

ev = read.load_model(EVIDENCE)
INPUTS = ("fam", "cls_ids", "cls_p", "p", "geo", "staffpos", "nstaves", "sys", "col", "pos_v", "pos_p",
          "dots_p", "voice_p", "grace_p", "stem_p")
HEADS = list(ev.heads.keys())


class Evidence(nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, *xs):
        b = dict(zip(INPUTS, xs))
        L = b["fam"].shape[1]
        b["cls_mask"] = torch.zeros_like(b["fam"])
        b["attr_mask"] = torch.zeros_like(b["fam"])
        b["pad"] = torch.zeros_like(b["fam"], dtype=torch.bool)
        o = self.m(b)
        pri = self.m.priors(b)
        return tuple([o[k] for k in HEADS] + [pri[k] for k in PRIOR_HEADS] + [o["_evidence"][k] for k in PRIOR_HEADS])


# a sample window shaped like features.page_arrays' output, for tracing
L = 37
sample = {
    "fam": torch.zeros(1, L, dtype=torch.int64), "cls_ids": torch.zeros(1, L, 3, dtype=torch.int64),
    "cls_p": torch.full((1, L, 3), 0.3), "p": torch.full((1, L), 0.9), "geo": torch.zeros(1, L, 0),
    "staffpos": torch.zeros(1, L, dtype=torch.int64), "nstaves": torch.ones(1, L, dtype=torch.int64),
    "sys": torch.zeros(1, L, dtype=torch.int64), "col": torch.zeros(1, L, dtype=torch.int64),
    "pos_v": torch.zeros(1, L, dtype=torch.int64), "pos_p": torch.full((1, L), 0.9),
    "dots_p": torch.zeros(1, L, 3), "voice_p": torch.zeros(1, L, 4), "grace_p": torch.zeros(1, L, 3),
    "stem_p": torch.zeros(1, L, 3),
}
if len(sys.argv) > 2:                    # a real window saved by check_onnx.py gives the exact dtypes and widths
    import numpy as np
    z = np.load(sys.argv[2])
    sample = {k: torch.from_numpy(z[k].astype(np.int64) if z[k].dtype.kind in "iu" else z[k]) for k in INPUTS}
with torch.no_grad():
    names = HEADS + [f"prior_{k}" for k in PRIOR_HEADS] + [f"ev_{k}" for k in PRIOR_HEADS]
    torch.onnx.export(Evidence(ev), tuple(sample[k] for k in INPUTS), out / "evidence.onnx", opset_version=OPSET,
                      dynamo=False, input_names=list(INPUTS), output_names=names,
                      dynamic_axes={**{k: {1: "L"} for k in INPUTS}, **{k: {1: "L"} for k in names}})
for p in sorted(out.glob("*.onnx")):
    print(p.name, round(p.stat().st_size / 1e6, 2), "MB")
print("heads", HEADS)
