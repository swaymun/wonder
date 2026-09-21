#!/usr/bin/env python3
"""Remove reproducible compiler output; preserve source, logs, results and dSYMs.

Dry run by default. Use --apply after the task's builds/tests have finished.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
XCODE_PARTS = (
    'Build/Intermediates.noindex', 'Build/Products', 'ModuleCache.noindex',
    'Index.noindex', 'SDKStatCaches.noindex', 'CompilationCache.noindex',
    'SourcePackages/artifacts', 'SourcePackages/workspace-state.json',
    'SDKExplicitPrecompiledModules',
)
SKIP = {'.git', 'node_modules', 'checkouts', 'repositories', 'RetainedSymbols'}
PACKAGES = ('apps/native', 'apps/menubar', 'apps/native-relay', 'native/computer-use')
SWIFTBUILD_PARTS = ('Products', 'Intermediates.noindex', 'ModuleCache.noindex',
                    'CompilationCache.noindex', 'SDKExplicitPrecompiledModules',
                    'SDKStatCaches.noindex', 'PCH')


def swiftbuild_directory(path):
    return (path / 'manifest.pif').is_file() and any(
        marker.is_file() and marker.read_text().strip() == 'swiftbuild'
        for marker in path.glob('.buildSystem_*'))


def contained(path, root):
    """Reject symlink traversal, including links that point back into the root."""
    path = Path(os.path.abspath(path))
    relative = path.relative_to(root)
    cursor = root
    for part in relative.parts:
        cursor /= part
        if cursor.is_symlink():
            raise ValueError(f'Refusing symlink: {cursor}')
    if path == root:
        raise ValueError('Refusing repository root')
    return path


def xcode_directory(path):
    try:
        info = plistlib.loads((path / 'info.plist').read_bytes())
        return str(info.get('WorkspacePath', '')).endswith('/Wonder.xcodeproj')
    except (OSError, ValueError, plistlib.InvalidFileException):
        return False


def discover(root):
    candidates = []
    for search in (root / '.local', root / 'target', root / 'apps/ios/DerivedData'):
        if not search.is_dir() or search.is_symlink():
            continue
        for base, dirs, _ in os.walk(search, followlinks=False):
            path = Path(base)
            dirs[:] = [name for name in dirs if name not in SKIP
                       and not name.endswith(('.app', '.xcarchive', '.xcresult', '.dSYM', '.trace', '.framework'))
                       and not (path / name).is_symlink()]
            if xcode_directory(path):
                candidates.extend(path / part for part in XCODE_PARTS)
                cache_roots = {part.split('/')[0] for part in XCODE_PARTS}
                dirs[:] = [name for name in dirs if name not in cache_roots | {'Logs', 'TestResults'}]
            elif (path / '.fingerprint').is_dir() and (path / 'deps').is_dir():
                candidates.append(path)
                dirs[:] = []
            elif (path / 'workspace-state.json').is_file() and ((path / 'build.db').is_file() or swiftbuild_directory(path)):
                for triple in dirs:
                    if '-apple-' in triple:
                        candidates.extend(path / triple / profile for profile in ('debug', 'release'))
                if swiftbuild_directory(path):
                    candidates.extend(path / 'out' / part for part in SWIFTBUILD_PARTS)
                dirs[:] = [name for name in dirs if '-apple-' not in name and name not in {'artifacts', 'out'}]
    for target in (root / 'apps/desktop/target',):
        for profile in ('debug', 'release'):
            path = target / profile
            if (path / '.fingerprint').is_dir() and (path / 'deps').is_dir():
                candidates.append(path)
    for package in PACKAGES:
        build = root / package / '.build'
        if build.is_dir() and not build.is_symlink():
            if swiftbuild_directory(build):
                candidates.extend(build / 'out' / part for part in SWIFTBUILD_PARTS)
            for triple in build.iterdir():
                if triple.is_dir() and not triple.is_symlink() and '-apple-' in triple.name:
                    candidates.extend(triple / profile for profile in ('debug', 'release'))
    return sorted({contained(p, root) for p in candidates if p.exists()})


def preserve_symbols(path):
    # Keep symbols beside the compiler cache before removing Build/Products.
    destination = path.parent / 'RetainedSymbols' / path.name
    symbols = []
    for base, dirs, _ in os.walk(path, followlinks=False):
        for name in list(dirs):
            child = Path(base) / name
            if child.is_symlink():
                dirs.remove(name)
            elif name.endswith('.dSYM'):
                symbols.append(child)
                dirs.remove(name)
    for symbol in symbols:
        digest = hashlib.sha256()
        for file in sorted(symbol.rglob('*')):
            if file.is_file():
                digest.update(str(file.relative_to(symbol)).encode())
                digest.update(file.read_bytes())
        target = destination / digest.hexdigest() / symbol.name
        if target.exists():
            continue
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(symbol), str(target))


def remove_candidates(paths, root):
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).split(b'\0')
    tracked_paths = [root / os.fsdecode(p) for p in tracked if p]
    # Validate the whole plan before the first deletion.
    for path in paths:
        contained(path, root)
        if any(p == path or path in p.parents for p in tracked_paths):
            raise ValueError(f'Refusing tracked files under {path}')
    for path in paths:
        if path.is_file():
            # Xcode's artifact receipts otherwise point to the deleted binaries
            # and package resolution incorrectly considers them downloaded.
            path.unlink()
        else:
            preserve_symbols(path)
            shutil.rmtree(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--xcode-directory', type=Path, help='Clean only this known Wonder DerivedData directory')
    args = parser.parse_args()
    if args.xcode_directory:
        directory = contained(args.xcode_directory, ROOT)
        if not xcode_directory(directory):
            parser.error('Expected a Wonder DerivedData directory with info.plist')
        paths = [contained(directory / part, ROOT) for part in XCODE_PARTS if (directory / part).exists()]
    else:
        paths = discover(ROOT)
    commands = subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()
    builders = {'cargo', 'rustc', 'xcodebuild', 'swift-build', 'swift-test', 'swift-frontend'}
    if args.apply and any(Path(command.strip()).name in builders for command in commands):
        parser.error('A build or test compiler is running; retry cleanup when it finishes')
    sizes = []
    for path in paths:
        size = int(subprocess.check_output(['du', '-sk', str(path)], text=True).split()[0]) * 1024
        sizes.append({'path': str(path.relative_to(ROOT)), 'allocatedBytes': size})
    report = {'apply': args.apply, 'candidateBytes': sum(s['allocatedBytes'] for s in sizes), 'paths': sizes}
    print(json.dumps(report, indent=2), flush=True)
    if args.apply:
        remove_candidates(paths, ROOT)
        print('Compiler output removed. Source, test results, logs and symbols retained.')


if __name__ == '__main__':
    main()
