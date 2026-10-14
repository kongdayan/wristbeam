#!/usr/bin/env python3
"""Scan committed history and current public-source files, including unstaged changes."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
subprocess.run(['gitleaks', 'git', str(root), '--redact', '--no-banner', '--exit-code', '1'], check=True)
files = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root, check=True, capture_output=True).stdout.decode().split('\0')
with tempfile.TemporaryDirectory(prefix='pulse-source-secrets-') as temporary:
    stage = Path(temporary)
    for name in filter(None, files):
        source = root / name
        if source.is_symlink():
            raise ValueError('Source symlink must be reviewed before public release')
        if not source.is_file():
            continue
        destination = stage / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    subprocess.run(['gitleaks', 'dir', str(stage), '--redact', '--no-banner', '--exit-code', '1'], check=True)
print('PASS secrets scan: full history and current public source')
