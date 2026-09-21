#!/usr/bin/env python3
"""Verify, stop, and replace an entire Wonder bundle, retaining a rollback copy."""
import datetime
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

COMPONENTS = [
    '',
    'Contents/MacOS/WonderHost',
    'Contents/MacOS/WonderMacBridge',
    'Contents/Resources/WonderComputerUse.app',
    'Contents/Resources/WonderComputerUse.app/Contents/MacOS/WonderComputerUse',
    'Contents/Resources/wonderd',
    'Contents/Resources/wonder-tunnel',
]
LEGACY_COMPUTER_USE = 'Contents/Resources/WonderComputerUse'
NESTED_COMPUTER_USE = 'Contents/Resources/WonderComputerUse.app'


def output(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def verify(app):
    output('codesign', '--verify', '--deep', '--strict', str(app))
    teams = set()
    for relative in COMPONENTS:
        path = app / relative
        output('codesign', '--verify', '--strict', str(path))
        info = output('codesign', '-dvv', str(path))
        team = re.search(r'^TeamIdentifier=(.+)$', info, re.M)
        if not team or team[1] == 'not set' or 'Signature=adhoc' in info:
            raise RuntimeError(f'{path} must be certificate-signed')
        teams.add(team[1])
    cloudflared = app / 'Contents/Resources/cloudflared'
    if cloudflared.exists():
        output('codesign', '--verify', '--strict', str(cloudflared))
        info = output('codesign', '-dvv', str(cloudflared))
        team = re.search(r'^TeamIdentifier=(.+)$', info, re.M)
        if not team or team[1] == 'not set' or 'Signature=adhoc' in info:
            raise RuntimeError('cloudflared must be certificate-signed')
        teams.add(team[1])
    if len(teams) != 1:
        raise RuntimeError('The app and helpers must use the same signing team')


def verify_update(previous, candidate):
    # An explicit first migration from unsigned/ad-hoc is allowed. Once signed,
    # refuse updates that change the identity privacy grants are attached to.
    for relative in COMPONENTS:
        old = previous / relative
        # The helper moved from a flat executable to a signed LSUIElement app.
        # Compare both nested helper code objects against the old executable's
        # designated requirement so the existing TCC identity can migrate.
        if relative == NESTED_COMPUTER_USE or relative.startswith(NESTED_COMPUTER_USE + '/'):
            # Only fall back when this component is absent from the previous
            # bundle. A later nested-to-nested update must compare like-for-like.
            if not old.exists():
                legacy = previous / LEGACY_COMPUTER_USE
                if legacy.exists():
                    old = legacy
        # Preserve the existing helper's signing identity during the GPUI migration.
        if relative == 'Contents/MacOS/WonderMacBridge' and not old.exists():
            old = previous / 'Contents/MacOS/WonderMenuUI'
        if relative == 'Contents/MacOS/WonderHost' and not old.exists():
            old = previous / 'Contents/MacOS/WonderDesktop'
        info = output('codesign', '-dvv', str(old))
        if 'Signature=adhoc' in info or 'TeamIdentifier=not set' in info:
            continue
        requirement = output('codesign', '-d', '-r-', str(old)).split('designated => ', 1)[1].strip()
        output('codesign', '--verify', '--strict', '-R', '=' + requirement, str(candidate / relative))


def stop(app):
    commands = {str(app / 'Contents/MacOS/WonderMenu'),
                'bash ' + str(app / 'Contents/MacOS/WonderMenu'),
                '/bin/bash ' + str(app / 'Contents/MacOS/WonderMenu'),
                '/bin/bash ' + str(app / 'Contents/Resources/WonderService.sh')}
    processes = output('ps', '-axo', 'pid=,command=').splitlines()
    pids = [int(parts[0]) for line in processes if len(parts := line.strip().split(None, 1)) == 2
            and parts[1] in commands]
    for pid in pids:
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 30
    for pid in pids:
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(.1)
        else:
            raise RuntimeError('Wonder has not stopped. Installed app left unchanged.')


def install(source, directory):
    source = source.resolve()
    directory = directory.resolve()
    destination = directory / 'Wonder.app'
    if source == destination or destination.is_symlink():
        raise RuntimeError('Build outside the installed app; symlink destinations are not supported')
    verify(source)
    directory.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.Wonder-install-', dir=directory))
    try:
        candidate = stage / 'Wonder.app'
        subprocess.run(['ditto', str(source), str(candidate)], check=True)
        verify(candidate)
        if destination.exists():
            verify_update(destination, candidate)
        stop(destination)
        backup = None
        if destination.exists():
            legacy = Path.home() / 'Library/Application Support/Wonder'
            data = Path.home() / '.wonder'
            root = (legacy if legacy.exists() and not data.exists() else data) / 'Backups'
            root.mkdir(parents=True, exist_ok=True)
            backup = Path(tempfile.mkdtemp(prefix=datetime.datetime.now().strftime('signed-update-%Y%m%d-%H%M%S-'), dir=root)) / 'Wonder.app'
            shutil.move(str(destination), str(backup))
        try:
            candidate.rename(destination)
            verify(destination)
        except Exception:
            if destination.exists():
                shutil.move(str(destination), str(stage / 'failed.app'))
            if backup:
                shutil.move(str(backup), str(destination))
            raise
        print(f'Installed and verified {destination}')
        if backup:
            print(f'Previous bundle: {backup}')
    finally:
        shutil.rmtree(stage)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Usage: install-signed-app.py SIGNED_APP INSTALL_DIRECTORY')
    install(Path(sys.argv[1]), Path(sys.argv[2]))
