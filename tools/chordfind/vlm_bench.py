"""Read exported chord crops with a local vision-language model through MLX-VLM, one crop per request.

usage: python vlm_bench.py MODEL CROPS_DIR ROUTE_NAME [--prompt phone|clear]

Writes CROPS_DIR/results-ROUTE_NAME.json in the same shape as the app's --crop-bench, so score_reads.py scores it
the same way. "phone" is the task as the phone test worded it; "clear" adds what the phone test showed small models
need: a lone capital letter is a chord, boxed rehearsal letters were already removed, and plain ASCII output.
"""

import json
import re
import sys
import time

from mlx_vlm import generate, load
from mlx_vlm.prompt_utils import apply_chat_template
from mlx_vlm.utils import load_config

PHONE = (
    "This image is one piece of text cut from the area above a music staff on a lead sheet. It may be a chord "
    "symbol, or it may be lyrics, a rehearsal mark, a tempo or style word, a section name, a measure number, a volta "
    "number, a title, a credit, or a fragment of notation. A chord symbol is a harmony name made of a root A to G "
    "with an optional accidental, quality, extensions, alterations and slash bass, such as C, Am7, C-7, F#m7b5, "
    "Bbmaj7, CΔ7, G7(b9), D/F#, or N.C. Transcribe only what is visibly printed; never infer harmony or correct the "
    "chord. If it is a chord symbol, answer with the chord using b and # for accidentals. If it is not a chord "
    "symbol, answer NONE. Answer with nothing else."
)
CLEAR = (
    "This image is one piece of text cut from just above a music staff on a lead sheet. Most of these are chord "
    "symbols. A chord symbol starts with a capital letter A to G, optionally followed by b or # and a quality, "
    "extensions, alterations in parentheses and a slash bass: for example C, F, Bb, Am7, C-7, F#m7b5, Bbmaj7, CΔ7, "
    "G7(b9), A7b9, D/F#, C6/E, or N.C. A single capital letter on its own, like C or F, is a chord. Small raised "
    "numbers are part of the chord: write them as normal digits (G⁷ is G7). A minus sign means minor. Things that are "
    "not chords: words of lyrics, tempo or style words like Swing or Slowly, titles and composer names, bar numbers, "
    "repeat or coda instructions, and stray fragments of notation. Transcribe exactly what is printed; never guess "
    "harmony. Answer with only the chord in plain ASCII (use b for flat and # for sharp), or NONE if it is not a "
    "chord symbol."
)

# The same as CLEAR with no example chords: small models repeat prompt examples on crops with no text.
PLAIN = (
    "This image is one piece of text cut from just above a music staff on a lead sheet. Most of these are chord "
    "symbols. A chord symbol starts with a capital letter A to G, optionally followed by a flat or sharp, a "
    "quality, extensions, alterations and a slash bass. A single capital letter on its own is a chord. Small raised "
    "numbers are part of the chord: write them as normal digits. A minus sign means minor. Lyrics, tempo or style "
    "words, titles, names, bar numbers, repeat instructions, and fragments of notes or lines are not chords; neither "
    "is an empty or unreadable image. Transcribe exactly what is printed; never guess. Answer with only the chord in "
    "plain ASCII (b for flat, # for sharp), or NONE."
)


def parse(answer):
    a = answer.strip().splitlines()[0].strip() if answer.strip() else ""
    a = a.strip("`\"' .").replace("♭", "b").replace("♯", "#")
    if not a or re.fullmatch(r"(?i)none|not a chord.*|no chord.*", a):
        return False, ""
    if re.fullmatch(r"(?i)n\.?c\.?", a):
        return True, "N.C."
    if not re.match(r"^[A-G]", a):
        return False, ""
    return True, a.split()[0]


def main():
    model_path, crops, route = sys.argv[1:4]
    choice = sys.argv[sys.argv.index("--prompt") + 1] if "--prompt" in sys.argv else "phone"
    prompt = {"phone": PHONE, "clear": CLEAR, "plain": PLAIN}[choice]
    model, processor = load(model_path)
    config = load_config(model_path)
    items = json.load(open(f"{crops}/manifest.json"))
    formatted = apply_chat_template(processor, config, prompt, num_images=1)
    results, start = [], time.time()
    for n, item in enumerate(items):
        t0 = time.time()
        out = generate(model, processor, formatted, [f"{crops}/{item['file']}"], max_tokens=24, temperature=0.0,
                       verbose=False)
        text = out.text if hasattr(out, "text") else str(out)
        is_chord, chord = parse(text)
        results.append(dict(id=item["id"], isChord=is_chord, visibleText=text.strip()[:60], chord=chord,
                            seconds=round(time.time() - t0, 3)))
        if n % 50 == 0:
            print(f"{n}/{len(items)} {text.strip()[:30]!r} -> {chord}", flush=True)
    seconds = time.time() - start
    json.dump(dict(route=route, seconds=seconds, requests=len(items), failed=0, batchSeconds=[], results=results),
              open(f"{crops}/results-{route}.json", "w"), indent=1)
    print(f"done {route}: {seconds:.1f} s for {len(items)} crops")


if __name__ == "__main__":
    main()
