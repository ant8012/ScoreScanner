# copisteria (copista-2m)

ScoreScanner reads pages with a Swift port of KobiMusic's copisteria reader
(https://github.com/kobimusic/copisteria, commit c685f28, Apache-2.0, see LICENSE and NOTICE here) and its
copista-2m models (https://huggingface.co/kobimusic/copista-2m), exported to ONNX:

- `App/SampleAssets/Models/copista_detector_a.onnx`, `copista_detector_b.onnx`: the symbol detector in two stages
- `App/SampleAssets/Models/copista_evidence.onnx`: the evidence model
- `App/SampleAssets/Models/copista-meta.json`: class and attribute tables, the staff-link weights (links.json)

The Swift port is `Core/Sources/ScannerCore/Copista` (changed from the original: Python to Swift, OCR text
features left out). Re-export with `tools/copista_export_onnx.py` and check against PyTorch with
`tools/copista_check_onnx.py` (both run from a copisteria checkout's root).
