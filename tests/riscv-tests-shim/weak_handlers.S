# Weak fallback definitions for mtvec_handler / stvec_handler.
#
# Upstream's env/p/riscv_test.h declared `.weak mtvec_handler` inside
# RVTEST_CODE_BEGIN, in the same assembly unit where rv32mi tests later
# `.global mtvec_handler`. LLVM's integrated assembler rejects the
# weak→global binding change within a single file; our shim riscv_test.h
# drops the `.weak` line to keep rv32mi happy.
#
# But rv32ui/um/ua tests still reference `mtvec_handler` (via the
# fall-through `la t5, mtvec_handler; beqz t5, 1f; jr t5` in the macro's
# trap_vector) without defining it. Without a definition, ld.lld errors
# out with "undefined symbol: mtvec_handler" — even for weak references,
# because our weak_handlers.S object doesn't supply a definition.
#
# Fix: provide a WEAK ABSOLUTE DEFINITION of each symbol with value 0.
# At link time:
#   - rv32ui/um/ua: no strong definition → our weak 0 wins → trap_vector's
#     `la t5, mtvec_handler; beqz t5, 1f` takes the branch (t5 == 0) and
#     continues past the jr, matching upstream's intent.
#   - rv32mi: strong `.global mtvec_handler: ...` in the test file
#     overrides our weak 0 → handler code runs.
# Both cases link cleanly.

.weak   mtvec_handler
.equ    mtvec_handler, 0
.weak   stvec_handler
.equ    stvec_handler, 0
