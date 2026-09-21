#!/usr/bin/env python3
"""Offline adapter and download integrity regressions; no model downloads."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("worker", ROOT / "nemo-speech-worker.py")
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class WorkerTests(unittest.TestCase):
    def request(self, audio, duration):
        return {"transcriptionId": "fixture", "audioFormat": "pcm_s16le", "sampleRateHz": 16000, "channels": 1, "durationMs": duration, "audioBase64": base64.b64encode(audio).decode()}

    def test_exact_five_minutes_and_false_duration(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "runtime"
            binary.write_text("#!/bin/sh\nprintf '%s\\n' '{\"text\":\"Test\",\"words\":[]}'\n")
            binary.chmod(0o700)
            model = Path(directory) / "model"
            model.write_bytes(b"fixture")
            with patch.dict(os.environ, {"WONDER_NEMO_SPEECH_BIN": str(binary), "WONDER_ASR_MODEL": str(model)}):
                self.assertEqual(worker.transcribe(self.request(bytes(9_600_000), 300_000))["transcriptText"], "Test")
                self.assertEqual(worker.transcribe(self.request(bytes(9_600_002), 300_000))["errorCategory"], "decoder")
                self.assertEqual(worker.transcribe(self.request(bytes(32_000), 300_000))["errorCategory"], "decoder")

    def test_worker_stops_its_runtime_when_daemon_parent_exits(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            model = root / "model"
            model.write_bytes(b"fixture")
            runtime = root / "runtime"
            runtime.write_text("#!/usr/bin/env python3\nimport os,time\nopen(os.environ['RUNTIME_PID_FILE'],'w').write(str(os.getpid()))\ntime.sleep(60)\n")
            runtime.chmod(0o700)
            pid_file = root / "pid"
            parent = root / "parent.py"
            parent.write_text("import os,subprocess,json,base64,time,sys\nrequest={'transcriptionId':'fixture','audioFormat':'pcm_s16le','sampleRateHz':16000,'channels':1,'durationMs':1000,'audioBase64':base64.b64encode(bytes(32000)).decode()}\np=subprocess.Popen([sys.argv[1]],stdin=subprocess.PIPE,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,env={**os.environ,'WONDER_ASR_PARENT_PID':str(os.getpid())})\np.stdin.write((json.dumps(request)+'\\n').encode());p.stdin.flush()\nfor _ in range(100):\n if os.path.exists(os.environ['RUNTIME_PID_FILE']): break\n time.sleep(.01)\n")
            result = subprocess.run(["python3", str(parent), str(ROOT / "nemo-speech-worker.py")], env={**os.environ, "WONDER_ASR_MODEL": str(model), "WONDER_NEMO_SPEECH_BIN": str(runtime), "RUNTIME_PID_FILE": str(pid_file)}, timeout=5)
            self.assertEqual(result.returncode, 0)
            pid = int(pid_file.read_text())
            for _ in range(100):
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return
                time.sleep(.01)
            self.fail("Runtime survived its daemon parent")

    def test_failed_download_never_activates_partial_or_loses_existing_file(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "bin"
            binary.mkdir()
            curl = binary / "curl"
            curl.write_text("#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do if [ \"$1\" = '-o' ]; then shift; printf corrupt > \"$1\"; exit 0; fi; shift; done\nexit 1\n")
            curl.chmod(0o700)
            models = root / "models"
            models.mkdir()
            model = models / "parakeet-tdt-0.6b-v3.q8_0.gguf"
            model.write_bytes(b"previous contents")
            result = subprocess.run([str(ROOT / "install-parakeet-model.sh")], env={**os.environ, "WONDER_MODEL_DIR": str(models), "PATH": str(binary) + os.pathsep + os.environ["PATH"]}, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(model.read_bytes(), b"previous contents")
            self.assertFalse(Path(str(model) + ".part").exists())


if __name__ == "__main__":
    unittest.main()
