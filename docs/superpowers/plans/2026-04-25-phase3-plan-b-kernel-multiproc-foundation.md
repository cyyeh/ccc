# Phase 3 Plan B — Kernel multi-process foundation (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Phase 2's single-process kernel with a real multi-process foundation: a free-list page allocator, a static `ptable[NPROC=16]` with full per-process state (pgdir, kernel stack, saved kernel context), a round-robin scheduler that runs on its own kernel stack and `swtch`-es into runnable processes, a kernel-side ELF32 loader, and the `getpid` / `sbrk` / `yield` syscalls. Phase 2's `userprog.bin` becomes `userprog.elf` (embedded directly, no objcopy flatten) and runs as PID 1 through the new ELF loader and scheduler. A new `kernel-multi.elf` build target embeds a second user ELF (`userprog2.elf`); its `kmain` hand-creates PID 1 + PID 2 and the round-robin scheduler interleaves them. The headline acceptance is two e2e tests: `e2e-kernel` (Phase 2's regression — PID 1 prints `hello from u-mode\nticks observed: N\n`, exits 0) keeps passing unchanged, and the new `e2e-multiproc-stub` boots two ELFs as PID 1 + PID 2, both print, both exit, emulator returns 0.

**Architecture:** The Phase 2 globals (`the_process`, `_kstack_top` in trampoline, single bump allocator) are replaced piece-by-piece. `page_alloc.zig` becomes a free-list: `init` walks `[heap_start, RAM_END)` linking every 4 KB page into a singly-linked free list whose nodes live in the pages themselves; `alloc()` pops, `free(pa)` pushes, `freeCount()` reports outstanding capacity. A new `Context` extern struct holds the 13 callee-saved kernel registers (`ra`, `sp`, `s0..s11`); `swtch.S`'s 30-line asm primitive saves the outgoing context to one pointer and restores the incoming context from another, returning into the new caller's `ra`. `Process` grows `pid`, `parent` (for 3.C), `chan` (for 3.D), `kstack` (page-allocator-owned 4 KB), `kstack_top`, and `context`; the `tf`-at-offset-0 invariant survives so trampoline.S only changes which Process the offsets reach into. A new singleton `Cpu` (one hart) holds `cur: ?*Process` and `sched_context: Context` plus a 4 KB scheduler kernel stack; `scheduler()` runs on that stack and never returns — it loops scanning `ptable` for `Runnable` and calls `swtch(&cpu.sched_context, &p.context)`. Yield, sleep (deferred to 3.D), and timer preemption all funnel through `proc.sched()` which in turn calls `swtch(&cur.context, &cpu.sched_context)`. New processes start at a Zig stub `forkret` (set as their initial `context.ra`); forkret tail-calls `s_return_to_user(&cur.tf)` to drop into U-mode. The kernel-side ELF32 loader (`elfload.zig`) reads `[*]const u8` containing an ELF, validates the header, walks `PT_LOAD` program headers, and for each segment allocates `ceil(p_memsz / 4 KB)` zeroed frames, copies `p_filesz` bytes from the embed, and installs `vm.mapPage(pgdir, va, pa, USER_RWX)` at every leaf — same flag set Phase 2's `mapUser` used. The build now skips the objcopy flatten step for `userprog.elf` (still produced as an ELF by the existing user_linker.ld) and embeds it directly via the same `@embedFile` stub mechanism Plan 2.D introduced. A second `userprog2.zig` (prints `[2] hello from u-mode 2\n` then exits) is built into `userprog2.elf` and embedded alongside. `boot_config.zig` is a tiny WriteFiles-generated stub that exposes `MULTI_PROC: bool` and the embed slices; two kernel ELF builds (`kernel.elf` MULTI_PROC=false, `kernel-multi.elf` MULTI_PROC=true) consume the same kmain/proc/sched code with comptime branching on `MULTI_PROC`. The trampoline's `csrw sscratch` after the GPR save dance becomes `csrw sscratch, sp` (sp already equals `&cur_proc` since `tf` is offset 0 and the swap put `&cur_proc` in sp); the kernel-stack switch becomes `lw sp, KSTACK_TOP_OFFSET(sp)` reading from the Process struct. The SSI ticker handler increments `cur.ticks_observed` (not `the_process.ticks_observed`) and calls `proc.sched()` so the timer drives preemption. `sysExit` halts the emulator only when `cur.pid == 1` (so the multi-proc test can have PID 2 finish before PID 1 prints `ticks observed: N\n` and halts); a follow-up Plan 3.C will replace this with a proper "no runnable processes left" condition.

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`), no new external dependencies. Asm targets RV32IMA. The kernel-side ELF loader uses `std.mem.readInt(u32, …, .little)` for header parsing — same pattern as `src/elf.zig`. Cross-compilation reuses the Phase 2 `rv_target` ResolvedTarget. Verifier `multiproc_verify_e2e.zig` follows the Plan 2.D `verify_e2e.zig` pattern (host-compiled, spawn ccc, regex stdout).

**Spec reference:** `docs/superpowers/specs/2026-04-25-phase3-multi-process-os-design.md` — Plan 3.B covers spec §Architecture (kernel modules `page_alloc`, `proc`, `sched`, `vm.copy_uvm` precursor (we land `mapPgdir` only; `copy_uvm` lands in 3.C), `elfload`), §Process model — `Process` struct (Phase 3.B subset: `pid`, `parent`, `state`, `satp`, `pgdir`, `sz`, `kstack`, `kstack_top`, `tf`, `context`, `ticks_observed`; the FS/file/wait fields land in 3.C/3.D), §Scheduler (round-robin with separate `cpu.sched_context`), §`swtch` primitive (30 lines of asm), §Static-table policy (`NPROC=16`), §Syscall surface (rows for `getpid` / `sbrk` / `yield`), and §Implementation plan decomposition entry **3.B**. The xv6 source (Cox/Kaashoek/Morris MIT) is the authoritative reference for the trampoline ↔ scheduler ↔ swtch dance — when this plan and that source disagree, the spec is right.

**Plan 3.B scope (subset of Phase 3 spec):**

- **`page_alloc.zig` (rewrite)** — Free-list allocator over `[heap_start, RAM_END)`:
  - **Storage:** a single `head: u32` (PA of first free page; 0 = empty).
  - **Layout:** Each free page contains a `*next` pointer at offset 0 (the rest is unused while free). Allocation pops the head and zero-fills before return; free pushes the page back.
  - **Public API (replaces Phase 2's `allocZeroPage`/`heapPos`):**
    - `pub fn init() void` — link every 4KB-aligned page in `[heap_start, RAM_END)` into the free list.
    - `pub fn alloc() ?u32` — pop head; return zeroed page PA, or `null` when empty.
    - `pub fn free(pa: u32) void` — push `pa` onto head. Panics on misaligned `pa` or `pa` outside `[heap_start, RAM_END)`.
    - `pub fn freeCount() u32` — count of pages currently free (debug aid).
    - `pub fn heapStart() u32` — the lowest PA the allocator manages (used by `vm.mapKernelAndMmio`).
  - **Compatibility shim:** A trivial `pub fn allocZeroPage() u32` helper that calls `alloc()` and panics on null, kept so existing call sites in `vm.zig` migrate in a follow-up step.

- **`Context` struct + `swtch.S`** — saved kernel callee-saved registers + the asm switch primitive:
  - **Layout** (52 bytes):
    ```
    ra, sp, s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11
    ```
  - **Asm:** `swtch(old: *Context, new: *Context)`. Stores callee-saved into `*old`; loads callee-saved from `*new`. Returns by jumping to `new.ra`.

- **`Process` struct extension + `ptable`:**
  - **Fields landing in 3.B:**
    ```
    pid: u32                  // PID; 0 means Unused slot
    parent: ?*Process         // null in 3.B; populated in 3.C
    state: State              // Unused | Embryo | Sleeping | Runnable | Running | Zombie
    satp: u32                 // SATP_MODE_SV32 | (pgdir_pa >> 12)
    pgdir: u32                // PA of root page table
    sz: u32                   // user heap high-water-mark (for sbrk)
    kstack: u32               // PA of the 4 KB kernel stack page
    kstack_top: u32           // VA == PA of kernel-stack top (one past last valid byte)
    tf: TrapFrame             // offset 0 — trampoline depends on this
    context: Context          // saved kernel callee-saved regs (for swtch)
    chan: u32                 // 0 in 3.B; populated in 3.D
    killed: u32               // 0 in 3.B; populated in 3.C (kill flag for ^C)
    xstate: i32               // exit status; 0 in 3.B
    ticks_observed: u32       // SSI handler increments this
    name: [16]u8              // debug aid; "init" for PID 1
    ```
  - **Field order:** `tf` must remain at offset 0 (trampoline.S reads at offsets 0..127 from the Process pointer). All later fields can go in any order within the struct; we lock the layout with comptime asserts.
  - **Static table:** `pub var ptable: [NPROC]Process = undefined;` in `.bss`. Zeroed by boot's BSS-zero loop.
  - **State enum:** `Unused = 0, Embryo = 1, Sleeping = 2, Runnable = 3, Running = 4, Zombie = 5` (xv6 ordering, 0 = Unused so zeroed-BSS slots are immediately reusable).

- **`proc.alloc()` / `proc.free()`:**
  - **alloc**: scan ptable, find first Unused slot, set `state = Embryo`, allocate kstack (one 4 KB page), pre-fill `context.ra = forkret` and `context.sp = kstack_top - 16` (16-byte alignment for first call frame), return `*Process`. If table full or page_alloc empty, return null.
  - **free**: tear down user pgdir (page_alloc free every leaf user page + every L0 table + the L1 table), free kstack, zero the entire Process record, set `state = Unused`. (User-space teardown deferred to 3.C; for 3.B we just free kstack and pgdir L1 — multi-proc tests don't exercise the recycle path.)

- **`Cpu` struct (singleton):**
  - **Fields:** `cur: ?*Process`, `sched_context: Context`, `sched_stack_top: u32` (the 4 KB scheduler kernel stack).
  - **Storage:** `pub var cpu: Cpu = undefined;` in `.bss`. Initialized by `kmain` before scheduler entry.
  - **Why a separate scheduler stack:** A process can sleep mid-syscall (3.D); the scheduler needs to resume on a stack that isn't owned by any sleeping process. We land the stack in 3.B even though nothing sleeps yet so that 3.D's sleep machinery has no extra moving parts.

- **Trampoline rework:**
  - **Old (Phase 2):** `la t0, the_process; csrw sscratch, t0` and `la sp, _kstack_top`.
  - **New:** After `csrrw sp, sscratch, sp` makes `sp == &cur_proc` (since `tf` is offset 0), the trampoline issues `csrw sscratch, sp` (re-arm sscratch for next trap with the same Process pointer) and `lw sp, KSTACK_TOP_OFFSET(sp)` (load kstack_top from the Process struct).
  - **Symbol changes:** `the_process` is no longer a public symbol; trampoline reads everything from sscratch + offsets. The `KSTACK_TOP_OFFSET` constant is mirrored as a `.equ` in trampoline.S and as a `pub const` in `proc.zig`, with a comptime assert tying them together.

- **`forkret` — initial-entry stub:**
  - **Signature:** `export fn forkret() callconv(.c) noreturn`.
  - **Body:** `s_return_to_user(&proc.cpu.cur.?.tf)`. (3.C will add lock release here when locking arrives.)
  - **Why:** A freshly-allocated process has no s_trap_dispatch frame to return into; it needs an entry point that knows how to drop into U-mode. `proc.alloc()` sets `context.ra = forkret` so the first `swtch` into the new process lands here.

- **`scheduler()`:**
  - Runs forever on `cpu.sched_stack_top`. Loop: scan `ptable[0..NPROC]` for the first `Runnable`; if found, set `cur = p`, `p.state = Running`, write `satp` from `p.satp`, `sfence.vma`, call `swtch(&cpu.sched_context, &p.context)`. On return (process yielded back), set `cur = null`. If no runnable, just loop back (a `wfi` here is safe but not required for 3.B since the timer keeps poking us).
  - **No-runnable halt:** when every proc is `Unused` or `Zombie`, write `0x00100000 = 0` to halt MMIO and exit. This is the "all done" signal for the multi-proc test.

- **`yield` syscall (replacing Phase 2 stub):**
  - Mark `cur.state = Runnable`, call `swtch(&cur.context, &cpu.sched_context)`. On return, sched has put us back to Running.

- **Timer-driven preemption:**
  - SSI handler in `trap.zig` increments `cur.ticks_observed` and calls `proc.yield()` (same as the syscall, but we factor it into `proc.zig`). Phase 2's "schedule()" no-op is removed.

- **Kernel ELF loader (`elfload.zig`):**
  - **Signature:** `pub fn load(blob: []const u8, pgdir_pa: u32) ElfError!u32` — returns entry PC (`e_entry`), or an error.
  - **Steps:**
    1. Validate ELF header: magic `\x7FELF`, class=32, data=LSB, machine=RISCV (0xF3), type=EXEC.
    2. For each `PT_LOAD` program header: `ceil(p_memsz / 4 KB)` pages from page_alloc; copy `p_filesz` bytes from the blob; map at `p_vaddr` with `USER_RWX` (we don't honor segment-level permissions in 3.B — 3.E will refine to per-segment R/W/X).
    3. Tail of `p_memsz` past `p_filesz` stays zero (page_alloc returns zeroed pages).
  - **Errors:** `BadMagic`, `NotElf32`, `NotLittleEndian`, `NotRiscV`, `NotExecutable`, `SegmentOutOfRange`, `OutOfMemory` (page_alloc returned null).
  - **Tests:** Use `tests/fixtures/minimal.elf` (already in repo) and a hand-crafted bad-magic blob.

- **`getpid` syscall (#172):**
  - Returns `cur.pid`.

- **`sbrk` syscall (#214):**
  - Increment-based: `sbrk(incr: i32) -> u32`. On positive `incr`, page-rounds up the new top, allocates and maps that many additional pages at `cur.sz`, advances `cur.sz`. On negative `incr` (3.B accepts but doesn't actually unmap — we just bump `sz` down). Returns the OLD `sz` (Linux brk semantics for relative).
  - **Limit:** `sz` capped at `0x000F_0000` (just under user stack at `0x0003_0000`... wait, in Phase 2 the user stack is at `0x0003_0000`. Phase 3.B keeps Phase 2's user layout (USER_TEXT_VA=0x00010000, USER_STACK_BOTTOM=0x00030000, USER_STACK_TOP=0x00032000). The user `sz` cap is therefore `USER_STACK_BOTTOM`, since heap grows up and stack lives above it; remapping is a 3.E concern.

- **Build wiring — second user ELF + multi-proc kernel:**
  - **`tests/programs/kernel/user/userprog2.zig`** — same shape as `userprog.zig`, prints `"[2] hello from u-mode\n"` (15 bytes) then `yield`s + busy-loops + `exit(0)`.
  - **`userprog2.elf`** built with the existing `user_linker.ld` (same VA layout, single segment).
  - **No more objcopy flatten:** both user ELFs are embedded as their `.elf` (raw ELF bytes), not flat .bin. The existing `user_blob.zig` stub gets renamed to `boot_config.zig` and gains:
    ```zig
    pub const MULTI_PROC: bool = …;     // set by build.zig per target
    pub const USERPROG_ELF = @embedFile("userprog.elf");
    pub const USERPROG2_ELF = @embedFile("userprog2.elf");  // empty array when MULTI_PROC=false to avoid breaking single-proc build
    ```
  - **Two kernel.elf targets** sharing all kernel objects:
    - `kernel.elf` — `MULTI_PROC=false`, only `userprog.elf` embedded as a real blob (the second is a 0-byte placeholder). `kmain` creates PID 1 only. `e2e-kernel` runs against this.
    - `kernel-multi.elf` — `MULTI_PROC=true`, both ELFs embedded. `kmain` creates PID 1 + PID 2. `e2e-multiproc-stub` runs against this.

- **`kmain` rewrite:**
  - Init free-list `page_alloc`, set up `cpu` struct (allocate scheduler stack from page_alloc).
  - Call `proc.alloc()` → PID 1; `vm.mapKernelAndMmio(pid1.pgdir)`; `elfload.load(USERPROG_ELF, pid1.pgdir)`; allocate user stack (mapUserStack helper); set `tf.sepc = entry; tf.sp = USER_STACK_TOP; satp = SATP_MODE_SV32 | (pid1.pgdir >> 12); state = Runnable`.
  - If `MULTI_PROC`, repeat for PID 2 with USERPROG2_ELF.
  - Set `stvec = s_trap_entry`, `sscratch = &pid1.tf` (or arbitrary; sched will overwrite before sret). Configure `sstatus.SPP=0`, `sstatus.SPIE=1`, `sie.SSIE=1`. Jump to `scheduler()` on the scheduler stack.

- **`sysExit` adjustment:**
  - Phase 2's behavior: print `"ticks observed: N\n"` and write halt MMIO with status. Phase 3.B keeps that behavior **only when `cur.pid == 1`**; for other PIDs, just mark `cur.state = Zombie`, set `cur.xstate = status`, call `proc.sched()` to yield to the scheduler (which will eventually loop back to PID 1).
  - This keeps Phase 2's `e2e-kernel` output exactly as before (PID 1 is the only proc; same trailer; same halt).
  - **Why pid==1, not "last runnable":** simpler to implement and 3.C properly handles "wait()/exit()" semantics; the multi-proc stub test arranges for PID 2 to finish first by busy-looping shorter than PID 1.

- **`e2e-multiproc-stub` test:**
  - **Verifier `multiproc_verify_e2e.zig`** (host tool, same pattern as Plan 2.D's `verify_e2e.zig`):
    1. Spawn `ccc kernel-multi.elf`, capture stdout, expect exit code 0.
    2. Assert stdout *contains* both `"hello from u-mode\n"` (PID 1's message) and `"[2] hello from u-mode\n"` (PID 2's message).
    3. Assert stdout ends with `"ticks observed: N\n"` for some `N >= 0` (PID 1's exit trailer).
  - The interleaving order is non-deterministic (round-robin + timer ticks), so the verifier checks substrings rather than byte-for-byte.

**Not in Plan 3.B (explicitly):**

- **fork / exec / wait / exit's full semantics** — Plan 3.C. (`sysExit` is a stub keyed on `pid==1` for now.)
- **kill flag (`^C`) / signals** — Plan 3.C.
- **set_fg_pid / console_set_mode syscalls** — Plan 3.C/E.
- **sleep / wakeup primitive** — Plan 3.D (the buffer cache and block driver are the first sleepers).
- **`dup` / `chan`** — Plan 3.D.
- **PLIC interrupt dispatch in S-mode trap.zig** — Plan 3.C+ (block IRQ wakeup arrives with the bufcache).
- **`copy_uvm` (full address-space copy for fork)** — Plan 3.C.
- **File table, fd table, openat, read, write to fd, lseek, fstat** — Plan 3.D/E.
- **`USER_TEXT_VA` change from `0x00010000` to `0x00001000`** — the spec calls for this in Phase 3, but moving it now would silently change user binaries' linker scripts; we leave it at `0x00010000` (Phase 2's value) and migrate when Plan 3.E rewrites userland. The null-pointer-fault property the spec wants is a minor 3.E task.
- **Real `sbrk` shrink (memory return on negative incr)** — Plan 3.E. 3.B accepts but no-ops the unmap.
- **Per-segment ELF permission honoring (R/W/X bits)** — Plan 3.E. 3.B uses USER_RWX uniformly.
- **`stvec_handler` / hooked-up PLIC IRQ paths in the kernel ISR** — Plan 3.C+.

**Deviation from Plan 3.A's closing note:** none. 3.A delivered the emulator-side substrate (PLIC, block, UART RX, WFI). Plan 3.B begins the kernel-side build-out and does not touch any emulator code.

---

## File structure (final state at end of Plan 3.B)

```
ccc/
├── .gitignore                                       ← UNCHANGED
├── .gitmodules                                      ← UNCHANGED
├── build.zig                                        ← MODIFIED (+userprog2.elf; +kernel-multi.elf; +e2e-multiproc-stub; embed ELFs not bins)
├── build.zig.zon                                    ← UNCHANGED
├── README.md                                        ← MODIFIED (status; Phase 3.B note; new e2e steps)
├── src/
│   ├── main.zig                                     ← UNCHANGED (emulator unchanged in 3.B)
│   ├── cpu.zig                                      ← UNCHANGED
│   ├── memory.zig                                   ← UNCHANGED
│   ├── decoder.zig                                  ← UNCHANGED
│   ├── execute.zig                                  ← UNCHANGED
│   ├── csr.zig                                      ← UNCHANGED
│   ├── trap.zig                                     ← UNCHANGED
│   ├── elf.zig                                      ← UNCHANGED
│   ├── trace.zig                                    ← UNCHANGED
│   └── devices/                                     ← UNCHANGED
└── tests/
    ├── programs/
    │   ├── hello/, mul_demo/, trap_demo/,
    │   │   hello_elf/                               ← UNCHANGED
    │   ├── plic_block_test/                         ← UNCHANGED (Phase 3.A)
    │   └── kernel/
    │       ├── boot.S                               ← UNCHANGED (M-mode shim)
    │       ├── linker.ld                            ← UNCHANGED
    │       ├── mtimer.S                             ← UNCHANGED
    │       ├── trampoline.S                         ← MODIFIED (csrw sscratch, sp; lw sp from KSTACK_TOP_OFFSET)
    │       ├── kmain.zig                            ← MODIFIED (alloc PID 1 [+PID 2], scheduler-driven boot)
    │       ├── kprintf.zig                          ← UNCHANGED
    │       ├── page_alloc.zig                       ← REWRITTEN (free-list)
    │       ├── proc.zig                             ← MODIFIED (Process extension; ptable; alloc/free; cpu singleton; yield; sched)
    │       ├── sched.zig                            ← MODIFIED (real scheduler() loop; halt-on-empty)
    │       ├── swtch.S                              ← NEW
    │       ├── elfload.zig                          ← NEW
    │       ├── syscall.zig                          ← MODIFIED (+getpid +sbrk; yield calls proc.yield; exit gates on pid==1)
    │       ├── trap.zig                             ← MODIFIED (SSI uses cur.ticks_observed; calls proc.yield)
    │       ├── uart.zig                             ← UNCHANGED
    │       ├── vm.zig                               ← MODIFIED (allocRoot returns null on OOM; mapUserStack helper; kernel-direct map uses heapStart instead of heapPos)
    │       ├── verify_e2e.zig                       ← UNCHANGED (Phase 2 e2e-kernel verifier)
    │       ├── multiproc_verify_e2e.zig             ← NEW (e2e-multiproc-stub verifier)
    │       └── user/
    │           ├── userprog.zig                     ← UNCHANGED (Phase 2 PID 1 payload)
    │           ├── userprog2.zig                    ← NEW (PID 2 payload — prints "[2] hello from u-mode\n")
    │           └── user_linker.ld                   ← UNCHANGED
    ├── fixtures/                                    ← UNCHANGED (minimal.elf used by elfload tests)
    ├── riscv-tests/                                 ← UNCHANGED
    ├── riscv-tests-p.ld                             ← UNCHANGED
    ├── riscv-tests-s.ld                             ← UNCHANGED
    └── riscv-tests-shim/                            ← UNCHANGED
