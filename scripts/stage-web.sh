#!/usr/bin/env bash
# Stage build artifacts into web/ for local browser testing.
# Usage:  ./scripts/stage-web.sh
# Then:   python3 -m http.server -d . 8000
# Open:   http://localhost:8000/web/
set -euo pipefail

cd "$(dirname "$0")/.."

zig build wasm

cp zig-out/web/ccc.wasm  web/ccc.wasm
cp zig-out/web/hello.elf web/hello.elf
cp zig-out/web/snake.elf web/snake.elf

echo "staged: web/ccc.wasm  ($(wc -c <web/ccc.wasm) bytes)"
echo "staged: web/hello.elf ($(wc -c <web/hello.elf) bytes)"
echo "staged: web/snake.elf ($(wc -c <web/snake.elf) bytes)"
