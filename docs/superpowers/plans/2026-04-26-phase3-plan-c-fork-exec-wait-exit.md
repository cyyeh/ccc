# Phase 3 Plan C — fork / exec / wait / exit / kill-flag (Implementation Plan)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land the full Unix-shaped process lifecycle on top of Phase 3.B's multi-process foundation. Implement `vm.copy_uvm` (full per-PTE address-space copy) and `vm.unmap_user` (per-PTE teardown); replace Plan 3.B's `proc.free` panic stub with a real reaper; add `proc.sleep` / `proc.wakeup` (xv6-style, with the SIE-disable race mitigation the spec calls out); add `proc.kill(pid)` (sets the kill flag, wakes the target if sleeping); implement `proc.fork` (full address-space copy, parent gets child PID, child gets 0 from the same `ecall`), `proc.exit` (closes fds — none yet — reparents children to PID 1, becomes Zombie, wakes parent), `proc.wait` (sleeps until a Zombie child appears, then harvests pid + xstate and frees the slot), and `proc.exec` (kernel-side rebuild of the calling proc's user AS from an embedded ELF blob; lands the System-V argv-on-user-stack tail). Wire syscalls 220 (`clone` → flagless fork), 221 (`execve`), 260 (`wait4`), 5000 (`set_fg_pid`), 5001 (`console_set_mode`); the latter two accept-and-discard until 3.E lands the console line discipline. Add a killed-flag check on every syscall return path: if `cur.killed != 0`, divert to `proc.exit(-1)` instead of `sret`-ing. Boot a new userland program `init.elf` (forks a child, parent waits, child execs `/bin/hello`) and a new `hello.elf` (writes a one-line greeting and exits 0). The headline acceptance is `e2e-fork`: `kernel-fork.elf` boots `init`, init forks `hello`, hello prints `hello from /bin/hello\n`, parent reaps the child, prints `init: reaped\n`, exits 0. Plan 3.B's two regression e2e tests (`e2e-kernel`, `e2e-multiproc-stub`) keep passing unchanged.

**Architecture:** Phase 3.B left every Process slot owning a `pgdir`, a `kstack`, and a slot of user pages — but no way to tear any of it down (`proc.free` was a panic stub) and no way to clone it (`vm.copy_uvm` did not exist). 3.C fills both halves. `vm.copy_uvm(src_pgdir, dst_pgdir, sz)` walks the source pgdir's L1 table, then each populated L0 table, copying every U-flagged 4 KB leaf into a freshly allocated frame in `dst_pgdir` with the same flags. Per-leaf failure path: free everything `dst_pgdir` owns and return `error.OutOfMemory`. `vm.unmap_user(pgdir, sz)` walks the same shape and frees every U-flagged leaf, every L0 table that backed only U leaves, and (if requested) the L1 root itself; kernel/MMIO leaves (G=1) are left alone. `proc.free(p)` calls `unmap_user(p.pgdir, p.sz, .free_root)`, frees `p.kstack`, and zeroes the slot (State.Unused == 0 by construction). `proc.sleep(chan)` sets `p.chan = chan; p.state = .Sleeping;` then calls `proc.sched()` — defensively wrapped in `disableSie()` per the spec's "sleep-then-yield race" mitigation. In 3.C the disable is redundant (trap entry already gives us `SIE = 0`), but we land it now so non-trap sleepers in 3.E+ stay correct without revisiting the call site. Critically, sleep does NOT re-enable SIE on return — the natural `sret` rotation (`SPIE → SIE`) restores `SIE = 1` for U-mode; re-enabling SIE inside sleep would leak `SIE = 1` into the residual trap-handler instructions where a timer-fired SSI could nest into trap.zig and clobber the trapframe (xv6's invariant: S-mode runs interrupts-off; only U-mode runs them on). `proc.wakeup(chan)` scans `ptable` and flips every Sleeping match to Runnable. `proc.kill(pid)` sets `target.killed = 1` and, if `target.state == .Sleeping`, also flips it to Runnable so the syscall return path observes the flag. The killed check itself lives in `trap.zig`'s ECALL branch right after `syscall.dispatch` returns: `if (proc.cur().killed != 0) sysExit(-1);`. `proc.fork()` allocates a child slot via existing `proc.alloc()` (which sets `context.ra = forkret` and a kernel stack), `vm.copy_uvm`s the parent into the child's freshly-allocated root, copies `parent.tf` into `child.tf` and pokes `child.tf.a0 = 0` so the child returns 0 from the same `ecall` instruction (parent gets the child PID via the syscall dispatcher's normal return path), copies `parent.sz`, marks `child.parent = parent`, copies the name, sets `child.state = .Runnable`. `proc.exit(status)` reparents every child of `cur` to `&ptable[0]` (PID 1, init), sets `cur.xstate = status; cur.state = .Zombie`, calls `proc.wakeup(@intFromPtr(cur.parent.?))` (parents sleep on their own pointer), then calls `proc.sched()` and never returns; the scheduler sees Zombie and skips. `proc.wait(status_user_va)` loops scanning `ptable` for `p.parent == cur`; if none exist it returns -1; if any exist but none are Zombie, it `proc.sleep(@intFromPtr(cur))` (parents sleep on their own address); if a Zombie child exists, it harvests pid + xstate (copying xstate into the user-supplied address with SUM=1), calls `proc.free(child)`, and returns the harvested pid. `proc.exec(path_va, argv_va)` is the trickiest piece: it builds the new user AS in scratch space (new pgdir, new mappings) before committing, so a mid-exec failure leaves the calling process untouched. The path string is copied from user space (with SUM=1) and looked up in a comptime "embedded blob registry" exposed by `boot_config.zig` (3.D will replace this lookup with `namei + readi`); if the path resolves, a fresh root is allocated, kernel + MMIO mapped via `vm.mapKernelAndMmio`, the ELF mapped via the existing `elfload.load` (re-used unchanged from 3.B), the user stack mapped via the existing `vm.mapUserStack`, and the System-V argv tail (argc, argv pointer array, NUL-terminated strings, 16-byte aligned) is written to the top of the new user stack via direct PA writes (since the new pgdir isn't installed yet, kernel addresses each user-stack page by the PA it just allocated). Once the new AS is fully built, exec swaps: it tears down the OLD user AS via `vm.unmap_user(old_pgdir, old_sz, .free_root)`, sets `cur.pgdir = new_root; cur.satp = SATP_MODE_SV32 | (new_root >> 12); cur.sz = new_high_water; cur.tf.sepc = entry; cur.tf.sp = USER_STACK_TOP - tail_size; cur.tf.a1 = argv_user_va;` (NOT `tf.a0` — the syscall dispatcher overwrites it with exec's return value), then `csrw satp` + `sfence.vma` so the kernel's own subsequent return-to-user uses the new translation. exec returns `argc`, which the dispatch arm writes into `tf.a0`, satisfying the System-V `_start(argc, argv)` calling convention. Plan 3.C's userland is still naked-asm Zig (the proper `start.S` / `usys.S` stdlib lands in 3.E): `init.zig` does `fork → if child execve("/bin/hello", ...) → if parent wait4(child_pid, &status) → write("init: reaped\n") → exit(0)`, and `hello.zig` does `write(1, "hello from /bin/hello\n", 22) → exit(0)`. Build adds an `init.elf` and `hello.elf` target alongside the existing `userprog.elf` / `userprog2.elf`, plus a third `boot_config` stub ("fork mode" — embeds init + hello + a `EMBEDDED_BLOBS` mapping `"/bin/hello" → HELLO_ELF`) feeding a new `kernel-fork.elf`. The new `e2e-fork` runs the new `fork_verify_e2e.zig` host harness (same pattern as `multiproc_verify_e2e.zig`): spawn `ccc kernel-fork.elf`, expect exit 0, assert stdout contains both `"hello from /bin/hello\n"` and `"init: reaped\n"` and ends with the canonical `"ticks observed: N\n"` trailer (PID 1 = init exits last).

**Tech Stack:** Zig 0.16.x (pinned in `build.zig.zon`), no new external dependencies. The userland binaries continue to use the Plan 2.D / 3.B naked-`_start` pattern — full `start.S` / `usys.S` / `ulib` / `uprintf` stdlib is a 3.E deliverable, and 3.C deliberately stays small. `fork_verify_e2e.zig` follows the Plan 2.D / 3.B `*_verify_e2e.zig` pattern (host-compiled, spawn ccc, regex stdout). Cross-compilation reuses the Phase 2 / 3.B `rv_target` ResolvedTarget. No new emulator code lands in 3.C — every change is kernel-side or build-wiring.

**Spec reference:** `docs/superpowers/specs/2026-04-25-phase3-multi-process-os-design.md` — Plan 3.C covers spec §Architecture (kernel modules `proc` extension and `vm.copy_uvm`), §Process model (`fork()`, `exec()`, `exit()` and `wait()`, Sleep / wakeup, Kill flag — minus the console RX wire-up which lands in 3.E), §Syscall surface rows for syscalls **220 (clone/fork)**, **221 (execve)**, **260 (wait4)**, **5000 (set_fg_pid — accept-and-discard)**, **5001 (console_set_mode — accept-and-discard)**, and §Implementation plan decomposition entry **3.C**. The xv6 source (Cox/Kaashoek/Morris MIT) remains the authoritative reference for the fork / exec / wait / exit dance and the sleep-channel pattern; when this plan and that source disagree, the spec is right.

**Plan 3.C scope (subset of Phase 3 spec):**

- **`vm.copy_uvm` (NEW in `vm.zig`)** — Full per-PTE copy of the user portion of one pgdir into another:
  - **Signature:** `pub fn copyUvm(src: u32, dst: u32, sz: u32) CopyError!void`.
  - **Walk:** scan VA from `0` (or `USER_TEXT_VA`, see below) to `sz` in `PAGE_SIZE` strides; for each VA, look up the leaf via `lookupPA(src, va)`; if absent, skip; if present, allocate a fresh frame in `dst` via `page_alloc.alloc()`, copy 4 KB from src PA to dst PA, install via `mapPage(dst, va, new_pa, USER_RWX)` (3.E will preserve per-segment flags). Also copy the user stack (`USER_STACK_BOTTOM` .. `USER_STACK_TOP`).
  - **Failure path:** any `page_alloc.alloc()` returning null triggers `vm.unmap_user(dst, sz, .leave_root)` and returns `error.OutOfMemory`. The caller (`proc.fork`) is responsible for freeing `dst`'s root and the child's kstack on error.
  - **Why `USER_RWX` not preserved-flags:** Phase 2 / 3.B's `elfload.load` maps every PT_LOAD with `USER_RWX` for simplicity, so the source PTEs already carry `USER_RWX` on every user page. 3.E refines `elfload.load` to honor per-segment R/W/X; `copy_uvm` will then need to preserve the source PTE's flags — but for 3.C the uniform `USER_RWX` choice is consistent with 3.B's `mapPage` calls.

