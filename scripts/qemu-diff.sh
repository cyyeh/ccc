#!/usr/bin/env bash
# qemu-diff.sh — diff per-instruction traces from our emulator and QEMU.
#
# Usage: scripts/qemu-diff.sh <file.elf> [max-instructions]
#
# Dependencies:
#   - qemu-system-riscv32 (brew install qemu / apt install qemu-system-misc)
#   - zig (already required for the project)
#
# Output:
#   stdout = nothing if traces match up to max-instructions
#   stderr = diagnostic info; exit 1 on divergence (with diff output)
#
# Known structural (non-bug) divergences on Phase 1 hello.elf:
#
#   1. Boot ROM (0x00001000-0x00001014) — QEMU runs the virt board's reset
#      bootstrap before jumping to 0x80000000. Our emulator sets PC=e_entry
#      directly from the ELF loader (spec §Boot model). Phase 1 doesn't
#      populate the boot ROM.
#
#   2. PMP writes (0x80000020, 0x80000024) — our monitor writes pmpaddr0
#      and pmpcfg0 so U-mode has memory access. QEMU executes the writes;
#      our emulator doesn't implement PMP CSRs, so they trap and the
#      monitor's trap-skip label jumps past them. Functionally equivalent.
#
#   3. Post-halt (anything after 0x800000b0 lui) — our halt MMIO terminates
#      ccc; QEMU doesn't know the MMIO, so it continues into the monitor's
#      `j self` safety loop. ccc naturally stops tracing; QEMU keeps going.
#
# For workloads WITHOUT these divergences (e.g., Phase 2+ kernels that do
# their own PMP setup and use QEMU's exit semantics), the script should
# produce a clean match.

set -euo pipefail

ELF="${1:-}"
MAX="${2:-1000}"

if [[ -z "$ELF" ]]; then
    echo "usage: $0 <file.elf> [max-instructions]" >&2
    exit 2
fi

if [[ ! -f "$ELF" ]]; then
    echo "error: $ELF not found" >&2
    exit 2
fi

if ! command -v qemu-system-riscv32 >/dev/null 2>&1; then
    echo "error: qemu-system-riscv32 not found on PATH" >&2
    echo "       macOS: brew install qemu" >&2
    echo "       Linux: apt install qemu-system-misc (or equivalent)" >&2
    exit 2
fi

# Build the emulator if needed.
if [[ ! -x ./zig-out/bin/ccc ]]; then
    echo "building ccc..." >&2
    zig build
fi

TMPDIR_="$(mktemp -d -t ccc-qemu-diff.XXXXXX)"
trap 'rm -rf "$TMPDIR_"' EXIT

QEMU_RAW="$TMPDIR_/qemu.raw"
CCC_RAW="$TMPDIR_/ccc.raw"
QEMU_CANON="$TMPDIR_/qemu.canon"
CCC_CANON="$TMPDIR_/ccc.canon"

echo "running under qemu-system-riscv32..." >&2
# QEMU's -d in_asm logs the instruction as it's decoded; one-insn-per-tb
# forces one TB per instruction so the logs line up with our per-instruction
# trace. QEMU 10+ removed the standalone `-singlestep` flag in favour of the
# `-accel tcg,one-insn-per-tb=on` form used here.
# macOS has no GNU `timeout`, so we run qemu in the background and kill it
# from a watchdog subshell after QEMU_TIMEOUT seconds. Our halt MMIO isn't
# known to QEMU, so QEMU keeps running past the "end of program" — the
# watchdog is how we stop.
QEMU_TIMEOUT="${QEMU_TIMEOUT:-30}"
qemu-system-riscv32 \
    -machine virt \
    -bios none \
    -kernel "$ELF" \
    -nographic \
    -accel tcg,one-insn-per-tb=on \
    -d in_asm \
    -D "$QEMU_RAW" \
    -no-reboot \
    > /dev/null 2>&1 &
QEMU_PID=$!
( sleep "$QEMU_TIMEOUT" && kill -9 "$QEMU_PID" 2>/dev/null ) &
WATCHDOG_PID=$!
wait "$QEMU_PID" 2>/dev/null || true    # ignore non-zero from halt MMIO / kill
kill "$WATCHDOG_PID" 2>/dev/null || true
wait "$WATCHDOG_PID" 2>/dev/null || true

echo "running under ccc --trace..." >&2
./zig-out/bin/ccc --trace "$ELF" 2>"$CCC_RAW" >/dev/null || true

# --- Canonicalize ---
# QEMU's `-d in_asm` lines look like:
#   ----------------
#   IN:
#   0x80000000:  00000297          auipc           t0,0
# Our emulator prints one line per step, format from src/trace.zig:
#   PC=0x80000000 RAW=0x00000297  auipc  [x5 := 0x80000000]
#
# Reduce both to:  PCHEX opname
# which catches PC and mnemonic divergences. Register-state diff would need
# format-aware parsing (our trace prints rd only; QEMU -d cpu prints all);
# extend canonicalization if needed for a specific bug hunt.

canon_qemu() {
    # QEMU `-d in_asm` lines look like:
    #   0x80000000:  00000297          auipc           t0,0
    # Emit:  "80000000 00000297" (PC + raw instruction word, lowercased).
    # We canonicalize on RAW bytes, not mnemonic — otherwise pseudo-instruction
    # rendering (bltu vs bgtu, beq vs beqz) falsely trips the diff.
    grep -E '^0x[0-9a-fA-F]+: ' "$1" \
        | awk '{
            pc = $1;
            sub(/^0x/, "", pc);
            sub(/:$/, "", pc);
            printf "%s %s\n", tolower(pc), tolower($2);
          }' \
        | dedupe_by_pc "$MAX"
}

canon_ccc() {
    # ccc --trace lines look like:
    #   PC=0x80000000 RAW=0x00000297  auipc  [x5 := 0x80000000]
    # Emit:  "80000000 00000297"
    awk '{
            pc = $1; sub(/^PC=0x/, "", pc);
            raw = $2; sub(/^RAW=0x/, "", raw);
            printf "%s %s\n", tolower(pc), tolower(raw);
          }' "$1" \
        | dedupe_by_pc "$MAX"
}

# Keep only the FIRST occurrence of each PC (matches QEMU's TB-cache
# behaviour: each instruction is translated once, logged once, even if
# executed thousands of times in a loop). Without this, ccc's full
# per-execution trace flood-overwhelms QEMU's one-shot trace and every
# loop shows up as a divergence.
dedupe_by_pc() {
    local max="$1"
    awk -v max="$max" '
        !seen[$1]++ {
            print
            count++
            if (count >= max) exit
        }
    '
}

canon_qemu "$QEMU_RAW" > "$QEMU_CANON"
canon_ccc  "$CCC_RAW"  > "$CCC_CANON"

QEMU_LINES=$(wc -l < "$QEMU_CANON")
CCC_LINES=$(wc -l < "$CCC_CANON")
echo "qemu traced $QEMU_LINES instructions; ccc traced $CCC_LINES" >&2

if diff -u "$QEMU_CANON" "$CCC_CANON" > "$TMPDIR_/diff" ; then
    echo "OK: traces match over $QEMU_LINES instructions" >&2
    exit 0
fi

echo "DIVERGENCE:" >&2
cat "$TMPDIR_/diff"
exit 1
