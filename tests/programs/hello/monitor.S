# Phase 1 M-mode monitor for hello.elf.
# Entry point `_start`, trap handler `trap_vector`, syscall dispatch by a7:
#   a7 == 64  (write) : for fd in {1,2}, copy a2 bytes from *a1 to UART THR.
#   a7 == 93  (exit)  : store low byte of a0 to halt MMIO (exit code).
#   otherwise         : return a0 = -ENOSYS (-38).
#
# Register conventions (RISC-V ABI):
#   sp  = x2   a0..a7 = x10..x17   t0..t6 = x5..x7,x28..x31
#
# MMIO addresses (spec §Memory layout):
#   UART THR  = 0x10000000
#   Halt MMIO = 0x00100000
#
# Stack layout: `_stack_top` symbol comes from linker.ld; monitor loads it
# into sp before doing anything that might need a stack. The U-mode payload
# is naked asm and never touches sp.

.section .text.init, "ax", @progbits
.globl _start
_start:
    # Initialise stack pointer.
    la      sp, _stack_top

    # === PMP setup (for QEMU / spec-compliant hardware) ===
    # A RISC-V M-mode environment with no PMP configuration leaves U-mode
    # with NO memory access (spec default). QEMU enforces this; our ccc
    # does not model PMP at all. To make the same hello.elf run in both,
    # install a "skip" label as mtvec, then write pmpaddr0/pmpcfg0 to
    # grant U-mode RWX on all of memory. If the target doesn't implement
    # PMP (ccc), the writes trap as illegal-instruction and jump to the
    # skip label, reaching the same post-PMP state. Same pattern riscv-tests'
    # INIT_PMP macro uses.
    la      t0, pmp_done
    csrw    mtvec, t0
    li      t0, 0x7FFFFFFF                   # NAPOT: base=0, size=2^34
    csrw    pmpaddr0, t0
    li      t0, 0x1F                         # A=NAPOT(11) | X | W | R
    csrw    pmpcfg0, t0
.balign 4
pmp_done:

    # Install the trap vector (mtvec = &trap_vector).
    la      t0, trap_vector
    csrw    mtvec, t0

    # Clear mstatus.MPP (bits 12:11): MPP = 00 = U-mode.
    # Also clear MIE (bit 3) and MPIE (bit 7). Phase 1 has no interrupts
    # delivered, so leaving MIE=0 is the honest state.
    li      t0, 0x1888                   # MIE | MPIE | MPP_MASK
    csrc    mstatus, t0

    # mepc <- U-mode entry symbol (provided by hello.zig).
    la      t0, u_entry
    csrw    mepc, t0

    # Drop to U-mode and branch to mepc.
    mret

# ---- Trap vector (M-mode) -----------------------------------------------
# Must be 4-byte aligned (direct mode, Phase 1 ignores mtvec.MODE).
.balign 4
.globl trap_vector
trap_vector:
    # Only ecall_from_u is handled; anything else hangs. We do NOT save
    # callee-saved registers because the Phase 1 U-mode payload doesn't
    # care about them either — it's naked asm that makes ecalls and halts.
    csrr    t0, mcause
    li      t1, 8                        # cause = ecall_from_u
    bne     t0, t1, unexpected_trap

    # Dispatch by a7.
    li      t0, 64
    beq     a7, t0, sys_write
    li      t0, 93
    beq     a7, t0, sys_exit

    # Unknown syscall: a0 <- -ENOSYS (-38). Then fall through to mret_resume.
    li      a0, -38
    j       mret_resume

# ---- sys_write(fd=a0, buf=a1, len=a2) -> a0 = len ----------------------
sys_write:
    # Only fd in {1,2} is supported (stdout, stderr). Phase 1's UART is
    # the same device regardless.
    li      t0, 2
    bgtu    a0, t0, sys_write_bad_fd
    beqz    a0, sys_write_bad_fd
    # Save the original length so we can return it.
    mv      t2, a2
    # t0 <- UART THR (0x10000000).
    li      t0, 0x10000000
    beqz    a2, sys_write_done
1:  lbu     t1, 0(a1)
    sb      t1, 0(t0)
    addi    a1, a1, 1
    addi    a2, a2, -1
    bnez    a2, 1b
sys_write_done:
    mv      a0, t2
    j       mret_resume
sys_write_bad_fd:
    li      a0, -9                        # -EBADF
    j       mret_resume

# ---- sys_exit(status=a0) -----------------------------------------------
sys_exit:
    # Halt MMIO: store low byte of a0 -> emulator exits with that byte.
    li      t0, 0x00100000
    sb      a0, 0(t0)
    # Should be unreachable; if halt didn't fire (shouldn't happen), spin.
1:  j       1b

# ---- Advance mepc past the 4-byte ecall and return. --------------------
mret_resume:
    csrr    t0, mepc
    addi    t0, t0, 4
    csrw    mepc, t0
    mret

# ---- Unexpected trap: hang. --------------------------------------------
unexpected_trap:
1:  j       1b