- **`vm.unmap_user` (NEW in `vm.zig`)** — Walk a pgdir, free every U-flagged leaf, free L0 tables that contained only U leaves, and optionally free the L1 root:
  - **Signature:** `pub fn unmapUser(pgdir: u32, sz: u32, root: enum { leave_root, free_root }) void`.
  - **Walk:** for each L1 entry in `pgdir`, if the entry is a valid pointer PTE, walk each L0 leaf; if leaf is U-flagged + valid, `page_alloc.free(leaf_pa)`. After walking the L0 table, free the L0 page itself (`page_alloc.free(l0_pa)`) — every L0 table allocated by `mapPage` was for user-region VAs only (kernel + MMIO are mapped at higher VA ranges in different L1 entries). If `root == .free_root`, finally `page_alloc.free(pgdir)`.
  - **Why this signature:** `proc.free` calls `unmap_user(p.pgdir, p.sz, .free_root)` to fully reap a process. `proc.exec` calls `unmap_user(old_pgdir, old_sz, .free_root)` to swap to a new pgdir built in `exec`'s scratch path. `proc.fork`'s error-rollback path calls `unmap_user(new_pgdir, partial_sz, .free_root)` — same API.
  - **G-flag invariant:** kernel + MMIO mappings carry `PTE_G` (set in `vm.zig`'s `KERNEL_*` constants). User mappings never set `PTE_G`. We use the `PTE_U` bit, not `PTE_G`, as the "is-user" predicate (more direct, matches what `elfload.load` and `mapUserStack` set).

- **`proc.free` (REWRITE in `proc.zig`)** — Replace Plan 3.B's panic stub with the real reaper:
  - **Body:** `vm.unmap_user(p.pgdir, p.sz, .free_root); page_alloc.free(p.kstack); p.* = std.mem.zeroes(Process);` — the final zero sets `state = .Unused` (since `Unused == 0`) so the slot is immediately reusable.
  - **Caller invariants:** caller must hold no pointer into `p.tf`, `p.context`, or any other field after `free` returns. In 3.C, the only caller is `proc.wait` (after harvesting xstate); `proc.exit` does NOT free its own slot (the parent does, via wait).

- **`proc.sleep` / `proc.wakeup` (NEW in `proc.zig`)** — xv6-style sleep on `chan` (a usize used purely as an identity):
  - **Signatures:**
    ```zig
    pub fn sleep(chan: u32) void;
    pub fn wakeup(chan: u32) void;
    ```
  - **`sleep` body:** defensively disable SIE (`csrc sstatus, SSTATUS_SIE`), set `cur.chan = chan`, set `cur.state = .Sleeping`, call `proc.sched()`. When `sched()` returns (i.e. the scheduler swtch'd back into us), clear `cur.chan = 0`. **Do NOT re-enable SIE on return** — the natural sret-rotation (`SPIE → SIE`) at syscall-return restores `SIE = 1` in user mode; re-enabling SIE here would leak `SIE = 1` back into the trap-handler context where a timer-fired SSI could nest into trap.zig and clobber the trapframe.
  - **`wakeup` body:** for each `p` in `ptable`, if `p.state == .Sleeping and p.chan == chan`, set `p.state = .Runnable`. (Caller doesn't need SIE-disable — `wakeup` only flips state, no scheduling decision.)
  - **Race mitigation:** see spec §Process model — Sleep / wakeup. In 3.C the trap-entry hardware behavior already gives us `SIE = 0` whenever sleep is invoked from a syscall (the only sleep call site in 3.C). The explicit `disableSie` in sleep is defensive — for the day a future plan adds a non-trap sleeper (e.g., a dedicated kernel idle thread), the call site stays correct without revisiting sleep. The scheduler is NOT modified — every Phase 3.B / 3.C kernel context already runs with `SIE = 0` in S-mode; the scheduler's swtch into a Runnable proc preserves the SIE state of the most-recent context, which is `SIE = 0`; the inevitable `s_return_to_user → sret` restores `SIE = 1` for U-mode.

- **`proc.kill` (NEW in `proc.zig`)** — Set the killed flag, wake target if sleeping:
  - **Signature:** `pub fn kill(pid: u32) bool;` (returns true if a matching pid was found, false otherwise — useful for future signal delivery accounting).
  - **Body:** scan `ptable` for `p.pid == pid and p.state != .Unused`; if found, set `p.killed = 1`; if `p.state == .Sleeping`, flip to `.Runnable` so the killed-check on syscall return can fire.
  - **3.C usage:** none in normal flow (no console RX yet); 3.E wires `^C` → `kill(fg_pid)`. We still land it now because `set_fg_pid` is part of 3.C's syscall surface and `kill` is the natural companion.

- **Killed-check on syscall return (in `trap.zig`)** — After `syscall.dispatch(tf)` returns from the ECALL branch, check `proc.cur().killed`; if non-zero, call `syscall.sysExit(@bitCast(@as(i32, -1)))` (which never returns). 3.C never sets `killed`, so this is a defensive land-it-now path; 3.E activates it via `^C`.

- **`proc.fork` (NEW in `proc.zig`)** — Full-AS clone:
  - **Signature:** `pub fn fork() i32;` returning child pid to parent (positive), 0 to child, or -1 on failure.
  - **Body:**
    1. `const parent = cur();`
    2. `const child = alloc() orelse return -1;` (alloc allocates kstack, sets context.ra = forkret, picks an Unused slot — invariants from 3.B unchanged).
    3. `const root = vm.allocRoot() orelse { free_kstack_only(child); return -1; };` (we can't call `proc.free` here because the slot isn't yet a fully-formed Process — kstack is the only allocated resource; we free it directly via `page_alloc.free` and zero the slot).
    4. `vm.mapKernelAndMmio(root);`
    5. `vm.copyUvm(parent.pgdir, root, parent.sz) catch { vm.unmapUser(root, parent.sz, .free_root); free_kstack_only(child); return -1; };`
    6. Also copy the user-stack pages: `vm.copyUserStack(parent.pgdir, root) catch { … };` (a small helper that allocates 2 user-stack frames in `root` and `memcpy`s from parent's). NOTE: `copyUvm` already covers `0..sz`, but the user stack lives at `USER_STACK_BOTTOM` (above `sz`), so it needs a separate copy step.
    7. `child.pgdir = root; child.satp = SATP_MODE_SV32 | (root >> 12); child.sz = parent.sz;`
    8. `child.tf = parent.tf; child.tf.a0 = 0;` (child returns 0 from the same `ecall`).
    9. `child.parent = parent;`
    10. `@memcpy(&child.name, &parent.name);`
    11. `child.state = .Runnable;`
    12. `return @intCast(child.pid);`
  - **Helper:** `freeKstackOnly(p)` is `page_alloc.free(p.kstack); p.* = std.mem.zeroes(Process);` — used only on partial-construction failure (before `pgdir` is set).

- **`proc.exit` (NEW — replaces Plan 3.B's `sysExit` half) in `proc.zig`** —
  - **Signature:** `pub fn exit(status: i32) noreturn;`
  - **Body:**
    1. `const p = cur();`
    2. Reparent: for each `c` in `ptable` where `c.parent == p`, set `c.parent = &ptable[0]` (PID 1 = init, hard-wired here as in xv6).
    3. `p.xstate = status; p.state = .Zombie;`
    4. If `p.parent != null` and `p.parent.?.pid != p.pid`, `wakeup(@intFromPtr(p.parent.?));` (parent sleeps on its own pointer).
    5. **PID 1 special-case:** if `p.pid == 1`, also print `"ticks observed: N\n"` and write halt MMIO with `status & 0xFF`, then spin in `wfi` (preserves Phase 2's `e2e-kernel` and 3.B's `e2e-multiproc-stub` regression behavior).
    6. Else: `proc.sched()` and never return; the scheduler will see Zombie and skip; the parent's `wait()` will eventually free us.
  - **`syscall.zig` shim:** Plan 3.B's `sysExit` (PID-1 halt + non-PID-1 yield-loop) is replaced by `fn sysExit(status: u32) noreturn { proc.exit(@bitCast(status)); }`.

- **`proc.wait` (NEW in `proc.zig`)** —
  - **Signature:** `pub fn wait(status_user_va: u32) i32;` returning child pid harvested or -1 if no children exist.
  - **Body:**
    1. Loop forever:
       1. `var has_children = false; var found_zombie: ?*Process = null;`
       2. Scan `ptable`: if `c.parent == cur()`, `has_children = true`; if also `c.state == .Zombie`, `found_zombie = c; break;`.
       3. If `found_zombie` is non-null:
          - `if (status_user_va != 0) { setSum(); const p: *volatile i32 = @ptrFromInt(status_user_va); p.* = c.xstate; clearSum(); }` (allow `wait4` callers to pass `NULL`).
          - `const pid = c.pid;`
          - `proc.free(c);`
          - `return @intCast(pid);`
       4. If no children at all, `return -1;`
       5. Else (children alive but no zombie): `proc.sleep(@intFromPtr(cur()));` (parent sleeps on its own pointer; `proc.exit` wakes us).

- **Embedded blob registry (NEW in `boot_config.zig` stub, "fork" variant only)** —
  - **Shape:** a comptime constant table of `{path: []const u8, blob: []const u8}` records. For 3.C's fork-mode kernel, the table contains a single entry: `{"/bin/hello", HELLO_ELF}`.
  - **Other modes:** the single-mode and multi-mode boot_config stubs export `pub const EMBEDDED_BLOBS = .{};` (empty tuple). `proc.exec` returns -1 if asked for a path absent from the registry — since single/multi-mode kernels never call `exec`, the table is just unused.
  - **API in `boot_config`:** `pub fn lookupBlob(path: []const u8) ?[]const u8;` walks the table, returning the matching blob slice or null. (Build-time generated — see Task 14.)

- **`proc.exec` (NEW in `proc.zig`)** —
  - **Signature:** `pub fn exec(path_user_va: u32, argv_user_va: u32) i32;` — returns `argc` on success (which the syscall dispatcher writes into `tf.a0`, landing in the exec'd program's `_start` via the standard System-V calling convention); -1 on failure (caller's user AS untouched). Exec does NOT independently set `tf.a0` — that responsibility belongs to the dispatch arm via the return value.
  - **Body — overview:** copy the path string from user space, look it up in the embedded blob registry, validate ELF, build new pgdir + map kernel/MMIO, load PT_LOADs into new pgdir, allocate user stack in new pgdir, copy argv strings out of user space (before the old pgdir is gone), construct the System-V argv tail (argc + argv-ptr-array + NUL-terminated strings) on the new user stack via direct PA writes to the freshly-allocated stack pages, then commit by tearing down the old user AS and patching cur.{pgdir, satp, sz, tf.sepc, tf.sp, tf.a1}. The `csrw satp + sfence.vma` happens last so any kernel mid-exec read still uses the old translation if needed (we don't actually need it because all user reads happen before the swap, but the ordering is the safe one).
  - **Detailed steps:**
    1. **Copy path:** `var path_buf: [256]u8 = undefined;` then `copyStrFromUser(path_user_va, &path_buf) catch return -1;` (returns the slice up to the first NUL, with SUM=1 around the read; bounded copy with truncation = -1).
    2. **Copy argv (count + strings):** `var argv_buf: [8][64]u8 = undefined; var argv_len: [8]u32 = undefined; var argc: u32 = 0;` walk argv until we see a NULL pointer or hit `argc == 8`; for each entry, copy the string into `argv_buf[i]` (with SUM=1) and remember its length in `argv_len[i]`. Bound: 8 args of ≤64 bytes each.
    3. **Look up blob:** `const blob = boot_config.lookupBlob(path_buf[0..path_len]) orelse return -1;`
    4. **Build new pgdir:** `const new_root = vm.allocRoot() orelse return -1; vm.mapKernelAndMmio(new_root);`
    5. **Load ELF:** `const entry = elfload.load(blob, new_root, &page_alloc.alloc, &vm.mapPage, &vm.lookupPA, vm.USER_RWX) catch { vm.unmapUser(new_root, 0, .free_root); return -1; };` (passes `sz=0` to `unmapUser` — we don't know how far the ELF mapped, so we walk every L0 table; safe but slightly redundant. 3.E refines this).
    6. **Allocate user stack in new pgdir:** `if (!vm.mapUserStack(new_root)) { vm.unmapUser(new_root, USER_TEXT_VA + 0x10000, .free_root); return -1; }`.
    7. **Build argv tail in new user stack:** compute total tail size (16-byte aligned: `4 (argc) + 4*(argc+1) (argv ptr array, NULL-terminated) + sum(argv_len[i] + 1) (NUL-terminated strings) + padding`), pick `sp = USER_STACK_TOP - aligned_tail_size`, write argc / argv pointers / strings to the corresponding PA in the new user stack. The new stack pages were just allocated; their PAs are recoverable via `vm.lookupPA(new_root, USER_STACK_BOTTOM + i*PAGE_SIZE)`. Do the writes through those PAs directly (kernel-direct mapped, no SUM dance needed).
    8. **Commit (point of no return):**
       - `const old_pgdir = cur().pgdir; const old_sz = cur().sz;`
       - `cur().pgdir = new_root; cur().satp = SATP_MODE_SV32 | (new_root >> 12); cur().sz = entry_high_water; cur().tf.sepc = entry; cur().tf.sp = sp; cur().tf.a1 = argv_user_ptr;` (do NOT set `cur().tf.a0` — the dispatch arm overwrites it with the return value; we return `argc` so a0 lands as argc).
       - `csrw satp, cur().satp; sfence.vma zero, zero;`
       - `vm.unmapUser(old_pgdir, old_sz, .free_root);`
    9. **Return:** `return @as(i32, @intCast(argc));` — dispatch writes this into `tf.a0`, satisfying the System-V `_start(argc, argv)` ABI.
  - **`entry_high_water`:** tracks the highest VA written by `elfload.load`. For 3.C we accept a trivial over-estimate: `cur().sz = USER_TEXT_VA + 0x10000` (matches Plan 3.B's kmain). Plan 3.E will compute the real high-water from PT_LOAD `p_vaddr + p_memsz`.

- **Syscall surface additions (in `syscall.zig`)** — Wire syscalls 220 (`clone` → flagless `fork`), 221 (`execve`), 260 (`wait4`), 5000 (`set_fg_pid`), 5001 (`console_set_mode`):
  - `220 (clone)`: `tf.a0 = @bitCast(proc.fork());`
  - `221 (execve)`: `tf.a0 = @bitCast(proc.exec(tf.a0, tf.a1));`
  - `260 (wait4)`: `tf.a0 = @bitCast(proc.wait(tf.a1));` (only `pid_user_va = tf.a0` and `status_user_va = tf.a1` are honored; `options` and `rusage` are ignored — matches Phase 3 spec syscall surface row).
  - `5000 (set_fg_pid)`: accept-and-discard. `tf.a0 = 0;` (3.E wires this to the console line-discipline state).
  - `5001 (console_set_mode)`: accept-and-discard. `tf.a0 = 0;` (3.E wires this).
  - Existing rows (64 write, 93 exit, 124 yield, 172 getpid, 214 sbrk) unchanged.

- **`init.zig` userland program (NEW)** —
  - **Path:** `tests/programs/kernel/user/init.zig`.
  - **Behavior:** `_start`:
    1. `fork()` (a7=220, ecall).
    2. If a0 == 0 (child): `execve("/bin/hello", argv, 0)` (a7=221, a0=path, a1=argv, a2=0). On exec failure, `exit(1)`.
    3. Else (parent, a0 = child pid): save in saved reg; `wait4(pid, &status, 0, 0)` (a7=260); print `"init: reaped\n"` (12 bytes) via `write(1, msg, 12)`; `exit(0)`.
  - **Strings (in `.rodata`):** `path = "/bin/hello\x00"` (11 bytes); `arg0 = "hello\x00"` (6 bytes); `argv = [&arg0, NULL]` (2 pointers — 8 bytes); `reaped_msg = "init: reaped\n"` (13 bytes — wait the byte count says 12, recount: `'i','n','i','t',':',' ','r','e','a','p','e','d','\n'` = 13 bytes; we'll pass `a2 = 13`).
  - **Stack:** PID 1's user stack at `0x00030000..0x00032000` (Plan 3.B's `mapUserStack`). The naked `_start` does no Zig stack traffic — just inline asm — so the stack pointer is irrelevant until the post-fork `wait` syscall, which the kernel handles entirely without touching user stack.
  - **Status output buffer:** allocated in `.bss` so `wait4`'s `status_user_va = &status` resolves to a stable VA.

- **`hello.zig` userland program (NEW)** —
  - **Path:** `tests/programs/kernel/user/hello.zig`.
  - **Behavior:** `_start`:
    1. `write(1, msg, 22)` where `msg = "hello from /bin/hello\n"` (22 bytes).
    2. `exit(0)`.

- **`fork_boot_config.zig` build-time stub (NEW shape, 3rd variant alongside Plan 3.B's single + multi)** —
  - **Generated file:**
    ```zig
    pub const MULTI_PROC: bool = false;
    pub const FORK_DEMO: bool = true;
    pub const USERPROG_ELF: []const u8 = "";
    pub const USERPROG2_ELF: []const u8 = "";
    pub const INIT_ELF: []const u8 = @embedFile("init.elf");
    pub const HELLO_ELF: []const u8 = @embedFile("hello.elf");
    pub fn lookupBlob(path: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, path, "/bin/hello")) return HELLO_ELF;
        return null;
    }
    const std = @import("std");
    ```
  - **Existing single + multi stubs** add `pub const FORK_DEMO: bool = false;` and `pub const INIT_ELF: []const u8 = "";` and `pub const HELLO_ELF: []const u8 = "";` and a `lookupBlob` returning `null`. (Three-way stub set, all compile against the same kmain.zig.)

- **`kmain.zig` extension** — Existing single + multi paths unchanged. NEW fork-mode path:
  ```zig
  if (boot_config.FORK_DEMO) {
      const init_p = proc.alloc() orelse kprintf.panic("kmain: alloc init", .{});
      @memcpy(init_p.name[0..4], "init");
      const root = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot init", .{});
      init_p.pgdir = root;
      init_p.satp = SATP_MODE_SV32 | (root >> 12);
      vm.mapKernelAndMmio(root);
      const entry = elfload.load(boot_config.INIT_ELF, root, allocFn, mapFn, lookupFn, vm.USER_RWX) catch |err|
          kprintf.panic("elfload init: {s}", .{@errorName(err)});
      if (!vm.mapUserStack(root)) kprintf.panic("mapUserStack init", .{});
      init_p.tf.sepc = entry;
      init_p.tf.sp = vm.USER_STACK_TOP;
      init_p.sz = vm.USER_TEXT_VA + 0x10000;
      init_p.state = .Runnable;
  }
  ```
  Placed BEFORE the existing single-PID-1 path so fork-mode kernel skips the userprog setup. Single + multi continue to use the existing block.

- **Build wiring (`build.zig`)** — Add `init.elf` + `hello.elf` build steps (same shape as `userprog.elf`); add `fork_boot_config.zig` write-files stub; extend single + multi stubs with the new `FORK_DEMO` / `INIT_ELF` / `HELLO_ELF` / `lookupBlob` declarations; add `kernel-fork.elf` executable + install + step; add `e2e-fork` runner using a new `fork_verify_e2e.zig` host harness.

- **`fork_verify_e2e.zig` (NEW)** — Host-side harness, same skeleton as `multiproc_verify_e2e.zig`:
  1. Spawn `ccc kernel-fork.elf`, capture stdout, expect exit 0.
  2. Assert stdout *contains* `"hello from /bin/hello\n"`.
  3. Assert stdout *contains* `"init: reaped\n"`.
  4. Assert stdout ends with the canonical `"ticks observed: N\n"` trailer (PID 1 = init exits last, syscall.sysExit hits the PID-1 special case).

**Not in Plan 3.C (explicitly):**

- **Console RX line discipline + actual `^C` → `kill(fg_pid)` wiring** — Plan 3.E. 3.C lands `proc.kill` and `set_fg_pid` / `console_set_mode` syscalls, but no caller exercises them yet.
- **Block-device interrupt dispatch in `trap.zig`** — Plan 3.D (the bufcache is the first `sleep`er on a real device IRQ).
- **PLIC interrupt dispatch in S-mode trap.zig** — Plan 3.D / 3.E.
- **File table / fd table / `openat` / `read` from fd / `lseek` / `fstat`** — Plan 3.D / 3.E.
- **`cwd` field on Process** — Plan 3.D (lands with the FS).
- **`ofile` field on Process** — Plan 3.D. `proc.exit` and `proc.fork` therefore do NOT touch ofile in 3.C; 3.D extends both with `for (ofile) |maybe_f| { if (maybe_f) |f| file.close(f); }` and `child.ofile[i] = file.dup(parent.ofile[i])`.
- **Per-segment ELF permission honoring** — Plan 3.E.
- **Real `sbrk` shrink** — Plan 3.E.
- **`USER_TEXT_VA` shift from `0x0001_0000` to `0x0000_1000`** — Plan 3.E (deferred from 3.B).
- **mkfs / fs.img / loading `init` from disk** — Plan 3.D. 3.C's `init` is embedded.
- **User stdlib (`start.S`, `usys.S`, `ulib.zig`, `uprintf.zig`)** — Plan 3.E. 3.C's `init.zig` and `hello.zig` use the Plan 3.B naked-`_start`-with-inline-ecalls pattern.
- **Real signals / `sigaction` / `sigreturn`** — never (kill flag suffices for `^C`).
- **Argv envp** — accepted and ignored in `execve` (matches Phase 3 spec).
- **Argv > 8 entries or string > 64 bytes** — truncate-and-fail (`return -1` from `exec`). 3.E will lift to 32 / 256.
- **Scheduler SIE manipulation** — the Phase 3 spec mentions "re-enable SIE inside the scheduler loop" as part of the sleep-yield race mitigation. We do NOT implement this in 3.C: it would conflict with the xv6 invariant that S-mode always runs with `SIE = 0` and would risk a timer SSI nesting on the scheduler's own kstack (whose trapframe would belong to whichever process last yielded). Plan 3.C's race mitigation is the `disableSie` in `proc.sleep` plus the natural trap-entry `SIE = 0`; both paths leave the scheduler untouched. If a future plan introduces a hart-local idle loop that genuinely needs interrupts on (e.g., to break out of WFI), it owns reasoning about ISR-vs-scheduler-stack safety.

**Deviation from Plan 3.B's closing note:** none. 3.B delivered the multi-process foundation (page_alloc, ptable, scheduler, swtch, kernel-side ELF loader, getpid/sbrk/yield syscalls). 3.C extends `proc.zig` with the lifecycle primitives (fork/exec/wait/exit/kill/sleep/wakeup), extends `vm.zig` with `copy_uvm` + `unmap_user`, and adds five new syscalls. No emulator code, no FS code, no console code lands in 3.C.

---

## File structure (final state at end of Plan 3.C)

```
ccc/
├── .gitignore                                       ← UNCHANGED
├── .gitmodules                                      ← UNCHANGED
├── build.zig                                        ← MODIFIED (+init.elf; +hello.elf; +fork_boot_config; +kernel-fork.elf; +e2e-fork; extends 3 stub variants)
├── build.zig.zon                                    ← UNCHANGED
├── README.md                                        ← MODIFIED (status; Phase 3.C note; new e2e step; updated Layout block)
├── src/                                             ← UNCHANGED (emulator unchanged in 3.C)
└── tests/
    ├── programs/
    │   ├── hello/, mul_demo/, trap_demo/,
    │   │   hello_elf/, plic_block_test/             ← UNCHANGED
    │   └── kernel/
    │       ├── boot.S                               ← UNCHANGED
    │       ├── linker.ld                            ← UNCHANGED
    │       ├── mtimer.S                             ← UNCHANGED
    │       ├── trampoline.S                         ← UNCHANGED
    │       ├── kmain.zig                            ← MODIFIED (+ fork-mode boot path before single-mode block)
    │       ├── kprintf.zig                          ← UNCHANGED
    │       ├── page_alloc.zig                       ← UNCHANGED
    │       ├── proc.zig                             ← MODIFIED (real proc.free; sleep/wakeup; kill; fork; exit; wait; exec)
    │       ├── sched.zig                            ← UNCHANGED
    │       ├── swtch.S                              ← UNCHANGED
    │       ├── elfload.zig                          ← UNCHANGED (re-used by exec; per-segment flags is 3.E)
    │       ├── syscall.zig                          ← MODIFIED (+220 fork +221 execve +260 wait4 +5000 set_fg_pid +5001 console_set_mode; sysExit thin shim around proc.exit)
    │       ├── trap.zig                             ← MODIFIED (killed check after syscall.dispatch)
    │       ├── uart.zig                             ← UNCHANGED
    │       ├── vm.zig                               ← MODIFIED (+copyUvm; +copyUserStack helper; +unmapUser)
    │       ├── verify_e2e.zig                       ← UNCHANGED (Phase 2 e2e-kernel verifier)
    │       ├── multiproc_verify_e2e.zig             ← UNCHANGED (Phase 3.B e2e-multiproc-stub verifier)
    │       ├── fork_verify_e2e.zig                  ← NEW (e2e-fork verifier)
    │       └── user/
    │           ├── userprog.zig                     ← UNCHANGED
    │           ├── userprog2.zig                    ← UNCHANGED
    │           ├── init.zig                         ← NEW (PID 1 in fork-mode kernel: fork+exec+wait+print+exit)
    │           ├── hello.zig                        ← NEW (the program init execs)
    │           └── user_linker.ld                   ← UNCHANGED (init/hello use the same linker script)
    ├── fixtures/                                    ← UNCHANGED
    ├── riscv-tests/                                 ← UNCHANGED
    ├── riscv-tests-p.ld                             ← UNCHANGED
    ├── riscv-tests-s.ld                             ← UNCHANGED
    └── riscv-tests-shim/                            ← UNCHANGED
```

**Files removed in this plan:** none.

**Files renamed in this plan:** none.

---

## Conventions used in this plan

- All Zig code targets Zig 0.16.x. Same API surface as Plans 2.D, 3.A, and 3.B.
- Tests live as inline `test "name" { ... }` blocks alongside the code under test. `zig build test` runs every test reachable from `src/main.zig`. Kernel-side modules (those in `tests/programs/kernel/`) are RV32 cross-compiled and **not run as host tests**; we cover them via the e2e harnesses (which exercise the same code under the emulator) and by host-runnable unit tests for any *pure-data* logic that has a host equivalent. 3.C adds two host tests in `vm.zig`'s pure-arithmetic helpers (Task 1's `freeUserPtesInL0` walk over a synthetic L0 table) and re-uses 3.B's `elfload` host tests.
- Each task ends with a TDD cycle: write failing test, see it fail, implement minimally, verify pass, commit. Commit messages follow Conventional Commits. The commit footer used elsewhere in the repo is preserved unchanged.
- When extending a grouped switch (syscall.zig dispatch arms, build.zig kernel object list), we show the full block so diffs are unambiguous.
- Kernel asm offsets and Zig `pub const`s that name the same byte position must always be paired with a comptime assert tying them together (Phase 2 set this convention; 3.C preserves it — but 3.C does not introduce any new asm-visible offsets, so no new asserts land).
- Whenever a test needs a real `Memory`, it uses a local `setupRig()` helper. Per Plan 2.A/B/3.A convention, we don't extract a shared rig module — each file gets its own copy.
- Task order respects strict dependencies: `vm.copy_uvm` + `vm.unmap_user` before `proc.free`; `proc.free` + `proc.sleep` + `proc.wakeup` before `proc.fork` / `proc.wait` / `proc.exit`; `proc.exec` before its syscall is wired; userland binaries before `kernel-fork.elf` build target; new e2e harness last.
- All references to "Plan 3.B" mean the implementation plan at `docs/superpowers/plans/2026-04-25-phase3-plan-b-kernel-multiproc-foundation.md`. References to "Phase 3 spec" mean `docs/superpowers/specs/2026-04-25-phase3-multi-process-os-design.md`.

---

## Tasks

### Task 1: Add `vm.unmapUser` (per-PTE teardown)

**Files:**
- Modify: `tests/programs/kernel/vm.zig` (append `unmapUser` + helpers)

**Why this task first:** Three later tasks (`proc.free`, `proc.fork` rollback, `proc.exec` commit) all depend on a working teardown primitive. We land it before any caller exists so each subsequent task drops in cleanly.

- [ ] **Step 1: Add a host-runnable test for the L0-walk helper**

`unmapUser` itself walks linker-managed page tables (no host equivalent), but the inner per-L0 walk is pure pointer arithmetic over a synthetic table. We factor that out as `freeLeavesInL0` operating on a `*volatile [1024]u32` plus a `freeFn: *const fn(u32) void` callback so a host test can substitute a mock free.

In `tests/programs/kernel/vm.zig`, append at the end of file (before the file's final `pub fn mapUserStack`):

```zig
pub const RootPolicy = enum { leave_root, free_root };

/// Walk one L0 table and free every U-flagged leaf via the supplied callback.
/// Returns true iff at least one leaf was found (used by callers to decide
/// whether the L0 table itself is reclaimable).
pub fn freeLeavesInL0(
    l0_pa: u32,
    free_fn: *const fn (u32) void,
) bool {
    var any: bool = false;
    var i: u32 = 0;
    while (i < 1024) : (i += 1) {
        const e = ptePtr(l0_pa, i);
        const v = e.*;
        if ((v & PTE_V) == 0) continue;
        if ((v & PTE_U) == 0) continue;
        const leaf_pa = ppnOfPte(v) << 12;
        free_fn(leaf_pa);
        e.* = 0;
        any = true;
    }
    return any;
}
```

Add a host test at the end of the file:

```zig
test "freeLeavesInL0 frees user leaves and skips kernel/MMIO leaves" {
    if (@import("builtin").os.tag != .freestanding) {
        const std = @import("std");

        var table: [1024]u32 align(PAGE_SIZE) = .{0} ** 1024;

        // Slot 0: U leaf at PA 0x1000.
        table[0] = makeLeaf(0x1000, USER_RWX);
        // Slot 1: kernel leaf (G=1, no U) at PA 0x2000.
        table[1] = makeLeaf(0x2000, KERNEL_DATA);
        // Slot 2: invalid (V=0).
        table[2] = 0;
        // Slot 3: U leaf at PA 0x4000.
        table[3] = makeLeaf(0x4000, USER_RWX);

        const Recorder = struct {
            var freed: [16]u32 = undefined;
            var n: usize = 0;
            fn cb(pa: u32) void {
                freed[n] = pa;
                n += 1;
            }
        };
        Recorder.n = 0;

        const any = freeLeavesInL0(@intFromPtr(&table[0]), &Recorder.cb);

        try std.testing.expect(any);
        try std.testing.expectEqual(@as(usize, 2), Recorder.n);
        try std.testing.expectEqual(@as(u32, 0x1000), Recorder.freed[0]);
        try std.testing.expectEqual(@as(u32, 0x4000), Recorder.freed[1]);
        // U slots are zeroed; kernel slot is preserved.
        try std.testing.expectEqual(@as(u32, 0), table[0]);
        try std.testing.expect(table[1] != 0);
        try std.testing.expectEqual(@as(u32, 0), table[3]);
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `zig build test`
Expected: FAIL — `freeLeavesInL0` not yet defined (we just added the test before its production code lands; verify the failure mode is "undeclared identifier").

Now actually add the production code from Step 1's first code block (the `pub fn freeLeavesInL0` definition above) into the file.

- [ ] **Step 3: Run the test again to verify it passes**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 4: Add the full `unmapUser` walking the L1 table**

Append after `freeLeavesInL0`:

```zig
/// Tear down all user mappings under `pgdir`. Frees every U-flagged leaf
/// page, the L0 tables that hosted them, and (if `policy == .free_root`)
/// the L1 root itself. Kernel + MMIO leaves (which carry G=1 and lack
/// PTE_U) are left intact.
pub fn unmapUser(pgdir: u32, sz: u32, policy: RootPolicy) void {
    _ = sz; // 3.C walks every L1 entry; sz is only used as a hint by future plans.

    // Walk every L1 entry.
    var l1_idx: u32 = 0;
    while (l1_idx < 1024) : (l1_idx += 1) {
        const l1_e = ptePtr(pgdir, l1_idx);
        const l1_v = l1_e.*;
        if ((l1_v & PTE_V) == 0) continue;
        // Reject superpages (Plan 2 invariant — never written by mapPage).
        if ((l1_v & (PTE_R | PTE_W | PTE_X)) != 0) continue;

        const l0_pa = ppnOfPte(l1_v) << 12;

        // Determine if the L0 table backs ANY user mapping by walking it.
        // freeLeavesInL0 frees the user leaves and reports whether any
        // were freed. If yes, the L0 table itself is purely user-purpose
        // (kernel + MMIO live at non-overlapping L1 indexes), so we free
        // it too.
        const had_user = freeLeavesInL0(l0_pa, &page_alloc.free);
        if (had_user) {
            page_alloc.free(l0_pa);
            l1_e.* = 0;
        }
    }

    if (policy == .free_root) {
        page_alloc.free(pgdir);
    }
}
```

- [ ] **Step 5: Build the kernel to confirm `unmapUser` compiles**

Run: `zig build kernel-elf`
Expected: PASS — kernel.elf links without errors.

- [ ] **Step 6: Run e2e-kernel to verify Phase 2 regression intact**

Run: `zig build e2e-kernel`
Expected: PASS — `unmapUser` is defined but never called yet, so behavior is unchanged.

- [ ] **Step 7: Commit**

```bash
git add tests/programs/kernel/vm.zig
git commit -m "feat(vm): add unmapUser + freeLeavesInL0 for per-PTE teardown"
```

---

### Task 2: Add `vm.copyUvm` and `vm.copyUserStack`

**Files:**
- Modify: `tests/programs/kernel/vm.zig` (append `copyUvm`, `copyUserStack`, `CopyError`)

**Why this task here:** `proc.fork` (Task 7) needs both. We land them together because they share the same allocate-then-rollback shape: any failure mid-copy must hand back every frame already allocated, and `unmapUser` (Task 1) is the rollback path. We test the algorithm via e2e (Task 16) since it requires a live kernel-direct-mapped RAM region — host tests can't simulate the real PTE walk + `memcpy` shape.

- [ ] **Step 1: Add `CopyError` and `copyUvm` to `vm.zig`**

Append after `unmapUser`:

```zig
pub const CopyError = error{OutOfMemory};

/// Walk every user PTE in `src` from VA 0 up to `sz` (page-rounded up),
/// allocate a fresh frame in `dst`, copy 4 KB from src PA to dst PA, and
/// install at the same VA in `dst` with USER_RWX flags.
///
/// On any allocation failure: free every dst leaf already installed
/// (via unmapUser with .leave_root), and return error.OutOfMemory.
/// `dst`'s root is NOT freed by this function — caller owns root teardown.
pub fn copyUvm(src: u32, dst: u32, sz: u32) CopyError!void {
    const end_va = (sz + (PAGE_SIZE - 1)) & ~@as(u32, PAGE_SIZE - 1);
    var va: u32 = 0;
    while (va < end_va) : (va += PAGE_SIZE) {
        const src_pa = lookupPA(src, va) orelse continue;

        const dst_pa = page_alloc.alloc() orelse {
            // Rollback: free every leaf already installed in dst.
            unmapUser(dst, end_va, .leave_root);
            return CopyError.OutOfMemory;
        };

        // Direct copy via kernel-direct-mapped PA pointers.
        const src_ptr: [*]const volatile u8 = @ptrFromInt(src_pa);
        const dst_ptr: [*]volatile u8 = @ptrFromInt(dst_pa);
        var i: u32 = 0;
        while (i < PAGE_SIZE) : (i += 1) dst_ptr[i] = src_ptr[i];

        mapPage(dst, va, dst_pa, USER_RWX);
    }
}

/// Copy the 2-page user stack region from `src` to `dst`. Allocates two
/// fresh frames in `dst`, memcpys 4 KB each, installs as USER_RW at
/// USER_STACK_BOTTOM .. USER_STACK_BOTTOM + 8 KB.
///
/// On allocation failure, frees the (possibly partial) stack pages
/// already installed in `dst`. `dst`'s root is NOT freed.
pub fn copyUserStack(src: u32, dst: u32) CopyError!void {
    var i: u32 = 0;
    while (i < USER_STACK_PAGES) : (i += 1) {
        const va = USER_STACK_BOTTOM + i * PAGE_SIZE;
        const src_pa = lookupPA(src, va) orelse continue;

        const dst_pa = page_alloc.alloc() orelse {
            // Rollback only the user-stack range (leave the rest of dst
            // intact; copyUvm's caller may still want to use other pages).
            // We use unmapUser which is idempotent and only touches U leaves.
            unmapUser(dst, USER_STACK_TOP, .leave_root);
            return CopyError.OutOfMemory;
        };

        const src_ptr: [*]const volatile u8 = @ptrFromInt(src_pa);
        const dst_ptr: [*]volatile u8 = @ptrFromInt(dst_pa);
        var k: u32 = 0;
        while (k < PAGE_SIZE) : (k += 1) dst_ptr[k] = src_ptr[k];

        mapPage(dst, va, dst_pa, USER_RW);
    }
}
```

- [ ] **Step 2: Build the kernel to verify the additions compile**

Run: `zig build kernel-elf`
Expected: PASS — kernel.elf links cleanly.

- [ ] **Step 3: Run e2e-kernel to verify Phase 2 regression intact**

Run: `zig build e2e-kernel`
Expected: PASS — neither function is called yet.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/vm.zig
git commit -m "feat(vm): add copyUvm + copyUserStack with rollback on OOM"
```

---

### Task 3: Replace `proc.free` panic stub with the real reaper

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (rewrite `proc.free`)

**Why this task here:** Plan 3.B left `proc.free` as a panic stub. We need a real reaper before `proc.wait` (Task 9) can call it on harvested zombies, and before `proc.fork` (Task 7) can use it as a partial-construction rollback path. We land it now so both later callers compile cleanly.

- [ ] **Step 1: Rewrite `proc.free`**

In `tests/programs/kernel/proc.zig`, replace the existing `pub fn free(p: *Process) void` body:

```zig
pub fn free(p: *Process) void {
    // Tear down user-space mappings + free leaf frames + free L0 tables
    // + free the L1 root. Kernel + MMIO leaves are preserved (G=1,
    // !PTE_U). vm.unmapUser walks the full pgdir; sz is a 3.E hint, not
    // used in 3.C.
    @import("vm.zig").unmapUser(p.pgdir, p.sz, .free_root);

    // Free the kernel stack page.
    page_alloc.free(p.kstack);

    // Zero the slot. State.Unused == 0 so the slot is immediately reusable.
    p.* = std.mem.zeroes(Process);
}
```

- [ ] **Step 2: Add a small partial-construction helper**

Append after `free`:

```zig
/// Used by fork's error-rollback path AFTER `alloc()` succeeded but
/// BEFORE `pgdir` was populated. Frees only the kstack and zeroes the
/// slot — does NOT call vm.unmapUser (which would walk an invalid pgdir).
pub fn freeKstackOnly(p: *Process) void {
    page_alloc.free(p.kstack);
    p.* = std.mem.zeroes(Process);
}
```

- [ ] **Step 3: Build the kernel to verify both compile**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 4: Run e2e-kernel and e2e-multiproc-stub**

Run: `zig build e2e-kernel`
Expected: PASS.

Run: `zig build e2e-multiproc-stub`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/proc.zig
git commit -m "feat(proc): implement proc.free reaper + freeKstackOnly helper"
```

---

### Task 4: Add `proc.sleep` and `proc.wakeup`

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (append `sleep`, `wakeup`, SIE helpers)

**Why this task here:** `proc.wait` (Task 9) is the first sleeper in the kernel. We need the sleep/wakeup primitive in place — and the defensive `disableSie` the spec calls out — before wait can be implemented. Landing it as a focused task keeps the diff for `wait` itself about lifecycle, not concurrency primitives.

- [ ] **Step 1: Add SIE helpers and `sleep` / `wakeup` to `proc.zig`**

In `tests/programs/kernel/proc.zig`, append at the bottom (after `pub fn yield`):

```zig
const SSTATUS_SIE: u32 = 1 << 1;

inline fn disableSie() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SIE),
        : .{ .memory = true }
    );
}

/// xv6-style sleep on `chan` (a u32 used purely as identity).
///
/// In 3.C, sleep is only ever invoked from a syscall handler — and trap
/// entry sets `sstatus.SIE = 0` automatically — so the explicit
/// `disableSie()` here is defensive. Even so, we keep it: if 3.E (or
/// later) adds a non-trap sleeper (e.g., a kernel idle thread), the
/// call-site stays correct without revisiting sleep.
///
/// We deliberately do NOT re-enable SIE on return. The natural
/// `s_return_to_user → sret` rotation (`SPIE → SIE`) restores
/// `SIE = 1` for U-mode. Re-enabling SIE here would leak `SIE = 1`
/// back into the trap-handler's residual instructions (killed-check +
/// s_return_to_user), where a freshly-fired SSI could nest into
/// trap.zig and clobber the trapframe. (xv6's invariant: S-mode runs
/// with interrupts disabled; only U-mode runs with them on.)
pub fn sleep(chan: u32) void {
    const p = cur();

    disableSie();
    p.chan = chan;
    p.state = .Sleeping;
    sched();

    // We're back. Clear chan; SIE intentionally stays disabled.
    p.chan = 0;
}

/// Wake every Sleeping process that's blocked on `chan`. Idempotent —
/// non-Sleeping procs and unrelated chans are skipped silently. Caller
/// holds no special interrupt state; this is safe to call from both
/// process context (e.g. proc.exit waking parent) and ISR context
/// (3.D's block-device ISR waking the bufcache waiter).
pub fn wakeup(chan: u32) void {
    var i: u32 = 0;
    while (i < NPROC) : (i += 1) {
        const p = &ptable[i];
        if (p.state == .Sleeping and p.chan == chan) {
            p.state = .Runnable;
        }
    }
}
```

- [ ] **Step 2: Build the kernel to verify the additions compile**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 3: Run e2e-kernel and e2e-multiproc-stub to verify regression**

Run: `zig build e2e-kernel`
Expected: PASS — Plan 3.B's single-proc kernel runs unchanged. sleep/wakeup are defined but never called yet.

Run: `zig build e2e-multiproc-stub`
Expected: PASS — Plan 3.B's multi-proc stub runs unchanged.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/proc.zig
git commit -m "feat(proc): add sleep/wakeup primitives (SIE-off invariant)"
```

---

### Task 5: Add `proc.kill`

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (append `kill`)

**Why this task here:** `set_fg_pid` (Task 12) and the killed-check on syscall return (Task 6) both reference `proc.kill`'s semantics in their comments. Landing `kill` first lets the syscall arm and trap.zig branch reference the real function without forward-declaration awkwardness. Note: 3.C never actually calls `kill` from any external trigger — the console line discipline in 3.E will. We land it for completeness and so 3.E has zero proc.zig changes.

- [ ] **Step 1: Add `proc.kill` to `proc.zig`**

In `tests/programs/kernel/proc.zig`, append after `wakeup`:

```zig
/// Set the kill flag on `pid`'s process. If the target is sleeping, also
/// flip it to Runnable so the killed-check on syscall return fires. No
/// effect if `pid` is unknown or refers to an Unused slot. Returns true
/// iff a matching slot was found.
pub fn kill(pid: u32) bool {
    var i: u32 = 0;
    while (i < NPROC) : (i += 1) {
        const p = &ptable[i];
        if (p.pid == pid and p.state != .Unused) {
            p.killed = 1;
            if (p.state == .Sleeping) p.state = .Runnable;
            return true;
        }
    }
    return false;
}
```

- [ ] **Step 2: Build the kernel to verify the addition compiles**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 3: Run e2e-kernel to verify regression**

Run: `zig build e2e-kernel`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/proc.zig
git commit -m "feat(proc): add proc.kill for ^C-style flag-setting"
```

---

### Task 6: Add killed-check on syscall return path

**Files:**
- Modify: `tests/programs/kernel/trap.zig` (insert killed-check after syscall.dispatch)

**Why this task here:** With `proc.kill` (Task 5) defined and `proc.exit` (Task 8) about to land, we wire the only place the kernel checks the kill flag: right after a syscall completes, before `s_return_to_user` runs. We land this check now (before exit) so Task 8's tests don't have to also exercise the trap-side wiring.

- [ ] **Step 1: Add the killed-check in `trap.zig`'s ECALL branch**

In `tests/programs/kernel/trap.zig`, find the existing ECALL handling block:

```zig
    if (!is_interrupt and cause == 8) {
        // ECALL from U — advance sepc past the ecall instruction (4 bytes)
        // so sret returns to the next instruction.
        tf.sepc +%= 4;
        syscall.dispatch(tf);
        return;
    }
```

Replace with:

```zig
    if (!is_interrupt and cause == 8) {
        // ECALL from U — advance sepc past the ecall instruction (4 bytes)
        // so sret returns to the next instruction.
        tf.sepc +%= 4;
        syscall.dispatch(tf);

        // Kill-flag check: if a ^C (or other source) flagged this proc
        // mid-syscall (or before re-entry), divert to exit(-1) instead
        // of returning to user. 3.C lands the check; 3.E lands the only
        // path that sets the flag (console line discipline).
        if (proc.cur().killed != 0) {
            syscall.sysExit(@as(u32, @bitCast(@as(i32, -1))));
        }
        return;
    }
```

- [ ] **Step 2: Mark `syscall.sysExit` `pub`**

In `tests/programs/kernel/syscall.zig`, change the line:

```zig
fn sysExit(status: u32) noreturn {
```

to:

```zig
pub fn sysExit(status: u32) noreturn {
```

- [ ] **Step 3: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 4: Run e2e-kernel and e2e-multiproc-stub**

Run: `zig build e2e-kernel`
Expected: PASS — `killed` is always 0 in 3.B paths, so the check is a no-op.

Run: `zig build e2e-multiproc-stub`
Expected: PASS — same reason.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/trap.zig tests/programs/kernel/syscall.zig
git commit -m "feat(trap): check killed flag on syscall return; promote sysExit to pub"
```

---

### Task 7: Implement `proc.fork`

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (append `fork`)

**Why this task here:** All dependencies are now in place: `vm.copyUvm` + `vm.copyUserStack` + `vm.unmapUser` (Task 1, 2), `proc.alloc` (Plan 3.B) sets `context.ra = forkret` and a kstack, `proc.freeKstackOnly` (Task 3) handles the partial-construction rollback. Fork's only real responsibility here is wiring the steps in the right order with rollback on each failure mode.

- [ ] **Step 1: Add `proc.fork` to `proc.zig`**

In `tests/programs/kernel/proc.zig`, append after `proc.kill`:

```zig
const SATP_MODE_SV32: u32 = 1 << 31;

/// Full-AS fork. Returns child pid in parent (positive), 0 in child,
/// or -1 on failure. The child resumes at the same instruction as the
/// parent's post-ecall (s_trap_dispatch advanced sepc by 4 BEFORE
/// dispatching, so child.tf.sepc inherits the post-advance value).
pub fn fork() i32 {
    const vm = @import("vm.zig");

    const parent = cur();

    const child = alloc() orelse return -1;

    // Allocate a root pgdir and map kernel + MMIO into it.
    const new_root = vm.allocRoot() orelse {
        freeKstackOnly(child);
        return -1;
    };
    vm.mapKernelAndMmio(new_root);

    // Copy user .text/.data/.bss/heap (VA 0..sz).
    vm.copyUvm(parent.pgdir, new_root, parent.sz) catch {
        vm.unmapUser(new_root, parent.sz, .free_root);
        freeKstackOnly(child);
        return -1;
    };

    // Copy the user stack (above sz; copyUvm doesn't reach it).
    vm.copyUserStack(parent.pgdir, new_root) catch {
        vm.unmapUser(new_root, vm.USER_STACK_TOP, .free_root);
        freeKstackOnly(child);
        return -1;
    };

    // Wire process state. tf is copied wholesale (including sepc), then
    // overridden so child sees a0 = 0 from the same ecall. Parent's tf
    // is untouched here; the syscall dispatcher writes child.pid into
    // parent.tf.a0 on return.
    child.pgdir = new_root;
    child.satp = SATP_MODE_SV32 | (new_root >> 12);
    child.sz = parent.sz;
    child.tf = parent.tf;
    child.tf.a0 = 0;
    child.parent = parent;
    @memcpy(&child.name, &parent.name);
    child.state = .Runnable;

    return @as(i32, @intCast(child.pid));
}
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 3: Run e2e-kernel + e2e-multiproc-stub for regression**

Run: `zig build e2e-kernel`
Expected: PASS — fork is defined but never called yet.

Run: `zig build e2e-multiproc-stub`
Expected: PASS — same.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/proc.zig
git commit -m "feat(proc): implement proc.fork (full address-space copy)"
```

---

### Task 8: Implement `proc.exit` (full version)

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (append `exit`)
- Modify: `tests/programs/kernel/syscall.zig` (`sysExit` becomes a thin shim around `proc.exit`)

**Why this task here:** With `proc.fork` (Task 7) in place, exit can reference `cur.parent` knowing that any parent pointer it sees is meaningful. We also need exit before wait (Task 9) — wait sleeps until exit wakes it.

- [ ] **Step 1: Add `proc.exit` to `proc.zig`**

In `tests/programs/kernel/proc.zig`, append after `proc.fork`:

```zig
/// Full process exit. Reparents children to PID 1 (init), marks self
/// Zombie, wakes the parent (which may be sleeping in wait()). Never
/// returns. PID 1's exit additionally prints the canonical
/// "ticks observed: N\n" trailer and halts the emulator (preserves
/// e2e-kernel and e2e-multiproc-stub regression behavior).
pub fn exit(status: i32) noreturn {
    const p = cur();
    const kprintf = @import("kprintf.zig");

    // Reparent every child of `p` to PID 1 (init). PID 1 is hard-wired
    // to slot 0; if 3.D ever changes that, this lookup needs to scan
    // ptable for pid==1.
    const init_proc = &ptable[0];
    var i: u32 = 0;
    while (i < NPROC) : (i += 1) {
        const c = &ptable[i];
        if (c.parent == p) c.parent = init_proc;
    }

    p.xstate = status;
    p.state = .Zombie;

    // Wake the parent if it's sleeping in wait() (parent sleeps on its
    // own pointer). Guard against PID 1's null parent.
    if (p.parent) |par| {
        wakeup(@as(u32, @intCast(@intFromPtr(par))));
    }

    // PID 1 special-case: same trailer + halt as Phase 2 / 3.B.
    // Preserves e2e-kernel and e2e-multiproc-stub byte-for-byte.
    if (p.pid == 1) {
        kprintf.print("ticks observed: {d}\n", .{p.ticks_observed});
        const halt: *volatile u8 = @ptrFromInt(0x00100000);
        halt.* = @as(u8, @truncate(@as(u32, @bitCast(status)) & 0xFF));
        while (true) asm volatile ("wfi");
    }

    // Non-PID-1 exit: yield forever; scheduler will skip Zombies; parent
    // will reap us in wait(). The loop is defensive — if a future
    // scheduler bug picks us anyway, we just yield again.
    while (true) sched();
}
```

- [ ] **Step 2: Replace `syscall.sysExit` with a thin shim**

In `tests/programs/kernel/syscall.zig`, replace the existing `pub fn sysExit(status: u32) noreturn { … }` body (the multi-line block from Plan 3.B) with:

```zig
pub fn sysExit(status: u32) noreturn {
    proc.exit(@bitCast(status));
}
```

- [ ] **Step 3: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 4: Run e2e-kernel and e2e-multiproc-stub for regression**

Run: `zig build e2e-kernel`
Expected: PASS — PID 1 (the only proc) exits via the new path; PID-1 special-case prints "ticks observed: N\n" and halts. Output identical to Plan 3.B.

Run: `zig build e2e-multiproc-stub`
Expected: PASS — PID 2 exits to Zombie (scheduler skips); PID 1 exits via PID-1 special-case. Output identical to Plan 3.B.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/proc.zig tests/programs/kernel/syscall.zig
git commit -m "feat(proc): implement proc.exit (reparent, zombie, wake parent)"
```

---

### Task 9: Implement `proc.wait`

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (append `wait`)

**Why this task here:** All of wait's dependencies now exist: `proc.sleep` (Task 4), `proc.free` (Task 3), `proc.exit`'s wake-parent path (Task 8). Wait is the last lifecycle primitive before the syscall surface (Task 12) and exec (Task 11) wire everything up.

- [ ] **Step 1: Add `proc.wait` to `proc.zig`**

In `tests/programs/kernel/proc.zig`, append after `proc.exit`:

```zig
const SSTATUS_SUM: u32 = 1 << 18;

inline fn setSum() void {
    asm volatile ("csrs sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
    );
}

inline fn clearSum() void {
    asm volatile ("csrc sstatus, %[b]"
        :
        : [b] "r" (SSTATUS_SUM),
        : .{ .memory = true }
    );
}

/// xv6-style wait. Returns the harvested child pid, or -1 if `cur` has
/// no children. Sleeps if children exist but none are Zombie.
///
/// `status_user_va`: if non-zero, the harvested xstate is written there
/// (via SUM=1) before we return.
pub fn wait(status_user_va: u32) i32 {
    const me = cur();
    while (true) {
        var has_children = false;
        var i: u32 = 0;
        while (i < NPROC) : (i += 1) {
            const c = &ptable[i];
            if (c.parent != me) continue;
            if (c.state == .Unused) continue;
            has_children = true;
            if (c.state == .Zombie) {
                if (status_user_va != 0) {
                    setSum();
                    const sp: *volatile i32 = @ptrFromInt(status_user_va);
                    sp.* = c.xstate;
                    clearSum();
                }
                const pid = c.pid;
                free(c);
                return @as(i32, @intCast(pid));
            }
        }
        if (!has_children) return -1;
        sleep(@as(u32, @intCast(@intFromPtr(me))));
    }
}
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf`
Expected: PASS.

- [ ] **Step 3: Run regression e2es**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub`
Expected: PASS — wait is defined but never called yet.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/proc.zig
git commit -m "feat(proc): implement proc.wait (sleep on self until zombie child)"
```

---

### Task 10: Add embedded-blob registry to `boot_config` (single + multi stubs)

**Files:**
- Modify: `build.zig` (extend single-mode and multi-mode `boot_config.zig` write-files stubs with the new declarations)

**Why this task here:** Task 11 (proc.exec) calls `boot_config.lookupBlob(path)`. The function must exist in every mode the kernel supports — even single + multi modes that never call exec — so kmain compiles unchanged for them. We add the no-op `lookupBlob` to single + multi here; the fork-mode stub with the real registry lands in Task 14.

- [ ] **Step 1: Extend the single-mode `boot_config.zig` stub**

In `build.zig`, find this block (around line 289):

```zig
    const boot_config_stub_dir = b.addWriteFiles();
    const boot_config_zig = boot_config_stub_dir.add(
        "boot_config.zig",
        \\pub const MULTI_PROC: bool = false;
        \\pub const USERPROG_ELF: []const u8 = @embedFile("userprog.elf");
    );
```

Replace with:

```zig
    const boot_config_stub_dir = b.addWriteFiles();
    const boot_config_zig = boot_config_stub_dir.add(
        "boot_config.zig",
        \\const std = @import("std");
        \\pub const MULTI_PROC: bool = false;
        \\pub const FORK_DEMO: bool = false;
        \\pub const USERPROG_ELF: []const u8 = @embedFile("userprog.elf");
        \\pub const USERPROG2_ELF: []const u8 = "";
        \\pub const INIT_ELF: []const u8 = "";
        \\pub const HELLO_ELF: []const u8 = "";
        \\pub fn lookupBlob(path: []const u8) ?[]const u8 {
        \\    _ = path;
        \\    return null;
        \\}
        ,
    );
```

- [ ] **Step 2: Extend the multi-mode `boot_config.zig` stub**

In the same `build.zig`, find this block (around line 334):

```zig
    const multi_boot_config_stub_dir = b.addWriteFiles();
    const multi_boot_config_zig = multi_boot_config_stub_dir.add(
        "boot_config.zig",
        \\pub const MULTI_PROC: bool = true;
        \\pub const USERPROG_ELF: []const u8 = @embedFile("userprog.elf");
        \\pub const USERPROG2_ELF: []const u8 = @embedFile("userprog2.elf");
    );
```

Replace with:

```zig
    const multi_boot_config_stub_dir = b.addWriteFiles();
    const multi_boot_config_zig = multi_boot_config_stub_dir.add(
        "boot_config.zig",
        \\const std = @import("std");
        \\pub const MULTI_PROC: bool = true;
        \\pub const FORK_DEMO: bool = false;
        \\pub const USERPROG_ELF: []const u8 = @embedFile("userprog.elf");
        \\pub const USERPROG2_ELF: []const u8 = @embedFile("userprog2.elf");
        \\pub const INIT_ELF: []const u8 = "";
        \\pub const HELLO_ELF: []const u8 = "";
        \\pub fn lookupBlob(path: []const u8) ?[]const u8 {
        \\    _ = path;
        \\    return null;
        \\}
        ,
    );
```

- [ ] **Step 3: Build the kernel + kernel-multi to verify both stubs compile**

Run: `zig build kernel-elf && zig build kernel-multi`
Expected: PASS — the new declarations are unused but compile cleanly.

- [ ] **Step 4: Run regression e2es**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add build.zig
git commit -m "build(boot_config): extend single + multi stubs with FORK_DEMO + lookupBlob"
```

---

### Task 11: Implement `proc.exec`

**Files:**
- Modify: `tests/programs/kernel/proc.zig` (append `exec` + helpers)

**Why this task here:** With wait + exit + fork in place and `boot_config.lookupBlob` callable in every mode, exec is the last lifecycle primitive to land before syscall wiring (Task 12). exec is the most algorithmically complex piece — building the new AS in scratch space, then committing — so we land it as a focused task with no other surface-area changes.

- [ ] **Step 1: Add `proc.exec` and the user-string copy helper**

In `tests/programs/kernel/proc.zig`, append after `proc.wait`:

```zig
const elfload = @import("elfload.zig");
const boot_config = @import("boot_config");

const MAX_PATH: u32 = 256;
const MAX_ARGS: u32 = 8;
const MAX_ARG_LEN: u32 = 64;

/// Copy a NUL-terminated user string into `buf`. Returns the slice up
/// to (but not including) the NUL. Returns null on truncation (string
/// longer than buf) or NUL not found within MAX_PATH bytes.
fn copyStrFromUser(user_va: u32, buf: []u8) ?[]u8 {
    setSum();
    defer clearSum();
    var i: u32 = 0;
    while (i < buf.len) : (i += 1) {
        const p: *const volatile u8 = @ptrFromInt(user_va + i);
        const c = p.*;
        buf[i] = c;
        if (c == 0) return buf[0..i];
    }
    return null;
}

/// Copy the argv pointer array + the strings it points to. argv_user_va
/// is the user VA of a `[*:null]?[*:0]u8`-style array. Returns argc on
/// success, null on overflow / truncation.
fn copyArgvFromUser(
    argv_user_va: u32,
    arg_storage: *[MAX_ARGS][MAX_ARG_LEN]u8,
    arg_lens: *[MAX_ARGS]u32,
) ?u32 {
    if (argv_user_va == 0) {
        return 0;
    }
    var argc: u32 = 0;
    while (argc < MAX_ARGS) : (argc += 1) {
        setSum();
        const slot: *const volatile u32 = @ptrFromInt(argv_user_va + argc * 4);
        const arg_ptr = slot.*;
        clearSum();
        if (arg_ptr == 0) return argc;
        const slice = copyStrFromUser(arg_ptr, &arg_storage[argc]) orelse return null;
        arg_lens[argc] = @intCast(slice.len);
    }
    // Hit MAX_ARGS without seeing the NULL terminator — refuse the call.
    return null;
}

/// In-place exec. Build new user AS in scratch, then commit by tearing
/// down the old AS and pointing cur at the new one. On any failure
/// before commit, the calling proc is untouched and we return -1.
pub fn exec(path_user_va: u32, argv_user_va: u32) i32 {
    const vm = @import("vm.zig");
    const PAGE_SIZE = vm.PAGE_SIZE;

    // 1. Copy path string out of user space.
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = copyStrFromUser(path_user_va, &path_buf) orelse return -1;

    // 2. Copy argv strings out of user space (before old AS is torn down).
    var arg_storage: [MAX_ARGS][MAX_ARG_LEN]u8 = undefined;
    var arg_lens: [MAX_ARGS]u32 = undefined;
    const argc = copyArgvFromUser(argv_user_va, &arg_storage, &arg_lens) orelse return -1;

    // 3. Look up the embedded blob.
    const blob = boot_config.lookupBlob(path) orelse return -1;

    // 4. Build new pgdir + map kernel/MMIO.
    const new_root = vm.allocRoot() orelse return -1;
    vm.mapKernelAndMmio(new_root);

    // 5. Load PT_LOADs into new pgdir.
    const allocFn = struct {
        fn f() ?u32 {
            return page_alloc.alloc();
        }
    }.f;
    const mapFn = struct {
        fn f(pgd: u32, va: u32, pa: u32, flags: u32) void {
            vm.mapPage(pgd, va, pa, flags);
        }
    }.f;
    const lookupFn = struct {
        fn f(pgd: u32, va: u32) ?u32 {
            return vm.lookupPA(pgd, va);
        }
    }.f;
    const entry = elfload.load(blob, new_root, allocFn, mapFn, lookupFn, vm.USER_RWX) catch {
        vm.unmapUser(new_root, 0, .free_root);
        return -1;
    };

    // 6. Allocate user stack in new pgdir.
    if (!vm.mapUserStack(new_root)) {
        vm.unmapUser(new_root, vm.USER_TEXT_VA + 0x10000, .free_root);
        return -1;
    }

    // 7. Build the System-V argv tail at the top of the new user stack.
    //
    // Layout (low -> high VA):
    //   [argc:u32] [argv[0]:u32] ... [argv[argc-1]:u32] [NULL:u32]
    //   [str0\0] [str1\0] ... [strN-1\0] [pad to 16-byte align]
    //
    // We place this so the final byte sits at USER_STACK_TOP - 1, then
    // sp = argc address (lowest byte of the tail).

    var strings_total: u32 = 0;
    var k: u32 = 0;
    while (k < argc) : (k += 1) strings_total += arg_lens[k] + 1;

    const ptr_array_bytes: u32 = 4 + (argc + 1) * 4; // argc + (argc+1)*ptr
    const tail_unaligned = ptr_array_bytes + strings_total;
    const tail_size = (tail_unaligned + 15) & ~@as(u32, 15);

    const sp_user_va = vm.USER_STACK_TOP - tail_size;

    // The tail spans at most 2 pages (USER_STACK_PAGES = 2; tail_size
    // bounded by ptr_array_bytes (≤ 40) + strings_total (≤ 8*65 = 520)
    // = 560 bytes, well under one page). For simplicity we still do
    // per-byte writes via lookupPA + page-offset arithmetic.

    var off: u32 = 0;
    while (off < tail_size) : (off += 1) {
        const va = sp_user_va + off;
        const page_va = va & ~@as(u32, PAGE_SIZE - 1);
        const page_off = va - page_va;
        const pa = vm.lookupPA(new_root, page_va) orelse {
            // Should never happen — mapUserStack just mapped both stack pages.
            vm.unmapUser(new_root, vm.USER_TEXT_VA + 0x10000, .free_root);
            return -1;
        };
        const dst: *volatile u8 = @ptrFromInt(pa + page_off);
        dst.* = 0; // pre-zero
    }

    // Helper: write a u32 at sp_user_va + off via PA lookup.
    const writeU32 = struct {
        fn f(root: u32, sp_va: u32, byte_off: u32, value: u32) void {
            const va_lo = sp_va + byte_off;
            const PS: u32 = 4096;
            const page_va = va_lo & ~@as(u32, PS - 1);
            const page_off = va_lo - page_va;
            const pa = @import("vm.zig").lookupPA(root, page_va).?;
            const dst: *volatile u32 = @ptrFromInt(pa + page_off);
            dst.* = value;
        }
    }.f;

    // Helper: write a byte at sp_user_va + off via PA lookup.
    const writeByte = struct {
        fn f(root: u32, sp_va: u32, byte_off: u32, value: u8) void {
            const va_lo = sp_va + byte_off;
            const PS: u32 = 4096;
            const page_va = va_lo & ~@as(u32, PS - 1);
            const page_off = va_lo - page_va;
            const pa = @import("vm.zig").lookupPA(root, page_va).?;
            const dst: *volatile u8 = @ptrFromInt(pa + page_off);
            dst.* = value;
        }
    }.f;

    // Write argc.
    writeU32(new_root, sp_user_va, 0, argc);

    // Compute and write argv[i] pointers (USER VAs into the strings region).
    var strings_off: u32 = ptr_array_bytes;
    var ai: u32 = 0;
    while (ai < argc) : (ai += 1) {
        const arg_va = sp_user_va + strings_off;
        writeU32(new_root, sp_user_va, 4 + ai * 4, arg_va);
        // Copy the bytes of arg_storage[ai][0..arg_lens[ai]] + NUL.
        var bi: u32 = 0;
        while (bi < arg_lens[ai]) : (bi += 1) {
            writeByte(new_root, sp_user_va, strings_off + bi, arg_storage[ai][bi]);
        }
        writeByte(new_root, sp_user_va, strings_off + arg_lens[ai], 0);
        strings_off += arg_lens[ai] + 1;
    }
    // Final NULL pointer in argv array.
    writeU32(new_root, sp_user_va, 4 + argc * 4, 0);

    // 8. Commit.
    const me = cur();
    const old_pgdir = me.pgdir;
    const old_sz = me.sz;

    me.pgdir = new_root;
    me.satp = SATP_MODE_SV32 | (new_root >> 12);
    me.sz = vm.USER_TEXT_VA + 0x10000; // 3.E will refine to real high-water
    me.tf.sepc = entry;
    me.tf.sp = sp_user_va;
    me.tf.a1 = sp_user_va + 4; // argv pointer is just past argc
    // Do NOT touch tf.a0 — the syscall dispatch arm overwrites it with
    // exec's return value below. We return argc so a0 lands as argc,
    // satisfying the System-V `_start(argc, argv)` calling convention.

    // Switch to new translation; the s_return_to_user path will run on it.
    asm volatile (
        \\ csrw satp, %[s]
        \\ sfence.vma zero, zero
        :
        : [s] "r" (me.satp),
        : .{ .memory = true }
    );

    // Tear down the old AS now that we're committed.
    vm.unmapUser(old_pgdir, old_sz, .free_root);

    return @as(i32, @intCast(argc));
}
```

- [ ] **Step 2: Build the kernel**

Run: `zig build kernel-elf && zig build kernel-multi`
Expected: PASS.

- [ ] **Step 3: Run regression e2es**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub`
Expected: PASS — exec is defined but never called.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/proc.zig
git commit -m "feat(proc): implement proc.exec (in-place AS rebuild + System-V argv tail)"
```

---

### Task 12: Wire syscalls 220 (clone/fork), 221 (execve), 260 (wait4), 5000, 5001

**Files:**
- Modify: `tests/programs/kernel/syscall.zig` (add five new syscall arms)

**Why this task here:** All kernel-side primitives (`fork`, `exec`, `wait`, `kill`) now exist. Wiring the syscalls is a pure-dispatch change — each new arm is one line. We do this together as a single task because they share the same dispatch surface and the diff is small.

- [ ] **Step 1: Add the five new syscall arms in `syscall.zig`**

In `tests/programs/kernel/syscall.zig`, replace the existing `pub fn dispatch(tf: *trap.TrapFrame) void` body:

```zig
pub fn dispatch(tf: *trap.TrapFrame) void {
    switch (tf.a7) {
        64 => tf.a0 = sysWrite(tf.a0, tf.a1, tf.a2),
        93 => sysExit(tf.a0),
        124 => tf.a0 = sysYield(),
        172 => tf.a0 = sysGetpid(),
        214 => tf.a0 = sysSbrk(tf.a0),
        220 => tf.a0 = @bitCast(proc.fork()),
        221 => tf.a0 = @bitCast(proc.exec(tf.a0, tf.a1)),
        260 => tf.a0 = @bitCast(proc.wait(tf.a1)),
        5000 => tf.a0 = sysSetFgPid(tf.a0),
        5001 => tf.a0 = sysConsoleSetMode(tf.a0),
        else => tf.a0 = @bitCast(@as(i32, -38)), // -ENOSYS
    }
}
```

- [ ] **Step 2: Add the two accept-and-discard syscall stubs**

In `tests/programs/kernel/syscall.zig`, immediately before `pub fn dispatch`, add:

```zig
/// 5000 set_fg_pid: shell-only API for telling the console what process
/// `^C` should target. 3.C accepts and discards; 3.E (when the console
/// line discipline lands) wires this to the actual fg_pid global.
fn sysSetFgPid(pid: u32) u32 {
    _ = pid;
    return 0;
}

/// 5001 console_set_mode: editor-only API for switching cooked vs raw
/// line discipline. 3.C accepts and discards; 3.E wires this to the
/// console state machine.
fn sysConsoleSetMode(mode: u32) u32 {
    _ = mode;
    return 0;
}
```

- [ ] **Step 3: Build the kernel**

Run: `zig build kernel-elf && zig build kernel-multi`
Expected: PASS.

- [ ] **Step 4: Run regression e2es**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub`
Expected: PASS — Plan 3.B's userprog.zig and userprog2.zig don't issue any of the new syscalls; behavior unchanged.

- [ ] **Step 5: Commit**

```bash
git add tests/programs/kernel/syscall.zig
git commit -m "feat(syscall): wire 220 fork / 221 execve / 260 wait4 / 5000 / 5001"
```

---

### Task 13: Add `init.zig` and `hello.zig` userland programs

**Files:**
- Create: `tests/programs/kernel/user/init.zig`
- Create: `tests/programs/kernel/user/hello.zig`

**Why this task here:** With every syscall wired, we can now build the userland programs that will exercise fork/exec/wait/exit end-to-end. We land them as source-only here; the build wiring + kernel-fork.elf + e2e harness come in Tasks 14-16.

- [ ] **Step 1: Create `init.zig`**

Create `tests/programs/kernel/user/init.zig` with:

```zig
// tests/programs/kernel/user/init.zig — Phase 3.C PID 1 payload.
//
// Behavior:
//   1. fork()
//   2. child:  execve("/bin/hello", ["hello", NULL], NULL); on failure exit(1)
//   3. parent: wait4(child_pid, &status, 0, 0); print "init: reaped\n"; exit(0)
//
// Naked _start with inline ecalls — same shape as Plan 3.B userprog.zig.
// 3.E will rewrite this against the userland stdlib (start.S + usys.S).
//
// .rodata layout:
//   path      : "/bin/hello\0"        (11 bytes)
//   arg0      : "hello\0"             (6 bytes)
//   reaped_msg: "init: reaped\n"      (13 bytes)
// .data (mutable) layout:
//   argv      : [&arg0, NULL]         (8 bytes)
//   status    : i32                   (wait's output)

export const path linksection(".rodata") = [_]u8{
    '/', 'b', 'i', 'n', '/', 'h', 'e', 'l', 'l', 'o', 0,
};

export const arg0 linksection(".rodata") = [_]u8{
    'h', 'e', 'l', 'l', 'o', 0,
};

export const reaped_msg linksection(".rodata") = [_]u8{
    'i', 'n', 'i', 't', ':', ' ', 'r', 'e', 'a', 'p', 'e', 'd', '\n',
};

// Mutable argv array — pointer slots filled by _start's la instructions.
// Plan 3.E userland-stdlib will move this out of .data into a stack-built
// argv; until then we use a fixed .data layout because naked asm can't
// easily build pointer arrays on the stack.
export var argv linksection(".data") = [_]u32{ 0, 0 };

export var status linksection(".bss") = @as(i32, 0);

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ // argv[0] = &arg0; argv[1] = 0
        \\ la   t0, argv
        \\ la   t1, arg0
        \\ sw   t1, 0(t0)
        \\ sw   zero, 4(t0)
        \\
        \\ // fork()
        \\ li   a7, 220
        \\ ecall
        \\ beqz a0, child
        \\
        \\ // parent: save child pid in s1 (callee-saved, survives ecall)
        \\ mv   s1, a0
        \\
        \\ // wait4(s1, &status, 0, 0)
        \\ li   a7, 260
        \\ mv   a0, s1
        \\ la   a1, status
        \\ li   a2, 0
        \\ li   a3, 0
        \\ ecall
        \\
        \\ // write(1, reaped_msg, 13)
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, reaped_msg
        \\ li   a2, 13
        \\ ecall
        \\
        \\ // exit(0)
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\
        \\ // unreachable
        \\1: j 1b
        \\
        \\child:
        \\ // execve("/bin/hello", argv, 0)
        \\ li   a7, 221
        \\ la   a0, path
        \\ la   a1, argv
        \\ li   a2, 0
        \\ ecall
        \\
        \\ // exec failure: exit(1)
        \\ li   a7, 93
        \\ li   a0, 1
        \\ ecall
        \\2: j 2b
    );
}
```

- [ ] **Step 2: Create `hello.zig`**

Create `tests/programs/kernel/user/hello.zig` with:

```zig
// tests/programs/kernel/user/hello.zig — Phase 3.C exec target.
//
// Naked _start: write(1, msg, 22); exit(0).
// Same shape as Plan 3.B userprog.zig.

const MSG = "hello from /bin/hello\n";

export const msg linksection(".rodata") = [_]u8{
    'h', 'e', 'l', 'l', 'o', ' ', 'f', 'r', 'o', 'm', ' ',
    '/', 'b', 'i', 'n', '/', 'h', 'e', 'l', 'l', 'o', '\n',
};

comptime {
    if (MSG.len != 22) @compileError("MSG must be 22 bytes (see _start's a2)");
    if (msg.len != 22) @compileError("msg array length must match MSG.len");
}

export fn _start() linksection(".text.init") callconv(.naked) noreturn {
    asm volatile (
        \\ li   a7, 64
        \\ li   a0, 1
        \\ la   a1, msg
        \\ li   a2, 22
        \\ ecall
        \\ li   a7, 93
        \\ li   a0, 0
        \\ ecall
        \\1: j 1b
    );
}
```

- [ ] **Step 3: Verify both files are well-formed by running `zig fmt`**

Run: `zig fmt tests/programs/kernel/user/init.zig tests/programs/kernel/user/hello.zig`
Expected: no output (files already formatted) and exit 0.

- [ ] **Step 4: Commit**

```bash
git add tests/programs/kernel/user/init.zig tests/programs/kernel/user/hello.zig
git commit -m "feat(userland): add init.zig (fork+exec+wait) and hello.zig (write+exit)"
```

---

### Task 14: Build wiring — `init.elf`, `hello.elf`, `fork_boot_config`, `kernel-fork.elf`

**Files:**
- Modify: `build.zig` (add `init.elf` + `hello.elf` build targets; add fork-mode `boot_config.zig` write-files stub; add `kernel-fork.elf` executable; add `kernel-fork` step alias)

**Why this task here:** With both userland sources in place (Task 13) and `boot_config.lookupBlob` already added to single + multi stubs (Task 10), the only build-side work left is plumbing init/hello/fork-mode into a kernel executable. We add the e2e harness wiring in Tasks 15-16.

- [ ] **Step 1: Add `init.elf` and `hello.elf` build targets in `build.zig`**

Find the `kernel-user2` step block (around line 332, just after `userprog2_step.dependOn(...)`). Insert immediately after:

```zig
    const init_obj = b.addObject(.{
        .name = "init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/user/init.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const init_elf = b.addExecutable(.{
        .name = "init.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    init_elf.root_module.addObject(init_obj);
    init_elf.setLinkerScript(b.path("tests/programs/kernel/user/user_linker.ld"));
    init_elf.entry = .{ .symbol_name = "_start" };

    const init_elf_bin = init_elf.getEmittedBin();
    const install_init_elf = b.addInstallFile(init_elf_bin, "init.elf");
    const init_step = b.step("kernel-init", "Build the Phase 3.C init.elf");
    init_step.dependOn(&install_init_elf.step);

    const hello_obj = b.addObject(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/user/hello.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });

    const hello_elf = b.addExecutable(.{
        .name = "hello.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    hello_elf.root_module.addObject(hello_obj);
    hello_elf.setLinkerScript(b.path("tests/programs/kernel/user/user_linker.ld"));
    hello_elf.entry = .{ .symbol_name = "_start" };

    const hello_elf_bin = hello_elf.getEmittedBin();
    const install_hello_elf = b.addInstallFile(hello_elf_bin, "hello.elf");
    const hello_step = b.step("kernel-hello", "Build the Phase 3.C hello.elf");
    hello_step.dependOn(&install_hello_elf.step);
```

- [ ] **Step 2: Add the fork-mode `boot_config.zig` write-files stub**

Immediately after the `multi_boot_config_stub_dir` block (around line 343 in 3.B; will have shifted slightly after Task 10's edit), add:

```zig
    const fork_boot_config_stub_dir = b.addWriteFiles();
    const fork_boot_config_zig = fork_boot_config_stub_dir.add(
        "boot_config.zig",
        \\const std = @import("std");
        \\pub const MULTI_PROC: bool = false;
        \\pub const FORK_DEMO: bool = true;
        \\pub const USERPROG_ELF: []const u8 = "";
        \\pub const USERPROG2_ELF: []const u8 = "";
        \\pub const INIT_ELF: []const u8 = @embedFile("init.elf");
        \\pub const HELLO_ELF: []const u8 = @embedFile("hello.elf");
        \\pub fn lookupBlob(path: []const u8) ?[]const u8 {
        \\    if (std.mem.eql(u8, path, "/bin/hello")) return HELLO_ELF;
        \\    return null;
        \\}
        ,
    );
    _ = fork_boot_config_stub_dir.addCopyFile(init_elf_bin, "init.elf");
    _ = fork_boot_config_stub_dir.addCopyFile(hello_elf_bin, "hello.elf");
```

- [ ] **Step 3: Add the fork-mode `kmain` object + `kernel-fork.elf` executable**

Immediately after the `kernel_kmain_multi_obj` block (around line 357), add:

```zig
    const kernel_kmain_fork_obj = b.addObject(.{
        .name = "kernel-kmain-fork",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/kmain.zig"),
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_kmain_fork_obj.root_module.addAnonymousImport("boot_config", .{
        .root_source_file = fork_boot_config_zig,
    });
```

Immediately after the `kernel_multi_step` block (around line 418), add:

```zig
    const kernel_fork_elf = b.addExecutable(.{
        .name = "kernel-fork.elf",
        .root_module = b.createModule(.{
            .root_source_file = null,
            .target = rv_target,
            .optimize = .Debug,
            .strip = false,
            .single_threaded = true,
        }),
    });
    kernel_fork_elf.root_module.addObject(kernel_boot_obj);
    kernel_fork_elf.root_module.addObject(kernel_trampoline_obj);
    kernel_fork_elf.root_module.addObject(kernel_mtimer_obj);
    kernel_fork_elf.root_module.addObject(kernel_swtch_obj);
    kernel_fork_elf.root_module.addObject(kernel_kmain_fork_obj);
    kernel_fork_elf.setLinkerScript(b.path("tests/programs/kernel/linker.ld"));
    kernel_fork_elf.entry = .{ .symbol_name = "_M_start" };

    const install_kernel_fork_elf = b.addInstallArtifact(kernel_fork_elf, .{});
    const kernel_fork_step = b.step("kernel-fork", "Build the Phase 3.C fork-demo kernel.elf");
    kernel_fork_step.dependOn(&install_kernel_fork_elf.step);
```

- [ ] **Step 4: Extend `kmain.zig` with the fork-mode boot path**

In `tests/programs/kernel/kmain.zig`, immediately AFTER the line `proc.cpuInit();` and BEFORE the line `// Allocate PID 1.`, insert:

```zig
    if (boot_config.FORK_DEMO) {
        const init_p = proc.alloc() orelse kprintf.panic("kmain: alloc init", .{});
        @memcpy(init_p.name[0..4], "init");
        const init_root = vm.allocRoot() orelse kprintf.panic("kmain: allocRoot init", .{});
        init_p.pgdir = init_root;
        init_p.satp = SATP_MODE_SV32 | (init_root >> 12);
        vm.mapKernelAndMmio(init_root);

        const allocFn_fork = struct {
            fn f() ?u32 {
                return page_alloc.alloc();
            }
        }.f;
        const mapFn_fork = struct {
            fn f(pgdir: u32, va: u32, pa: u32, flags: u32) void {
                vm.mapPage(pgdir, va, pa, flags);
            }
        }.f;
        const lookupFn_fork = struct {
            fn f(pgdir: u32, va: u32) ?u32 {
                return vm.lookupPA(pgdir, va);
            }
        }.f;

        const entry_init = elfload.load(boot_config.INIT_ELF, init_root, allocFn_fork, mapFn_fork, lookupFn_fork, vm.USER_RWX) catch |err|
            kprintf.panic("elfload init: {s}", .{@errorName(err)});
        if (!vm.mapUserStack(init_root)) kprintf.panic("mapUserStack init", .{});
        init_p.tf.sepc = entry_init;
        init_p.tf.sp = vm.USER_STACK_TOP;
        init_p.sz = vm.USER_TEXT_VA + 0x10000;
        init_p.state = .Runnable;

        // Skip the single + multi setup blocks below — install stvec + sscratch
        // + sstatus and jump into scheduler() the same way they do.
        const stvec_val_fork: u32 = @intCast(@intFromPtr(&s_trap_entry));
        const sscratch_val_fork: u32 = @intCast(@intFromPtr(init_p));
        asm volatile (
            \\ csrw stvec, %[stv]
            \\ csrw sscratch, %[ss]
            :
            : [stv] "r" (stvec_val_fork),
              [ss] "r" (sscratch_val_fork),
            : .{ .memory = true }
        );

        const SIE_SSIE_F: u32 = 1 << 1;
        asm volatile ("csrs sie, %[b]"
            :
            : [b] "r" (SIE_SSIE_F),
            : .{ .memory = true }
        );

        const SSTATUS_SPP_F: u32 = 1 << 8;
        const SSTATUS_SPIE_F: u32 = 1 << 5;
        asm volatile (
            \\ csrc sstatus, %[spp]
            \\ csrs sstatus, %[spie]
            :
            : [spp] "r" (SSTATUS_SPP_F),
              [spie] "r" (SSTATUS_SPIE_F),
            : .{ .memory = true }
        );

        var bootstrap_fork: proc.Context = std.mem.zeroes(proc.Context);
        proc.cpu.sched_context.ra = @intCast(@intFromPtr(&sched.scheduler));
        proc.cpu.sched_context.sp = proc.cpu.sched_stack_top;
        proc.swtch(&bootstrap_fork, &proc.cpu.sched_context);
        unreachable;
    }
```

- [ ] **Step 5: Build all three kernel variants to verify everything compiles**

Run: `zig build kernel-elf && zig build kernel-multi && zig build kernel-fork`
Expected: PASS — three kernel ELFs install cleanly.

- [ ] **Step 6: Run regression e2es to verify single + multi paths intact**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub`
Expected: PASS — neither test exercises the new fork-mode path.

- [ ] **Step 7: Commit**

```bash
git add build.zig tests/programs/kernel/kmain.zig
git commit -m "build(kernel-fork): add init.elf + hello.elf + fork boot_config + kernel-fork.elf"
```

---

### Task 15: Add `fork_verify_e2e.zig` host harness

**Files:**
- Create: `tests/programs/kernel/fork_verify_e2e.zig`

**Why this task here:** The kernel-fork.elf binary now exists; we need a host-side verifier to drive it and assert the right output. We follow the exact same pattern as `multiproc_verify_e2e.zig` (Plan 3.B) so the change is mechanical.

- [ ] **Step 1: Create `fork_verify_e2e.zig`**

Create `tests/programs/kernel/fork_verify_e2e.zig` with:

```zig
// tests/programs/kernel/fork_verify_e2e.zig — Phase 3.C verifier.
//
// Spawns ccc on kernel-fork.elf, captures stdout, asserts:
//   - exit code 0
//   - stdout contains "hello from /bin/hello\n" (the child's exec'd binary)
//   - stdout contains "init: reaped\n" (init's post-wait announcement)
//   - stdout contains "ticks observed: " followed by a decimal number
//     and a newline (PID 1 = init exits last)
//
// Order is deterministic in this test (init forks → wait sleeps → child
// runs → child exits → wakeup → init reaps → init prints → init exits),
// but we still check substrings rather than byte-exact prefixes to stay
// robust against future scheduler tweaks.

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
        stderr.print("usage: {s} <ccc-binary> <kernel-fork.elf>\n", .{argv[0]}) catch {};
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
            stderr.print("fork_verify_e2e: output exceeded {d} bytes\n", .{MAX_BYTES}) catch {};
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
            stderr.print("fork_verify_e2e: expected exit 0, got {d}\nstdout was:\n{s}\n", .{ code, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
        else => {
            stderr.print("fork_verify_e2e: child terminated abnormally: {any}\nstdout was:\n{s}\n", .{ term, out }) catch {};
            stderr.flush() catch {};
            return FAIL_EXIT;
        },
    }

    if (std.mem.indexOf(u8, out, "hello from /bin/hello\n") == null) {
        stderr.print("fork_verify_e2e: missing exec'd child message\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    if (std.mem.indexOf(u8, out, "init: reaped\n") == null) {
        stderr.print("fork_verify_e2e: missing init reap announcement\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }

    const ticks_marker = "ticks observed: ";
    const ticks_idx = std.mem.indexOf(u8, out, ticks_marker) orelse {
        stderr.print("fork_verify_e2e: missing ticks-observed trailer\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };
    const after_ticks = out[ticks_idx + ticks_marker.len ..];
    var nl: usize = 0;
    while (nl < after_ticks.len and after_ticks[nl] != '\n') : (nl += 1) {}
    if (nl == 0 or nl == after_ticks.len) {
        stderr.print("fork_verify_e2e: malformed ticks line\n  stdout: {s}\n", .{out}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    }
    _ = std.fmt.parseInt(u32, after_ticks[0..nl], 10) catch {
        stderr.print("fork_verify_e2e: ticks N not a number: {s}\n", .{after_ticks[0..nl]}) catch {};
        stderr.flush() catch {};
        return FAIL_EXIT;
    };

    return 0;
}
```

- [ ] **Step 2: Verify file is well-formed**

Run: `zig fmt tests/programs/kernel/fork_verify_e2e.zig`
Expected: no output and exit 0.

- [ ] **Step 3: Commit**

```bash
git add tests/programs/kernel/fork_verify_e2e.zig
git commit -m "test(e2e): add fork_verify_e2e.zig host harness for Phase 3.C"
```

---

### Task 16: Wire `e2e-fork` into `build.zig`

**Files:**
- Modify: `build.zig` (add `fork_verify_e2e` executable + `e2e-fork` step)

**Why this task here:** Last build-side task. Gives us a runnable `zig build e2e-fork` that ties Tasks 11-15 together end-to-end.

- [ ] **Step 1: Add the fork-verifier executable + e2e-fork run step in `build.zig`**

In `build.zig`, immediately after the `e2e_multiproc_step` block (around line 457 after Task 14's edits), add:

```zig
    const fork_verify = b.addExecutable(.{
        .name = "fork_verify_e2e",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/programs/kernel/fork_verify_e2e.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const e2e_fork_run = b.addRunArtifact(fork_verify);
    e2e_fork_run.addFileArg(exe.getEmittedBin());
    e2e_fork_run.addFileArg(kernel_fork_elf.getEmittedBin());
    e2e_fork_run.expectExitCode(0);

    const e2e_fork_step = b.step("e2e-fork", "Run the Phase 3.C fork+exec+wait+exit e2e test");
    e2e_fork_step.dependOn(&e2e_fork_run.step);
```

- [ ] **Step 2: Run e2e-fork — the headline test**

Run: `zig build e2e-fork`
Expected: PASS — kernel-fork.elf boots, init forks hello, hello prints `"hello from /bin/hello\n"`, parent reaps and prints `"init: reaped\n"`, init exits and the canonical `"ticks observed: N\n"` trailer appears. Exit code 0.

If this fails, the most likely culprits and where to look:

| Failure | Likely cause | Fix |
|---|---|---|
| Hangs forever | scheduler can't pick init (e.g. Embryo never advanced) | check `kmain.zig`'s fork-mode branch sets `init_p.state = .Runnable` |
| `"hello from /bin/hello\n"` missing | exec failed silently | add `kprintf.panic("exec failed", .{})` to `init.zig`'s fallback exit(1) path; rerun |
| `"init: reaped\n"` missing | wait returned -1 (no children) | check `proc.fork` set `child.parent = parent` |
| Hangs after hello prints | parent never woken | check `proc.exit` calls `wakeup(@intFromPtr(p.parent.?))` |
| Stack-trash / page-fault panic during exec | argv tail PA writes addressed wrong page | check `proc.exec`'s `lookupPA` page-walk arithmetic; `mapUserStack` allocates 2 pages so the tail (~560 bytes) fits in the top page |

- [ ] **Step 3: Run regression e2es to verify nothing else broke**

Run: `zig build e2e-kernel && zig build e2e-multiproc-stub`
Expected: PASS for both.

- [ ] **Step 4: Commit**

```bash
git add build.zig
git commit -m "test(e2e): wire e2e-fork step in build.zig"
```

---

### Task 17: Run the full test gauntlet

**Files:** none modified.

**Why this task here:** Verify every Phase 1, 2, 3.A, 3.B, and 3.C test still passes alongside the new lifecycle primitives. Catches any incidental breakage and confirms 3.C is end-to-end ready.

- [ ] **Step 1: Run all unit tests**

Run: `zig build test`
Expected: PASS — host tests for elfload (3 tests), free-list, the new `freeLeavesInL0` test (Task 1), every Phase 1/2/3.A/3.B test.

- [ ] **Step 2: Run all riscv-tests**

Run: `zig build riscv-tests`
Expected: PASS — rv32ui (39), rv32um (8), rv32ua (10), rv32mi (8), rv32si (5).

- [ ] **Step 3: Run all e2e steps individually, in order**

Run, in order:
- `zig build e2e`
- `zig build e2e-mul`
- `zig build e2e-trap`
- `zig build e2e-hello-elf`
- `zig build e2e-kernel`
- `zig build e2e-plic-block`
- `zig build e2e-multiproc-stub`
- `zig build e2e-fork`

Expected: all eight e2e tests PASS.

- [ ] **Step 4: Confirm no incidental file changes leaked through**

Run: `git status`
Expected: clean working tree (no modified files outside what tasks committed).

- [ ] **Step 5: No commit (this is a gate, not a code change).**

If any step in 1-3 fails, return to the relevant earlier task and fix. Common cross-task failure modes:

| Failure | Likely cause | Fix |
|---|---|---|
| `e2e-multiproc-stub` regresses with "missing PID N message" | proc.exit's wakeup uses wrong chan, or zombies are picked by scheduler | check Task 8: `wakeup(@intFromPtr(par))` not `wakeup(par.pid)`; check sched.zig still skips `.Zombie` (Plan 3.B behavior unchanged) |
| `e2e-kernel` regresses with extra trailer | proc.exit's PID-1 special-case fires twice | check Task 8: only PID 1 prints; Task 6's killed-check in trap.zig must NOT also call sysExit for non-killed procs |
| `e2e-fork` exits with non-zero "ticks line malformed" | PID 1 (init) didn't exit cleanly — exec child trapped its own kill | check Task 6: killed-check applies to `cur()`, which is the post-exec child after exec swaps tf; `child.killed` is 0 by `freshly-zeroed` slot from `proc.alloc` |
| Host tests fail with `error: unknown identifier 'freeLeavesInL0'` | Task 1 Step 1's test was added but Step 1's production code wasn't | re-apply Task 1 Step 1's `pub fn freeLeavesInL0` definition above the test block |

---

### Task 18: README + status update

**Files:**
- Modify: `README.md` (status line, Layout / e2e tests section)

- [ ] **Step 1: Update the status line**

In `README.md`, find the line beginning with "Status:" or similar (the status set by Plan 3.B's Task 21). Bump it to:

```
Status: Phase 3 Plan C done — fork / exec / wait / exit / kill-flag.
```

- [ ] **Step 2: Add `e2e-fork` to the Layout / e2e tests section**

Append the new e2e step to the existing list, with a one-line description:

```
- `e2e-fork` — boot kernel-fork.elf; init forks /bin/hello; parent reaps; emulator returns 0
```

- [ ] **Step 3: Verify README renders cleanly**

Run: `cat README.md | head -100`
Expected: status / layout sections display correctly; no unclosed code fences or broken table formatting.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(readme): record Phase 3 Plan C (fork/exec/wait/exit)"
```

---

## Wrap-up

After all 18 tasks complete and `zig build test && zig build riscv-tests && zig build e2e && zig build e2e-mul && zig build e2e-trap && zig build e2e-hello-elf && zig build e2e-kernel && zig build e2e-plic-block && zig build e2e-multiproc-stub && zig build e2e-fork` all pass:

- Plan 3.C is complete.
- The kernel now has the full Unix-shaped process lifecycle: fork (full address-space copy), exec (kernel-side AS rebuild + System-V argv tail), wait (sleep until zombie child, harvest pid + xstate), exit (reparent, zombie, wake parent), kill (set flag + wake if sleeping), with sleep/wakeup race mitigation via SIE-disable.
- `kernel-fork.elf` boots a real `init` userland program that forks an embedded `/bin/hello`, waits, reaps, and exits cleanly.
- All Phase 2 + 3.B regression coverage holds.
- The killed check on syscall return + `set_fg_pid` / `console_set_mode` accept-and-discard syscalls are landed but not yet exercised — they wait for Plan 3.E's console line discipline.
- **Next plan:** 3.D — Bufcache + block driver in kernel + FS read path. With proc.sleep / proc.wakeup in place, 3.D's bufcache can sleep on busy buffers and wait for block-device IRQs; with proc.exec lookup-from-blob in place, 3.D's swap to lookup-from-FS is a one-line change in the lookupBlob shim.

**REQUIRED SUB-SKILL when this plan completes successfully:** Use `superpowers:finishing-a-development-branch` to verify tests, present options, execute the chosen completion path (PR / merge / cleanup).
