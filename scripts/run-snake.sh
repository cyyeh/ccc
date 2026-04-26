#!/usr/bin/env bash
# Wrapper around `ccc --input /dev/stdin snake.elf` that puts the tty
# in raw mode so single keystrokes reach the program.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/.."

CCC="$ROOT/zig-out/bin/ccc"
SNAKE="$ROOT/zig-out/bin/snake.elf"

if [[ ! -x "$CCC" || ! -f "$SNAKE" ]]; then
  echo "missing artifacts; run 'zig build snake-elf' first" >&2
  exit 1
fi

# Save current tty settings; restore on exit (incl. Ctrl+C).
SAVED_STTY=$(stty -g)
trap 'stty "$SAVED_STTY"' EXIT INT TERM

stty -icanon -echo
exec "$CCC" --input /dev/stdin "$SNAKE"
