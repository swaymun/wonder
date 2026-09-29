#!/usr/bin/env python3
"""Check two real signed builds, including changed code and tamper rejection."""
import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-signed-app.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
a, b = map(Path, sys.argv[1:])
installer.verify(a)
installer.verify(b)
installer.verify_update(a, b)
installer.verify_update(b, a)
helper = a / installer.COMPUTER_USE
info = installer.output('codesign', '-dvv', str(helper))
assert 'Identifier=com.saimun.wonder.computer-use' in info, f'Unexpected helper identifier: {helper}'
assert 'Info.plist=not bound' in info, 'The helper must not carry its own bundle identity'
assert not (a / 'Contents/Resources/WonderComputerUse.app').exists(), 'The helper must not be a separate app'
app_hashes_changed = False
for relative in ['', installer.COMPUTER_USE]:
    first = installer.output('codesign', '-d', '--verbose=4', str(a / relative))
    second = installer.output('codesign', '-d', '--verbose=4', str(b / relative))
    hash_a = next(line for line in first.splitlines() if line.startswith('CDHash='))
    hash_b = next(line for line in second.splitlines() if line.startswith('CDHash='))
    if relative == '':
        app_hashes_changed = hash_a != hash_b
assert app_hashes_changed, 'Test needs changed app code (for example, a build-version change)'
with tempfile.TemporaryDirectory(prefix='wonder-previous-layout-') as root:
    previous = Path(root) / 'Wonder.app'
    subprocess.run(['ditto', str(a), str(previous)], check=True)
    nested = previous / installer.PREVIOUS_COMPUTER_USE[0]
    nested.parent.mkdir(parents=True)
    shutil.move(str(previous / installer.COMPUTER_USE), str(nested))
    # An update from the nested-app layout compares the same signing identity.
    installer.verify_update(previous, b)
with tempfile.TemporaryDirectory(prefix='wonder-signature-test-') as root:
    candidate = Path(root) / 'Wonder.app'
    subprocess.run(['ditto', str(b), str(candidate)], check=True)
    with (candidate / installer.COMPUTER_USE).open('ab') as helper:
        helper.write(b'tampered')
    try:
        installer.verify(candidate)
    except subprocess.CalledProcessError:
        pass
    else:
        raise AssertionError('Modified bundle passed verification')
print('PASS: changed app hash, helper identity compatibility, previous-layout update, and tampered-bundle rejection verified')
