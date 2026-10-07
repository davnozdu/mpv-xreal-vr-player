#!/usr/bin/env python3
"""Exercise the real mpv Lua client and native source sizes through JSON IPC."""
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'xreal/test-output'
OUT.mkdir(exist_ok=True)
BINARY = Path(sys.argv[1]).resolve()
reports = []

with tempfile.TemporaryDirectory(prefix='xreal-', dir='/tmp') as directory:
    temp = Path(directory)
    movie = temp / 'movie.mkv'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=red:s=960x540:r=60',
                    '-f', 'lavfi', '-i', 'color=blue:s=960x540:r=60', '-filter_complex', 'hstack',
                    '-frames:v', '2', '-c:v', 'ffv1', str(movie)], check=True)
    large = temp / 'unmarked-8k.mkv'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=red:s=4096x4096:r=60',
                    '-f', 'lavfi', '-i', 'color=blue:s=4096x4096:r=60', '-filter_complex', 'hstack',
                    '-frames:v', '1', '-c:v', 'ffv1', str(large)], check=True)
    ipc = temp / 'ipc'
    with (OUT / 'mpv.log').open('w') as log:
        process = subprocess.Popen([str(BINARY), '--no-config', '--load-scripts=no',
            '--vo=null', '--ao=null', '--hwdec=no', '--idle=yes', '--pause=yes',
            '--terminal=yes', '--msg-level=all=warn', f'--input-ipc-server={ipc}',
            f'--script={ROOT}/xreal/resources/xreal.lua',
            f'--script-opts=xreal-prefs={temp}/preferences.json'], stdout=log, stderr=log)
        try:
            deadline = time.monotonic() + 20
            while not ipc.exists():
                if process.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError((OUT / 'mpv.log').read_text())
                time.sleep(0.1)
            client = socket.socket(socket.AF_UNIX)
            client.settimeout(10)
            client.connect(str(ipc))
            stream = client.makefile('rwb', buffering=0)
            request = 0

            def command(*args):
                global request
                request += 1
                stream.write((json.dumps({'command': args, 'request_id': request}) + '\n').encode())
                while True:
                    reply = json.loads(stream.readline())
                    if reply.get('request_id') == request:
                        if reply.get('error') != 'success':
                            raise RuntimeError(reply)
                        return reply.get('data')

            def wait_property(name, expected):
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        value = command('get_property', 'user-data/xreal')
                        if isinstance(value, dict) and value.get(name) == expected:
                            return value
                    except RuntimeError:
                        pass
                    time.sleep(0.05)
                raise AssertionError(f'{name} did not become {expected}: {value}')

            command('loadfile', str(movie))
            wait_property('resolved', 'hsbs')
            for mode in ['hsbs', 'fsbs', 'vr180', 'vr360', 'vr180tb', 'vr360tb']:
                command('script-message', 'xreal-mode', mode)
                state = wait_property('resolved', mode)
                assert abs(state['eye_aspect'] - (16/9 if mode == 'hsbs' else 8/9)) < 0.001
                reports.append({'test': f'mode-{mode}', 'passed': True})
            command('script-message', 'xreal-look', '20', '15')
            assert wait_property('yaw', 20)['pitch'] == 15
            command('script-message', 'xreal-swap')
            wait_property('swapped', True)
            command('script-message', 'xreal-reset')
            state = wait_property('yaw', 0)
            assert state['pitch'] == 0 and state['fov'] == 70
            reports.append({'test': 'look-swap-reset', 'passed': True})
            for output, ratio in [('half', 16/9), ('full', 32/9), ('preview', 32/9)]:
                command('script-message', 'xreal-output', 'auto')
                command('script-message', 'xreal-display', output)
                wait_property('output', output)
                assert abs(float(command('get_property', 'video-aspect-override')) - ratio) < 0.001
                reports.append({'test': f'output-{output}', 'passed': True})
            command('script-message', 'xreal-mode', 'auto')
            # Different filenames must select the appropriate projection.
            for filename, expected in [('film-Full-SBS.mkv', 'fsbs'), ('film-Half-SBS.mkv', 'hsbs'),
                                       ('film-VR180-SBS.mkv', 'vr180'), ('film-VR360-TB-test.mkv', 'vr360tb')]:
                path = temp / filename
                shutil.copy2(movie, path)
                command('loadfile', str(path))
                wait_property('resolved', expected)
                reports.append({'test': f'auto-{filename}', 'passed': True})
            command('loadfile', str(large))
            state = wait_property('resolved', 'vr180')
            assert state['guessed'] is True
            reports.append({'test': 'auto-8192x4096', 'passed': True})
            command('script-message', 'xreal-mode', 'vr360')
            wait_property('resolved', 'vr360')
            command('loadfile', str(movie))
            wait_property('resolved', 'hsbs')
            command('loadfile', str(large))
            wait_property('mode', 'vr360')
            reports.append({'test': 'per-file-preference', 'passed': True})
            command('quit')
            process.wait(timeout=10)
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)

text = (OUT / 'mpv.log').read_text()
assert 'Lua error' not in text, text
(OUT / 'report.json').write_text(json.dumps({'passed': len(reports), 'tests': reports}, indent=2))
print(f'PASS: {len(reports)} real-player checks')
