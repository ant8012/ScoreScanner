# ScannerCore third-party notices

ScannerCore's original source is copyright 2026 Jack Gruber and licensed under the
GNU General Public License version 3. See LICENSE. Third-party code and model assets
retain their original notices and licenses.

## copisteria and copista-2m

KobiMusic's reader, ported from Python to Swift, and copista-2m models exported to ONNX.
Apache License 2.0, copyright 2026 KobiMusic.
Source: https://github.com/kobimusic/copisteria (revision c685f28).
Models: https://huggingface.co/kobimusic/copista-2m.
Preserve Vendor/copisteria/LICENSE, NOTICE and README.md.
Export and comparison tools: tools/copista_export_onnx.py and tools/copista_check_onnx.py.

## PaddleOCR PP-OCRv6 small

Apache License 2.0, copyright PaddlePaddle Authors.
Source: https://github.com/PaddlePaddle/PaddleOCR.
The chord reader is fine-tuned on synthetic chord-symbol images; the text reader uses
unmodified upstream weights exported to ONNX. The models and dictionary are supplied
in Sources/ScannerCore/Resources/Models. Rebuild/training scripts and configuration
are in tools/chordfind. Private scan benchmarks are not distributed.
Preserve Licenses/PaddleOCR-NOTICE.txt and Licenses/Apache-2.0.txt.

## ONNX Runtime 1.27.0

MIT License, copyright Microsoft Corporation.
Source: https://github.com/microsoft/onnxruntime.
The exact source revision, binary URL, SHA-256 and binding-file hashes are recorded in
Vendor/onnxruntime/UPSTREAM.json. Preserve Vendor/onnxruntime/LICENSE and the original
notices in Sources/OnnxRuntimeBindings and Sources/COnnxRuntimeAndroid.
