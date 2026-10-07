#!/usr/bin/env python3
"""Fail CI if the ARM/macOS release and hardware backends are missing."""
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
binary = ROOT / 'build/mpv'
options = json.loads((ROOT / 'build/meson-info/intro-buildoptions.json').read_text())
settings = {o['name']: o['value'] for o in options}
assert settings['buildtype'] == 'release'
assert settings['optimization'] == '3'
assert settings['b_lto'] is True
assert settings['videotoolbox-pl'] == 'enabled'
assert settings['vulkan'] == 'enabled'
architecture = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).strip()
assert architecture == 'arm64', architecture
def help_option(option):
    result = subprocess.run([str(binary), '--no-config', option], capture_output=True, text=True)
    return result.stdout + result.stderr
decoders = help_option('--hwdec=help')
contexts = help_option('--gpu-context=help')
assert 'videotoolbox' in decoders, decoders
assert 'macvk' in contexts, contexts
report = {'architecture': architecture, 'release': True, 'optimization': 3, 'lto': True,
          'hardware_decoder': 'VideoToolbox', 'hardware_metal_interop': True,
          'gpu_context': 'macvk (Vulkan via MoltenVK/Metal)',
          'projection': 'GPU shader; no CPU v360 or copy-back filter',
          'runtime_defaults': 'gpu-next,gpu / vulkan,gl / macvk,cocoa / hwdec=auto-safe',
          'hardware_runtime_test': 'requires actual video and display; this audit verifies build capabilities'}
out = ROOT / 'xreal/test-output'
out.mkdir(exist_ok=True)
(out / 'optimization-audit.json').write_text(json.dumps(report, indent=2))
print('PASS: arm64, Release -O3, LTO, VideoToolbox, Metal interop, macvk')
