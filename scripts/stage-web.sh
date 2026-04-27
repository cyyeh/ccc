#!/usr/bin/env bash
# Stage build artifacts into web/ for local browser testing.
# Usage:  ./scripts/stage-web.sh
# Then:   python3 -m http.server -d . 8000
# Open:   http://localhost:8000/web/
set -euo pipefail

cd "$(dirname "$0")/.."

zig build wasm

cp zig-out/web/ccc.wasm        web/ccc.wasm
cp zig-out/web/hello.elf       web/hello.elf
cp zig-out/web/snake.elf       web/snake.elf
cp zig-out/web/kernel-fs.elf   web/kernel-fs.elf
cp zig-out/web/shell-fs.img    web/shell-fs.img

echo "staged: web/ccc.wasm        ($(wc -c <web/ccc.wasm) bytes)"
echo "staged: web/hello.elf       ($(wc -c <web/hello.elf) bytes)"
echo "staged: web/snake.elf       ($(wc -c <web/snake.elf) bytes)"
echo "staged: web/kernel-fs.elf   ($(wc -c <web/kernel-fs.elf) bytes)"
echo "staged: web/shell-fs.img    ($(wc -c <web/shell-fs.img) bytes)"