```

**Files removed in this plan:** none.

**Files renamed in this plan:** the build-time-generated `user_blob.zig` stub becomes `boot_config.zig` (now exposes `MULTI_PROC` and both ELF embeds).

---

## Conventions used in this plan

- All Zig code targets Zig 0.16.x. Same API surface as Plan 2.D and Plan 3.A.
- Tests live as inline `test "name" { ... }` blocks alongside the code under test. `zig build test` runs every test reachable from `src/main.zig`. Kernel-side modules (those in `tests/programs/kernel/`) are RV32 cross-compiled and **not run as host tests**; we cover them via the e2e harnesses (which exercise the same code under the emulator) and by host-runnable unit tests for any *pure-data* logic that has a host equivalent (e.g., the ELF parser tests can run on the host because they don't call asm). Tasks call this out individually.
- Each task ends with a TDD cycle: write failing test, see it fail, implement minimally, verify pass, commit. Commit messages follow Conventional Commits. The commit footer used elsewhere in the repo is preserved unchanged.
- When extending a grouped switch (syscall.zig dispatch arms, build.zig kernel object list), we show the full block so diffs are unambiguous.
- Kernel asm offsets and Zig `pub const`s that name the same byte position must always be paired with a comptime assert tying them together (Phase 2 set this convention).
- Whenever a test needs a real `Memory`, it uses a local `setupRig()` helper. Per Plan 2.A/B/3.A convention, we don't extract a shared rig module — each file gets its own copy.
- Task order respects strict dependencies: `page_alloc` rewrite before anyone uses `alloc()/free()`; `Context` + `swtch` before any scheduler logic; trampoline rework before kmain restructures; `forkret` before scheduler tries to switch into a fresh process; ELF loader before kmain uses it; second-userprog build before multi-proc kmain branch; the `kernel-multi.elf` target last among build-wiring tasks; new e2e harness last.

---

## Tasks

### Task 1: Rewrite `page_alloc.zig` as a free-list

**Files:**
- Modify: `tests/programs/kernel/page_alloc.zig` (full rewrite)
- Modify: `tests/programs/kernel/vm.zig` (`mapKernelAndMmio` calls `heapStart()` instead of `heapPos()`)

**Why this task first:** Every later 3.B task allocates pages — kernel stacks, scheduler stack, user-program frames, page-table tables, scratch buffers in the ELF loader. The bump allocator's "no recycle" property would also block the multi-proc demo because PID 2 setup might exhaust the bump arena before PID 1 ever runs. Rewriting first, with an `allocZeroPage` shim for back-compat, lets us keep `vm.zig`'s call sites unchanged.

- [ ] **Step 1: Add a host-runnable test that exercises the allocator's algorithm purely from a buffer**

The kernel module is RV32-compiled, but the algorithm is pure pointer arithmetic; we factor a generic `FreeList` into a `tests/programs/kernel/page_alloc.zig` block that operates on `[*]u8`-style storage so a host test can drive it with a `std.heap.page_allocator`-backed buffer.

For now, write the failing host test as a placeholder skeleton at the top of `page_alloc.zig` (will compile under the kernel's RV32 build *only if* `@hasDecl(builtin, "freestanding")` is false — it's gated):

```zig
test "free-list pop returns most-recently pushed page" {
    if (@import("builtin").os.tag != .freestanding) {
        // Host-runnable algorithmic check: a 3-page buffer linked into a list
        // should produce LIFO pops.
        const std = @import("std");
        var buf: [3 * PAGE_SIZE]u8 align(PAGE_SIZE) = undefined;
        var fl = FreeList.empty();
        fl.pushPage(@intFromPtr(&buf[0]));
        fl.pushPage(@intFromPtr(&buf[PAGE_SIZE]));
        fl.pushPage(@intFromPtr(&buf[2 * PAGE_SIZE]));
        try std.testing.expectEqual(@intFromPtr(&buf[2 * PAGE_SIZE]), fl.pop().?);
        try std.testing.expectEqual(@intFromPtr(&buf[PAGE_SIZE]), fl.pop().?);
        try std.testing.expectEqual(@intFromPtr(&buf[0]), fl.pop().?);
        try std.testing.expectEqual(@as(?u32, null), fl.pop());
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: FAIL — `FreeList`, `pushPage`, `pop`, `empty` not yet defined.

- [ ] **Step 3: Implement the free-list module**

Replace the entire contents of `tests/programs/kernel/page_alloc.zig` with:

```zig
// tests/programs/kernel/page_alloc.zig — physical-page free-list allocator.
//
// Phase 3.B replaces Phase 2's bump allocator. The free-list links every
// 4 KB page in [heap_start, RAM_END) by reusing the page itself as its
// own list node — the first u32 of a free page is `next` (a PA, with 0
// meaning end-of-list). `alloc()` pops the head and returns a zeroed
// page; `free(pa)` pushes back. Both run in O(1).
//
// We pre-link in PA-descending order so `init()` walks the available
// region once. The first allocation returns the LOWEST physical page,
// not the highest — kmain therefore knows that early allocations land
// near `heap_start` (a useful debugging invariant).
//
// Out-of-memory returns null. Callers that should panic instead use
// `allocZeroPage()` — a shim wrapping `alloc()` with a panic on null.

const kprintf = @import("kprintf.zig");

pub const PAGE_SIZE: u32 = 4096;
pub const RAM_END: u32 = 0x8800_0000; // 128 MiB RAM ceiling

extern const _end: u8;

pub const FreeList = struct {
    head: u32,

    pub fn empty() FreeList {
        return .{ .head = 0 };
    }

    pub fn pushPage(self: *FreeList, pa: u32) void {
        const slot: *volatile u32 = @ptrFromInt(pa);
        slot.* = self.head;
        self.head = pa;
    }

    pub fn pop(self: *FreeList) ?u32 {
        if (self.head == 0) return null;
        const pa = self.head;
        const slot: *volatile u32 = @ptrFromInt(pa);
        self.head = slot.*;
        return pa;
    }
};

var fl: FreeList = .empty();
var heap_start: u32 = 0;

pub fn heapStart() u32 {
    return heap_start;
}

pub fn init() void {
    const end_addr: u32 = @intCast(@intFromPtr(&_end));
    heap_start = alignForward(end_addr);

    // Walk the heap region in descending order so `pop` returns the
    // lowest-PA page first.
    var pa: u32 = (RAM_END - PAGE_SIZE);
    while (pa >= heap_start) : (pa -%= PAGE_SIZE) {
        fl.pushPage(pa);
        if (pa == heap_start) break; // avoid wraparound below heap_start
    }
}

pub fn alloc() ?u32 {
    const pa = fl.pop() orelse return null;
    const slice: [*]volatile u8 = @ptrFromInt(pa);
    var i: u32 = 0;
    while (i < PAGE_SIZE) : (i += 1) slice[i] = 0;
    return pa;
}

pub fn free(pa: u32) void {
    if ((pa & (PAGE_SIZE - 1)) != 0) {
        kprintf.panic("page_alloc.free: misaligned pa {x}", .{pa});
    }
    if (pa < heap_start or pa >= RAM_END) {
        kprintf.panic("page_alloc.free: pa {x} out of range", .{pa});
    }
    fl.pushPage(pa);
}

pub fn freeCount() u32 {
    var n: u32 = 0;
    var p = fl.head;
    while (p != 0) {
        n += 1;
        const slot: *volatile u32 = @ptrFromInt(p);
        p = slot.*;
    }
    return n;
}

pub fn allocZeroPage() u32 {
    return alloc() orelse kprintf.panic("page_alloc: out of RAM", .{});
}

fn alignForward(x: u32) u32 {
    const mask: u32 = PAGE_SIZE - 1;
    return (x + mask) & ~mask;
}

test "free-list pop returns most-recently pushed page" {
    if (@import("builtin").os.tag != .freestanding) {
        const std = @import("std");
        var buf: [3 * PAGE_SIZE]u8 align(PAGE_SIZE) = undefined;
        var local = FreeList.empty();
        local.pushPage(@intFromPtr(&buf[0]));
        local.pushPage(@intFromPtr(&buf[PAGE_SIZE]));
        local.pushPage(@intFromPtr(&buf[2 * PAGE_SIZE]));
        try std.testing.expectEqual(@intFromPtr(&buf[2 * PAGE_SIZE]), local.pop().?);
        try std.testing.expectEqual(@intFromPtr(&buf[PAGE_SIZE]), local.pop().?);
        try std.testing.expectEqual(@intFromPtr(&buf[0]), local.pop().?);
        try std.testing.expectEqual(@as(?u32, null), local.pop());
    }
}
```

- [ ] **Step 4: Update `vm.zig` to use `heapStart()` instead of `heapPos()`**

In `tests/programs/kernel/vm.zig`, line 178, change:
```zig
const heap_s = page_alloc.heapPos();
```
to:
```zig
const heap_s = page_alloc.heapStart();
```

- [ ] **Step 5: Run the host test to verify it passes**

Run: `zig build test`
Expected: PASS — "free-list pop returns most-recently pushed page" passes.

- [ ] **Step 6: Run the existing Phase 2 e2e test to verify the kernel still boots**

Run: `zig build e2e-kernel`
Expected: PASS (Phase 2 behavior unchanged: `userprog.elf` still runs as PID 1, prints `"hello from u-mode\nticks observed: N\n"`, exits 0).

- [ ] **Step 7: Commit**

```bash
git add tests/programs/kernel/page_alloc.zig tests/programs/kernel/vm.zig
git commit -m "refactor(page_alloc): swap bump allocator for free-list"
```

---

### Task 2: `Context` struct + `swtch.S`

**Files:**
- Create: `tests/programs/kernel/swtch.S`
- Modify: `tests/programs/kernel/proc.zig` (add `Context` extern struct + comptime offset asserts)
- Modify: `build.zig` (add a new `kernel-swtch` object compiled into kernel.elf)

**Why this task here:** No further scheduler progress is possible without a context-switch primitive. We define `Context` first because both `proc.zig` and `swtch.S` reference its layout.

- [ ] **Step 1: Add the `Context` struct + offset asserts to `proc.zig`**

In `tests/programs/kernel/proc.zig`, after the `State` enum and before the `Process` struct, insert:

```zig
pub const Context = extern struct {
    ra: u32,
    sp: u32,
    s0: u32, s1: u32, s2: u32, s3: u32, s4: u32, s5: u32,
    s6: u32, s7: u32, s8: u32, s9: u32, s10: u32, s11: u32,
};

pub const CTX_RA: u32 = 0;
pub const CTX_SP: u32 = 4;
pub const CTX_S0: u32 = 8;
pub const CTX_S1: u32 = 12;
pub const CTX_S2: u32 = 16;
pub const CTX_S3: u32 = 20;
pub const CTX_S4: u32 = 24;
pub const CTX_S5: u32 = 28;
pub const CTX_S6: u32 = 32;
pub const CTX_S7: u32 = 36;
pub const CTX_S8: u32 = 40;
pub const CTX_S9: u32 = 44;
pub const CTX_S10: u32 = 48;
pub const CTX_S11: u32 = 52;
pub const CTX_SIZE: u32 = 56;

comptime {
    std.debug.assert(@offsetOf(Context, "ra") == CTX_RA);
    std.debug.assert(@offsetOf(Context, "sp") == CTX_SP);
    std.debug.assert(@offsetOf(Context, "s0") == CTX_S0);
    std.debug.assert(@offsetOf(Context, "s11") == CTX_S11);
    std.debug.assert(@sizeOf(Context) == CTX_SIZE);
}
```

- [ ] **Step 2: Create `swtch.S` with the asm primitive**

Create `tests/programs/kernel/swtch.S`:

```asm
# tests/programs/kernel/swtch.S — Phase 3.B context-switch primitive.
#
# void swtch(Context *old, Context *new);
#
# Saves callee-saved kernel registers (ra, sp, s0..s11) into *old,
# then restores them from *new. Returns by jumping to new->ra (loaded
# into the actual ra register and used by the trailing `ret`).
#
# Caller-saved (a0..a7, t0..t6) and floating-point regs are NOT saved —
# the calling Zig function is responsible for spilling them per the
# RISC-V calling convention. We rely on swtch being called as a regular
# function (so the compiler has already preserved everything important).

.equ CTX_RA,   0
.equ CTX_SP,   4
.equ CTX_S0,   8
.equ CTX_S1,  12
.equ CTX_S2,  16
.equ CTX_S3,  20
.equ CTX_S4,  24
.equ CTX_S5,  28
.equ CTX_S6,  32
.equ CTX_S7,  36
.equ CTX_S8,  40
.equ CTX_S9,  44
.equ CTX_S10, 48
.equ CTX_S11, 52

.section .text, "ax", @progbits
.balign 4
.globl swtch
swtch:
    # a0 = old (Context*), a1 = new (Context*)
    sw      ra,  CTX_RA(a0)
    sw      sp,  CTX_SP(a0)
    sw      s0,  CTX_S0(a0)
    sw      s1,  CTX_S1(a0)
    sw      s2,  CTX_S2(a0)
    sw      s3,  CTX_S3(a0)
    sw      s4,  CTX_S4(a0)
    sw      s5,  CTX_S5(a0)
    sw      s6,  CTX_S6(a0)
    sw      s7,  CTX_S7(a0)
    sw      s8,  CTX_S8(a0)
    sw      s9,  CTX_S9(a0)
    sw      s10, CTX_S10(a0)
    sw      s11, CTX_S11(a0)

    lw      ra,  CTX_RA(a1)
    lw      sp,  CTX_SP(a1)
    lw      s0,  CTX_S0(a1)
    lw      s1,  CTX_S1(a1)
    lw      s2,  CTX_S2(a1)
    lw      s3,  CTX_S3(a1)
    lw      s4,  CTX_S4(a1)
    lw      s5,  CTX_S5(a1)
    lw      s6,  CTX_S6(a1)
    lw      s7,  CTX_S7(a1)
    lw      s8,  CTX_S8(a1)
    lw      s9,  CTX_S9(a1)
    lw      s10, CTX_S10(a1)
    lw      s11, CTX_S11(a1)
    ret
```

- [ ] **Step 3: Wire `swtch.S` into the kernel build**

In `build.zig`, after the existing `kernel_mtimer_obj` block, insert a new object:

```zig
    const kernel_swtch_obj = b.addObject(.{
        .name = "kernel-swtch",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
        }),
    });
    kernel_swtch_obj.root_module.addAssemblyFile(b.path("tests/programs/kernel/swtch.S"));
```

And in the `kernel_elf.root_module.addObject(...)` chain (currently 4 lines: boot, trampoline, mtimer, kmain), add:
```zig
    kernel_elf.root_module.addObject(kernel_swtch_obj);
```
between `kernel_mtimer_obj` and `kernel_kmain_obj`.

- [ ] **Step 4: Add a Zig `extern fn` declaration for `swtch` in `proc.zig`**

In `tests/programs/kernel/proc.zig`, near the top (after imports, before the State enum), add:

```zig
pub extern fn swtch(old: *Context, new: *Context) void;
```

- [ ] **Step 5: Build the kernel to verify the asm assembles and links**

Run: `zig build kernel-elf`
Expected: PASS — kernel.elf links without unresolved-symbol errors.

- [ ] **Step 6: Run the existing e2e-kernel to verify the kernel still boots**

Run: `zig build e2e-kernel`
Expected: PASS (no behavioral change yet — `swtch` is defined but never called).

- [ ] **Step 7: Commit**

```bash
git add tests/programs/kernel/swtch.S tests/programs/kernel/proc.zig build.zig
git commit -m "feat(swtch): add Context struct and swtch.S kernel context-switch primitive"
```

---

### Task 3: Extend `Process` struct + `ptable[NPROC]`

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (replace the Process struct, drop `the_process`, add `ptable`)
- Modify: `tests/programs/kernel/trampoline.S` (rename `the_process` references to `ptable`)
- Modify: `tests/programs/kernel/sched.zig` (`schedule()` returns `proc.cur()`)
- Modify: `tests/programs/kernel/syscall.zig` (use `proc.cur()` for `ticks_observed`)
- Modify: `tests/programs/kernel/trap.zig` (use `proc.cur()` for `ticks_observed`)
- Modify: `tests/programs/kernel/kmain.zig` (initialize `ptable[0]` instead of `the_process`)

**Why this task here:** The Process struct gains the Phase 3.B fields (`pid`, `pgdir`, `sz`, `kstack`, `kstack_top`, `context`, etc.). Phase 2's `the_process` global is dropped; everywhere that referenced it now references `ptable[0]` (kernel sites with explicit access) or `proc.cur()` (logical "current process" reads). We also rename trampoline.S's `the_process` references to `ptable`, which works because Zig's `pub export var ptable` produces a global at `ptable`'s start address — equal to `&ptable[0]` — satisfying the existing offset-0 `tf` invariant.

- [ ] **Step 1: Replace the contents of `proc.zig` with the Phase 3.B struct + ptable**

Replace the entire body of `tests/programs/kernel/proc.zig` from `pub const State` onward (everything after the imports + `Context` block from Task 2) with:

```zig
pub const NPROC: u32 = 16;

pub const State = enum(u32) {
    Unused = 0,
    Embryo = 1,
    Sleeping = 2,
    Runnable = 3,
    Running = 4,
    Zombie = 5,
};

pub const Process = extern struct {
    tf: trap.TrapFrame,    // offset 0 — trampoline.S depends on this
    satp: u32,             // offset 128
    pgdir: u32,            // offset 132
    sz: u32,               // offset 136
    kstack: u32,           // offset 140
    kstack_top: u32,       // offset 144 — referenced by trampoline.S
    state: State,
    pid: u32,
    chan: u32,
    killed: u32,
    xstate: i32,
    ticks_observed: u32,
    context: Context,
    name: [16]u8,
    parent: ?*Process,
};

pub const KSTACK_TOP_OFFSET: u32 = 144;

comptime {
    std.debug.assert(@offsetOf(Process, "tf") == 0);
    std.debug.assert(@offsetOf(Process, "satp") == trap.TF_SIZE);
    std.debug.assert(@offsetOf(Process, "kstack_top") == KSTACK_TOP_OFFSET);
}

// Static process table. `pub export var` so trampoline.S can resolve
// `la t0, ptable` — the symbol address equals &ptable[0], whose first
// field is `tf` (offset 0), preserving the trampoline's existing
// "trapframe lives at sscratch" invariant.
pub export var ptable: [NPROC]Process = undefined;

/// Phase 3.B "current process" accessor. Until the scheduler boots
/// (Task 9, where `cpu.cur` becomes meaningful), this returns
/// `&ptable[0]` so trap/syscall code keeps working unchanged.
pub fn cur() *Process {
    return &ptable[0];
}
```

(The `the_process` `pub export var` is gone. Anyone who needs the trapframe pointer that previously came from `&the_process` now uses `&ptable[0]` directly.)

- [ ] **Step 2: Rename `the_process` to `ptable` in trampoline.S**

In `tests/programs/kernel/trampoline.S`, replace every occurrence of `the_process` with `ptable`. Specifically:

```diff
-    la      t0, the_process
+    la      t0, ptable
```
(twice — once after the GPR save dance, once before the dispatcher call)

```diff
-    la      a0, the_process
+    la      a0, ptable
```
(twice — once before `call s_trap_dispatch`, once after the call returns)

No other lines change in this task.

- [ ] **Step 3: Update `kmain.zig` to initialize `ptable[0]`**

In `tests/programs/kernel/kmain.zig`, replace the Phase 2 init block:

```zig
proc.the_process = std.mem.zeroes(proc.Process);
proc.the_process.tf.sepc = vm.USER_TEXT_VA;
proc.the_process.tf.sp = vm.USER_STACK_TOP;
proc.the_process.satp = SATP_MODE_SV32 | (root_pa >> 12);
proc.the_process.kstack_top = @intCast(@intFromPtr(&_kstack_top));
proc.the_process.state = .Runnable;
```

with:

```zig
const p = &proc.ptable[0];
p.* = std.mem.zeroes(proc.Process);
p.tf.sepc = vm.USER_TEXT_VA;
p.tf.sp = vm.USER_STACK_TOP;
p.satp = SATP_MODE_SV32 | (root_pa >> 12);
p.pgdir = root_pa;
p.kstack_top = @intCast(@intFromPtr(&_kstack_top));
p.kstack = p.kstack_top - 0x4000; // Phase 2 has a 16 KB linker-supplied stack
p.state = .Runnable;
p.pid = 1;
@memcpy(p.name[0..4], "init");
```

And replace the trapframe-pointer line:

```zig
const tf_addr: u32 = @intCast(@intFromPtr(&proc.the_process));
```

with:

```zig
const tf_addr: u32 = @intCast(@intFromPtr(&proc.ptable[0]));
```

And replace the final tail-call lines:

```zig
sched.context_switch_to(&proc.the_process);
s_return_to_user(@ptrCast(&proc.the_process));
```

with:

```zig
sched.context_switch_to(&proc.ptable[0]);
s_return_to_user(@ptrCast(&proc.ptable[0]));
```

- [ ] **Step 4: Update `trap.zig` and `syscall.zig` to use `cur()`**

In `tests/programs/kernel/trap.zig`, replace:
```zig
proc.the_process.ticks_observed +%= 1;
```
with:
```zig
proc.cur().ticks_observed +%= 1;
```

In `tests/programs/kernel/syscall.zig`, replace:
```zig
kprintf.print("ticks observed: {d}\n", .{proc.the_process.ticks_observed});
```
with:
```zig
kprintf.print("ticks observed: {d}\n", .{proc.cur().ticks_observed});
```

- [ ] **Step 5: Update `sched.zig` to call `cur()`**

In `tests/programs/kernel/sched.zig`, replace:
```zig
return &proc.the_process;
```
with:
```zig
return proc.cur();
```

- [ ] **Step 6: Build the kernel + run e2e-kernel**

Run: `zig build kernel-elf && zig build e2e-kernel`
Expected: PASS — same Phase 2 output (`"hello from u-mode\nticks observed: N\n"`, N > 0, exit 0). The struct layout changed but `ptable[0]` occupies the role `the_process` used to. Trampoline still walks the trapframe at offset 0 of `ptable[0]`. Behavior identical.

- [ ] **Step 7: Commit**

```bash
git add tests/programs/kernel/proc.zig tests/programs/kernel/trampoline.S tests/programs/kernel/kmain.zig tests/programs/kernel/trap.zig tests/programs/kernel/syscall.zig tests/programs/kernel/sched.zig
git commit -m "refactor(proc): introduce ptable[NPROC]; replace the_process with cur()"
```

---

### Task 4: `proc.alloc()` and `proc.free()`

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (add `alloc`, `free`, `forkret_stub` placeholder)
- Modify: `tests/programs/kernel/syscall.zig` (no change yet, but verify it compiles)

**Why this task here:** Process slot allocation is the prerequisite for kmain to create PID 1 the "real" way and for Task 18 to add PID 2. We land `alloc()` now without a real `forkret` (Task 8 wires that in); `alloc()` records a placeholder address that will be patched in Task 8.

- [ ] **Step 1: Add the `forkret` extern declaration and `alloc`/`free` functions**

In `tests/programs/kernel/proc.zig`, append (after the `cur()` function):

```zig
const page_alloc = @import("page_alloc.zig");

// Forward-declared in Task 8. For Task 4, alloc() points new procs at a
// placeholder address that's never reached because we only allocate
// PID 1 (whose context is overridden by kmain's direct sret).
extern fn forkret() callconv(.c) noreturn;

pub fn alloc() ?*Process {
    var i: u32 = 0;
    while (i < NPROC) : (i += 1) {
        const p = &ptable[i];
        if (p.state == .Unused) {
            p.* = std.mem.zeroes(Process);
            p.state = .Embryo;
            p.pid = nextPid();
            const ks = page_alloc.alloc() orelse return null;
            p.kstack = ks;
            p.kstack_top = ks + page_alloc.PAGE_SIZE;
            p.context.ra = @intCast(@intFromPtr(&forkret));
            p.context.sp = p.kstack_top - 16; // 16-byte aligned first frame
            return p;
        }
    }
    return null;
}

pub fn free(p: *Process) void {
    if (p.kstack != 0) {
        page_alloc.free(p.kstack);
        p.kstack = 0;
    }
    // pgdir teardown deferred to 3.C; 3.B never calls free() in
    // expected paths.
    p.* = std.mem.zeroes(Process);
}

var next_pid: u32 = 1;
fn nextPid() u32 {
    const p = next_pid;
    next_pid += 1;
    return p;
}
```

- [ ] **Step 2: Add a Phase 3.B kmain skeleton test (does not run yet — for Task 14)**

(Skip — this comes in Task 14. Task 4 just adds the API.)

- [ ] **Step 3: Build the kernel to verify the new API compiles**

Run: `zig build kernel-elf`
Expected: PASS — kernel.elf links without unresolved-`forkret` errors. (We'll provide a real `forkret` body in Task 8; the symbol resolves to whatever the linker picks for `extern fn forkret` — it would be unresolved unless we add a placeholder. The trick: `extern fn` only declares; it expects a definition elsewhere. We need to add a placeholder definition now.)

After verifying the build *fails* due to unresolved `forkret`, add a placeholder definition at the bottom of `proc.zig`:

```zig
// Placeholder; real body lands in Task 8. We need this to satisfy the
// linker for now. Task 8 replaces it.
export fn forkret() callconv(.c) noreturn {
    @import("kprintf.zig").panic("forkret called before Task 8 wired it up", .{});
}
```

- [ ] **Step 4: Re-build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 5: Run e2e-kernel — Phase 2 path is untouched**

Run: `zig build e2e-kernel`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add tests/programs/kernel/proc.zig
git commit -m "feat(proc): add alloc/free for ptable slots with placeholder forkret"
```

---

### Task 5: Trampoline rework — read kstack and sscratch from sp

**Files:**
- Modify: `tests/programs/kernel/trampoline.S`

**Why this task here:** Subsequent tasks will create new processes whose kstack lives at unpredictable PAs (page_alloc returns whatever's free). The trampoline's hard-coded `la sp, _kstack_top` must become a load from the Process struct. Doing this on its own task lets us run e2e-kernel after the change to confirm we haven't broken Phase 2.

- [ ] **Step 1: Modify trampoline.S to use the per-process kstack**

In `tests/programs/kernel/trampoline.S`, modify the section between the GPR save loop and the `call s_trap_dispatch`. After Task 3, the relevant lines look like:

```asm
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
```

Replace with (note: the new lines use `KSTACK_TOP_OFFSET = 144` mirrored from `proc.zig`):

```asm
    csrr    t0, sscratch
    sw      t0, TF_SP(sp)

    # Re-arm sscratch for the next trap. sp currently points at &cur_proc
    # (since we swapped sp<->sscratch on entry and tf is offset 0 in
    # Process), so simply reflect it back into sscratch.
    csrw    sscratch, sp

    # Save sepc.
    csrr    t0, sepc
    sw      t0, TF_SEPC(sp)

    # Move &cur_proc into a0 BEFORE switching the stack — the dispatcher
    # takes the tf pointer in a0, and we need to keep it accessible.
    mv      a0, sp

    # Switch sp to the per-process kernel stack. KSTACK_TOP_OFFSET = 144
    # is the byte offset of `kstack_top` inside Process (asserted in
    # proc.zig at compile time).
    .equ KSTACK_TOP_OFFSET, 144
    lw      sp, KSTACK_TOP_OFFSET(a0)

    # Call s_trap_dispatch(tf).
    call    s_trap_dispatch

    # On return, s_trap_dispatch may have called swtch, which leaves us
    # on a (possibly different) process's kstack with a0 clobbered. We
    # need a0 = &cur_proc.tf for the s_return_to_user path. Read sscratch
    # — re-armed at trap entry to point at the current process struct.
    csrr    a0, sscratch
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 3: Run e2e-kernel — Phase 2 path is unchanged**

Run: `zig build e2e-kernel`
Expected: PASS — the kernel uses ptable[0]'s `kstack_top` (set to `_kstack_top` in Task 3 step 2) so the kstack is the same physical region as Phase 2's. Output unchanged.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/trampoline.S
git commit -m "refactor(trampoline): load kstack and sscratch from per-process struct"
```

---

### Task 6: `Cpu` singleton + scheduler stack

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (add `Cpu` struct + `cpu` global + setup helper)
- Modify: `tests/programs/kernel/kmain.zig` (allocate scheduler stack and set `cpu.cur`)

**Why this task here:** The scheduler needs its own kernel stack and saved Context. We land both in `proc.zig` alongside `Process` since they're conceptually one module.

- [ ] **Step 1: Define `Cpu` and the global**

In `tests/programs/kernel/proc.zig`, after the `Context` struct and before the `Process` struct, add:

```zig
pub const Cpu = extern struct {
    cur: ?*Process,
    sched_context: Context,
    sched_stack_top: u32,
};

pub var cpu: Cpu = undefined;

pub fn cpuInit() void {
    cpu = std.mem.zeroes(Cpu);
    const stack = page_alloc.alloc() orelse @import("kprintf.zig").panic("cpuInit: no scheduler stack", .{});
    cpu.sched_stack_top = stack + page_alloc.PAGE_SIZE;
}
```

Update the `cur()` accessor to read from `cpu.cur` (with a Phase-2 fallback to ptable[0] when cpu.cur is null — happens during early kmain before scheduler boots):

```zig
pub fn cur() *Process {
    return cpu.cur orelse &ptable[0];
}
```

- [ ] **Step 2: Wire cpuInit into kmain**

In `tests/programs/kernel/kmain.zig`, change the order of init at the top of `kmain`:

```zig
export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    proc.cpuInit();   // <-- new
    // ... rest of existing kmain unchanged
```

- [ ] **Step 3: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 4: Run e2e-kernel**

Run: `zig build e2e-kernel`
Expected: PASS — output unchanged.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/proc.zig tests/programs/kernel/kmain.zig
git commit -m "feat(proc): add Cpu singleton and scheduler kernel stack"
```

---

### Task 7: `proc.yield` and `proc.sched` helpers

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (add `yield` and `sched` Zig functions)
- Modify: `tests/programs/kernel/syscall.zig` (sysYield calls proc.yield instead of sched.schedule)
- Modify: `tests/programs/kernel/trap.zig` (SSI handler calls proc.yield instead of sched.schedule)

**Why this task here:** The yield path needs to exist before Task 9 lands the real scheduler — Task 9 fills in the scheduler-side of `swtch`, and we need yield's caller-side ready to wire up. After this task, `yield` *would* call swtch, but the scheduler hasn't entered yet so nothing happens — we keep Phase 2's no-op semantics until Task 9 + 10.

- [ ] **Step 1: Add yield and sched in proc.zig with a bootstrap guard**

In `tests/programs/kernel/proc.zig`, append:

```zig
/// Save current process state and switch to the scheduler context. The
/// scheduler picks the next runnable proc and swtch's back into us when
/// our turn comes. Until kmain wires `cpu.sched_context.ra` to the real
/// scheduler entry (Task 14), `sched()` is a no-op so the existing
/// single-proc boot path keeps working unchanged.
pub fn sched() void {
    if (cpu.sched_context.ra == 0) return;
    const p = cur();
    swtch(&p.context, &cpu.sched_context);
}

/// User-facing yield: mark current Runnable, switch to scheduler. Phase
/// 3.B's scheduler may pick the same proc back immediately, which is
/// fine — yield is just a "scheduling point".
pub fn yield() void {
    const p = cur();
    p.state = .Runnable;
    sched();
    p.state = .Running;
}
```

- [ ] **Step 2: Update sysYield to call proc.yield**

In `tests/programs/kernel/syscall.zig`, replace:
```zig
fn sysYield() u32 {
    _ = sched.schedule();
    return 0;
}
```
with:
```zig
fn sysYield() u32 {
    proc.yield();
    return 0;
}
```

- [ ] **Step 3: Update SSI handler to call proc.yield**

In `tests/programs/kernel/trap.zig`, find the SSI branch (after Task 3 it reads `proc.cur().ticks_observed +%= 1; _ = sched.schedule();`) and replace `_ = sched.schedule();` with:
```zig
proc.yield();
```

- [ ] **Step 4: Build the kernel and run e2e-kernel**

Run: `zig build kernel-elf && zig build e2e-kernel`
Expected: PASS — `swtch` resolves; `sched()`'s guard short-circuits because `cpu.sched_context.ra == 0` until Task 14, so behavior is identical to Phase 2.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/proc.zig tests/programs/kernel/syscall.zig tests/programs/kernel/trap.zig
git commit -m "feat(proc): add yield/sched helpers gated until scheduler is wired"
```

---

### Task 8: `forkret` — initial entry stub

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (replace placeholder forkret with real body)

**Why this task here:** Process slots set `context.ra = forkret` in `alloc()` (Task 4). The first `swtch` into a fresh process will jump to whatever `forkret` resolves to. We replace the placeholder panic with the real body now so Task 9's scheduler can switch into newly-allocated processes correctly.

- [ ] **Step 1: Replace the placeholder forkret**

In `tests/programs/kernel/proc.zig`, replace the placeholder forkret (the one that panics) with:

```zig
// Initial entry for newly-allocated processes. Reached via the first
// swtch into the proc — its context.ra is set to this address by alloc().
//
// 3.B body: just call s_return_to_user(&cur.tf). We're already on the
// new proc's kstack (swtch loaded sp from context.sp = kstack_top - 16),
// so srets cleanly into U-mode. 3.C will add lock release here when
// locks arrive.
extern fn s_return_to_user(tf: *trap.TrapFrame) noreturn;

export fn forkret() callconv(.c) noreturn {
    const p = cur();
    s_return_to_user(&p.tf);
}
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS — `forkret` exports cleanly, no unresolved `s_return_to_user` (it's declared in trampoline.S as `.globl s_return_to_user`).

- [ ] **Step 3: Run e2e-kernel**

Run: `zig build e2e-kernel`
Expected: PASS — Phase 2 path doesn't reach forkret (kmain tail-calls s_return_to_user directly), so output unchanged.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/proc.zig
git commit -m "feat(proc): real forkret body — sret into newly scheduled procs"
```

---

### Task 9: `scheduler()` — round-robin loop

**Files:**
- Modify: `tests/programs/kernel/sched.zig` (rewrite scheduler() body; drop context_switch_to)

**Why this task here:** With swtch, Context, alloc, forkret, and the Cpu singleton all in place, the scheduler can finally be implemented. Phase 3.B's scheduler is a forever loop: scan ptable, pick next Runnable, set cur, swtch into it. On return (proc yielded), set cur=null and continue.

- [ ] **Step 1: Rewrite sched.zig**

Replace the entire contents of `tests/programs/kernel/sched.zig`:

```zig
// tests/programs/kernel/sched.zig — Phase 3.B round-robin scheduler.
//
// Runs forever on cpu.sched_stack_top. Loop:
//   1. Scan ptable for the first Runnable proc.
//   2. If found: cpu.cur = p; p.state = Running; csrw satp from p.satp;
//      sfence.vma; swtch into p.context.
//   3. On return (p yielded back), cpu.cur = null. Continue.
//   4. If no Runnable proc and at least one Embryo or Sleeping or Running
//      exists, loop. (We'll WFI here in 3.D when there's something to wait
//      on; for now the timer tick keeps poking us.)
//   5. If every slot is Unused or Zombie, halt the system via the halt
//      MMIO with status from the most-recently-zombied proc (or 0).

const proc = @import("proc.zig");

const SATP_MODE_SV32: u32 = 1 << 31;

pub fn scheduler() noreturn {
    while (true) {
        var picked: ?*proc.Process = null;
        var any_alive = false;
        var last_xstatus: i32 = 0;

        var i: u32 = 0;
        while (i < proc.NPROC) : (i += 1) {
            const p = &proc.ptable[i];
            switch (p.state) {
                .Runnable => {
                    picked = p;
                    any_alive = true;
                    break;
                },
                .Embryo, .Sleeping, .Running => any_alive = true,
                .Zombie => {
                    last_xstatus = p.xstate;
                    any_alive = true; // a zombie is still alive until reaped
                },
                .Unused => {},
            }
        }

        if (picked) |p| {
            proc.cpu.cur = p;
            p.state = .Running;
            asm volatile (
                \\ csrw satp, %[s]
                \\ sfence.vma zero, zero
                :
                : [s] "r" (p.satp),
                : .{ .memory = true }
            );
            proc.swtch(&proc.cpu.sched_context, &p.context);
            // p has yielded back; swtch left us here.
            proc.cpu.cur = null;
            continue;
        }

        if (!any_alive) {
            // No runnable, no embryo/sleeping/zombie — halt with last
            // observed exit status (or 0).
            const halt: *volatile u8 = @ptrFromInt(0x00100000);
            halt.* = @intCast(@as(u8, @bitCast(@as(i8, @truncate(last_xstatus)))));
            while (true) asm volatile ("wfi");
        }
        // Else: spin (timer tick will fire and re-enter sched's caller —
        // but we're not anyone's callee. We just busy-loop until something
        // becomes Runnable. 3.D adds proper WFI here.)
    }
}
```

(Note: the existing `pub fn schedule()` and `pub fn context_switch_to()` are dropped. Update remaining call sites.)

- [ ] **Step 2: Drop the old `sched.schedule()` references**

Search for remaining callers:

Run: `grep -n "sched.schedule\|sched.context_switch_to" tests/programs/kernel/`
Expected matches:
- `kmain.zig` — line ~87 calls `sched.context_switch_to(&proc.ptable[0])`. Replace with inline `csrw satp; sfence.vma`.

In `kmain.zig`, find the line after the `sstatus` setup:
```zig
sched.context_switch_to(&proc.ptable[0]);
```
Replace with:
```zig
asm volatile (
    \\ csrw satp, %[s]
    \\ sfence.vma zero, zero
    :
    : [s] "r" (proc.ptable[0].satp),
    : .{ .memory = true }
);
```

(All other `sched.*` references are gone after Task 7.)

- [ ] **Step 3: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 4: Run e2e-kernel — Phase 2 path unchanged**

Run: `zig build e2e-kernel`
Expected: PASS. (kmain still tail-calls `s_return_to_user(&proc.ptable[0])` directly without going through the scheduler. The scheduler() function exists but is unreached in 3.B's single-proc kernel.elf path.)

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/sched.zig tests/programs/kernel/kmain.zig
git commit -m "feat(sched): round-robin scheduler() with halt-on-no-runnable"
```

---

### Task 10: `sysExit` — gate halt on `pid == 1`

**Files:**
- Modify: `tests/programs/kernel/syscall.zig`

**Why this task here:** Multi-proc tests need PID 2 to *not* halt the emulator on its own exit. We gate the existing halt behavior on `cur.pid == 1`; non-PID-1 procs become Zombie and call sched (which will reap them in 3.C; for 3.B we just halt-when-pid-1 and rely on PID 1 being the last to exit in our test).

- [ ] **Step 1: Update sysExit**

In `tests/programs/kernel/syscall.zig`, replace `sysExit`:

```zig
fn sysExit(status: u32) noreturn {
    const p = proc.cur();
    p.xstate = @bitCast(status);
    p.state = .Zombie;

    if (p.pid == 1) {
        // Phase 2 §Definition of done: print "ticks observed: N\n" before
        // halting. We use this proc's own ticks_observed; the multi-proc
        // test arranges for PID 1 to be the last to exit.
        kprintf.print("ticks observed: {d}\n", .{p.ticks_observed});
        const halt: *volatile u8 = @ptrFromInt(0x00100000);
        halt.* = @intCast(status & 0xFF);
        while (true) asm volatile ("wfi");
    }

    // Non-PID-1 proc: yield back to scheduler. 3.C will reap zombies via
    // wait(); for 3.B's multi-proc demo, the scheduler will keep cycling
    // between PID 1 and PID 2 (now Zombie, skipped) until PID 1 exits and
    // halts.
    proc.sched();
    // Should not return — but if it does, panic.
    @import("kprintf.zig").panic("sysExit: zombie woke up", .{});
}
```

- [ ] **Step 2: Build + e2e-kernel**

Run: `zig build kernel-elf && zig build e2e-kernel`
Expected: PASS — Phase 2 single-proc path: PID 1 exits → prints ticks → halts. Output unchanged.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/syscall.zig
git commit -m "feat(syscall): exit() gates halt on pid==1, marks zombie + yields otherwise"
```

---

### Task 11: Kernel ELF loader (`elfload.zig`)

**Files:**
- Create: `tests/programs/kernel/elfload.zig`

**Why this task here:** Standalone module. Tests run on the host (the parsing logic doesn't touch asm or page_alloc directly — it takes a `pgdir_pa` and a `mapPage`-like callback so we can stub it in tests).

- [ ] **Step 1: Write a failing test against a hand-crafted minimal ELF**

Create `tests/programs/kernel/elfload.zig`:

```zig
// tests/programs/kernel/elfload.zig — kernel-side ELF32 loader.
//
// Phase 3.B: parse an ELF32 RISC-V EXEC blob, walk PT_LOAD program
// headers, and for each segment allocate physical frames and install
// user PTEs at the segment's p_vaddr. Returns the entry PC (e_entry).
//
// All Phase 3.B segments map with USER_RWX. Plan 3.E will refine to
// per-segment R/W/X based on p_flags.

const std = @import("std");

pub const ElfError = error{
    BadMagic,
    NotElf32,
    NotLittleEndian,
    NotRiscV,
    NotExecutable,
    SegmentOutOfRange,
    OutOfMemory,
};

const EI_CLASS = 4;
const EI_DATA = 5;
const ELFCLASS32: u8 = 1;
const ELFDATA2LSB: u8 = 1;
const EM_RISCV: u16 = 0xF3;
const ET_EXEC: u16 = 2;
const PT_LOAD: u32 = 1;

pub const PageAllocFn = *const fn () ?u32;
pub const MapFn = *const fn (pgdir: u32, va: u32, pa: u32, flags: u32) void;

pub fn parse(blob: []const u8) ElfError!struct { entry: u32, ph_off: u32, ph_num: u16, ph_entsize: u16 } {
    if (blob.len < 52) return ElfError.BadMagic;
    if (!std.mem.eql(u8, blob[0..4], "\x7FELF")) return ElfError.BadMagic;
    if (blob[EI_CLASS] != ELFCLASS32) return ElfError.NotElf32;
    if (blob[EI_DATA] != ELFDATA2LSB) return ElfError.NotLittleEndian;
    const e_type = std.mem.readInt(u16, blob[16..18], .little);
    if (e_type != ET_EXEC) return ElfError.NotExecutable;
    const e_machine = std.mem.readInt(u16, blob[18..20], .little);
    if (e_machine != EM_RISCV) return ElfError.NotRiscV;
    return .{
        .entry = std.mem.readInt(u32, blob[24..28], .little),
        .ph_off = std.mem.readInt(u32, blob[28..32], .little),
        .ph_num = std.mem.readInt(u16, blob[44..46], .little),
        .ph_entsize = std.mem.readInt(u16, blob[42..44], .little),
    };
}

pub fn load(blob: []const u8, pgdir: u32, alloc_fn: PageAllocFn, map_fn: MapFn, user_flags: u32) ElfError!u32 {
    const hdr = try parse(blob);

    var i: u32 = 0;
    while (i < hdr.ph_num) : (i += 1) {
        const off = hdr.ph_off + i * hdr.ph_entsize;
        if (off + 32 > blob.len) return ElfError.SegmentOutOfRange;
        const p_type = std.mem.readInt(u32, blob[off..][0..4], .little);
        if (p_type != PT_LOAD) continue;

        const p_offset = std.mem.readInt(u32, blob[off + 4 ..][0..4], .little);
        const p_vaddr = std.mem.readInt(u32, blob[off + 8 ..][0..4], .little);
        const p_filesz = std.mem.readInt(u32, blob[off + 16 ..][0..4], .little);
        const p_memsz = std.mem.readInt(u32, blob[off + 20 ..][0..4], .little);

        if (p_offset + p_filesz > blob.len) return ElfError.SegmentOutOfRange;

        const PAGE_SIZE: u32 = 4096;
        const va_start: u32 = p_vaddr & ~@as(u32, PAGE_SIZE - 1);
        const va_end: u32 = (p_vaddr + p_memsz + PAGE_SIZE - 1) & ~@as(u32, PAGE_SIZE - 1);

        var va = va_start;
        while (va < va_end) : (va += PAGE_SIZE) {
            const pa = alloc_fn() orelse return ElfError.OutOfMemory;
            map_fn(pgdir, va, pa, user_flags);

            // Copy bytes that fall in this page from the blob.
            const seg_lo = if (va < p_vaddr) p_vaddr else va;
            const seg_hi = @min(va + PAGE_SIZE, p_vaddr + p_filesz);
            if (seg_hi > seg_lo) {
                const dst: [*]volatile u8 = @ptrFromInt(pa + (seg_lo - va));
                const src_off = p_offset + (seg_lo - p_vaddr);
                var k: u32 = 0;
                while (k < seg_hi - seg_lo) : (k += 1) dst[k] = blob[src_off + k];
            }
            // Tail (seg's [filesz, memsz) within this page) stays zero
            // because alloc_fn returns zeroed pages.
        }
    }

    return hdr.entry;
}

test "parse rejects empty blob" {
    if (@import("builtin").os.tag != .freestanding) {
        const empty: []const u8 = &.{};
        try std.testing.expectError(ElfError.BadMagic, parse(empty));
    }
}

test "parse rejects bad magic" {
    if (@import("builtin").os.tag != .freestanding) {
        var bogus: [64]u8 = .{0} ** 64;
        bogus[0] = 'X';
        try std.testing.expectError(ElfError.BadMagic, parse(&bogus));
    }
}

test "parse accepts the minimal.elf fixture" {
    if (@import("builtin").os.tag != .freestanding) {
        const fixture = @import("minimal_elf_fixture").bytes;
        const hdr = try parse(fixture);
        try std.testing.expect(hdr.entry != 0);
        try std.testing.expect(hdr.ph_num >= 1);
    }
}
```

- [ ] **Step 2: Wire elfload.zig into the kernel build**

In `build.zig`, the kernel kmain object needs access to `elfload.zig` — but `elfload.zig` is a kernel module imported via `@import("elfload.zig")` from `kmain.zig` (Task 14). Building the kernel doesn't need a build.zig change; it's pulled in transitively via the kmain object.

For the **host** test pass (`zig build test`), wire up the test by adding `_ = @import("...");` to `src/main.zig`'s comptime block — but `src/main.zig` runs as host code and can't pull in kernel modules built with `rv_target`. The kernel-side tests are integration-tested via `e2e-kernel` and `e2e-multiproc-stub`; the host-runnable parser tests live at the bottom of `elfload.zig` and are excluded from the kernel build by the `if (@import("builtin").os.tag != .freestanding)` gate.

We need a separate way to run those host tests. Add to `build.zig`, alongside the existing `tests` step:

```zig
    // Host-runnable tests for kernel-side modules whose algorithms can run
    // outside the cross-compiled kernel (e.g., elfload's parser).
    const kernel_host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/elfload.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    kernel_host_tests.root_module.addAnonymousImport("minimal_elf_fixture", .{
        .root_source_file = b.path("tests/fixtures/minimal_elf.zig"),
    });
    const kernel_host_tests_run = b.addRunArtifact(kernel_host_tests);
    test_step.dependOn(&kernel_host_tests_run.step);
```

(`test_step` is the existing `b.step("test", ...)` declared earlier in build.zig.)

- [ ] **Step 3: Run host tests**

Run: `zig build test`
Expected: PASS — three new tests "parse rejects empty blob", "parse rejects bad magic", "parse accepts the minimal.elf fixture".

- [ ] **Step 4: Run e2e-kernel — must still pass (elfload not used by kmain yet)**

Run: `zig build e2e-kernel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/elfload.zig build.zig
git commit -m "feat(elfload): kernel-side ELF32 loader with host-runnable parse tests"
```

---

### Task 12: `vm.zig` — `mapUserStack` helper + null-safe `allocRoot`

**Files:**
- Modify: `tests/programs/kernel/vm.zig` (`allocRoot` returns `?u32`; new `mapUserStack` helper)
- Modify: `tests/programs/kernel/kmain.zig` (handle the new optional return from `allocRoot`)

**Why this task here:** `kmain` (Task 14) will build PID 1's pgdir from scratch via `allocRoot()` then `mapKernelAndMmio` then `elfload.load` then `mapUserStack`. We need the helpers ready. `allocRoot` is converted to handle alloc failure gracefully.

- [ ] **Step 1: Convert `allocRoot` to return `?u32` and add `mapUserStack`**

In `tests/programs/kernel/vm.zig`, replace the existing `allocRoot`:

```zig
pub fn allocRoot() u32 {
    return page_alloc.allocZeroPage();
}
```

with:

```zig
pub fn allocRoot() ?u32 {
    return page_alloc.alloc();
}
```

After the `mapUser` function, append:

```zig
/// Allocate USER_STACK_PAGES (2) zeroed frames, map them at
/// USER_STACK_BOTTOM..USER_STACK_TOP with U+R+W. Returns false on OOM,
/// in which case partial mappings remain in pgdir (caller frees).
pub fn mapUserStack(root_pa: u32) bool {
    var s: u32 = 0;
    while (s < USER_STACK_PAGES) : (s += 1) {
        const stack_pa = page_alloc.alloc() orelse return false;
        const va = USER_STACK_BOTTOM + s * PAGE_SIZE;
        mapPage(root_pa, va, stack_pa, USER_RW);
    }
    return true;
}
```

- [ ] **Step 2: Update kmain's `allocRoot` call site**

In `tests/programs/kernel/kmain.zig`, find:
```zig
const root_pa = vm.allocRoot();
```
and replace with:
```zig
const root_pa = vm.allocRoot() orelse kprintf.panic("allocRoot OOM", .{});
```

(This call site will be replaced wholesale in Task 14; the `orelse` keeps Phase 2 e2e-kernel green in the meantime. Add a `const kprintf = @import("kprintf.zig");` import line at the top of `kmain.zig` if it's not already there — Phase 2 brought it in transitively.)

- [ ] **Step 3: Build kernel + run e2e-kernel**

Run: `zig build kernel-elf && zig build e2e-kernel`
Expected: PASS — same Phase 2 output.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/vm.zig tests/programs/kernel/kmain.zig
git commit -m "feat(vm): mapUserStack helper and null-safe allocRoot"
```

---

### Task 13: Build wiring — embed ELFs, not flat .bin

**Files:**
- Modify: `build.zig` (drop the objcopy step; embed userprog.elf bytes directly; rename user_blob.zig → boot_config.zig)

**Why this task here:** The kernel ELF loader (Task 11) consumes raw ELF bytes. We must stop flattening `userprog.elf` to `userprog.bin` and instead embed the ELF directly. Doing this on its own task lets us re-run e2e-kernel and confirm Phase 2's payload still parses correctly via the ELF loader once Task 14 hooks it in.

- [ ] **Step 1: Drop the userprog objcopy step and rename the embed stub**

In `build.zig`, find:
```zig
    const userprog_objcopy = b.addObjCopy(userprog_elf.getEmittedBin(), .{
        .format = .bin,
        .basename = "userprog.bin",
    });
    const userprog_bin = userprog_objcopy.getOutput();

    const user_blob_stub_dir = b.addWriteFiles();
    const user_blob_zig = user_blob_stub_dir.add(
        "user_blob.zig",
        "pub const BLOB = @embedFile(\"userprog.bin\");\n",
    );
    _ = user_blob_stub_dir.addCopyFile(userprog_bin, "userprog.bin");

    const install_userprog_bin = b.addInstallFile(userprog_bin, "userprog.bin");
    const kernel_user_step = b.step("kernel-user", "Build the Plan 2.C userprog.bin");
    kernel_user_step.dependOn(&install_userprog_bin.step);
```

Replace with:
```zig
    const userprog_elf_bin = userprog_elf.getEmittedBin();

    const boot_config_stub_dir = b.addWriteFiles();
    const boot_config_zig = boot_config_stub_dir.add(
        "boot_config.zig",
        \\pub const MULTI_PROC: bool = false;
        \\pub const USERPROG_ELF: []const u8 = @embedFile("userprog.elf");
        \\pub const USERPROG2_ELF: []const u8 = &.{};
        \\
    );
    _ = boot_config_stub_dir.addCopyFile(userprog_elf_bin, "userprog.elf");

    const install_userprog_elf = b.addInstallFile(userprog_elf_bin, "userprog.elf");
    const kernel_user_step = b.step("kernel-user", "Build the Phase 3.B userprog.elf");
    kernel_user_step.dependOn(&install_userprog_elf.step);
```

And update the kernel kmain object's anonymous import:
```zig
    kernel_kmain_obj.root_module.addAnonymousImport("user_blob", .{
        .root_source_file = user_blob_zig,
    });
```
to:
```zig
    kernel_kmain_obj.root_module.addAnonymousImport("boot_config", .{
        .root_source_file = boot_config_zig,
    });
```

- [ ] **Step 2: Update kmain.zig to import boot_config and load via elfload**

The new embed is an ELF file (not a flat binary), so kmain must use `elfload.load` to install PT_LOAD segments. Doing this here keeps `e2e-kernel` green between Task 13 and Task 14; Task 14 then refines kmain to use `proc.alloc` and the scheduler.

In `tests/programs/kernel/kmain.zig`, change the import block:
```zig
const user_blob = @import("user_blob");
pub const USER_BLOB: []const u8 = user_blob.BLOB;
```
to:
```zig
const boot_config = @import("boot_config");
const elfload = @import("elfload.zig");
pub const USERPROG_ELF: []const u8 = boot_config.USERPROG_ELF;
```

Replace the existing `vm.mapUser(root_pa, USER_BLOB.ptr, @intCast(USER_BLOB.len));` line with:

```zig
const allocFn = struct {
    fn f() ?u32 {
        return page_alloc.alloc();
    }
}.f;
const mapFn = struct {
    fn f(pgdir: u32, va: u32, pa: u32, flags: u32) void {
        vm.mapPage(pgdir, va, pa, flags);
    }
}.f;
const entry = elfload.load(USERPROG_ELF, root_pa, allocFn, mapFn, vm.USER_RWX) catch |err| {
    kprintf.panic("elfload PID 1 failed: {s}", .{@errorName(err)});
};
if (!vm.mapUserStack(root_pa)) kprintf.panic("mapUserStack PID 1 failed", .{});
```

And replace:
```zig
p.tf.sepc = vm.USER_TEXT_VA;
```
with:
```zig
p.tf.sepc = entry;
```

(Keep the `p.tf.sp = vm.USER_STACK_TOP;` line.)

- [ ] **Step 3: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 4: Run e2e-kernel — Phase 2 output through ELF loader**

Run: `zig build e2e-kernel`
Expected: PASS — same output as before. The userprog.elf's `_start` is at 0x00010000 (per user_linker.ld); the ELF loader maps PT_LOAD at p_vaddr = 0x00010000; `entry == 0x00010000`. tf.sepc = entry = 0x00010000 = same as Phase 2.

- [ ] **Step 5: Commit**

```bash
git add build.zig tests/programs/kernel/kmain.zig
git commit -m "feat(kernel): embed userprog.elf directly, load via elfload"
```

---

### Task 14: kmain — alloc PID 1 via proc.alloc + scheduler entry

**Files:**
- Modify: `tests/programs/kernel/kmain.zig`

**Why this task here:** With page_alloc, swtch, alloc, forkret, scheduler, and elfload all wired, we can now have kmain go through the official path: `proc.alloc()` for a fresh slot, `vm.allocRoot()` for the pgdir, `mapKernelAndMmio + elfload + mapUserStack`, set Runnable, jump to `scheduler()` on the scheduler stack.

- [ ] **Step 1: Rewrite kmain to use the proc/sched flow**

Replace the body of `kmain()` in `tests/programs/kernel/kmain.zig`:

```zig
export fn kmain() callconv(.c) noreturn {
    page_alloc.init();
    proc.cpuInit();

    // Allocate PID 1.
    const pid1 = proc.alloc() orelse kprintf.panic("kmain: proc.alloc PID 1", .{});
    @memcpy(pid1.name[0..4], "init");

    // Build PID 1's address space.
    const root = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot PID 1", .{});
    pid1.pgdir = root;
    pid1.satp = SATP_MODE_SV32 | (root >> 12);
    vm.mapKernelAndMmio(root);

    const allocFn = struct {
        fn f() ?u32 {
            return page_alloc.alloc();
        }
    }.f;
    const mapFn = struct {
        fn f(pgdir: u32, va: u32, pa: u32, flags: u32) void {
            vm.mapPage(pgdir, va, pa, flags);
        }
    }.f;

    const entry = elfload.load(boot_config.USERPROG_ELF, root, allocFn, mapFn, vm.USER_RWX) catch |err| {
        kprintf.panic("elfload PID 1: {s}", .{@errorName(err)});
    };
    if (!vm.mapUserStack(root)) kprintf.panic("mapUserStack PID 1", .{});

    pid1.tf.sepc = entry;
    pid1.tf.sp = vm.USER_STACK_TOP;
    pid1.sz = vm.USER_TEXT_VA + 0x10000; // initial brk above text region
    pid1.state = .Runnable;

    // Optional: PID 2.
    if (boot_config.MULTI_PROC) {
        const pid2 = proc.alloc() orelse kprintf.panic("kmain: alloc PID 2", .{});
        @memcpy(pid2.name[0..5], "init2");
        const root2 = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot PID 2", .{});
        pid2.pgdir = root2;
        pid2.satp = SATP_MODE_SV32 | (root2 >> 12);
        vm.mapKernelAndMmio(root2);
        const entry2 = elfload.load(boot_config.USERPROG2_ELF, root2, allocFn, mapFn, vm.USER_RWX) catch |err| {
            kprintf.panic("elfload PID 2: {s}", .{@errorName(err)});
        };
        if (!vm.mapUserStack(root2)) kprintf.panic("mapUserStack PID 2", .{});
        pid2.tf.sepc = entry2;
        pid2.tf.sp = vm.USER_STACK_TOP;
        pid2.sz = vm.USER_TEXT_VA + 0x10000;
        pid2.state = .Runnable;
    }

    // Install the S-mode trap vector + sscratch (will be overwritten on
    // each schedule, but a non-null initial value matters in case the
    // first schedule races a tick — defense-in-depth).
    const stvec_val: u32 = @intCast(@intFromPtr(&s_trap_entry));
    asm volatile (
        \\ csrw stvec, %[stv]
        \\ csrw sscratch, %[ss]
        :
        : [stv] "r" (stvec_val),
          [ss] "r" (@as(u32, @intCast(@intFromPtr(pid1)))),
        : .{ .memory = true }
    );

    // sie.SSIE for forwarded timer ticks.
    const SIE_SSIE: u32 = 1 << 1;
    asm volatile ("csrs sie, %[b]"
        :
        : [b] "r" (SIE_SSIE),
        : .{ .memory = true }
    );

    // sstatus: SPP=0, SPIE=1 — for whoever sret's first.
    const SSTATUS_SPP: u32 = 1 << 8;
    const SSTATUS_SPIE: u32 = 1 << 5;
    asm volatile (
        \\ csrc sstatus, %[spp]
        \\ csrs sstatus, %[spie]
        :
        : [spp] "r" (SSTATUS_SPP),
          [spie] "r" (SSTATUS_SPIE),
        : .{ .memory = true }
    );

    // Switch onto the scheduler stack and jump into scheduler(). swtch
    // saves the (irrelevant) caller context to a throwaway and jumps
    // into scheduler() with sp = sched_stack_top.
    var bootstrap: proc.Context = std.mem.zeroes(proc.Context);
    proc.cpu.sched_context.ra = @intCast(@intFromPtr(&sched.scheduler));
    proc.cpu.sched_context.sp = proc.cpu.sched_stack_top;
    proc.swtch(&bootstrap, &proc.cpu.sched_context);
    unreachable;
}
```

- [ ] **Step 2: Update imports at top of kmain.zig**

```zig
const std = @import("std");
const uart = @import("uart.zig");
const vm = @import("vm.zig");
const page_alloc = @import("page_alloc.zig");
const trap = @import("trap.zig");
const proc = @import("proc.zig");
const sched = @import("sched.zig");
const elfload = @import("elfload.zig");
const kprintf = @import("kprintf.zig");
const boot_config = @import("boot_config");

const SATP_MODE_SV32: u32 = 1 << 31;

extern fn s_trap_entry() void;

// Keep `uart` in the reachable set for early-boot panic printing.
comptime {
    _ = uart;
}
```

(Remove the `extern fn s_return_to_user` and `_kstack_top` — kmain no longer references them.)

- [ ] **Step 3: Build kernel and run e2e-kernel**

Run: `zig build kernel-elf && zig build e2e-kernel`
Expected: PASS — PID 1 enters via the scheduler+forkret path, prints "hello from u-mode\n", exits, sysExit prints "ticks observed: N\n", halts. Output unchanged.

If FAIL, common pitfalls:
- The scheduler reads `cpu.cur` to set `proc.cur()`; trap dispatch reads `proc.cur()` for `ticks_observed`. If `cpu.cur` is null briefly, `proc.cur()` falls back to `&ptable[0]` — a harmless coincidence in 3.B since pid1 *is* ptable[0].
- The scheduler's `csrw satp` happens AFTER swtch saves the bootstrap context, but BEFORE we jump to forkret. Verify the ordering in `sched.scheduler()` (Task 9).

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/kmain.zig
git commit -m "refactor(kmain): create PID 1 via proc.alloc and enter scheduler"
```

---

### Task 15: `getpid` syscall (#172)

**Files:**
- Modify: `tests/programs/kernel/syscall.zig`

**Why this task here:** Trivial syscall; lands now so userprog2 (Task 17) can label its output by pid.

- [ ] **Step 1: Add the syscall**

In `tests/programs/kernel/syscall.zig`, in the `dispatch` switch, add a `172` arm:

```zig
pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        93 => sysExit(tf.a0),
        124 => tf.a0 = sysYield(),
        172 => tf.a0 = sysGetpid(),
        else => tf.a0 = @bitCast(@as(i32, -38)),
    }
}

fn sysGetpid() u32 {
    return proc.cur().pid;
}
```

- [ ] **Step 2: Build kernel + e2e-kernel**

Run: `zig build e2e-kernel`
Expected: PASS — userprog.zig doesn't call getpid yet, so behavior unchanged.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/syscall.zig
git commit -m "feat(syscall): add getpid (#172)"
```

---

### Task 16: `sbrk` syscall (#214)

**Files:**
- Modify: `tests/programs/kernel/syscall.zig`

**Why this task here:** Provides heap growth for userland. Required by spec; userprog2 doesn't actually call it but landing it now keeps Plan 3.B's syscall list complete.

- [ ] **Step 1: Add the syscall**

In `tests/programs/kernel/syscall.zig`, after `sysGetpid`, add:

```zig
fn sysSbrk(incr_signed: u32) u32 {
    const incr: i32 = @bitCast(incr_signed);
    const p = proc.cur();
    const old_sz = p.sz;

    if (incr > 0) {
        const new_sz = old_sz + @as(u32, @intCast(incr));
        const PAGE_SIZE: u32 = 4096;
        const old_top = (old_sz + PAGE_SIZE - 1) & ~@as(u32, PAGE_SIZE - 1);
        const new_top = (new_sz + PAGE_SIZE - 1) & ~@as(u32, PAGE_SIZE - 1);
        var va: u32 = old_top;
        while (va < new_top) : (va += PAGE_SIZE) {
            const pa = page_alloc.alloc() orelse return @bitCast(@as(i32, -12)); // -ENOMEM
            vm.mapPage(p.pgdir, va, pa, vm.USER_RW);
        }
        p.sz = new_sz;
    } else if (incr < 0) {
        // 3.B accepts but doesn't unmap. 3.E will properly unmap and free.
        const dec: u32 = @intCast(-incr);
        if (dec > old_sz) return @bitCast(@as(i32, -22)); // -EINVAL
        p.sz = old_sz - dec;
    }
    return old_sz;
}
```

And in dispatch:
```zig
        214 => tf.a0 = sysSbrk(tf.a0),
```

Add the imports at top of syscall.zig:
```zig
const page_alloc = @import("page_alloc.zig");
const vm = @import("vm.zig");
```

- [ ] **Step 2: Build kernel + e2e-kernel**

Run: `zig build e2e-kernel`
Expected: PASS — userprog.zig doesn't call sbrk, so behavior unchanged.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/syscall.zig
git commit -m "feat(syscall): add sbrk (#214) with grow-only semantics for 3.B"
```

---

### Task 17: Second user ELF — `userprog2.zig`

**Files:**
- Create: `tests/programs/kernel/user/userprog2.zig`
- Modify: `build.zig` (add userprog2.elf build + embed)

**Why this task here:** The multi-proc test needs a second distinguishable user binary. We mirror userprog.zig's shape — naked `_start` makes write/yield/exit syscalls — but with a different message (`"[2] hello from u-mode\n"`, 22 bytes).

- [ ] **Step 1: Create userprog2.zig**

Create `tests/programs/kernel/user/userprog2.zig`:

```zig
// tests/programs/kernel/user/userprog2.zig — Phase 3.B PID 2 payload.
//
// Same shape as userprog.zig: write a message, yield, busy-loop, exit.
// Different message lets the multi-proc verifier distinguish PID 1 vs.
// PID 2 output. The busy-loop is shorter (10k vs. 100k) so PID 2
// finishes first and PID 1's exit triggers the halt + ticks-trailer.

const MSG = "[2] hello from u-mode\n"; // 22 bytes

export const msg2 linksection(".rodata") = [_]u8{
    '[', '2', ']', ' ',
    'h', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm', ' ',
    'u', '-', 'm', 'o', 'd', 'e', '\n',
};

comptime {
    if (MSG.len != 22) @compileError("MSG must be 22 bytes (see _start's a2)");
    if (msg2.len != 22) @compileError("msg2 array length must match MSG.len");
}

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, msg2
        \\ li   a2, 22
        \\ ecall
        \\ li   a7, 124
        \\ ecall
        \\ li   t0, 10000
        \\ 1:
        \\ addi t0, t0, -1
        \\ bnez t0, 1b
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\ 2:
        \\ j    2b
    );
}
```

- [ ] **Step 2: Add userprog2.elf to the build**

In `build.zig`, after the existing `userprog_elf` block, add:

```zig
    const userprog2_obj = b.addObject(.{
        .name = "userprog2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/user/userprog2.zig"),
            .target = rv_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const userprog2_elf = b.addExecutable(.{
        .name = "userprog2.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .ReleaseSmall,
            .strip = false,
            .single_threaded = true,
        }),
    });
    userprog2_elf.root_module.addObject(userprog2_obj);
    userprog2_elf.setLinkerScript(b.path("tests/programs/kernel/user/user_linker.ld"));
    userprog2_elf.entry = .{ .symbol_name = "_start" };

    const userprog2_elf_bin = userprog2_elf.getEmittedBin();
