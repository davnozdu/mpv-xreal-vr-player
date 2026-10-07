#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BREW_PREFIX="$(brew --prefix)"
export PKG_CONFIG_PATH="$BREW_PREFIX/lib/pkgconfig:$BREW_PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
for dependency in ffmpeg libass libplacebo luajit zlib bzip2 vulkan-loader shaderc; do
    export PKG_CONFIG_PATH="$BREW_PREFIX/opt/$dependency/lib/pkgconfig:$PKG_CONFIG_PATH"
done
meson setup build --buildtype=release -Db_lto=true -Dlibmpv=false -Dtests=true \
    -Dmanpage-build=disabled -Djavascript=disabled -Dlibcurl=disabled \
    -Dvapoursynth=disabled -Dlibarchive=disabled -Dlibbluray=disabled \
    -Dvulkan=enabled -Dshaderc=disabled -Dvideotoolbox-pl=enabled -Dgl-cocoa=enabled -Dlua=luajit \
    "-Dswift-flags=-module-cache-path $PWD/build/module-cache"
meson compile -C build -j 3
meson test -C build --print-errorlogs
python3 xreal/test_player.py build/mpv
python3 xreal/audit.py
python3 xreal/package.py
