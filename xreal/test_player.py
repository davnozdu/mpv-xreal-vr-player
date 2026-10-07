#!/usr/bin/env python3
"""Exercise two real mpv Lua clients without requiring an IPC socket."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'xreal/test-output'
OUT.mkdir(exist_ok=True)
BINARY = Path(sys.argv[1]).resolve()
steps = []

with tempfile.TemporaryDirectory(prefix='xreal-', dir='/tmp') as directory:
    temp = Path(directory)
    movie = temp / 'movie.mkv'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=red:s=960x1080:r=60',
                    '-f', 'lavfi', '-i', 'color=blue:s=960x1080:r=60', '-filter_complex', 'hstack',
                    '-frames:v', '2', '-c:v', 'ffv1', str(movie)], check=True)
    large = temp / 'unmarked-8k.mkv'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=red:s=4096x4096:r=60',
                    '-f', 'lavfi', '-i', 'color=blue:s=4096x4096:r=60', '-filter_complex', 'hstack',
                    '-frames:v', '1', '-c:v', 'ffv1', str(large)], check=True)

    def step(name, actions, expected, **checks):
        steps.append(dict(name=name, actions=actions, expected=expected, **checks))

    step('open-SBS', [['loadfile', str(movie)]], {'resolved': 'hsbs'}, path=str(movie))
    for mode in ['hsbs', 'fsbs', 'vr180', 'vr360', 'vr180tb', 'vr360tb']:
        step(f'mode-{mode}', [['script-message', 'xreal-mode', mode]], {'resolved': mode},
             eye_aspect=16/9 if mode == 'hsbs' else 8/9)
    step('panorama-look', [['script-message', 'xreal-look', '20', '15']], {'yaw': 20, 'pitch': 15})
    step('swap-eyes', [['script-message', 'xreal-swap']], {'swapped': True})
    step('reset-look', [['script-message', 'xreal-reset']], {'yaw': 0, 'pitch': 0, 'fov': 70})
    for output, ratio in [('half', 16/9), ('full', 32/9), ('preview', 32/9)]:
        step(f'output-{output}', [['script-message', 'xreal-output', 'auto'],
                                 ['script-message', 'xreal-display', output]], {'output': output}, aspect=ratio)
    step('auto-mode', [['script-message', 'xreal-mode', 'auto']], {'mode': 'auto'})
    for filename, expected in [('film-Full-SBS.mkv', 'fsbs'), ('film-Half-SBS.mkv', 'hsbs'),
                               ('film-VR180-SBS.mkv', 'vr180'), ('film-VR360-TB-test.mkv', 'vr360tb')]:
        path = temp / filename
        shutil.copy2(movie, path)
        step(f'auto-{filename}', [['loadfile', str(path)]], {'resolved': expected}, path=str(path))
    step('auto-8192x4096', [['loadfile', str(large)]], {'resolved': 'vr180', 'guessed': True}, path=str(large))
    step('remember-format', [['script-message', 'xreal-mode', 'vr360']], {'resolved': 'vr360'})
    step('switch-file', [['loadfile', str(movie)]], {'resolved': 'hsbs'}, path=str(movie))
    step('per-file-preference', [['loadfile', str(large)]], {'mode': 'vr360', 'resolved': 'vr360'}, path=str(large))
    scenario = temp / 'scenario.json'
    scenario.write_text(json.dumps(steps))
    report_path = OUT / 'report.json'
    report_path.unlink(missing_ok=True)
    with (OUT / 'mpv.log').open('w') as log:
        process = subprocess.run([str(BINARY), '--no-config', '--load-scripts=no',
            '--vo=null', '--ao=null', '--hwdec=no', '--idle=yes', '--pause=yes',
            '--terminal=yes', '--msg-level=all=warn',
            f'--script={ROOT}/xreal/resources/xreal.lua',
            f'--script={ROOT}/xreal/tests/client.lua',
            f'--script-opts=xreal-prefs={temp}/preferences.json,xreal_test-scenario={scenario},xreal_test-report={report_path}'],
            stdout=log, stderr=log, timeout=90)
    text = (OUT / 'mpv.log').read_text()
    if process.returncode or not report_path.exists():
        raise RuntimeError(text)
    report = json.loads(report_path.read_text())
    assert not report.get('error'), report
    assert report['passed'] == len(steps), report
    assert 'Lua error' not in text, text
    print(f"PASS: {report['passed']} real-player checks")