```

- [ ] **Step 3: Build userprog2.elf as a standalone artifact (sanity-check)**

Add an install + step:
```zig
    const install_userprog2_elf = b.addInstallFile(userprog2_elf_bin, "userprog2.elf");
    const userprog2_step = b.step("kernel-user2", "Build the Phase 3.B userprog2.elf");
    userprog2_step.dependOn(&install_userprog2_elf.step);
```

Run: `zig build kernel-user2`
Expected: PASS — `zig-out/userprog2.elf` exists.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/user/userprog2.zig build.zig
git commit -m "feat(userprog2): add Phase 3.B PID 2 payload binary"
```

---

### Task 18: `kernel-multi.elf` — second kernel ELF target with both userprogs

**Files:**
- Modify: `build.zig`

**Why this task here:** The multi-proc test needs a kernel built with `MULTI_PROC=true` and both ELFs embedded. We re-use every kernel object (boot, trampoline, mtimer, swtch, kmain) but feed in a different `boot_config.zig` stub.

- [ ] **Step 1: Add a second WriteFiles dir for the multi-proc boot_config**

In `build.zig`, after the existing `boot_config_stub_dir`, add:

```zig
    const multi_boot_config_stub_dir = b.addWriteFiles();
    const multi_boot_config_zig = multi_boot_config_stub_dir.add(
        "boot_config.zig",
        \\pub const MULTI_PROC: bool = true;
        \\pub const USERPROG_ELF: []const u8 = @embedFile("userprog.elf");
        \\pub const USERPROG2_ELF: []const u8 = @embedFile("userprog2.elf");
        \\
    );
    _ = multi_boot_config_stub_dir.addCopyFile(userprog_elf_bin, "userprog.elf");
    _ = multi_boot_config_stub_dir.addCopyFile(userprog2_elf_bin, "userprog2.elf");
```

