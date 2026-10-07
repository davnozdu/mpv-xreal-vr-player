#!/usr/bin/env python3
"""Compile the production shader with real Vulkan GLSL tools before shipping."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
shader = (ROOT / 'xreal/resources/xreal.glsl').read_text()
# PARAM bodies contain default values for mpv's preprocessor, not GLSL.
shader = shader[shader.index('//!HOOK MAIN'):]
header = '''#version 450
layout(location=0) in vec2 texcoord;
layout(location=0) out vec4 color;
layout(binding=0) uniform sampler2D source;
layout(binding=1) uniform Parameters {
    int xreal_mode;
    int xreal_mono;
    float eye_aspect;
    int swap_eyes;
    float yaw;
    float pitch;
    float fov;
};
#define HOOKED_pos texcoord
#define HOOKED_size vec2(8192.0, 4096.0)
vec4 HOOKED_tex(vec2 position) { return texture(source, position); }
'''
with tempfile.TemporaryDirectory(prefix='xreal-glsl-', dir='/tmp') as directory:
    path = Path(directory) / 'xreal.frag'
    path.write_text(header + shader + '\nvoid main() { color = hook(); }\n')
    subprocess.run(['glslc', '-fshader-stage=frag', '-O', str(path), '-o', str(path.with_suffix('.spv'))], check=True)
out = ROOT / 'xreal/test-output'
out.mkdir(exist_ok=True)
(out / 'shader-validation.json').write_text(json.dumps({'passed': True, 'compiler': 'glslc',
    'target': 'Vulkan SPIR-V', 'shader': 'xreal.glsl', 'runtime_gpu_test': False}, indent=2))
print('PASS: stereo projection GLSL compiles to Vulkan SPIR-V')
