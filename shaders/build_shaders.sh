#!/usr/bin/env bash
# Compiles every GLSL shader in this dir to SPIR-V (.spv) for SDL_gpu.
# Uses glslangValidator (vendored by download-deps.sh into vendor/bin, or a
# system one via $GLSLANG). The .spv files are embedded into the Odin binary
# via #load, so they must be built before `odin build`.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
GLSLANG="${GLSLANG:-$ROOT/vendor/bin/glslangValidator}"

if ! command -v "$GLSLANG" >/dev/null 2>&1 && [ ! -x "$GLSLANG" ]; then
    echo "error: glslangValidator not found ($GLSLANG) — run ./download-deps.sh" >&2
    exit 1
fi

for src in "$DIR"/*.vert "$DIR"/*.frag; do
    [ -e "$src" ] || continue
    out="$src.spv"
    echo "  $(basename "$src") -> $(basename "$out")"
    "$GLSLANG" -V "$src" -o "$out"
done

echo "  shaders ok"
