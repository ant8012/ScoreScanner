# Public ScannerCore source release

## Publication status

Prepared locally; not published. The private ScoreScanner repository must stay private.
The proposed public repository is https://github.com/hdi200/ScannerCore.
Do not distribute an Aria build using this package until its exact source tag is
publicly downloadable without authentication.

## Prepare

1. Commit the complete reader fix, tests, licenses and notices, then tag 0.1.19.
2. Run `python3 tools/prepare_public_package.py --ref 0.1.19 --output DESTINATION`.
   DESTINATION must not exist. The script exports an allowlist from the committed tag,
   never copies the working tree, and writes RELEASE_SOURCE.json with SHA-256 hashes.
3. Review the package files and manifest. Build/test the exported package. It includes
   Package.swift, all Sources, ScannerCore tests, models, vendor notices, licenses and
   tracked model/export/evaluation code. It excludes the standalone app, private Git
   history, local scans, training data, benchmark reports, credentials and caches.
4. Initialize a new main-branch Git repository in that directory. Commit the snapshot
   and tag 0.1.19. The public snapshot has its own commit ID; compare its manifest with
   the private tag rather than assuming those IDs are identical.

## Publish after owner approval

1. Create the public hdi200/ScannerCore repository and push only the reviewed main
   branch and 0.1.19 tag. Do not change private ScoreScanner visibility or mirror history.
2. Change Aria's package URL to the public repository and record the public tag's exact
   revision in Package.resolved. The prepared Aria commit currently pins the private
   release until publication; it must not ship with that private URL.
3. Resolve packages in a clean checkout without credentials. Verify all model assets
   and notices download and the normal Aria build uses that revision with no override.
4. Tag and publish the matching Aria source with its normal release version/build.

GPL corresponding source includes the code, interface files and build scripts for the
shipped work. Preserve build inputs and third-party notices, not just a license file.
References: https://www.gnu.org/licenses/gpl-3.0.html (sections 1 and 6) and
https://www.gnu.org/licenses/quick-guide-gplv3.html.
