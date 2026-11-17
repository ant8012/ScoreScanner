#!/usr/bin/env python3
"""Export a reviewed ScannerCore package from a committed release, without private history."""
import argparse
import hashlib
import json
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def git(*args):
    return subprocess.check_output(['git', '-C', str(ROOT), *args])

def included(path):
    if '__pycache__' in path.parts:
        return False
    if path.as_posix() in {
        'Package.swift', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'PUBLIC_PACKAGE_README.md',
        'tools/chordfind/README.md', 'tools/eval/README.md',
    }:
        return True
    if path.parts[0] in {'Sources', 'Vendor', 'Licenses'}:
        return True
    if path.parts[:2] == ('Tests', 'ScannerCoreTests'):
        return True
    return path.parts[0] == 'tools' and path.suffix in {'.py', '.sh', '.swift', '.yml', '.yaml'} and path.name != 'prepare_player.py'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    revision = git('rev-parse', '--verify', args.ref + '^{commit}').decode().strip()
    paths = [Path(p.decode()) for p in git('ls-tree', '-rz', '--name-only', revision).split(b'\0') if p]
    exports = {}
    for path in paths:
        if not included(path):
            continue
        target = Path('README.md') if path.name == 'PUBLIC_PACKAGE_README.md' else path
        data = git('show', f'{revision}:{path.as_posix()}')
        if path.suffix in {'.swift', '.py', '.sh', '.md', '.yml', '.yaml'}:
            if re.search(rb"/(?:Users|private/tmp|tmp)/", data):
                raise SystemExit(f'Review machine path before publication: {path}')
        exports[target] = data
    if not all(Path(p) in exports for p in ('Package.swift', 'LICENSE', 'README.md', 'THIRD_PARTY_NOTICES.md', 'Sources/ScannerCore/ScoreGapRestsMusicXML.swift')):
        raise SystemExit('Required package source or license is missing')
    args.output.mkdir(parents=True, exist_ok=False)
    for path, data in sorted(exports.items()):
        target = args.output / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        if path.suffix in {'.py', '.sh'}:
            target.chmod(0o755)
    manifest = {
        'version': args.ref,
        'sourceRevision': revision,
        'license': 'GPL-3.0-only',
        'files': {p.as_posix(): hashlib.sha256(data).hexdigest() for p, data in sorted(exports.items())},
    }
    (args.output / 'RELEASE_SOURCE.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Exported {len(exports)} files for {args.ref}; source revision {revision}')

if __name__ == '__main__':
    main()