- [ ] **Step 2: Add a second kernel kmain object that imports the multi-proc config**

After `kernel_kmain_obj`, add:

```zig
    const kernel_kmain_multi_obj = b.addObject(.{
        .name = "kernel-kmain-multi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/kmain.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_kmain_multi_obj.root_module.addAnonymousImport("boot_config", .{
        .root_source_file = multi_boot_config_zig,
    });
```

- [ ] **Step 3: Add `kernel-multi.elf` executable target**

After `install_kernel_elf` step:

```zig
    const kernel_multi_elf = b.addExecutable(.{
        .name = "kernel-multi.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_multi_elf.root_module.addObject(kernel_boot_obj);
    kernel_multi_elf.root_module.addObject(kernel_trampoline_obj);
    kernel_multi_elf.root_module.addObject(kernel_mtimer_obj);
    kernel_multi_elf.root_module.addObject(kernel_swtch_obj);
    kernel_multi_elf.root_module.addObject(kernel_kmain_multi_obj);
    kernel_multi_elf.setLinkerScript(b.path("tests/programs/kernel/linker.ld"));
    kernel_multi_elf.entry = .{ .symbol_name = "_M_start" };

    const install_kernel_multi_elf = b.addInstallArtifact(kernel_multi_elf, .{});
    const kernel_multi_step = b.step("kernel-multi", "Build the Phase 3.B multi-proc kernel.elf");
    kernel_multi_step.dependOn(&install_kernel_multi_elf.step);
```

