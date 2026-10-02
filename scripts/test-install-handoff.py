#!/usr/bin/env python3
"""Installer owner authority and failure ordering; no installed app or model use.

Real Developer ID and tamper checks remain owned by test-signed-update.py.
"""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).with_name('install-signed-app.py'))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.app = self.root / 'installed/Wonder.app'
        self.source = self.root / 'candidate/Wonder.app'
        self.app.mkdir(parents=True); self.source.mkdir(parents=True)
        (self.app / 'version').write_text('old'); (self.source / 'version').write_text('new')
        self.control = self.root / 'Service/update-control'
        self.control.parent.mkdir()
        self.requests = []
        self.ready = True
        self.redirect = False
        test = self
        class Host(BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                if test.redirect:
                    self.send_response(302); self.send_header('Location','/leak'); self.end_headers(); return
                if self.path == '/healthz':
                    self.send_response(200); self.end_headers()
                    self.wfile.write(b'{"status":"ok"}')
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                test.assertEqual(self.headers['x-wonder-loopback-capability'],'private-capability')
                test.requests.append((self.path,request['requestId']))
                if test.redirect:
                    self.send_response(302); self.send_header('Location','/leak'); self.end_headers(); return
                self.send_response(200 if test.ready or self.path.endswith('/cancel') else 409)
                self.end_headers()
                if self.path.endswith('/prepare'):
                    self.wfile.write(json.dumps({'ready':test.ready,'requestId':request['requestId']}).encode())
        self.host = ThreadingHTTPServer(('127.0.0.1',0),Host)
        threading.Thread(target=self.host.serve_forever,daemon=True).start()
        self.addCleanup(self.host.server_close); self.addCleanup(self.host.shutdown)
        self.control.write_bytes(f'{self.app}\0'.encode() + f'127.0.0.1:{self.host.server_port}\0private-capability\0'.encode())
        self.control.chmod(0o600)
        env = patch.dict(os.environ,{'WONDER_DATA_DIR':str(self.root)})
        env.start(); self.addCleanup(env.stop)

    def test_owner_only_control_and_no_redirect(self):
        self.control.chmod(0o644)
        with self.assertRaises(RuntimeError): installer.UpdateHandoff(self.app)
        self.control.chmod(0o600)
        handoff = installer.UpdateHandoff(self.app)
        handoff.prepare(); handoff.cancel()
        self.assertEqual(self.requests[0][1],self.requests[1][1])
        self.redirect = True
        with self.assertRaises(installer.urllib.error.HTTPError) as error: handoff.prepare()
        error.exception.close()
        self.assertFalse(any(path == '/leak' for path,_ in self.requests))
        target = self.control.with_name('target')
        self.control.rename(target); self.control.symlink_to(target)
        with self.assertRaises(RuntimeError): installer.UpdateHandoff(self.app)

    def test_rejected_preparation_never_stops_or_replaces(self):
        self.ready = False
        with patch.object(installer,'verify'), patch.object(installer,'verify_update'), \
             patch.object(installer,'running_pids',return_value=[123]), \
             patch.object(installer,'stop') as stop, patch.object(installer,'launch') as launch:
            with self.assertRaises(installer.urllib.error.HTTPError):
                installer.install(self.source,self.app.parent)
            stop.assert_not_called(); launch.assert_not_called()
        self.assertEqual((self.app/'version').read_text(),'old')

    def test_failed_replacement_rolls_back_cancels_and_relaunches(self):
        def verify(app):
            if app == self.app and (app/'version').read_text() == 'new':
                raise RuntimeError('replacement verification failed')
        with patch.object(installer,'verify',side_effect=verify), patch.object(installer,'verify_update'), \
             patch.object(installer,'running_pids',return_value=[123]), \
             patch.object(installer,'stop'), patch.object(installer,'launch') as launch:
            with self.assertRaisesRegex(RuntimeError,'verification failed'):
                installer.install(self.source,self.app.parent)
            launch.assert_called_once_with(self.app)
        self.assertEqual((self.app/'version').read_text(),'old')
        self.assertEqual([path.rsplit('/',1)[-1] for path,_ in self.requests],['prepare','cancel'])

    def test_success_relaunches_replacement_after_handoff(self):
        with patch.object(installer,'verify'), patch.object(installer,'verify_update'), \
             patch.object(installer,'running_pids',return_value=[123]), \
             patch.object(installer,'stop') as stop, patch.object(installer,'launch') as launch:
            installer.install(self.source,self.app.parent)
            stop.assert_called_once_with(self.app,[123]); launch.assert_called_once_with(self.app)
        self.assertEqual((self.app/'version').read_text(),'new')
        self.assertEqual(len(self.requests),1)

    def test_failed_replacement_health_restores_signed_previous_bundle(self):
        def check_health(_origin):
            self.assertEqual((self.app/'version').read_text(),'new')
            raise RuntimeError('new host failed health check')
        with patch.object(installer,'verify'), patch.object(installer,'verify_update'), \
             patch.object(installer,'running_pids',return_value=[123]), \
             patch.object(installer,'stop') as stop, patch.object(installer,'launch') as launch, \
             patch.object(installer,'wait_for_health',side_effect=check_health):
            with self.assertRaisesRegex(RuntimeError,'new host failed health check'):
                installer.install(self.source,self.app.parent)
        self.assertEqual((self.app/'version').read_text(),'old')
        self.assertEqual(stop.call_count,2)
        self.assertEqual(launch.call_count,2)
        self.assertEqual([path.rsplit('/',1)[-1] for path,_ in self.requests],['prepare','cancel'])

    def test_failed_replacement_launch_restores_signed_previous_bundle(self):
        attempts = []
        def launch(app):
            attempts.append((app/'version').read_text())
            if attempts[-1] == 'new':
                raise OSError('replacement launch failed')
        with patch.object(installer,'verify'), patch.object(installer,'verify_update'), \
             patch.object(installer,'running_pids',return_value=[123]), \
             patch.object(installer,'stop'), patch.object(installer,'launch',side_effect=launch):
            with self.assertRaisesRegex(OSError,'replacement launch failed'):
                installer.install(self.source,self.app.parent)
        self.assertEqual(attempts,['new','old'])
        self.assertEqual((self.app/'version').read_text(),'old')

    def test_failed_candidate_move_restores_previous_bundle(self):
        real_rename = Path.rename
        def fail_candidate_move(path, target):
            if path.name == 'Wonder.app' and path.parent.name.startswith('.Wonder-install-'):
                raise OSError('candidate move failed')
            return real_rename(path, target)
        with patch.object(installer,'verify'), patch.object(installer,'verify_update'), \
             patch.object(installer,'running_pids',return_value=[123]), \
             patch.object(installer,'stop'), patch.object(installer,'launch') as launch, \
             patch.object(Path,'rename',fail_candidate_move):
            with self.assertRaisesRegex(OSError,'candidate move failed'):
                installer.install(self.source,self.app.parent)
        self.assertEqual((self.app/'version').read_text(),'old')
        launch.assert_called_once_with(self.app)

    def test_health_probe_rejects_unhealthy_and_redirected_host(self):
        installer.wait_for_health(f'http://127.0.0.1:{self.host.server_port}', timeout=1)
        self.redirect = True
        with self.assertRaisesRegex(RuntimeError,'did not become healthy'):
            installer.wait_for_health(f'http://127.0.0.1:{self.host.server_port}', timeout=.1)


if __name__ == '__main__': unittest.main()
