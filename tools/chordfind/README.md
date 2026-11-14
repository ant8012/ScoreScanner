# Chord finder (prototype)

Finds each chord symbol above a staff as its own box, with its bar and beat, using copisteria's symbol boxes to
erase the music first. Python prototype; nothing here runs in the app yet.

| Script | What it does |
| --- | --- |
| `gen.py OUT N SEED` | Random lead sheets rendered by MuseScore 4, each twice: black (scanner input) and with every chord in its own colour (answer key). Standard and jazz-handwriting styles, with rehearsal marks, staff text, tempo, lyrics, voltas, slurs, high notes and dynamics. |
| `key.py` | Decodes the coloured render into one exact box per chord. |
| `find.py` | The finder: erase copisteria's music symbols (above the staff only notes it timed, and the accidentals and dots beside them), drop stems, ledger lines, slurs and beams by shape, group the rest into words, drop words before the music starts and words stacked above the chord row, then place each word on the note under it (centre or left alignment, decided per page) or, with no note under it, on the nearest strong beat. |
| `evaluate.py DATA [--draw DIR]` | Scores the finder on generated sheets: isolated, merged, split, missed, bar and beat, junk words. |
| `analyze.py DATA` | Measures the answer key: letter gaps inside and between chords, which anchor lines up with the note. |
| `export_crops.py OUT NAME=IMAGE:COPISTA ...` | Cuts the finder's word boxes from real pages for `--crop-bench`. |
| `score_reads.py` | Scores chord readings (a `--crop-bench` route, or a scan's MusicXML) against hand-made answer keys. |

Copisteria's inputs come from `ScannerCheck --copista PAGE MODELS OUT` (`layout.json`, `tok.json`, `dets.json`).
Python 3.12 with numpy, scipy and Pillow.

The app's debug build has `--crop-bench DIR [--routes pcc,device]`: it reads the exported crops in
`Documents/DIR` with Private Cloud Compute and/or the on-device model and writes `results-<route>.json`. It is
compiled only in Debug and is not part of ScannerCore.

## Results (November 2026)

Generated sheets (30, 714 chords): 701 isolated, 0 merged, 700 on the right bar and beat.

Three real charts (two hand-copied, one engraved; 130 chords), read on an iPhone:

| Method | Exact | Root | False chords | Chord time |
| --- | --- | --- | --- | --- |
| Today's pipeline (PCC on bar strips) | 119 | 125 | 2 | ~37 s |
| PCC on finder crops | 120 | 128 | 11 | 53 s |
| On-device model on finder crops | 80 | 97 | 11 | 256 s |

Reading whole bars already works; the finder's value is the beat of each chord, which today's pipeline takes from
fixed metre defaults. Its known weak spots: lyrics of the line above become candidate words, and a small `#`, `b9`
or `b5` set apart from its chord is split off.
