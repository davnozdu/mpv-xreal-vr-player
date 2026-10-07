#!/usr/bin/env python3
"""Run the actual branded bundle, including all of its injected startup options."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP = Path(sys.argv[1]).resolve()
with (APP / 'Contents/Info.plist').open('rb') as file:
    plist = plistlib.load(file)
assert plist['CFBundleIdentifier'] == 'com.davnozdu.xreal-vr-player'
binary = APP / 'Contents/MacOS' / plist['CFBundleExecutable']
out = ROOT / 'xreal/test-output'
out.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix='xreal-bundle-', dir='/tmp') as directory:
    temp = Path(directory)
    movie = temp / 'smoke-Half-SBS.mkv'
    subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=red:s=1920x1080:r=24',
                    '-frames:v', '3', '-c:v', 'ffv1', str(movie)], check=True)
    # Disable the physical display/audio only. Keep the packaged startup defaults
    # (particularly gpu-api and gpu-context) to validate their actual parsing.
    result = subprocess.run([str(binary), '--vo=null', '--ao=null', '--hwdec=no',
        '--idle=no', '--force-window=no', '--keep-open=no', '--frames=2',
        '--terminal=yes', f'--log-file={temp}/startup.log',
        f'--script-opts=xreal-prefs={temp}/preferences.json,xreal-shaders={APP}/Contents/Resources,xreal-autofs=no',
        f'--watch-later-directory={temp}/watch-later',
        f'--gpu-shader-cache-dir={temp}/shaders', f'--icc-cache-dir={temp}/icc', str(movie)],
        capture_output=True, text=True, timeout=30, env={**os.environ, 'XREAL_NO_UPDATE': '1'})
    log = (temp / 'startup.log').read_text() if (temp / 'startup.log').exists() else ''
    (out / 'bundle-startup.log').write_text(result.stdout + result.stderr + log)
    if result.returncode:
        raise RuntimeError(f'Bundle startup exited {result.returncode}: {result.stdout}\n{result.stderr}\n{log}')
    assert '--gpu-api=vulkan' in log and '--gpu-context=macvk' in log, 'Branded startup defaults did not run'
    assert 'VO: [null]' in log, 'Packaged player did not decode the test movie'
    for error in ['Fatal error', 'Error parsing option', 'Lua error']:
        assert error not in log, log
(out / 'bundle-startup.json').write_text(json.dumps({
    'passed': True, 'version': plist['CFBundleShortVersionString'],
    'test': 'actual .app startup and video decode with its injected defaults',
    'physical_gpu_test': False,
}, indent=2))
print('PASS: packaged .app startup options and video decode')