- [ ] **Step 4: Build the multi-proc kernel**

Run: `zig build kernel-multi`
Expected: PASS — `zig-out/bin/kernel-multi.elf` exists.

- [ ] **Step 5: Smoke-test by running the emulator manually**

Run: `zig-out/bin/ccc zig-out/bin/kernel-multi.elf`
Expected: stdout contains both `"hello from u-mode\n"` and `"[2] hello from u-mode\n"`. Final line is `"ticks observed: N\n"`. Exit code 0.

If this fails:
- Check that `cpu.cur` is being set + cleared correctly across swtch
- Check that the SSI handler runs while PID 2 is in its busy-loop and yields back to the scheduler (otherwise PID 2 monopolizes)
- Inspect via `zig-out/bin/ccc --trace zig-out/bin/kernel-multi.elf 2>&1 | head -200` and confirm sret transitions to USER_TEXT_VA happen for both pgdirs.

- [ ] **Step 6: Run e2e-kernel — must still pass (single-proc target unchanged)**

Run: `zig build e2e-kernel`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add build.zig
git commit -m "feat(kernel): add kernel-multi.elf target with two embedded userprogs"
```

---

### Task 19: `e2e-multiproc-stub` — verifier + build step

**Files:**
- Create: `tests/programs/kernel/multiproc_verify_e2e.zig`
- Modify: `build.zig` (add e2e-multiproc-stub step)

**Why this task here:** Locks in the multi-proc behavior. Mirrors Plan 2.D's verify_e2e but checks substrings rather than exact prefix.

- [ ] **Step 1: Create the verifier**

Create `tests/programs/kernel/multiproc_verify_e2e.zig`:

```zig
// tests/programs/kernel/multiproc_verify_e2e.zig — Phase 3.B verifier.
//
// Spawns ccc on kernel-multi.elf, captures stdout, asserts:
//   - exit code 0
//   - stdout contains "hello from u-mode\n" (PID 1)
//   - stdout contains "[2] hello from u-mode\n" (PID 2)
//   - stdout contains "ticks observed: " followed by a decimal number
//     and a newline (PID 1's exit trailer; PID 1 is last to exit so
//     this line is preserved).
//
// Interleaving order is non-deterministic (round-robin + timer ticks).
// We check substrings rather than byte-exact prefixes.

