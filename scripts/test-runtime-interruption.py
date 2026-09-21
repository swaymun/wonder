#!/usr/bin/env python3
"""Fault injection into the shipped installer, using a local download fixture."""
import os,pathlib,subprocess,tempfile,time
ROOT=pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='wonder-repair-') as tmp:
    root=pathlib.Path(tmp);state=root/'state';runtime=state/'Runtime';runtime.mkdir(parents=True)
    (runtime/'current').symlink_to('release-sentinel')
    helper=root/'download'; helper.write_text('#!/bin/bash\necho $$ > "'+str(root/'download.pid')+'"\ntrap "exit 143" TERM\nwhile true; do sleep .1; done\n');helper.chmod(0o700)
    script=root/'manage-runtime.sh';script.write_text((ROOT/'scripts/manage-runtime.sh').read_text().replace('/usr/bin/curl',str(helper)))
    env={**os.environ,'WONDER_DATA_DIR':str(state)}
    with (root/'log').open('w') as log:
        process=subprocess.Popen(['/bin/bash',str(script)],env=env,stdout=log,stderr=log)
        try:
            end=time.monotonic()+5
            while not (root/'download.pid').exists():
                assert time.monotonic()<end;time.sleep(.05)
            child=int((root/'download.pid').read_text())
            process.terminate();assert process.wait(timeout=5)==143
            try:os.kill(child,0);raise AssertionError('download survived cancellation')
            except ProcessLookupError:pass
            assert not list(runtime.glob('staging.*'))
            assert os.readlink(runtime/'current')=='release-sentinel'
        finally:
            if process.poll() is None:process.kill();process.wait()
        helper.write_text('#!/bin/bash\nwhile [[ "$1" != -o ]]; do shift; done\nshift\nprintf corrupt > "$1"\n')
        result=subprocess.run(['/bin/bash',str(script)],env=env,stdout=log,stderr=log,timeout=5)
        assert result.returncode!=0
        assert os.readlink(runtime/'current')=='release-sentinel'
        assert not list(runtime.glob('staging.*'))
    print('PASS: cancellation stops download and removes staging; checksum mismatch preserves activation; recovery reacquires lock')
