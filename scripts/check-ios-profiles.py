#!/usr/bin/env python3
"""Verify matching app identity and exclusion of diagnostic machinery in Release."""
import argparse, plistlib, subprocess, json
from pathlib import Path
p=argparse.ArgumentParser(description=__doc__)
p.add_argument('diagnostics',type=Path);p.add_argument('release',type=Path)
a=p.parse_args(); result={}
for profile,path in [('diagnostics',a.diagnostics),('release',a.release)]:
    info=plistlib.loads((path/'Info.plist').read_bytes())
    assert info['CFBundleIdentifier']=='com.swaymun.wonder'
    assert info['WonderBuildProfile']==profile
    executable=path/info['CFBundleExecutable']
    strings=subprocess.check_output(['strings',str(executable)],text=True)
    markers=['DiagnosticJournal','DiagnosticScenarioControl','/api/v1/diagnostics/batches']
    for marker in markers: assert (marker in strings)==(profile=='diagnostics'), (profile,marker)
    result[profile]={'executableBytes':executable.stat().st_size,'appBytes':sum(f.stat().st_size for f in path.rglob('*') if f.is_file())}
print(json.dumps(result,indent=2))
