#!/usr/bin/env bash
# Builds the strata tool (src/tool) -> tool/strata: the headless CLI
# (eval/dump/topo, M1–M2) and the M3 editor shell (SDL3_GPU + ImGui) in one
# binary — `strata edit <doc>` opens the editor. Mirrors dymeta-tool/build.sh:
# vendored static SDL3 + prebuilt imgui lib + embedded SPIR-V shaders
# (vendor/ is copied from dymeta-tool; no download step of its own yet).
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOL_DIR="$PROJECT_DIR/tool"
SDL_PREFIX="$PROJECT_DIR/vendor/sdl3"

if [ ! -e "$SDL_PREFIX/lib/pkgconfig/sdl3.pc" ] && [ ! -e "$SDL_PREFIX/lib64/pkgconfig/sdl3.pc" ]; then
    echo "error: vendored SDL3 missing — copy vendor/ from dymeta-tool" >&2
    exit 1
fi
if [ ! -f "$PROJECT_DIR/vendor/odin-imgui/imgui_linux_x64.a" ]; then
    echo "error: imgui static lib missing — copy vendor/ from dymeta-tool" >&2
    exit 1
fi

# Static SDL3: the vendor:sdl3 binding emits -lSDL3, resolving to our vendored
# libSDL3.a (no .so installed). Append SDL's private static deps + its -L path
# from pkg-config (the source of truth). --define-prefix derives sdl3.pc's
# `prefix` from the file's on-disk location so moving the project dir doesn't
# strand -L at a stale path.
export PKG_CONFIG_PATH="$SDL_PREFIX/lib/pkgconfig:$SDL_PREFIX/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
SDL_LINK="$(pkg-config --define-prefix --static --libs sdl3 | tr ' ' '\n' | grep -vx -- '-lSDL3' | tr '\n' ' ')"

# Shaders are #load'd into the binary, so compile them up front.
echo "==> compiling shaders"
GLSLANG="${GLSLANG:-$PROJECT_DIR/vendor/bin/glslangValidator}" \
    "$PROJECT_DIR/shaders/build_shaders.sh"

echo "==> checking library packages"
odin check "$PROJECT_DIR/src/engine" -no-entry-point

echo "==> Tool build: src/tool -> $TOOL_DIR"
mkdir -p "$TOOL_DIR"
odin build "$PROJECT_DIR/src/tool" -out:"$TOOL_DIR/strata" -o:speed \
    -extra-linker-flags:"$SDL_LINK"
echo "==> Tool done: $TOOL_DIR/strata"
