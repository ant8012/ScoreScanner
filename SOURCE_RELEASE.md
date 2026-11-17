# ScoreScanner source releases

ScoreScanner and its ScannerCore Swift package stay together in this repository:
https://github.com/hdi200/ScoreScanner. No separate package repository is needed.

Original code is copyright 2026 Jack Gruber and licensed under GNU GPL version 3.
Keep LICENSE, THIRD_PARTY_NOTICES.md, Licenses and the original Vendor notices in
source releases. Third-party code and model assets retain their original licenses.

## Release 0.1.19

Includes ordinary printed rests for silent gaps, the complete ScannerCore source,
synthetic unit tests, bundled ONNX models, model training/export scripts and build
inputs. The full scanner unit suite passes: 157 tests in 19 suites. See
PRINTED_RESTS_VALIDATION.md for the earlier recognition and engraving comparisons.

Aria depends on this repository's 0.1.19 tag. Preserve that tag once pushed. Publish
future changes with a new patch tag rather than moving a published release.

## Before distributing Aria

- Make this existing repository publicly readable, including the exact shipped tag.
- Check an anonymous clone of the tag includes Package.swift, Sources, Tests, Vendor,
  Licenses and the five ONNX model files. No local package override may be required.
- Resolve Aria's normal remote dependency and confirm Package.resolved matches the tag.
- Keep the GPL license and scanner source link in Aria's notices and legal screen.
- Publish the matching Aria source with its own version/build tag.

Local scans, training data, private benchmark reports and standalone sample pages
remain excluded by .gitignore. They are not required to build ScannerCore with the
checked-in models. Preserve model export/training code and third-party provenance.

GPL source-release guidance: https://www.gnu.org/licenses/gpl-3.0.html (sections 1
and 6) and https://www.gnu.org/licenses/quick-guide-gplv3.html.
