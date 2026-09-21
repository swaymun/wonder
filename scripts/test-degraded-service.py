#!/usr/bin/env python3
"""Real daemon, isolated SQLite, no runtime/model/tunnel. Tests HTTP and signals."""
import json, os, pathlib, signal, socket, subprocess, tempfile, time, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='wonder-degraded-') as tmp:
    root = pathlib.Path(tmp)
    with socket.socket() as sock: sock.bind(('127.0.0.1',0)); port=sock.getsockname()[1]
    env={**os.environ, 'WONDER_DATA_DIR':tmp,'WONDER_LOG_DIR':tmp+'/logs','WONDER_CODEX_BIN':tmp+'/missing','WONDER_LOOPBACK_CAPABILITY':'isolated-test-capability','WONDER_LISTEN_ADDR':f'127.0.0.1:{port}','CODEX_HOME':tmp+'/codex'}
    def get(path, auth=True):
        return urllib.request.urlopen(urllib.request.Request(f'http://127.0.0.1:{port}'+path,headers={'x-wonder-loopback-capability':'isolated-test-capability'} if auth else {}),timeout=2)
    identity=None
    for mode in ['missing','mismatch','restart']:
        if mode != 'missing':
            runtime=root/'wrong-runtime';runtime.write_text('#!/bin/sh\necho codex-cli unsupported\n');runtime.chmod(0o700);env['WONDER_CODEX_BIN']=str(runtime)
        with (root/'process.log').open('a') as log:
            process=subprocess.Popen([str(ROOT/'target/debug/wonderd')],env=env,stdout=log,stderr=log)
            try:
                deadline=time.monotonic()+10
                while True:
                    try: status=json.load(get('/api/v1/host/status'));break
                    except Exception:
                        if time.monotonic()>deadline: raise
                        time.sleep(.1)
                assert status['execution']['ready'] is False, status
                current=status['hostInstallationId']
                if identity: assert identity == current
                identity=current
                assert json.load(get('/healthz'))['status']=='ok'
                assert get('/api/v1/conversations').status==200
                try: get('/api/v1/conversations',False);raise AssertionError('unauthenticated access')
                except urllib.error.HTTPError as error: assert error.code in (401,403,503)
                started=time.monotonic();process.send_signal(signal.SIGTERM)
                assert process.wait(timeout=6)==0
                assert time.monotonic()-started<5
                assert 'daemon_stopped' in (root/'logs/wonderd.jsonl').read_text()
            finally:
                if process.poll() is None: process.kill();process.wait()
    print('PASS: missing/mismatched runtime preserves authenticated local reads, rejects unauthenticated reads, stable installation identity, SIGTERM exits cleanly across restarts')
