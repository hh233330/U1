# Catalina GitHub Actions build fix v4

## Fix 1: exact Flutter engine revision

The previous CI used the archived standalone `https://github.com/flutter/engine.git` repository and attempted to fetch:

`42d3d75a56efe1a2e9902f52dc8006099c45d937`

That revision is a merged commit in the `flutter/flutter` monorepo used by Flutter 3.41.9. The current Flutter engine setup documentation says the engine source is part of the `flutter/flutter` repository and uses `engine/scripts/standard.gclient` from that checkout.

The new script clones `flutter/flutter`, checks out the exact revision, creates a monorepo-style `.gclient`, and runs `gclient sync -D` from the Flutter repository root.

## Fix 2: permission denied after GitHub web upload

The workflow no longer executes `./scripts/build_catalina_canvaskit.sh` directly. It executes:

`bash scripts/build_catalina_canvaskit.sh`

and runs `bash -n` first. This works even when the GitHub web UI stored the script with mode 0644.

## Fix 3: Catalina CanvasKit validation

The workflow builds CanvasKit from the exact Flutter revision and then converts the resulting WASM to WAT with `wasm2wat`. Any WebAssembly SIMD opcode causes the job to fail.

The application bootstrap already selects `canvaskit-catalina/` for macOS 10.15 user agents.
