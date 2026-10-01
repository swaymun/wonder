#!/usr/bin/env python3
"""Verify, stop, and replace an entire Wonder bundle, retaining a rollback copy."""
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import stat

COMPONENTS = [
    '',
    'Contents/MacOS/WonderHost',
    'Contents/MacOS/WonderMacBridge',
    'Contents/Helpers/WonderComputerUse',
    'Contents/Resources/wonderd',
    'Contents/Resources/wonder-tunnel',
]
COMPUTER_USE = 'Contents/Helpers/WonderComputerUse'
# Earlier layouts of the same helper, newest first.
PREVIOUS_COMPUTER_USE = ['Contents/Resources/WonderComputerUse.app/Contents/MacOS/WonderComputerUse',
                         'Contents/Resources/WonderComputerUse']


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
        # The helper keeps its signing identifier across layout moves; compare
        # against whichever earlier path the previous bundle used.
        if relative == COMPUTER_USE and not old.exists():
            old = next((previous / path for path in PREVIOUS_COMPUTER_USE if (previous / path).exists()), old)
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


def running_pids(app):
    commands = {str(app / 'Contents/MacOS/WonderMenu'),
                'bash ' + str(app / 'Contents/MacOS/WonderMenu'),
                '/bin/bash ' + str(app / 'Contents/MacOS/WonderMenu'),
                '/bin/bash ' + str(app / 'Contents/Resources/WonderService.sh')}
    processes = output('ps', '-axo', 'pid=,command=').splitlines()
    pids = [int(parts[0]) for line in processes if len(parts := line.strip().split(None, 1)) == 2
            and parts[1] in commands]
    return pids


def stop(app, pids=None):
    for pid in (pids := running_pids(app) if pids is None else pids):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
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


def data_directory():
    if configured := os.environ.get('WONDER_DATA_DIR'):
        return Path(configured)
    legacy = Path.home() / 'Library/Application Support/Wonder'
    current = Path.home() / '.wonder'
    return legacy if legacy.exists() and not current.exists() else current


class UpdateHandoff:
    """Only the running installation's owner capability may pause its work."""
    def __init__(self, app):
        path = data_directory() / 'Service/update-control'
        self.legacy = False
        try:
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
        except FileNotFoundError:
            # One-time upgrade from hosts that kept their capability only in
            # the daemon environment. Authenticate to their existing idle-work
            # lease; never force-stop active work without continuation records.
            application, address, capability = legacy_control(app)
            self.legacy = True
        except OSError as error:
            raise RuntimeError('The private update control file cannot be safely read') from error
        else:
            with os.fdopen(descriptor, 'rb') as saved:
                info = os.fstat(saved.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                    raise RuntimeError('The update control file must be private to its owner')
                fields = saved.read(16384).decode().split('\0')
            if len(fields) != 4 or fields[-1] != '':
                raise RuntimeError('Invalid update control file')
            application, address, capability, _ = fields
        if Path(application).resolve() != app.resolve():
            raise RuntimeError('The running host belongs to a different Wonder installation')
        if not re.fullmatch(r'127\.0\.0\.1:[0-9]{1,5}', address):
            raise RuntimeError('Update handoff requires the local Wonder host')
        self.origin = 'http://' + address
        self.capability = capability
        self.request_id = str(uuid.uuid4())

    def request(self, action):
        request = urllib.request.Request(self.origin + '/api/v1/host/update/' + action,
            data=json.dumps({'requestId': self.request_id}).encode(), method='POST',
            headers={'Content-Type': 'application/json', 'x-wonder-loopback-capability': self.capability})
        # Never forward the capability through a proxy or follow a redirect.
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        with opener.open(request, timeout=30) as response:
            return json.load(response) if action == 'prepare' else None

    def prepare(self):
        deadline = time.monotonic() + 3 * 60 * 60
        while True:
            try:
                reply = self.request('prepare')
                break
            except urllib.error.HTTPError as error:
                retry = self.legacy and error.code == 409 and time.monotonic() < deadline
                error.close()
                if not retry:
                    raise
                time.sleep(5)
        if reply.get('ready') is not True or reply.get('requestId') != self.request_id:
            raise RuntimeError('Wonder did not confirm a safe update handoff')

    def cancel(self):
        self.request('cancel')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, url):
        return None


