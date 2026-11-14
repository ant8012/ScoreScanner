"""Read exported chord crops with a PaddleOCR text recogniser (PP-OCRv6 tiny / small / medium), no language model.

usage: python ocr_bench.py MODEL_NAME CROPS_DIR ROUTE_NAME [--min-score S] [--model-dir DIR]

--model-dir loads a fine-tuned model exported by train_chords.sh (MODEL_NAME then names its architecture). A
reading of "~" is the fine-tuned model's "not a chord".

MODEL_NAME is a PaddleOCR recognition model such as PP-OCRv6_small_rec. Writes CROPS_DIR/results-ROUTE_NAME.json in
the shape of the app's --crop-bench, so score_reads.py scores it the same way. A recogniser has no "not a chord"
answer: a reading counts as a chord when it parses as one (score_reads.is_chord) and the model's confidence is at
least --min-score (default 0). The raw text and confidence are kept for choosing a cutoff later.
"""

import json
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from score_reads import is_chord  # noqa: E402


def clean(text):
    t = (text or "").strip().replace(" ", "")
    t = t.replace("♭", "b").replace("♯", "#").replace("△", "Δ").replace("º", "o").replace("°", "o")
    return t


def main():
    model_name, crops, route = sys.argv[1:4]
    min_score = float(sys.argv[sys.argv.index("--min-score") + 1]) if "--min-score" in sys.argv else 0.0
    from paddleocr import TextRecognition

    model_dir = sys.argv[sys.argv.index("--model-dir") + 1] if "--model-dir" in sys.argv else None
    model = TextRecognition(model_name=model_name, **({"model_dir": model_dir} if model_dir else {}))
    items = json.load(open(f"{crops}/manifest.json"))
    paths = [f"{crops}/{item['file']}" for item in items]
    start = time.time()
    outputs = list(model.predict(input=paths, batch_size=16))
    seconds = time.time() - start
    results = []
    for item, out in zip(items, outputs):
        text, score = out["rec_text"], float(out["rec_score"])
        t = clean(text)
        chord = "N.C." if re.fullmatch(r"(?i)n\.?c\.?", t) else t
        ok = bool(chord) and (chord == "N.C." or is_chord(chord)) and score >= min_score
        results.append(dict(id=item["id"], isChord=ok, visibleText=text, chord=chord if ok else "", score=round(score, 4)))
    json.dump(dict(route=route, seconds=seconds, requests=len(items), failed=0, batchSeconds=[], results=results),
              open(f"{crops}/results-{route}.json", "w"), indent=1, ensure_ascii=False)
    print(f"done {route}: {seconds:.1f} s for {len(items)} crops ({1000 * seconds / max(1, len(items)):.1f} ms each)")


if __name__ == "__main__":
    main()
