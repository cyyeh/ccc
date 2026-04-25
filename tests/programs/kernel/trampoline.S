# tests/programs/kernel/trampoline.S — S-mode trap entry/exit.
#
# On trap: stvec points here. sscratch holds &ptable[0] (kmain
# initializes it before sret). Since tf is the first field of Process
# (@offsetOf(Process,"tf")==0), &ptable[0] is also the TrapFrame pointer
# used throughout this file. We swap sp with sscratch to land on the tf,
# save all user GPRs at fixed offsets, then switch to the kernel stack
# and call s_trap_dispatch (Zig, in trap.zig).
#
# Return-to-user path: restore GPRs from the tf at a0, then sret. The
# last two loads handle sp and a0 — a0 has been serving as the tf base
# pointer, so it's loaded last (which discards the base pointer as
# a side effect — well-known RISC-V trampoline idiom).
#
# Offsets MUST match trap.zig's TF_* constants. comptime asserts in
# trap.zig catch drift; this .equ block mirrors the numeric values.

.equ TF_RA,   0
.equ TF_SP,   4
.equ TF_GP,   8
.equ TF_TP,  12
.equ TF_T0,  16
.equ TF_T1,  20
.equ TF_T2,  24
.equ TF_S0,  28
.equ TF_S1,  32
.equ TF_A0,  36
.equ TF_A1,  40
.equ TF_A2,  44
.equ TF_A3,  48
.equ TF_A4,  52
.equ TF_A5,  56
.equ TF_A6,  60
.equ TF_A7,  64
.equ TF_S2,  68
.equ TF_S3,  72
.equ TF_S4,  76
.equ TF_S5,  80
.equ TF_S6,  84
.equ TF_S7,  88
.equ TF_S8,  92
.equ TF_S9,  96
.equ TF_S10, 100
.equ TF_S11, 104
.equ TF_T3,  108
.equ TF_T4,  112
.equ TF_T5,  116
.equ TF_T6,  120
.equ TF_SEPC, 124

.section .text, "ax", @progbits
.balign 4
.globl s_trap_entry
s_trap_entry:
    # sp <-> sscratch: sp now = &ptable[0].tf, sscratch now = user sp.
    csrrw   sp, sscratch, sp

    # Save all GPRs except x0 and x2 (sp, which we'll save from sscratch).
    sw      x1,  TF_RA(sp)
    sw      x3,  TF_GP(sp)
    sw      x4,  TF_TP(sp)
    sw      x5,  TF_T0(sp)
    sw      x6,  TF_T1(sp)
    sw      x7,  TF_T2(sp)
    sw      x8,  TF_S0(sp)
    sw      x9,  TF_S1(sp)
    sw      x10, TF_A0(sp)
    sw      x11, TF_A1(sp)
    sw      x12, TF_A2(sp)
    sw      x13, TF_A3(sp)
    sw      x14, TF_A4(sp)
    sw      x15, TF_A5(sp)
    sw      x16, TF_A6(sp)
    sw      x17, TF_A7(sp)
    sw      x18, TF_S2(sp)
    sw      x19, TF_S3(sp)
    sw      x20, TF_S4(sp)
    sw      x21, TF_S5(sp)
    sw      x22, TF_S6(sp)
    sw      x23, TF_S7(sp)
    sw      x24, TF_S8(sp)
    sw      x25, TF_S9(sp)
    sw      x26, TF_S10(sp)
    sw      x27, TF_S11(sp)
    sw      x28, TF_T3(sp)
    sw      x29, TF_T4(sp)
    sw      x30, TF_T5(sp)
    sw      x31, TF_T6(sp)

    # User sp is in sscratch. Save it into tf.sp.
    csrr    t0, sscratch
    sw      t0, TF_SP(sp)

    # Reset sscratch = &ptable[0] so the NEXT trap has something valid
    # to swap with. @offsetOf(Process, "tf") == 0 so &ptable[0] is also
    # the TrapFrame pointer trampoline save/restore blocks work on.
    la      t0, ptable
    csrw    sscratch, t0

    # Save sepc.
    csrr    t0, sepc
    sw      t0, TF_SEPC(sp)

    # Switch sp to the kernel stack. _kstack_top is the linker symbol.
    la      sp, _kstack_top

    # Call s_trap_dispatch(tf).
    la      a0, ptable
    call    s_trap_dispatch

    # s_trap_dispatch is a C-ABI function and may clobber a0. Reload
    # it before the return path, which expects a0 = &ptable[0] (equal
    # to &ptable[0].tf since tf is the first field).
    la      a0, ptable

    # Fall through to return-to-user.

.globl s_return_to_user
s_return_to_user:
    # a0 = &ptable[0].tf (either from call return or kmain's initial jump via &ptable[0]).

    # Restore sepc first.
    lw      t0, TF_SEPC(a0)
    csrw    sepc, t0

    # Restore every GPR except a0 and sp. Order doesn't matter except
    # that a0 comes last.
    lw      x1,  TF_RA(a0)
    lw      x3,  TF_GP(a0)
    lw      x4,  TF_TP(a0)
    lw      x5,  TF_T0(a0)
    lw      x6,  TF_T1(a0)
    lw      x7,  TF_T2(a0)
    lw      x8,  TF_S0(a0)
    lw      x9,  TF_S1(a0)
    lw      x11, TF_A1(a0)
    lw      x12, TF_A2(a0)
    lw      x13, TF_A3(a0)
    lw      x14, TF_A4(a0)
    lw      x15, TF_A5(a0)
    lw      x16, TF_A6(a0)
    lw      x17, TF_A7(a0)
    lw      x18, TF_S2(a0)
    lw      x19, TF_S3(a0)
    lw      x20, TF_S4(a0)
    lw      x21, TF_S5(a0)
    lw      x22, TF_S6(a0)
    lw      x23, TF_S7(a0)
    lw      x24, TF_S8(a0)
    lw      x25, TF_S9(a0)
    lw      x26, TF_S10(a0)
    lw      x27, TF_S11(a0)
    lw      x28, TF_T3(a0)
    lw      x29, TF_T4(a0)
    lw      x30, TF_T5(a0)
    lw      x31, TF_T6(a0)

    # Restore sp (from tf.sp — the user's sp saved on entry). a0 is
    # still the tf pointer here; the next load reuses it.
    lw      x2,  TF_SP(a0)

    # Last: restore a0 (user's saved a0 value). This overwrites the tf
    # base pointer, but we don't need it after this.
    lw      x10, TF_A0(a0)

    sret
