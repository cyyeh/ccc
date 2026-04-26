# trap_demo — Plan 1.C end-to-end privilege demo

A hand-crafted `--raw` binary exercising the M-mode + U-mode + ecall +
mret + CSR + UART + halt paths end-to-end.

## Flow

1. M-mode entry (offset 0x000): set mtvec=handler, mstatus.MPP=U,
   mepc=U_entry, mret.
2. U-mode (offset 0x200): ecall — traps into M-mode.
3. M-mode handler (offset 0x100): walk "trap ok\n" at 0x80000300
   writing to UART THR; then write 0 to halt MMIO.

## Rebuild

    zig build trap-demo

## End-to-end test

    zig build e2e-trap

Expected: the step passes and stdout equals `"trap ok\n"`.
