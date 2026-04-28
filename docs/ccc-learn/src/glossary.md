# Glossary

Quick definitions of the jargon. Cross-referenced from every topic. Search this page (or the search bar) when a term feels unfamiliar.

## RISC-V ISA

| Term | Expanded | Definition |
|------|----------|------------|
| RV32 | 32-bit RISC-V | The 32-bit base RISC-V architecture. `ccc` targets RV32IMA + Zicsr + Zifencei. |
| RV32I | 32-bit base integer | The 47-instruction integer base — adds, branches, loads/stores, jumps. |
| M | Multiply/divide ext | Adds `mul`, `mulh`, `div`, `rem`, etc. (8 instructions). |
| A | Atomic ext | Adds `lr.w`/`sc.w` (load-reserved/store-conditional) + AMOs like `amoadd.w`. |
| Zicsr | CSR access ext | The `csrr*` family — read/write/swap CSR atomically. |
| Zifencei | Instruction-fetch fence | `fence.i` — flush the instruction cache (no-op in `ccc`'s emulator). |
| hart | Hardware thread | A CPU that can run instructions — `ccc` has exactly one. |
| PC | Program counter | The address of the next instruction to fetch. |
| xN | Integer register | One of 32 GPRs: x0 (always zero), x1=ra, x2=sp, etc. |
| ABI name | Application binary name | Aliases: `zero`, `ra`, `sp`, `a0..a7`, `s0..s11`, `t0..t6`. |
| ECALL | Environment call | The "I'd like to ask my supervisor" instruction. Traps to higher mode. |
| EBREAK | Environment break | Like ECALL but for debugger handover. |
| MRET / SRET | Machine/supervisor return | Pop privilege and PC out of the trap-frame CSRs. Only legal in M / S. |
| FENCE | Memory fence | Order memory operations. `ccc`'s emulator is sequential, so it's a no-op. |
| WFI | Wait for interrupt | "Don't fetch until something async happens." `ccc` implements via `idleSpin`. |
| SFENCE.VMA | Supervisor fence VMA | TLB flush. `ccc` has no TLB so it's a no-op. |
| LR/SC | Load-reserved / store-conditional | Atomic primitives: LR sets a reservation, SC succeeds only if it's still set. |
| AMO | Atomic memory operation | Read-modify-write in one instruction (`amoadd.w`, `amoswap.w`, etc.). |

## Privilege & traps

| Term | Expanded | Definition |
|------|----------|------------|
| M-mode | Machine mode | Highest privilege. Can do anything. The boot shim runs here. |
| S-mode | Supervisor mode | Kernel privilege. Can use Sv32 paging, S CSRs. |
| U-mode | User mode | User-program privilege. Cannot access M/S CSRs or do MMIO directly. |
| CSR | Control/status register | A side-band register accessed via `csrr*` instructions. |
| trap | Synchronous or async exception | The mechanism by which control transfers between privilege modes. |
| interrupt | Async trap | A trap raised by an external event (timer, device IRQ). |
| exception | Sync trap | A trap raised by the current instruction (page fault, illegal op, ECALL). |
| delegation | Routing M-traps to S | Setting bits in `medeleg`/`mideleg` so traps go straight to S without M's help. |
| mtvec / stvec | Trap vector base | CSRs holding the address of the M / S trap handler. |
| mepc / sepc | Saved PC | The PC at the moment of trap. `mret`/`sret` returns there. |
| mcause / scause | Trap cause | Encoded reason for the trap (interrupt N or exception N). |
| mip / sip | Interrupt pending | Bitmask of currently-pending interrupts at each level. |
| mie / sie | Interrupt enable | Bitmask of which interrupts are enabled at each level. |
| mstatus / sstatus | Status CSR | Holds MIE/SIE/MPP/SPP — the "current interrupt enable" + "previous privilege" bits. |
| MPP / SPP | Previous privilege bits | When trap fires, the *old* privilege is saved here for `mret`/`sret` to restore. |
| MIE / SIE | M/S interrupt enable bit | One bit each — globally gates async interrupts at that mode. |
| MTIP | M timer interrupt pending | Set by CLINT when `mtime ≥ mtimecmp`. |
| MEIP / SEIP | M/S external interrupt pending | Set by PLIC when any source has a pending IRQ at that context. |
| SSIP | S software interrupt pending | The boot shim sets this in M-mode to forward MTI down to S. |
| SIE window | Brief SIE-enabled window | The scheduler enables SIE for one instruction across `wfi` so device IRQs can land. |
| trampoline | M/S/U-shared trap entry | A page mapped in every address space that holds `s_trap_entry`. |

## Memory & paging

| Term | Expanded | Definition |
|------|----------|------------|
| MMIO | Memory-mapped I/O | Devices appear as ranges of "memory" — load/store hits a function, not RAM. |
| Sv32 | Supervisor virtual 32-bit | RISC-V 2-level paging: 4 KB pages, 32-bit virtual addresses, 2 page-table levels. |
| satp | Supervisor address translation | CSR holding the PPN of the L1 page table + the mode bit. |
| PPN | Physical page number | Upper 22 bits of a 4 KB-aligned physical address. |
| VPN | Virtual page number | Upper 20 bits of a 4 KB-aligned virtual address (VPN[1] = L1, VPN[0] = L0). |
| PTE | Page table entry | 32-bit slot: PPN + flag bits (V, R, W, X, U, G, A, D). |
| TLB | Translation lookaside buffer | Hardware cache of recent VPN→PPN lookups. `ccc` has no TLB. |
| identity map | VA == PA | The kernel's own pages are mapped 1:1 so it can keep running with paging on. |
| page fault | PTE invalid trap | Sync trap `12`/`13`/`15` when a load/store/fetch hits an unmapped or unprivileged page. |

## Devices & I/O

| Term | Expanded | Definition |
|------|----------|------------|
| UART | Universal async receiver/transmitter | A 1-byte-at-a-time serial port. `ccc` emulates a NS16550A. |
| FIFO | First-in first-out queue | UART RX uses one of these (256 bytes deep) so bytes don't drop. |
| CLINT | Core-local interruptor | Per-hart MMIO providing `msip` (software IRQ) + `mtime`/`mtimecmp` (timer). |
| PLIC | Platform-level interrupt controller | Routes 32 device-source IRQs to the S-context external-interrupt line. |
| claim / complete | PLIC handshake | "Tell me which IRQ fired" + "I'm done with that one." |
| ISR | Interrupt service routine | The kernel function that runs when a specific IRQ fires. |
| level-triggered | Stays asserted | An IRQ source raises its line and holds it until the device clears the cause. |
| edge-triggered | One-shot pulse | An IRQ source pulses and then drops; missing it = losing it. |
| block device | Disk-like MMIO | `ccc`'s simple device serves 4 KB sectors out of a host file. |
| `mtime` / `mtimecmp` | Timer counter / target | When `mtime ≥ mtimecmp`, MTIP fires. |

## Operating system

| Term | Expanded | Definition |
|------|----------|------------|
| process | Running program + state | A `Process` struct: regs + page table + kstack + open files + cwd. |
| PID | Process ID | The index into `ptable[NPROC=16]` (1-based, 0 = unused). |
| context | Saved CPU state | Callee-saved kernel regs (`ra`, `sp`, `s0..s11`) — not user regs. |
| context switch | Hand CPU to another process | `swtch.S` — store one Context, load another. |
| scheduler | Picks the next process | Round-robin in `ccc`. Runs on its own kernel stack. |
| kernel stack | Per-process scratch in S-mode | 4 KB on the kernel side; not visible from user space. |
| trap frame | Saved user state on trap | Pushed by `s_trap_entry`, popped by the matching exit. |
| syscall | User → kernel call | An `ecall` from U-mode + a number in `a7` + args in `a0..a5`. |
| fork | Process clone | Copy parent's address space; child gets a new PID; both return from one call. |
| exec / execve | Replace image | Tear down current address space, load a new ELF, jump to its entry. |
| wait / wait4 | Reap a child | Sleep until any (or specific) zombie child exists; collect its exit status. |
| zombie | Exited but not yet reaped | The proc's resources are freed except its slot — `wait4` finishes the cleanup. |
| reparent | Adoption | If a parent exits before its children, those children get reparented to PID 1. |
| kill flag | Async terminate request | Set by `proc.kill`; checked on every syscall return; a soft `^C`. |
| sleep / wakeup | Channel-based blocking | "Sleep on channel X" + "wake everyone sleeping on X" — the only IPC primitive. |

## Filesystem

| Term | Expanded | Definition |
|------|----------|------------|
| superblock | FS metadata | Block 0: layout constants (NBLOCKS, NINODES, bitmap start, etc.). |
| bitmap | Free-block tracker | One bit per data block: 1 = allocated. |
| inode | Index node | On-disk file metadata: type + size + nlink + 12 direct + 1 indirect block addrs. |
| direct block | Direct data pointer | A `bnum` in the inode pointing straight at a data block. |
| indirect block | Pointer block | A 4 KB block of 1024 `bnum`s — extends the inode beyond the 12 direct slots. |
| dirent | Directory entry | 32-byte record: 30-byte name + inum. Stored as a regular file. |
| inum | Inode number | Index into the inode table. The OS-internal "filename." |
| `bmap` | Logical → physical block | Given (inode, file-relative block index), returns the disk `bnum`. |
| `namei` | Path → inode | Walk a path string component-by-component, returning the final inode. |
| bufcache | Block-buffer cache | LRU cache of 16 disk buffers; sleep-on-busy concurrency. |
| fd | File descriptor | A small int the kernel maps to an open `File` (per-process `ofile[16]`). |
| `O_CREAT` / `O_TRUNC` / `O_APPEND` | open flags | Create-if-missing / truncate-on-open / position-at-end. |

## Console & terminal

| Term | Expanded | Definition |
|------|----------|------------|
| cooked mode | Line-buffered + edit | Default mode: backspace edits, `^C` kills, `\n` commits a line. |
| raw mode | Per-byte unfiltered | Editor mode: every keypress lands in `read()` immediately, no echo. |
| `^C` | Control-C | Byte 0x03. In cooked mode, calls `proc.kill(fg_pid)`. |
| `^U` | Control-U | Byte 0x15. In cooked mode, kills the current line buffer. |
| `^D` | Control-D | Byte 0x04. In cooked mode, EOF (read returns 0). |
| ANSI escape | CSI sequence | `\x1b[...` control sequences for cursor movement, screen clear, etc. |
| line discipline | TTY filter layer | The kernel-side rules that turn raw bytes into lines (or pass them through). |

## Zig & build

| Term | Expanded | Definition |
|------|----------|------------|
| `comptime` | Compile-time | Code that runs at compile time — used for branchy build-target logic. |
| freestanding | No OS target | A target with no syscalls, no libc, no `main()`. wasm32-freestanding ≈ "raw wasm." |
| bare-metal | No OS at all | A program that *is* the OS — runs directly on hardware (or `ccc`'s emulator). |
| ELF | Executable & linkable format | The binary layout `ccc` loads. Has segments (`PT_LOAD`) and sections. |
| linker script | `.ld` file | Tells the linker where to put each section in memory. |
| `_start` | Program entry | The first user-mode instruction. Parses argc/argv off the stack tail. |

## Phases (as `ccc` uses them)

| Term | Expanded | Definition |
|------|----------|------------|
| Phase 1 | Emulator | RV32I + M + A + Zicsr + Zifencei + privilege + paging. **Done.** |
| Phase 2 | Bare-metal kernel | M boot shim + S kernel + U user-prog. **Done.** |
| Phase 3 | Multi-process OS | PLIC + processes + FS + console + shell. **Done.** |
| Phase 4 | Network stack | Ethernet → ARP → IP → ICMP → UDP → TCP → DNS. **Planned.** |
| Phase 5 | Browser | HTTP/1.0 client + text-mode HTML renderer. **Planned.** |
| Plan X.Y | Sub-plan within a phase | E.g., Plan 1.C = traps + CSRs; Plan 3.E = shell + utilities. |