def legacy_control(app):
    launchers = set(running_pids(app))
    rows = {}
    for line in output('ps', '-axo', 'pid=,ppid=,uid=,command=').splitlines():
        fields = line.strip().split(None,3)
        if len(fields) == 4:
            rows[int(fields[0])] = (int(fields[1]),int(fields[2]),fields[3])
    daemon = str(app / 'Contents/Resources/wonderd')
    candidates = []
    for pid,(parent,owner,command) in rows.items():
        if owner != os.getuid() or command != daemon:
            continue
        for _ in range(32):
            if parent in launchers:
                candidates.append(pid); break
            if parent not in rows: break
            parent = rows[parent][0]
    if len(candidates) != 1:
        raise RuntimeError('The running installation has no verifiable update authority. Quit it after work finishes, then install.')
    # Inspect only the verified daemon. Never print its environment, persist
    # it, or expose any other credential in diagnostics or exceptions.
    environment = output('ps', 'eww', '-p', str(candidates[0]), '-o', 'command=')
    capability = re.search(r'(?:^| )WONDER_LOOPBACK_CAPABILITY=([A-Za-z0-9-]{16,512})(?: |$)',environment)
    address = re.search(r'(?:^| )WONDER_LISTEN_ADDR=(127\.0\.0\.1:[0-9]{1,5})(?: |$)',environment)
    if capability is None:
        raise RuntimeError('The running host cannot authorize an update. Quit it after work finishes, then install.')
    return str(app), address[1] if address else '127.0.0.1:3777', capability[1]


def launch(app):
    subprocess.run(['open', '-n', str(app)], check=True)


def inside_wonder():
    """An updater invoked by an agent must outlive that agent's Stop."""
    pid = os.getppid()
    for _ in range(32):
        try:
            parts = output('ps', '-p', str(pid), '-o', 'ppid=', '-o', 'comm=').strip().split(None, 1)
        except subprocess.CalledProcessError:
            break
        if len(parts) != 2:
            break
        if Path(parts[1]).name == 'wonderd':
            return True
        pid = int(parts[0])
        if pid <= 1:
            break
    return False


def install(source, directory):
    source = source.resolve()
    directory = directory.resolve()
    destination = directory / 'Wonder.app'
    if source == destination or destination.is_symlink():
        raise RuntimeError('Build outside the installed app; symlink destinations are not supported')
    verify(source)
    directory.mkdir(parents=True, exist_ok=True)
    stage = Path(tempfile.mkdtemp(prefix='.Wonder-install-', dir=directory))
    handoff = None
    stopped = False
    was_running = False
    try:
        candidate = stage / 'Wonder.app'
        subprocess.run(['ditto', str(source), str(candidate)], check=True)
        verify(candidate)
        if destination.exists():
            verify_update(destination, candidate)
        pids = running_pids(destination)
        was_running = bool(pids)
        if was_running:
            handoff = UpdateHandoff(destination)
            handoff.prepare()
        stopped = was_running
        stop(destination, pids)
        backup = None
        if destination.exists():
            root = data_directory() / 'Backups'
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
        if was_running:
            launch(destination)
    except Exception:
        if handoff:
            try:
                handoff.cancel()
            except Exception:
                # A replacement/rollback host also recovers the durable roster.
                pass
        if stopped and destination.exists():
            launch(destination)
        raise
    finally:
        shutil.rmtree(stage)


if __name__ == '__main__':
    worker = len(sys.argv) == 5 and sys.argv[1] == '--worker'
    if not worker and len(sys.argv) != 3:
        raise SystemExit('Usage: install-signed-app.py SIGNED_APP INSTALL_DIRECTORY')
    if worker:
        time.sleep(1) # let the launching tool return before its turn is paused
        result_path = Path(sys.argv[4])
        try:
            install(Path(sys.argv[2]), Path(sys.argv[3]))
            result = {'status': 'installed'}
        except Exception as error:
            result = {'status': 'failed', 'error': str(error)}
        descriptor = os.open(result_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as saved:
            saved.write(json.dumps(result) + '\n')
        raise SystemExit(0 if result['status'] == 'installed' else 1)
    if inside_wonder():
        # Detach before asking the daemon to interrupt the caller. Otherwise
        # its cancelled tool process would die halfway through replacement.
        jobs = data_directory() / 'Service/updates'
        jobs.mkdir(parents=True, exist_ok=True, mode=0o700)
        job = jobs / str(uuid.uuid4())
        environment = dict(os.environ)
        environment.pop('WONDER_LOOPBACK_CAPABILITY', None)
        descriptor = os.open(str(job) + '.log', os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as log:
            subprocess.Popen([sys.executable, str(Path(__file__).resolve()), '--worker',
                str(Path(sys.argv[1]).resolve()), str(Path(sys.argv[2]).resolve()), str(job) + '.json'],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True, env=environment)
        print(f'Update detached from the agent. Result: {job}.json; log: {job}.log')
    else:
        install(Path(sys.argv[1]), Path(sys.argv[2]))
