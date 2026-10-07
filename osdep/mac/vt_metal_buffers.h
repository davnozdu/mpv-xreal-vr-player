#pragma once

#include <stdbool.h>

// Make VideoToolbox sessions created afterwards output Metal-compatible
// buffers without OpenGL compatibility. Only valid for non-GL interops.
void mp_vt_set_metal_buffers(bool enable);
