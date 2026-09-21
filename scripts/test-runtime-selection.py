#!/usr/bin/env python3
"""Runtime management checks without network, login, or host installation edits."""
import os
from pathlib import Path
import subprocess
import tempfile

script = Path(__file__).resolve().parent / "manage-runtime.sh"
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    runtime = root / "ChatGPT.app" / "codex"
    runtime.parent.mkdir()
    verifier = root / "wonderd"
    verifier.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$WONDER_TEST_ARGS"\n')
    verifier.chmod(0o700)
    env = {**os.environ, "WONDER_RESOURCES": str(root), "WONDER_CODEX_BIN": str(runtime), "WONDER_TEST_ARGS": str(root / "args")}
    def run(action):
        return subprocess.run(["bash", str(script), action], env=env, capture_output=True, text=True)
    assert run("check").returncode != 0
    assert not (root / "args").exists()
    runtime.write_text("#!/bin/sh\nexit 0\n")
    runtime.chmod(0o700)
    assert run("check").returncode == 0
    assert (root / "args").read_text().splitlines() == ["--verify-runtime", str(runtime)]
    assert run("rollback").returncode != 0
    verifier.write_text("#!/bin/sh\nexit 1\n")
    assert run("check").returncode != 0
    assert not (root / "Runtime").exists()
print("PASS: missing runtime, selected executable, verifier failure, no managed install/rollback")
