/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

// FFmpeg always asks VideoToolbox for OpenGL-compatible IOSurfaces on macOS.
// On Apple Silicon this forces a slower output path: an 8K HEVC stream decodes
// at ~45 fps instead of ~120 fps on an M2 Pro. The Vulkan/Metal interop only
// needs Metal-compatible buffers, so it requests them through this hook.
//
// dyld applies __interpose only from loaded libraries, never from the main
// executable, hence this file is built as a separate dylib.

#include <stdatomic.h>
#include <stdbool.h>

#include <VideoToolbox/VideoToolbox.h>

#include "vt_metal_buffers.h"

static atomic_bool metal_buffers;

void mp_vt_set_metal_buffers(bool enable)
{
    atomic_store(&metal_buffers, enable);
}

static OSStatus create_session(CFAllocatorRef allocator,
                               CMVideoFormatDescriptionRef format,
                               CFDictionaryRef decoder_spec,
                               CFDictionaryRef buffer_attrs,
                               const VTDecompressionOutputCallbackRecord *callback,
                               VTDecompressionSessionRef *session)
{
    CFMutableDictionaryRef attrs = NULL;
    if (buffer_attrs && atomic_load(&metal_buffers)) {
        attrs = CFDictionaryCreateMutableCopy(NULL, 0, buffer_attrs);
        if (attrs) {
            CFDictionaryRemoveValue(attrs, kCVPixelBufferIOSurfaceOpenGLTextureCompatibilityKey);
            CFDictionarySetValue(attrs, kCVPixelBufferMetalCompatibilityKey, kCFBooleanTrue);
        }
    }
    OSStatus ret = VTDecompressionSessionCreate(allocator, format, decoder_spec,
                                                attrs ? attrs : buffer_attrs,
                                                callback, session);
    if (attrs)
        CFRelease(attrs);
    return ret;
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement, *original; } interpose = {
    (const void *)create_session, (const void *)VTDecompressionSessionCreate,
};
