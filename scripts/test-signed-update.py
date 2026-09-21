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
# Existing nested bundles must remain compatible with one another without a
# legacy flat helper being present.
installer.verify_update(a, b)
installer.verify_update(b, a)
for bundle in (
    a / 'Contents/Resources/WonderComputerUse.app',
    a / 'Contents/Resources/WonderComputerUse.app/Contents/MacOS/WonderComputerUse',
):
    info = installer.output('codesign', '-dvv', str(bundle))
    assert 'Identifier=com.saimun.wonder.computer-use' in info, f'Unexpected helper identifier: {bundle}'
    requirement = installer.output('codesign', '-d', '-r-', str(bundle)).split('designated => ', 1)[1].strip()
    if bundle.name == 'WonderComputerUse.app':
        app_requirement = requirement
    else:
        assert requirement == app_requirement, 'Nested bundle and executable designated requirements differ'
app_hashes_changed = False
for relative in ['', 'Contents/Resources/WonderComputerUse.app/Contents/MacOS/WonderComputerUse']:
    first = installer.output('codesign', '-d', '--verbose=4', str(a / relative))
    second = installer.output('codesign', '-d', '--verbose=4', str(b / relative))
    hash_a = next(line for line in first.splitlines() if line.startswith('CDHash='))
    hash_b = next(line for line in second.splitlines() if line.startswith('CDHash='))
    if relative == '':
        app_hashes_changed = hash_a != hash_b
assert app_hashes_changed, 'Test needs changed app code (for example, a build-version change)'
with tempfile.TemporaryDirectory(prefix='wonder-legacy-update-') as root:
    legacy = Path(root) / 'Wonder.app'
    subprocess.run(['ditto', str(a), str(legacy)], check=True)
    nested = legacy / 'Contents/Resources/WonderComputerUse.app/Contents/MacOS/WonderComputerUse'
    flat = legacy / 'Contents/Resources/WonderComputerUse'
    shutil.copy2(nested, flat)
    shutil.rmtree(legacy / 'Contents/Resources/WonderComputerUse.app')
    # First migration: the old flat executable must validate against the new
    # nested app and nested executable requirements.
    installer.verify_update(legacy, b)
with tempfile.TemporaryDirectory(prefix='wonder-signature-test-') as root:
    candidate = Path(root) / 'Wonder.app'
    subprocess.run(['ditto', str(b), str(candidate)], check=True)
    with (candidate / 'Contents/Resources/WonderComputerUse.app/Contents/MacOS/WonderComputerUse').open('ab') as helper:
        helper.write(b'tampered')
    try:
        installer.verify(candidate)
    except subprocess.CalledProcessError:
        pass
    else:
        raise AssertionError('Modified bundle passed verification')
print('PASS: changed app hash, helper identity compatibility, legacy flat-helper migration, and tampered-bundle rejection verified')