const std = @import("std");
const Io = std.Io;

const FAIL_EXIT: u8 = 1;
const USAGE_EXIT: u8 = 2;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var stderr_buf: [512]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stderr = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(gpa);
    defer gpa.free(argv);

    if (argv.len != 3) {
        stderr.print("usage: {s} <ccc-binary> <kernel-multi.elf>\n", .{argv[0]}) catch {};
        stderr.flush() catch {};
        return USAGE_EXIT;
    }

    const child_argv = &[_][]const u8{ argv[1], argv[2] };
    var child = try std.process.spawn(io, .{
        .argv = child_argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    const MAX_BYTES: usize = 65536;
    var read_buf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &read_buf);
    const out = reader.interface.allocRemaining(gpa, .limited(MAX_BYTES)) catch |err| switch (err) {
        error.StreamTooLong => {
            stderr.print("multiproc_verify_e2e: output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
            stderr.flush() catch {};
            child.kill(io);
            return FAIL_EXIT;
        },
        else => return err,
    };
    defer gpa.free(out);

    const term = try child.wait(io);
    switch (term) {
        .exited => |code| if (code != 0) {
            stderr.print("multiproc_verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n", .{ code, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print("multiproc_verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n", .{ term, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    if (std.mem.indexOf(u8, out, "hello from u-mode\n") == null) {
        stderr.print("multiproc_verify_e2e: missing PID 1 message\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    if (std.mem.indexOf(u8, out, "[2] hello from u-mode\n") == null) {
        stderr.print("multiproc_verify_e2e: missing PID 2 message\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    const ticks_marker = "ticks observed: ";
    const ticks_idx = std.mem.indexOf(u8, out, ticks_marker) orelse {
        stderr.print("multiproc_verify_e2e: missing ticks-observed trailer\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };
    const after_ticks = out[ticks_idx + ticks_marker.len ..];
    var nl: usize = 0;
    while (nl < after_ticks.len and after_ticks[nl] != '\n') : (nl += 1) {}
    if (nl == 0 or nl == after_ticks.len) {
        stderr.print("multiproc_verify_e2e: malformed ticks line\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }
    _ = std.fmt.parseInt(u32, after_ticks[0..nl], 10) catch {
        stderr.print("multiproc_verify_e2e: ticks N not a number: {s}\n", .{after_ticks[0..nl]}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };

    return 0;
}
```

- [ ] **Step 2: Wire e2e-multiproc-stub into build.zig**

After the `e2e-kernel` step, add:

```zig
    const multiproc_verify = b.addExecutable(.{
        .name = "multiproc_verify_e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/multiproc_verify_e2e.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const e2e_multiproc_run = b.addRunArtifact(multiproc_verify);
    e2e_multiproc_run.addFileArg(exe.getEmittedBin());
    e2e_multiproc_run.addFileArg(kernel_multi_elf.getEmittedBin());
    e2e_multiproc_run.expectExitCode(0);

    const e2e_multiproc_step = b.step("e2e-multiproc-stub", "Run the Phase 3.B multi-proc e2e test (PID 1 + PID 2)");
    e2e_multiproc_step.dependOn(&e2e_multiproc_run.step);
```

- [ ] **Step 3: Run e2e-multiproc-stub**

Run: `zig build e2e-multiproc-stub`
Expected: PASS — both PID messages and the ticks-observed trailer appear in stdout, exit code 0.

- [ ] **Step 4: Run e2e-kernel — must also pass (Phase 2 regression)**

Run: `zig build e2e-kernel`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/multiproc_verify_e2e.zig build.zig
git commit -m "feat(test): add e2e-multiproc-stub Phase 3.B integration test"
```

---

### Task 20: Run the full test gauntlet

**Files:** none modified.

**Why this task here:** Verify every Phase 1, 2, and 3.A test still passes alongside the new Phase 3.B kernel changes.

- [ ] **Step 1: Run all unit tests**

Run: `zig build test`
Expected: PASS — host tests for elfload (3 tests), free-list, every Phase 1/2/3.A test.

- [ ] **Step 2: Run all riscv-tests**

Run: `zig build riscv-tests`
Expected: PASS — rv32ui (39 tests), rv32um (8), rv32ua (10), rv32mi (8), rv32si (5).

- [ ] **Step 3: Run all e2e steps individually**

Run, in order:
- `zig build e2e`
- `zig build e2e-mul`
- `zig build e2e-trap`
- `zig build e2e-hello-elf`
- `zig build e2e-kernel`
- `zig build e2e-plic-block`
- `zig build e2e-multiproc-stub`

Expected: All seven e2e tests PASS.

- [ ] **Step 4: Confirm no incidental file changes leaked through**

Run: `git status`
Expected: clean working tree (no modified files outside what tasks committed).

- [ ] **Step 5: No commit (this is a gate, not a code change).**

If any step in 1-3 fails, return to the relevant earlier task and fix. Common failure modes:

| Failure | Likely cause | Fix |
|---|---|---|
| `e2e-kernel` hangs | scheduler can't pick PID 1 (state stuck Embryo) | check `kmain` sets `state = .Runnable` before swtch into scheduler |
| `e2e-multiproc-stub` only shows PID 1 | timer tick not preempting PID 1's busy-loop | check `proc.yield` in SSI handler |
| `e2e-multiproc-stub` shows neither | scheduler halts immediately | check `cpu.sched_context.ra = scheduler` in kmain |
| host tests fail with `error: file not found: minimal_elf_fixture` | anonymous import not wired | re-check `kernel_host_tests.root_module.addAnonymousImport` |
| riscv-tests segfault | trampoline regression — sscratch dance broken | inspect trampoline.S Task 5 |

---

### Task 21: README + status update

**Files:**
- Modify: `README.md` (status line, layout section, e2e step list)

- [ ] **Step 1: Update the status line**

In `README.md`, find the line beginning with "Status:" or similar and bump to "Phase 3 Plan B in progress; Phase 3 Plan B done — multi-process foundation."

- [ ] **Step 2: Add e2e-multiproc-stub to the Layout / e2e tests section**

Append the new e2e step to the list, with a one-line description.

- [ ] **Step 3: Verify README renders cleanly**

Run: `cat README.md | head -100`
Expected: status / layout sections display correctly; no unclosed code fences or broken table formatting.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): record Phase 3 Plan B (multi-proc foundation)"
```

---

## Wrap-up

After all 21 tasks complete and `zig build test && zig build riscv-tests && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build e2e-kernel && zig build e2e-plic-block && zig build e2e-multiproc-stub` all pass:

- Plan 3.B is complete.
- The kernel now supports a real multi-process model: free-list page allocator, NPROC=16 process table, round-robin scheduler with `swtch`, kernel-side ELF loader, `getpid`/`sbrk`/`yield` syscalls.
- PID 1 boots from an embedded `userprog.elf`. The optional `kernel-multi.elf` build also creates PID 2 from `userprog2.elf`.
- All Phase 2 regression coverage holds.
- **Next plan:** 3.C — fork / exec / wait / exit / kill-flag. With ptable, alloc/free, ELF loader, and scheduler in place, 3.C extends the syscall surface and adds `copy_uvm` for full-AS fork.

**REQUIRED SUB-SKILL when this plan completes successfully:** Use `superpowers:finishing-a-development-branch` to verify tests, present options, execute the chosen completion path (PR / merge / cleanup).
