#!/usr/bin/env python3
"""Isolated real-launcher fault tests; no installed app, tunnel, or model usage."""
import json, os, pathlib, signal, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[1]

def wait_for(fn, seconds=15):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        result = fn()
        if result: return result
        time.sleep(.1)
    raise AssertionError('timed out')

def alive(pid):
    try: os.kill(pid, 0); return True
    except ProcessLookupError: return False

def process_rows():
    rows = []
    for line in subprocess.check_output(['ps', '-axo', 'pid=,ppid=,command='], text=True).splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            rows.append((int(fields[0]), int(fields[1]), fields[2]))
    return rows

def assert_native_launcher_chain(pid, launcher, script, script_arguments=()):
    rows = process_rows()
    parent = next((row for row in rows if row[0] == pid), None)
    assert parent is not None, 'native launcher must remain alive while the service runs'
    assert parent[2].split(None, 1)[0] == str(launcher), parent
    children = [row for row in rows if row[1] == pid]
    assert len(children) == 1, children
    child_pid, _, command = children[0]
    expected = ' '.join(['/bin/bash', str(script), *script_arguments])
    assert command == expected, (child_pid, command, expected)
    return child_pid

with tempfile.TemporaryDirectory(prefix='wonder-lifecycle-') as tmp:
    root = pathlib.Path(tmp)
    resources = root/'Wonder.app/Contents/Resources'; resources.mkdir(parents=True)
    macos = resources.parent/'MacOS'; macos.mkdir()
    launcher = macos/'WonderMenu'
    (resources/'WonderService.sh').write_bytes((ROOT/'apps/menubar/WonderMenu.launcher').read_bytes())
    import plistlib
    (resources.parent/'Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable': 'WonderMenu', 'CFBundleIdentifier': 'com.saimun.wonder'}))
    subprocess.run(['xcrun', 'swiftc', str(ROOT/'apps/menubar/Launcher/main.swift'), '-o', str(launcher)], check=True)
    for name in ['WonderHost', 'wonderd', 'wonder-tunnel']:
        path = (macos if name == 'WonderHost' else resources)/name
        path.write_text('''#!/bin/bash
name="$(basename "$0")"
echo $$ >> "$WONDER_DATA_DIR/$name.pids"
trap 'exit 0' TERM INT
if [[ "$name" == wonderd ]]; then
  sleep 1000 &
  echo $! >> "$WONDER_DATA_DIR/worker.pids"
fi
while true; do sleep 0.1; done
'''); path.chmod(0o700)
    data = root/'state'; data.mkdir()
    (data/'sentinel').write_text('saved chat')
    env = {**os.environ, 'HOME': str(root), 'WONDER_DATA_DIR':str(data)}
    def pids(name):
        f = data/(name+'.pids')
        return [int(x) for x in f.read_text().split()] if f.exists() else []
    with (root/'launcher.log').open('w') as log:
        process = subprocess.Popen([str(launcher), '--lifecycle-argument'], env=env, stdout=log, stderr=log)
        try:
            wait_for(lambda: all(pids(n) for n in ['WonderHost','wonderd','wonder-tunnel','worker']))
            service_shell = assert_native_launcher_chain(process.pid, launcher, resources/'WonderService.sh', ('--lifecycle-argument',))
            duplicate = subprocess.run([str(launcher)], env=env, capture_output=True, timeout=5)
            assert duplicate.returncode == 0 and len(pids('WonderHost')) == 1
            assert (data/'Service/open-settings').exists(), 'second launch must reopen Settings'
            old_daemon = pids('wonderd')[-1]; old_tunnel = pids('wonder-tunnel')[-1]; worker = pids('worker')[-1]
            os.kill(old_daemon, signal.SIGKILL)
            wait_for(lambda: len(pids('wonderd')) == 2)
            wait_for(lambda: not alive(worker))
            assert pids('wonder-tunnel')[-1] == old_tunnel
            os.kill(old_tunnel, signal.SIGKILL)
            wait_for(lambda: len(pids('wonder-tunnel')) == 2)
            assert len(pids('wonderd')) == 2
            (data/'Service/restart').touch()
            wait_for(lambda: len(pids('wonderd')) == 3 and len(pids('wonder-tunnel')) == 3)
            # Native/Sparkle quit handshake stops services before menu exits.
            (data/'Service/stop').touch()
            wait_for(lambda: (data/'Service/stopped').exists())
            assert not alive(pids('wonderd')[-1]) and not alive(pids('wonder-tunnel')[-1])
            os.kill(pids('WonderHost')[-1], signal.SIGTERM)
            assert process.wait(timeout=15) == 0
            wait_for(lambda: not alive(service_shell))
            wait_for(lambda: all(not alive(pid) for name in ['wonderd','wonder-tunnel','worker','WonderHost'] for pid in pids(name)))
            assert (data/'sentinel').read_text() == 'saved chat'
            assert json.loads((data/'Service/tunnel.jsonl').read_text())['state'] == 'stopped'
            # Stale owner from a killed launcher is reclaimed on next open.
            (data/'Service/launcher.pid').write_text(str(process.pid)+'\n')
            process = subprocess.Popen([str(launcher)], env=env, stdout=log, stderr=log)
            wait_for(lambda: len(pids('WonderHost')) == 2)
            interrupt_shell = assert_native_launcher_chain(process.pid, launcher, resources/'WonderService.sh')
            process.send_signal(signal.SIGINT)
            assert process.wait(timeout=15) == 130
            wait_for(lambda: not alive(interrupt_shell))
            wait_for(lambda: all(not alive(pid) for name in ['wonderd','wonder-tunnel','worker','WonderHost'] for pid in pids(name)))

            (data/'Service/launcher.pid').write_text(str(process.pid)+'\n')
            process = subprocess.Popen([str(launcher)], env=env, stdout=log, stderr=log)
            wait_for(lambda: len(pids('WonderHost')) == 3)
            term_shell = assert_native_launcher_chain(process.pid, launcher, resources/'WonderService.sh')
            process.terminate()
            assert process.wait(timeout=15) == 143
            wait_for(lambda: not alive(term_shell))
            wait_for(lambda: all(not alive(pid) for name in ['wonderd','wonder-tunnel','worker','WonderHost'] for pid in pids(name)))
            print('PASS: native launcher attribution, duplicate launch, daemon crash/worker cleanup, independent tunnel crash, restart, updater quit handshake, menu quit, stale lock, SIGINT/SIGTERM forwarding, descendant cleanup, state preservation')
        finally:
            if process.poll() is None: process.terminate(); process.wait(timeout=20)
            if process.returncode not in (0, 143): print((root/'launcher.log').read_text())
            for name in ['wonderd','wonder-tunnel','worker','WonderHost']:
                for pid in pids(name):
                    if alive(pid): os.kill(pid, signal.SIGKILL)
