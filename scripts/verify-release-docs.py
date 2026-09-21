#!/usr/bin/env python3
"""Check local release-document links and public screenshot references, offline."""
from pathlib import Path
import re
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[1]
DOCUMENTS = ('README.md', 'INSTALL.md', 'DEVELOPMENT.md', 'RELEASING.md', 'BETA_STATUS.md',
             'SECURITY.md', 'THIRD_PARTY_NOTICES.md', 'assets/screenshots/README.md')
errors = []
links = 0
for name in DOCUMENTS:
    path = ROOT / name
    if not path.is_file():
        errors.append(f'{name}: missing document')
        continue
    text = re.sub(r'```.*?```', '', path.read_text(), flags=re.S)
    targets = re.findall(r'\]\(([^\s)]+)(?:\s+"[^"]*")?\)', text)
    targets += re.findall(r'(?:href|src)="([^"]+)"', text)
    for target in targets:
        parsed = urlsplit(target.strip('<>'))
        if parsed.scheme or parsed.netloc:
            continue
        links += 1
        destination = (path.parent / unquote(parsed.path)).resolve() if parsed.path else path
        if not destination.is_relative_to(ROOT) or not destination.exists():
            errors.append(f'{name}: missing or outside-repository target {target}')
        elif parsed.fragment and destination.suffix == '.md':
            headings = re.findall(r'^#{1,6}\s+(.+?)\s*#*$', destination.read_text(), flags=re.M)
            anchors = {re.sub(r'[^\w\- ]', '', heading.lower()).replace(' ', '-') for heading in headings}
            if unquote(parsed.fragment) not in anchors:
                errors.append(f'{name}: missing heading {target}')
    for alt in re.findall(r'!\[([^\]]*)\]\(', text):
        if not alt.strip():
            errors.append(f'{name}: image missing alt text')
    for tag in re.findall(r'<img\b[^>]*>', text):
        if not re.search(r'\balt="[^"\s][^"]*"', tag):
            errors.append(f'{name}: HTML image missing alt text')
for name in ('LICENSE', 'THIRD_PARTY_NOTICES.md', 'compatibility-manifest.json'):
    if not (ROOT / name).is_file():
        errors.append(f'{name}: required release file missing')
for path in (ROOT / 'assets/screenshots').glob('*.png'):
    if path.stat().st_size > 2_000_000:
        errors.append(f'{path.relative_to(ROOT)}: image exceeds 2 MB')
if errors:
    print('\n'.join(errors), file=sys.stderr)
    sys.exit(1)
print(f'Release docs: {len(DOCUMENTS)} documents and {links} local links checked; image alt text and size checks passed.')
print('External download links and release/device acceptance require separate verification.')
