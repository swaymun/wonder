#!/usr/bin/env python3
"""Audit or export an explicit source inventory, without copying Git history.

No files are copied unless --output is supplied. Findings and exact file hashes
stay in --report, outside the export. This check does not certify privacy or
redistribution rights; the inventory and binary assets still require review.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import sys
from urllib.parse import unquote, urlsplit


INVENTORY = 'scripts/public-source-files.txt'
FORBIDDEN_PARTS = {'.git', '.local', '.research', '.impeccable', '.build',
                   'node_modules', 'target', 'DerivedData', 'xcuserdata',
                   '__pycache__', '.venv', '.wrangler', '.swiftpm'}
FORBIDDEN_ROOTS = {'docs', 'artifacts', 'output', 'evidence', 'dist'}
PRIVATE_CLAUDE_PATHS = ('research/CLAUDE_', 'scripts/claude-sdk-smoke/')
FORBIDDEN_SUFFIXES = {'.ipa', '.dmg', '.pkg', '.zip', '.p12', '.p8', '.pem',
                      '.key', '.mobileprovision', '.sqlite', '.sqlite3', '.db',
                      '.log', '.xcresult', '.trace', '.profraw', '.pyc'}
SYNTHETIC_USERS = {'example', 'test', 'user', 'owner', 'private', 'demo',
                   'alice', 'bob', 'Shared', 'USERNAME', 'YourName'}
SECRET_PATTERNS = {
    'private-key-block': re.compile(
        r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----\s+'
        r'[A-Za-z0-9+/=\s]{64,}-----END (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'github-token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b'),
    'provider-key': re.compile(r'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}\b'),
    'aws-access-key': re.compile(r'\bAKIA[0-9A-Z]{16}\b'),
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def safe_name(name):
    path = PurePosixPath(name)
    return (bool(path.parts) and not path.is_absolute() and name == path.as_posix()
            and not name.startswith(PRIVATE_CLAUDE_PATHS)
            and '..' not in path.parts and '\\' not in name
            and not any(part in FORBIDDEN_PARTS for part in path.parts)
            and path.parts[0] not in FORBIDDEN_ROOTS
            and path.suffix.lower() not in FORBIDDEN_SUFFIXES
            and not any(part == '.env' or part.startswith('.env.') for part in path.parts))


def read_inventory(root):
    names = [line.strip() for line in (root / INVENTORY).read_text().splitlines()
             if line.strip() and not line.lstrip().startswith('#')]
    if names != sorted(set(names)):
        raise ValueError('Public source inventory must be sorted and contain no duplicates.')
    for name in names:
        if not safe_name(name):
            raise ValueError(f'Forbidden or noncanonical inventory path: {name}')
    return names


def reviewed_binary(name):
    return (name == 'apps/ios/Wonder/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
            or name == 'apps/menubar/Resources/WonderMenuIcon.pdf'
            or name == 'research/assets/wonder-brand/wonder-sun-logo-source.png'
            or name == 'licenses/Rust-COPYRIGHT.html.gz'
            or (name.startswith('assets/screenshots/') and name.endswith('.png')))


def text_findings(name, text):
    findings = []
    for kind, pattern in SECRET_PATTERNS.items():
        for match in pattern.finditer(text):
            findings.append({'path': name, 'line': text.count('\n', 0, match.start()) + 1,
                             'kind': kind})
    for match in re.finditer(r'/(?:Users|home)/([^/\s"\'{}<>]+)', text):
        if match.group(1) not in SYNTHETIC_USERS:
            findings.append({'path': name, 'line': text.count('\n', 0, match.start()) + 1,
                             'kind': 'non-synthetic-account-path'})
    return findings


def local_targets(name, text):
    if name.endswith('.md'):
        text = re.sub(r'```.*?```', '', text, flags=re.S)
        targets = re.findall(r'\]\(([^\s)]+)(?:\s+"[^"]*")?\)', text)
        targets += re.findall(r'(?:href|src)="([^"]+)"', text)
        for target in targets:
            parsed = urlsplit(target.strip('<>'))
            if parsed.path and not parsed.scheme and not parsed.netloc:
                yield unquote(parsed.path)
    elif name.endswith('.rs'):
        yield from re.findall(r'include_(?:str|bytes)!\s*\(\s*"([^"]+)"', text)


def audit(root, names):
    records, findings, texts = [], [], {}
    selected = set(names)
    for name in names:
        path = root / name
        if any(parent.is_symlink() for parent in [path, *path.parents] if parent != root.parent):
            findings.append({'path': name, 'kind': 'symlink'})
            continue
        if not path.is_file():
            findings.append({'path': name, 'kind': 'missing-file'})
            continue
        data = path.read_bytes()
        mode = stat.S_IMODE(path.stat().st_mode)
        records.append({'path': name, 'sha256': digest(data), 'bytes': len(data),
                        'executable': bool(mode & 0o111)})
        try:
            text = data.decode('utf-8')
            if '\x00' in text:
                raise UnicodeError('binary data')
        except UnicodeError:
            if not reviewed_binary(name):
                findings.append({'path': name, 'kind': 'unreviewed-binary'})
            continue
        texts[name] = text
        findings.extend(text_findings(name, text))
    for name, text in texts.items():
        for target in local_targets(name, text):
            destination = (root / name).parent / target
            try:
                relative = destination.resolve().relative_to(root).as_posix()
            except ValueError:
                findings.append({'path': name, 'kind': 'outside-source-reference'})
                continue
            # A directory link is usable only if the exported tree contains it.
            if relative != '.' and relative not in selected and not any(p.startswith(relative.rstrip('/') + '/') for p in names):
                findings.append({'path': name, 'kind': 'excluded-local-reference', 'target': relative})
    return records, findings


def export_tree(root, destination, records):
    if destination.exists() or destination.is_symlink():
        raise ValueError('Export destination already exists; use a new empty path.')
    if root == destination or root.is_relative_to(destination):
        raise ValueError('Export destination must not contain the source checkout.')
    destination.mkdir(parents=True)
    for record in records:
        source = root / record['path']
        target = destination / record['path']
        target.parent.mkdir(parents=True, exist_ok=True)
        # Copy bytes, not extended attributes, resource forks or local metadata.
        data = source.read_bytes()
        if digest(data) != record['sha256']:
            raise ValueError(f"Source changed during export: {record['path']}")
        target.write_bytes(data)
        target.chmod(0o755 if record['executable'] else 0o644)


def verify_tree(destination, records):
    findings = []
    expected = {item['path']: item for item in records}
    actual = set()
    for path in destination.rglob('*'):
        name = path.relative_to(destination).as_posix()
        if path.is_symlink() or not safe_name(name):
            findings.append({'path': name, 'kind': 'forbidden-export-entry'})
        if path.is_file() or path.is_symlink():
            actual.add(name)
    for name in sorted(actual - expected.keys()):
        findings.append({'path': name, 'kind': 'unexpected-export-file'})
    for name, record in expected.items():
        path = destination / name
        if name not in actual:
            findings.append({'path': name, 'kind': 'missing-export-file'})
        elif path.is_symlink() or digest(path.read_bytes()) != record['sha256']:
            findings.append({'path': name, 'kind': 'export-content-mismatch'})
        elif bool(path.stat().st_mode & 0o111) != record['executable']:
            findings.append({'path': name, 'kind': 'export-mode-mismatch'})
    return findings


def git_metadata(root, names):
    def git(*args):
        result = subprocess.run(['git', '-C', str(root), *args], capture_output=True, text=True)
        return result.stdout.strip() if result.returncode == 0 else None
    git_root = git('rev-parse', '--show-toplevel')
    if git_root is None or Path(git_root).resolve() != root.resolve():
        # An export nested in a checkout has no history of its own.
        return {'sourceCommit': None, 'sourceStatus': None, 'excludedTrackedFiles': []}
    tracked = git('ls-files', '-z')
    return {'sourceCommit': git('rev-parse', 'HEAD'),
            'sourceStatus': git('status', '--short'),
            'excludedTrackedFiles': sorted(set((tracked or '').split('\0')) - set(names) - {''})}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--output', type=Path, help='Create a new source tree after a clean audit.')
    mode.add_argument('--verify', type=Path, help='Compare an existing export with selected source bytes.')
    parser.add_argument('--report', type=Path, required=True, help='Private audit directory outside the export.')
    args = parser.parse_args()
    root = args.root.resolve()
    destination = (args.output or args.verify)
    if destination is not None:
        destination = destination.absolute()
        if args.report.resolve().is_relative_to(destination.resolve()):
            parser.error('Keep the private audit report outside the public export.')
    try:
        names = read_inventory(root)
        records, findings = audit(root, names)
        if args.verify:
            if not destination.is_dir() or destination.is_symlink():
                raise ValueError('Verification requires an existing export directory.')
            findings.extend(verify_tree(destination, records))
        elif args.output and not findings:
            export_tree(root, destination, records)
            findings.extend(verify_tree(destination, records))
        report = {'schemaVersion': 1, **git_metadata(root, names),
                  'inventorySha256': digest((root / INVENTORY).read_bytes()),
                  'mode': 'verify' if args.verify else 'export' if args.output else 'audit',
                  'files': records, 'findings': findings,
                  'automatedChecksPassed': not findings,
                  'manualPrivacyAndRightsReviewRequired': True,
                  'note': 'No Git history is copied. Credential patterns are incomplete; binary privacy and rights need human review.'}
        args.report.mkdir(parents=True, exist_ok=True)
        (args.report / 'source-audit.json').write_text(json.dumps(report, indent=2) + '\n')
        print(f'Public source {report["mode"]}: {len(records)} files, {len(findings)} findings.')
        for finding in findings[:50]:
            line = f":{finding['line']}" if 'line' in finding else ''
            target = f" -> {finding['target']}" if 'target' in finding else ''
            print(f"{finding['path']}{line}: {finding['kind']}{target}", file=sys.stderr)
        print('Manual privacy/provenance review and builds from the exported tree remain required.')
        return 1 if findings else 0
    except (OSError, ValueError) as error:
        print(f'Public source export failed: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
