#!/usr/bin/env bash
set -euo pipefail

# Build a scalar CanvasKit from the exact Flutter 3.41.9 engine revision used by
# this Orca Web bundle. IMPORTANT: since late 2024 Flutter Engine is part of the
# flutter/flutter monorepo; the old standalone flutter/engine repo is archived
# and does not contain this revision.
ENGINE_REV="42d3d75a56efe1a2e9902f52dc8006099c45d937"
ENGINE_ROOT="${1:-${RUNNER_TEMP:-$PWD}/flutter-engine-${ENGINE_REV:0:12}}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$REPO_ROOT/resources/web/flutter_web/canvaskit-catalina"
DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-${RUNNER_TEMP:-$PWD}/depot_tools}"

export GIT_TERMINAL_PROMPT=0
export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-$RUNNER_TEMP/flutter-gitconfig}"

command -v git >/dev/null
command -v python3 >/dev/null
command -v curl >/dev/null

printf '%s\n' '== Catalina scalar CanvasKit build ==' 
printf 'Flutter monorepo revision: %s\n' "$ENGINE_REV"
printf 'Workspace: %s\n' "$ENGINE_ROOT"
printf 'Output: %s\n' "$OUT_DIR"

# depot_tools supplies gclient and the rest of the Chromium checkout tooling.
if ! command -v gclient >/dev/null 2>&1; then
  if [[ ! -x "$DEPOT_TOOLS_DIR/gclient" ]]; then
    rm -rf "$DEPOT_TOOLS_DIR"
    git clone --depth 1 --filter=blob:none \
      https://chromium.googlesource.com/chromium/tools/depot_tools.git \
      "$DEPOT_TOOLS_DIR"
  fi
  export PATH="$DEPOT_TOOLS_DIR:$PATH"
fi

command -v gclient >/dev/null

# Checkout the Flutter monorepo at the exact merged engine revision. This is the
# critical fix for the previous error:
#   fatal: remote error: upload-pack: not our ref <ENGINE_REV>
# That happened because the script cloned the archived standalone
# github.com/flutter/engine repository. The revision now lives in
# github.com/flutter/flutter.
if [[ ! -d "$ENGINE_ROOT/.git" ]]; then
  rm -rf "$ENGINE_ROOT"
  mkdir -p "$(dirname "$ENGINE_ROOT")"
  git clone --filter=blob:none --no-checkout --no-tags \
    https://github.com/flutter/flutter.git \
    "$ENGINE_ROOT"
fi

git -C "$ENGINE_ROOT" fetch --no-tags --depth 1 origin "$ENGINE_REV"
git -C "$ENGINE_ROOT" checkout --force --detach "$ENGINE_REV"

ACTUAL_REV="$(git -C "$ENGINE_ROOT" rev-parse HEAD)"
[[ "$ACTUAL_REV" == "$ENGINE_REV" ]] || {
  echo "ERROR: Flutter checkout is $ACTUAL_REV, expected $ENGINE_REV" >&2
  exit 10
}

# Use the .gclient template shipped by this exact Flutter revision. The current
# standard template uses name='.' because the engine is inside the monorepo.
cat > "$ENGINE_ROOT/.gclient" <<'EOF_GCLIENT'
solutions = [
  {
    "custom_deps": {},
    "deps_file": "DEPS",
    "managed": False,
    "name": ".",
    "safesync_url": "",
    "url": "https://github.com/flutter/flutter.git",
    "custom_vars": {
      "download_emsdk": True,
    },
  },
]
EOF_GCLIENT

cd "$ENGINE_ROOT"
# First run is deliberately shallow: this cuts dependency history while keeping
# the exact DEPS revisions required by the checked-out Flutter engine.
gclient sync --no-history -D -j2

FLUTTER_ENGINE_DIR="$ENGINE_ROOT/engine/src/flutter"
[[ -d "$FLUTTER_ENGINE_DIR" ]] || {
  echo "ERROR: expected engine source at $FLUTTER_ENGINE_DIR" >&2
  exit 11
}

# The web engine tooling is in the checked-out engine source.
export PATH="$FLUTTER_ENGINE_DIR/lib/web_ui/dev:$FLUTTER_ENGINE_DIR/bin:$DEPOT_TOOLS_DIR:$PATH"
command -v felt

# Keep the CanvasKit build scalar. The Flutter/Skia CanvasKit compile script
# only enables WebAssembly SIMD when the build is explicitly requested with a
# SIMD variant, so do NOT append a 'simd' build argument here. Also prevent
# toolchain-side automatic vectorization from sneaking SIMD back in.
export EMCC_CFLAGS="${EMCC_CFLAGS:-} -fno-vectorize -fno-slp-vectorize"
export EMXX_CFLAGS="${EMXX_CFLAGS:-} -fno-vectorize -fno-slp-vectorize"

cd "$FLUTTER_ENGINE_DIR/lib/web_ui"
rm -rf "$ENGINE_ROOT/engine/src/out/wasm_debug" \
       "$ENGINE_ROOT/engine/src/out/wasm_profile" \
       "$ENGINE_ROOT/engine/src/out/wasm_release"

felt build canvaskit

WASM=""
JS=""
for candidate in \
  "$ENGINE_ROOT/engine/src/out/wasm_debug/canvaskit.wasm" \
  "$ENGINE_ROOT/engine/src/out/wasm_profile/canvaskit.wasm" \
  "$ENGINE_ROOT/engine/src/out/wasm_release/canvaskit.wasm"
do
  if [[ -s "$candidate" ]]; then
    WASM="$candidate"
    break
  fi
done

for candidate in \
  "$ENGINE_ROOT/engine/src/out/wasm_debug/canvaskit.js" \
  "$ENGINE_ROOT/engine/src/out/wasm_profile/canvaskit.js" \
  "$ENGINE_ROOT/engine/src/out/wasm_release/canvaskit.js"
do
  if [[ -s "$candidate" ]]; then
    JS="$candidate"
    break
  fi
done

if [[ -z "$WASM" || -z "$JS" ]]; then
  echo "ERROR: CanvasKit artifacts were not found." >&2
  find "$ENGINE_ROOT/engine/src/out" -type f \
    \( -name 'canvaskit.wasm' -o -name 'canvaskit.js' \) -print | head -100 >&2 || true
  exit 12
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
cp "$WASM" "$OUT_DIR/canvaskit.wasm"
cp "$JS" "$OUT_DIR/canvaskit.js"

# Basic artifact sanity checks.
python3 - "$OUT_DIR/canvaskit.wasm" <<'PY'
from pathlib import Path
import struct, sys
p = Path(sys.argv[1])
b = p.read_bytes()
assert b[:4] == b'\\x00asm', 'not a WebAssembly module'
assert len(b) > 1024 * 1024, 'CanvasKit WASM unexpectedly small'
print(f'CanvasKit WASM bytes: {len(b):,}')
PY

printf 'Generated CanvasKit assets:\n'
ls -lh "$OUT_DIR/canvaskit.wasm" "$OUT_DIR/canvaskit.js"
printf 'Exact engine revision verified: %s\n' "$ACTUAL_REV"
printf '%s\n' 'Catalina scalar CanvasKit build finished.'
