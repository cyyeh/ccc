#!/usr/bin/env bash
# qemu-diff-kernel.sh — diff per-instruction traces of kernel.elf between
# our emulator and qemu-system-riscv32. Thin wrapper over qemu-diff.sh:
# builds the kernel first, then delegates to the Phase 1 harness.
#
# Usage:
#   scripts/qemu-diff-kernel.sh [max-instructions]
#
# Known structural (non-bug) divergences, in addition to the ones noted
# in qemu-diff.sh:
#
#   * Async timer interrupts — our emulator and QEMU have independent
#     wall clocks; MTIP will fire at different moments, causing the
#     post-first-tick traces to diverge. For debug of the synchronous
#     M→S drop and the user entry, pass a low max-instructions (e.g.,
#     200) to halt before the first TIMESLICE expires.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "building kernel.elf..." >&2
zig build kernel

exec "$SCRIPT_DIR/qemu-diff.sh" zig-out/bin/kernel.elf "$@"
