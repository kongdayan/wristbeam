#!/usr/bin/env python3
"""Check public source syntax, portable doc links and pinned workflow actions."""
import ast
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
from urllib.parse import unquote, urlsplit

root = Path(__file__).resolve().parent.parent
names = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'], cwd=root, check=True, capture_output=True).stdout.decode().split('\0')
files = sorted({root / name for name in names if name and (root / name).is_file()})
public = {str(path.relative_to(root)) for path in files}
errors = []

class Links(HTMLParser):
    def __init__(self):
        super().__init__()
        self.values = []
    def handle_starttag(self, tag, attrs):
        self.values += [value for key, value in attrs if key in {'src', 'href'} and value]

for path in files:
    name = str(path.relative_to(root))
    if path.suffix == '.py':
        try:
            ast.parse(path.read_text(), filename=name)
        except SyntaxError as error:
            errors.append(f'{name}: {error}')
    if path.suffix.lower() in {'.md', '.html'}:
        text = path.read_text()
        links = re.findall(r'\]\(([^\s)]+)', text)
        parser = Links(); parser.feed(text); links += parser.values
        for value in links:
            value = value.strip('<>')
            parsed = urlsplit(value)
            if parsed.scheme or parsed.netloc or not parsed.path:
                continue
            target = (path.parent / unquote(parsed.path)).resolve()
            try:
                relative = str(target.relative_to(root))
            except ValueError:
                errors.append(f'{name}: local link escapes public repository')
                continue
            if relative not in public and not target.is_dir():
                errors.append(f'{name}: missing public target {relative}')
    if name.startswith('.github/workflows/'):
        text = path.read_text()
        if 'pull_request_target' in text:
            errors.append(f'{name}: privileged PR trigger requires separate review')
        for action in re.findall(r'uses:\s*([^\s#]+)', text):
            if not action.startswith('./') and not re.fullmatch(r'[\w.-]+/[\w./-]+@[0-9a-f]{40}', action):
                errors.append(f'{name}: action must be pinned to full commit: {action}')
    if any(part in {'dist', '.build', 'Received', 'UploadQueue', 'Telemetry', 'Diagnostics'} for part in path.relative_to(root).parts) or path.suffix.lower() in {'.fit', '.log', '.jsonl'}:
        errors.append(f'{name}: runtime/private artifact is not public source')

readmes = ['README.md', 'README.cn.md', 'README.ja.md', 'README.ko.md', 'README.ru.md']
for name in readmes:
    path = root / name
    if not path.is_file():
        errors.append(f'Missing {name}')
        continue
    text = path.read_text()
    for link in readmes + ['LICENSE', 'docs/DEVICES.md', 'docs/METRICS.md']:
        if f']({link})' not in text:
            errors.append(f'{name}: missing shared navigation {link}')
license_text = (root / 'LICENSE').read_text()
if not license_text.startswith('MIT License') or 'Permission is hereby granted, free of charge' not in license_text:
    errors.append('Missing MIT license text')
if errors:
    raise SystemExit('\n'.join(errors))
print(f'PASS repository checks: {len(files)} public files, Python syntax, doc targets, five README languages and pinned actions')
