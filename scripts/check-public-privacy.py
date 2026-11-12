#!/usr/bin/env python3
"""Check the exact staged files (default), the tracked working tree, or a package tree."""
from pathlib import Path
import argparse
import subprocess
import sys

from privacy_checks import inspect_bytes, inspect_directory

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--working-tree', action='store_true', help='Inspect tracked working files instead of staged bytes')
parser.add_argument('--directory', type=Path, help='Inspect an already-expanded release payload')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
if args.directory:
    if not args.directory.is_dir():
        parser.error('--directory must exist')
    findings = inspect_directory(args.directory)
else:
    entries = subprocess.check_output(['git', 'ls-files', '--stage', '-z'], cwd=root).split(b'\0')
    findings = []
    count = 0
    for entry in entries:
        if not entry:
            continue
        header, raw_path = entry.split(b'\t', 1)
        mode, oid, stage = header.decode().split()
        name = raw_path.decode('utf-8')
        count += 1
        if mode not in {'100644', '100755'} or stage != '0':
            findings.append(f'{name}: unexpected file mode or unresolved merge')
            continue
        data = (root / name).read_bytes() if args.working_tree else subprocess.check_output(['git', 'cat-file', 'blob', oid], cwd=root)
        findings.extend(inspect_bytes(name, data))
    if not count:
        findings.append('No staged source files were found')
if findings:
    print('\n'.join(sorted(set(findings))), file=sys.stderr)
    sys.exit(1)
print('PASS: public-file privacy checks (manual pixel/content review is still required).')
