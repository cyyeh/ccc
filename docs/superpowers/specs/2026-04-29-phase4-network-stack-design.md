# Phase 4 — Network Stack (Design)

**Project:** From-Scratch Computer (directory `ccc/`).
**Phase:** 4 of 6 — see `2026-04-23-from-scratch-computer-roadmap.md`.
**Status:** Approved design, ready for implementation planning.

## Goal

Add a from-scratch IPv4 network stack to our Phase 3 OS. Drive a custom
MMIO NIC inside the emulator; the emulator's host-side **SLIRP backend**
NATs the guest's frames out through normal POSIX sockets — no kext, no
admin rights, no Linux VM. Implement Ethernet → ARP → IPv4 → ICMP →
UDP → TCP → DNS by hand. A BSD sockets API hands those layers to
userland through Linux-numbered syscalls. The shell ships `ping`, `nc`,
`host`, and `ifconfig`. `ping 1.1.1.1` lights up real internet; an
HTTP/1.0 client (Phase 5) plugs straight into the same socket layer.

## Definition of done

- `zig build kernel` produces `kernel.elf`. `fs.img` (built by Phase 3's
  `mkfs`) gains `/bin/{ping,nc,host,ifconfig}`, `/etc/resolv.conf`,
  `/etc/hosts`, `/etc/network`.
- `ccc --disk fs.img --net slirp kernel.elf` boots, configures the NIC
  from `/etc/network`, and reaches `$ ` with a working stack.
- The seven demo items pass interactively:
  1. `ping 1.1.1.1` — real internet round trips through SLIRP.
  2. `ping example.com` — name resolves via the in-OS resolver, then
     ICMP echo succeeds.
  3. `host example.com` — prints `example.com has address …`.
  4. `nc <test-peer> 7` — TCP echo round-trip succeeds.
  5. `nc -l 7777` accepts a connection from `nc localhost 7777` in
     a second pseudo-tty.
  6. `ifconfig` prints MAC, IPv4, gateway, MTU, RX/TX counters.
  7. `^C` cleanly aborts a stuck `nc` (kernel kill-flag still works
     across blocking sleeps in the network code).
- All Phase 1 e2e tests, `e2e-kernel`, `e2e-multiproc-stub`, `e2e-fork`,
  `e2e-fs`, `e2e-shell`, `e2e-editor`, `e2e-persist` still pass.
- New e2e tests pass: `e2e-net-link`, `e2e-arp`, `e2e-icmp`, `e2e-udp`,
  `e2e-tcp-handshake`, `e2e-tcp-stream`, `e2e-tcp-loss`, `e2e-tcp-cc`,
  `e2e-dns`, `e2e-pipe`.
- `riscv-tests` (rv32ui/um/ua/mi/si all `-p-*`) still pass.
- `--trace` works across the new external-interrupt path; NIC TX/RX
  show up as synthetic marker lines (`--- nic: rx 64 bytes ---`).

## Scope

### In scope

- **Emulator additions:** custom MMIO NIC (PLIC IRQ #2); single
  `HostBackend` interface with one implementation, `slirp.zig`, that
  NATs guest TCP/UDP/ICMP-DGRAM out through host BSD sockets;
  `--net slirp|loopback|none`, `--net-mac`, `--net-ip-range`,
  `--dns SERVER`, `--net-drop-pct`, `--net-reorder-pct`,
  `--net-rtt-ms`.
- **Kernel — link & networking:**
  - NIC driver (TX/RX path, IRQ-driven RX, sleep on full TX).
  - Ethernet framing (Type II only, no 802.3 LLC).
  - ARP (request/reply, cache with timeout, gratuitous ARP on boot).
  - IPv4 (header validation, fragmentation reassembly, TTL, checksum;
    forwarding *not* implemented — single interface).
  - ICMP (echo request + reply, port-unreachable, TTL-exceeded;
    everything else dropped silently).
  - UDP (basic; DNS rides on it).
  - **Full TCP** — RFC 793 base; RFC 5681 congestion control (slow
    start, CA, fast retransmit, fast recovery); RFC 6298 RTO; RFC 7323
    timestamps + window scaling; RFC 2018 SACK; RFC 896 Nagle. Full
    state machine (CLOSED → LISTEN → SYN_SENT → SYN_RCVD → ESTABLISHED
    → FIN_WAIT_1/2 / CLOSE_WAIT / CLOSING / LAST_ACK / TIME_WAIT). 2MSL
    TIME_WAIT.
  - DNS resolver — RFC 1035 client-side: A records, CNAME chasing,
    EDNS0 (RFC 6891), TTL-aware cache, negative caching (RFC 2308),
    multi-server failover, configurable per `/etc/resolv.conf`.
- **Kernel — fd unification:** `Socket` becomes a third fd type
  alongside `RegularFile` and `Console`; `read`/`write`/`close`
  polymorph through a vtable. `pipe(2)` lands here (deferred from
  Phase 3); pipes share the buffered-fd machinery. `fcntl(F_SETFL,
  O_NONBLOCK)` on socket and pipe fds.
- **Sockets API:** Linux-numbered: `socket`, `bind`, `listen`,
  `accept4`, `connect`, `sendto`, `recvfrom`, `setsockopt`,
  `getsockopt`, `getpeername`, `getsockname`, `shutdown`, `pipe2`,
  `dup`, `dup3`, `fcntl`. AF_INET / SOCK_STREAM / SOCK_DGRAM /
  SOCK_RAW for ICMP only.
- **Userland:** `ping`, `nc`, `host`, `ifconfig`. Static IPv4 config
  via `/etc/network`. `/etc/hosts` consulted before the resolver.
- **Host tooling:** `tests/net-peer/echo.zig` — small Zig program the
  e2e harness launches; acts as TCP and UDP echo server, with knobs
  for deterministic loss/reorder/delay so CC and retransmit code paths
  actually run.

### Out of scope (deferred or never)

- IPv6 / NDP / ICMPv6 / DAD — entire stack is IPv4-only.
- DHCP client — `--net slirp` hands us a static address; `/etc/network`
  pins it. ~150 LoC if we ever want it; not load-bearing.
- TLS / TCP Authentication Option / DNSSEC — phase 5+ or never.
- IP forwarding / multi-interface routing — single NIC, single route.
- IGMP / multicast / broadcast beyond ARP.
- `select` / `poll` / `epoll` — multiplexing happens via fork+pipe.
- Raw sockets beyond ICMP-echo (no `SOCK_PACKET` etc).
- Real-world driver shapes: virtio-net, e1000, etc.
- `traceroute`, `arp` (binary), `route` (binary) — `ifconfig` covers
  inspection; the rest add nothing for the demo.
- Asynchronous DNS in-process — resolver is a synchronous library
  used by `connect()` and userland; no background daemon.
- TCP user-timeout option, MD5 sig option, urgent pointer, OOB data,
  PSH-flag-driven semantics beyond "deliver promptly."

## Architecture

### Emulator modules — Phase 4 deltas

| Module | Phase 4 additions |
|---|---|
| `cpu.zig` | unchanged |
| `trap.zig` | unchanged (NIC reuses Phase 3's PLIC + S-external path) |
| `memory.zig` | one new MMIO range: NIC at `0x1000_2000` (64 B) |
| `devices/nic.zig` | **NEW.** TX/RX register file, single in-flight TX, single pre-posted RX buffer, IRQ on RX. ~150 LoC. |
| `devices/slirp/slirp.zig` | **NEW.** Frame classifier and host-backend dispatcher. ~250 LoC. |
| `devices/slirp/tcp.zig` | **NEW.** Per-flow TCP NAT (terminates guest TCP at the gateway, splices bytes to a host `AF_INET STREAM` socket). ~400 LoC. |
| `devices/slirp/udp.zig` | **NEW.** Per-flow UDP NAT, idle-timeout-based eviction. ~150 LoC. |
| `devices/slirp/icmp.zig` | **NEW.** ICMP echo via host `SOCK_DGRAM IPPROTO_ICMP` (macOS / most Linux); per-OS fallback path documented. ~120 LoC. |
| `devices/slirp/arp.zig` | **NEW.** Synthesizes ARP replies for the gateway IP. ~50 LoC. |
| `devices/slirp/loss.zig` | **NEW.** Drop / reorder / delay injector for both directions. ~80 LoC. |
| `main.zig` | `--net slirp\|loopback\|none`, `--net-mac`, `--net-ip-range`, `--dns`, `--net-drop-pct`, `--net-reorder-pct`, `--net-rtt-ms`. |

### Kernel modules — Phase 4 additions

```
tests/programs/kernel/
├── … (all Phase 3 modules unchanged)
├── nic.zig                     NIC driver — TX (sleep on busy) + RX (PLIC #2 ISR)
├── net/
│   ├── checksum.zig            internet checksum, TCP/UDP pseudo-header helpers
│   ├── frame.zig               Ethernet II framing + multiplex on EtherType
│   ├── arp.zig                 ARP cache (NARP=16, LRU + 60s timeout) + req/reply
│   ├── ip.zig                  IPv4 input/output, frag reassembly (NREASM=4 × 16 KB)
│   ├── icmp.zig                Echo, port-unreachable, TTL-exceeded
│   ├── udp.zig                 demux, bind table (NUDP=16), per-port queues
│   ├── tcp.zig                 socket struct, public API, dispatch into in/out
│   ├── tcp_input.zig           segment processing — full state machine
│   ├── tcp_output.zig          retransmit queue, segment formation, Nagle, PUSH
│   ├── tcp_cc.zig              SS / CA / fast-retransmit / fast-recovery
│   ├── tcp_timer.zig           RTO (Karn + Jacobson), 2MSL TIME_WAIT, persist
│   ├── tcp_sack.zig            SACK option encode/decode + sender bookkeeping
│   ├── socket.zig              Socket struct, fd polymorph dispatch
│   ├── pipe.zig                pipe(2), shared buffered-fd machinery
│   ├── route.zig               single-route lookup, "next-hop = gateway"
│   ├── netif.zig               interface state (MAC, IP, gw, MTU, counters)
│   └── dns.zig                 client-side resolver — cache + RFC 1035 parser
└── userland/
    ├── ping.zig
    ├── nc.zig
    ├── host.zig
    └── ifconfig.zig
```

### Static-table policy (Phase 3 invariant preserved)

Phase 4 keeps Phase 3's "no kernel heap" rule. New bounded counts:

| Table | Size | Per-entry size | Notes |
|---|---|---|---|
| ARP cache | `NARP = 16` | ~24 B | LRU; pending-IP queue per entry (`NPENDIP = 4`). |
| IP reassembly | `NREASM = 4` | 16 KB + ~32 B | Buffer pages from page allocator. |
| UDP binds | `NUDP = 16` | ~24 B | Each holds `NQ = 8` queued datagram pages. |
| TCP sockets | `NTCP = 64` | ~200 B | Send/recv buffers (4–16 KB each) page-allocator-backed on open. |
| Frame pool | `NFRAME = 32` | 2 KB | Two slots per page. |
| DNS cache | `NCACHE = 64` | ~80 B | LRU; positive + negative entries share. |

Worst-case static memory ≈ 16 KB tables + ~2 MB of dynamically-page-allocated buffers when fully loaded. Comfortable inside our 128 MB.

### NIC register map

Offsets relative to `0x1000_2000`:

| Off | Reg | Sz | RW | Behavior |
|---|---|---|---|---|
| `0x00` | `MAC_LO` | u32 | R | Low 32 bits of locally-assigned MAC (default `52:54:00:12:34:56`; override via `--net-mac`). |
| `0x04` | `MAC_HI` | u32 | R | High 16 bits in the low half. |
| `0x08` | `STATUS` | u32 | R | bit0 link-up, bit1 tx-busy, bit2 rx-pending, bit3 rx-overrun. |
| `0x0C` | `CTRL` | u32 | W | bit0 enable, bit1 rx-release (re-arm RX), bit2 tx-cancel. |
| `0x10` | `TX_ADDR` | u32 | W | Physical addr of frame buffer. |
| `0x14` | `TX_LEN` | u32 | W | Frame length; **writing kicks TX**. Guest must wait on `tx-busy` clearing or sleep on PLIC #2 if it wants flow control. |
| `0x18` | `RX_ADDR` | u32 | W | Pre-posted physical addr where the next RX frame is copied (single buffer, no ring). |
| `0x1C` | `RX_LEN` | u32 | R | Length of the last received frame; valid when bit2 of STATUS is set. |
| `0x20` | `RX_DROPS` | u32 | R | Counter. RX with no buffer pre-posted, or oversized frames, increment this. |
| `0x24` | `TX_DROPS` | u32 | R | Counter. SLIRP-side errors / link-down increments this. |

Single-buffer TX and RX (matches the project's "no virtio" stance from
the block device). RX drops if a frame arrives while bit2 of STATUS is
still set — the kernel must re-arm via `rx-release` quickly. The
emulator additionally maintains a small drain queue (~32 frames) so
the bytestream is preserved end-to-end and only the timing knobs
(loss/reorder/delay) drop frames intentionally.

### SLIRP responsibilities

The host process is the network. SLIRP pretends to be:

- **The gateway** — `10.0.2.1` by default. Owns its own MAC, responds
  to ARP requests for that IP, **never** asks the guest for ARP back.
- **The guest's view of the world** — a `/24` subnet `10.0.2.0/24`.
  Guest gets `10.0.2.2` (configured statically via `/etc/network`);
  SLIRP also remembers it for logging. No DHCP.
- **A pure splicer at L4** — for each guest TCP connect, SLIRP
  terminates the guest's TCP at the gateway and `connect(2)`s a host
  socket to the real destination; it then copies bytes both ways.
  Same shape for UDP. **Real congestion / retransmit / window
  behavior in the guest TCP runs against SLIRP** (a near-perfect peer);
  the loss/reorder/delay injector is what exercises CC code paths in
  tests.

```
guest                            SLIRP                            host POSIX
─────────────────────            ────────────────────────         ───────────────────
sends Ethernet frame             receives raw bytes
  TX_KICK → emulator             ┌────────────────────┐
  hands frame to slirp           │ classify by type   │
                                 │ - ARP req for GW   │ → synthesizes ARP reply
                                 │ - IPv4 ICMP echo   │ → SOCK_DGRAM ICMP send
                                 │ - IPv4 UDP         │ → AF_INET DGRAM send/recv
                                 │ - IPv4 TCP SYN     │ → connect() on AF_INET STREAM
                                 │ - IPv4 TCP data    │ → write() on flow socket
                                 │ - IPv4 TCP FIN     │ → shutdown() / close()
                                 │ - other            │ → drop, count
                                 └────────────────────┘
sees Ethernet frame              forms frame & sends      ← reads from host socket
  RX_LEN set, IRQ                                          ← OS routes to internet
                                                           ← host kernel does NAT
```

ICMP echo gets a real round-trip via `SOCK_DGRAM IPPROTO_ICMP`
(macOS/Linux unprivileged on most distros). On *BSD or restricted
Linux we fall back to `SOCK_RAW` with a printed warning; on Windows
the `IcmpSendEcho` helper. Documented in the spec, not a phase-4
blocker.

## Memory layout

### Physical address space

| Address | Size | Purpose | Phase |
|---|---|---|---|
| `0x0000_1000` | 4 KB | Boot ROM (reserved, unused) | 1 |
| `0x0010_0000` | 8 B | Halt MMIO | 1 |
| `0x0200_0000` | 64 KB | CLINT | 1 |
| `0x0c00_0000` | 4 MB | PLIC | 3 |
| `0x1000_0000` | 256 B | NS16550A UART (TX + RX) | 1, ext. 3 |
| `0x1000_1000` | 16 B | Block device | 3 |
| **`0x1000_2000`** | **64 B** | **NIC** | **NEW (4.A)** |
| `0x8000_0000` | 128 MB | RAM | 1 |

PLIC sources used: #1 = block (Phase 3), **#2 = NIC (NEW)**, #10 =
UART RX (Phase 3).

### Per-process virtual address space (Sv32)

Phase 3's per-process layout is unchanged; the NIC MMIO range is added
to the kernel-shared, S-only direct-mapped band:

| VA range | Purpose | Perm | Per-proc / shared |
|---|---|---|---|
| `0x1000_0000 – 0x1000_2FFF` | UART + block + **NIC** (S-only) | S, R+W | shared |

Other VA bands match Phase 3 exactly.

## Network stack architecture

### Frame buffer pool

Static pool of `NFRAME = 32` 2 KB frame buffers (page-allocator-backed;
one page holds two slots). RX path: kernel pre-posts a slot's address
into NIC `RX_ADDR` and the NIC writes into it on the next received
frame. TX path: caller fills a slot, hands the address to NIC
`TX_ADDR`, sleeps on `tx-busy`, slot returns to pool on IRQ. Pool
exhausted → caller sleeps on `pool.free_chan`.

### Ethernet & ARP

Type II framing only. EtherType demux: `0x0800` → `ip_input`, `0x0806`
→ `arp_input`, everything else dropped + counter bumped.

ARP cache: `NARP = 16` entries `{ip, mac, last_used, state ∈ {Free,
Pending, Resolved}}`. LRU eviction. Resolved entries expire after
60 s; Pending entries retry every 2 s up to 5 times before failing
the requesting flow with `ENETUNREACH`. Boot path sends one gratuitous
ARP for our own IP — catches collisions on the SLIRP subnet.

When `ip_output` needs a MAC for a next-hop and the cache says
Pending, the IP packet is queued in a per-entry `pending[NPENDIP = 4]`
list; the ARP reply path drains the queue.

### IPv4

`ip_input(frame)`:

1. Length + checksum verify.
2. Drop if `version != 4`, `IHL < 5`, `ttl == 0`, or `dst` ∉ {our IP,
   broadcast}.
3. If `MF` set or `frag_offset > 0` → reassembly.
4. Demux on protocol: 1 → `icmp_input`, 6 → `tcp_input`, 17 →
   `udp_input`. Else drop.

`ip_output(dst, proto, payload)`:

1. Route: single static `(prefix, gateway, iface)` from `/etc/network`.
   Walk ARP for the gateway MAC.
2. Build header (no options, monotonically incrementing `ip_id` for
   safe fragmentation).
3. If `len > MTU - 20` → fragment. Otherwise single frame.
4. Hand to Ethernet output.

Reassembly: `NREASM = 4` × 16 KB buffers, 30 s timeout (RFC 791); on
timeout, emit ICMP type 11 code 1 to the source. Overlapping fragments
are dropped per RFC 5722.

### ICMP

| Type | Code | Direction | Behavior |
|---|---|---|---|
| 8 | 0 | RX | Echo request → emit type 0 echo reply with same `id`/`seq`/payload. |
| 0 | 0 | RX | Echo reply → deliver to matching `SOCK_RAW` socket keyed on `(id, seq)`. |
| 3 | 0–4 | TX | Net/host/proto/port/frag-needed unreachable, generated by `ip_input` / `udp_input`. |
| 11 | 0, 1 | TX/RX | TTL exceeded / reassembly timeout. |
| other | — | — | Dropped, counter bumped. |

### UDP

`UdpBind` table `NUDP = 16` keyed on `(local_ip, local_port)`. Each
bind owns a queue of `NQ = 8` datagrams (1500 B each, page-backed) and
a sleep channel. `recvfrom` sleeps on empty queue; `sendto` is direct
(build header + pseudo-header checksum, hand to `ip_output`). Wildcard
bind on `0.0.0.0`. Ephemeral-port allocation walks `49152..65535`
linearly, skipping bound entries.

### TCP

The bulk of phase 4. RFC 793 + 5681 + 6298 + 7323 + 2018 + 896.

#### Socket struct

```zig
pub const TcpState = enum {
    Closed, Listen, SynSent, SynRcvd, Established,
    FinWait1, FinWait2, CloseWait, Closing, LastAck, TimeWait,
};

pub const TcpSocket = struct {
    state: TcpState,

    // 4-tuple
    laddr: u32, lport: u16,
    raddr: u32, rport: u16,

    // RFC 793 sequence variables
    snd_una: u32, snd_nxt: u32, snd_wnd: u32,
    snd_wl1: u32, snd_wl2: u32, snd_iss: u32,
    rcv_nxt: u32, rcv_wnd: u32, rcv_irs: u32,

    // Buffers (page-allocator-backed, sized by SO_{SND,RCV}BUF, 4..16 KB)
    snd_buf: RingBuffer, rcv_buf: RingBuffer,
    rcv_ofo: OutOfOrderQueue,           // up to NOFO=16 segments

    // Retransmit queue (NRTX=64 entries)
    snd_rtx: RetransQueue,

    // CC (RFC 5681 + 6582 NewReno)
    cwnd: u32, ssthresh: u32, dupack_count: u32,
    in_recovery: bool, recover: u32,

    // RTO (RFC 6298)
    srtt: u32, rttvar: u32, rto: u32, rto_backoff: u32,

    // Timers (driven by Phase 3's timer subsystem;
    // tcp_tick() runs at 100 Hz off the existing SSIP-forwarded path)
    rtx_timer: Timer, persist_timer: Timer,
    delayed_ack_timer: Timer, timewait_timer: Timer,
    keepalive_timer: Timer,

    // Options
    sack_permitted: bool, rcv_sack_blocks: [4]SackBlock,
    ts_enabled: bool, ts_recent: u32, ts_recent_age: u32,
    snd_wnd_scale: u3, rcv_wnd_scale: u3,
    nodelay: bool,                       // TCP_NODELAY

    // Sleep channels
    chan_read: usize, chan_write: usize, chan_accept: usize,

    // Listen-only
    backlog: u32, accept_q: ?*AcceptQueue,

    // Misc
    sticky_err: i32, refs: u32,
};

pub var socket_table: [NTCP]TcpSocket = undefined;   // .bss; NTCP = 64
```

#### State machine

```
                          passive open
                     ┌────► LISTEN ────────────────┐
                     │       │                      │ rcv SYN
                     │       │ snd SYN              │ snd SYN+ACK
                CLOSE│   ┌───▼─────────┐   ┌────────▼─────┐
       active open──┴──► │  SYN_SENT   │   │  SYN_RCVD    │
                         └───┬─────────┘   └────┬─────────┘
                              │ rcv SYN+ACK      │ rcv ACK
                              │ snd ACK           │
                              ▼                   ▼
                          ┌──────────────────────────┐
                          │       ESTABLISHED        │◄── data
                          └──────────┬───────────────┘
                          close            rcv FIN
                              │                │
                              ▼                ▼
                        ┌──────────┐      ┌────────────┐
                        │FIN_WAIT_1│      │ CLOSE_WAIT │── close ──┐
                        └────┬──┬──┘      └─────┬──────┘           │
                  rcv ACK    │  │ rcv FIN+ACK   │ snd FIN          │
                             │  │               ▼                  ▼
                ┌──────────┐ │  └─────► ┌──────────────┐  ┌────────────┐
                │FIN_WAIT_2│◄┘          │   CLOSING    │  │  LAST_ACK  │
                └────┬─────┘            └──────┬───────┘  └─────┬──────┘
                     │ rcv FIN              rcv ACK             │ rcv ACK
                     │ snd ACK                 │                │
                     ▼                         ▼                ▼
                          ┌────────────────────────────────┐
                          │           TIME_WAIT             │
                          └─────────────┬───────────────────┘
                                        │ 2MSL = 60 s
                                        ▼
                                      CLOSED
```

#### Output path

`tcp_output(sock)`:

1. Effective window `W = min(cwnd, snd_wnd) - flight`. If `W <= 0`: if
   `snd_wnd == 0`, arm persist timer; else nothing to send.
2. Pick segment size `s = min(W, MSS, snd_buf.readable)`.
3. Honor Nagle: if `!nodelay && flight > 0 && s < MSS && !rtx_pending`,
   hold (unless `s == snd_buf.readable` and we're closing — final
   segment always flushes).
4. Build options list: timestamps if `ts_enabled`; SACK ACK blocks if
   any; padding to 4-byte align.
5. Form segment, append to `snd_rtx` with `ts_sent`, push to
   `ip_output`.
6. Set `PSH` if this empties the send buffer; set `FIN` on
   `close`-initiated final segment.

#### Input path (segment processing)

Follows RFC 793 §3.10 ordering with 5681 + 6298 + 2018 + 7323 hooks:

1. Look up socket by 4-tuple (or LISTEN-on-`(0.0.0.0, lport)`); RST
   orphans.
2. Sequence check + PAWS (timestamps).
3. Process state-specific transitions.
4. Process ACK: free `snd_rtx` head, sample RTT into `srtt/rttvar/rto`
   if not Karn-poisoned, update `cwnd` per CC mode, slide `snd_una`. On
   `dupack_count == 3`: enter fast retransmit. On partial ACK during
   recovery: retransmit next SACK hole.
5. Process data: deliver in-order segment to `rcv_buf`, drain
   `rcv_ofo` prefix; otherwise enqueue in `rcv_ofo` and add SACK
   block. Wake reader.
6. Process FIN, RST.
7. Schedule output (delayed ACK timer 200 ms, or immediate if
   window-update worthy / out-of-order arrived / 2nd in-order full
   segment).

#### Retransmit timer (RFC 6298)

`SRTT = 7/8 SRTT + 1/8 R`; `RTTVAR = 3/4 RTTVAR + 1/4 |SRTT - R|`;
`RTO = SRTT + 4 * RTTVAR`, clamped to `[200 ms, 60 s]`. Karn's rule:
don't sample retransmitted segments. Initial RTO = 3 s (we drop to 1 s
after first sample). On timer fire: head of `snd_rtx` is retransmitted,
`rto *= 2` (capped at 60 s), Karn arms (next sample skipped), CC drops
to RTO-loss profile (`ssthresh = max(flight/2, 2*MSS); cwnd = MSS`).
Retransmit cap = 12 (≈ 9 minutes); past that, drop the connection
with `ETIMEDOUT`.

#### Congestion control (RFC 5681 + 6582 NewReno)

`cwnd` in bytes. `IW = min(4*MSS, max(2*MSS, 4380))`. SS until
`cwnd >= ssthresh`; CA after. On loss:

- **RTO loss:** `ssthresh = max(flight/2, 2*MSS)`; `cwnd = MSS`; SS
  again.
- **Fast retransmit (3 dupACKs):** `ssthresh = max(flight/2, 2*MSS)`;
  `cwnd = ssthresh + 3*MSS`; retransmit; on each subsequent dupACK,
  `cwnd += MSS`; on partial ACK during recovery, retransmit next hole;
  on full recovery (`recover` ACKed), `cwnd = ssthresh`. RFC 6582
  NewReno deduplication.

#### SACK (RFC 2018)

`SACK-Permitted` exchanged in SYN/SYN-ACK. Receiver builds up to 3
SACK blocks per ACK (option fits with timestamps and 12-byte
alignment). Sender uses SACK info to skip already-acked bytes within
`snd_rtx` during retransmit walks.

#### Timestamps + window scaling (RFC 7323)

- TSopt in every segment after both peers advertise it. `ts_recent`
  updated only when in-window. PAWS rejects out-of-window timestamps.
- WS exchanged in SYN/SYN-ACK; `snd_wnd` and `rcv_wnd` scaled
  accordingly. Default scale = 2 (so a 16 KB recv-buf advertises 64 KB
  usable).

#### TIME_WAIT

2MSL = 60 s. The 100 Hz `tcp_tick()` walks `socket_table` and harvests
expired TIME_WAIT entries (per-tick is overkill but cheap at
NTCP = 64). Concurrent reuse of the 4-tuple before 2MSL
elapses is allowed *only* if our timestamp option is strictly newer
(PAWS).

#### Nagle (RFC 896) and PUSH

- Nagle on by default; `setsockopt(TCP_NODELAY, 1)` disables.
- PSH bit set on every segment that empties the send buffer.

#### MSS and MTU

MTU 1500 → MSS 1460. With timestamps (12 B incl. NOPs) + SACK ACK
blocks (variable) the on-wire payload trims to ~1448; we don't
pre-shrink, we just account for option size when packing.

### DNS resolver (`net/dns.zig`)

Synchronous library, called from `connect()` and userland.

Public API:

```zig
pub fn resolve(name: []const u8, kind: enum{A}) ![]const u32;
```

- **Hosts file** (`/etc/hosts`) parsed once at boot into a small
  `[NHOSTS = 32]` table. Consulted before the resolver.
- **Cache** — `NCACHE = 64` entries keyed by `(name, type)`, storing
  IPs + absolute expiry. LRU eviction. Negative cache (RFC 2308)
  shares the table; expiry capped at 5 min.
- **Query loop** (per `/etc/resolv.conf` server, in order):
  1. Build query: random 16-bit ID, RD = 1, single QNAME, EDNS0 OPT
     pseudo-RR with payload size 4096.
  2. UDP send to `(server, 53)`. Per-attempt timeout 1.5 s.
  3. On reply: validate ID, drop if mismatched.
  4. If TC = 1 → TCP fallback (open stream socket to `(server, 53)`,
     length-prefixed query).
  5. Walk answer section; if only CNAMEs, recurse on the canonical
     name (≤ 8 hops).
  6. If no answer: check authority for SOA → cache negative result.
- **Failover:** 1.5 s per attempt; on timeout, advance to next server
  in `/etc/resolv.conf`. Total resolution budget is **5 s**
  (configurable) — i.e. up to ~3 attempts before giving up regardless
  of how many servers are listed.

`resolve` returns a list of A records or an error; the caller
(typically `connect`) picks the first.

## Sockets, fds, pipes

Phase 3's `File` becomes vtable-shaped:

```zig
pub const FileOps = struct {
    read:  fn(*File, []u8) i32,
    write: fn(*File, []const u8) i32,
    close: fn(*File) void,
    ioctl: fn(*File, u32, usize) i32,
    fcntl: fn(*File, u32, usize) i32,
};

pub const File = struct {
    refs: u32, flags: u32,           // O_NONBLOCK lives here
    ops: *const FileOps,
    private: usize,                   // → RegFile | ConsoleFile
                                      //   | TcpSocket | UdpSocket | RawSocket
                                      //   | Pipe
};
```

`Pipe` is a 4 KB ring + two `File` views (read-end, write-end) sharing
one `Pipe` struct via `private`. EOF on closed write-end; `EPIPE` on
closed read-end (no signals → just an error return). `pipe2(int fd[2],
int flags)` recognizes `O_NONBLOCK`.

## Syscall surface (Phase 4 additions)

| # | Name | Args | Return | Phase |
|---|---|---|---|---|
| 23 | `dup(fd)` | u32 | newfd / -1 | 4 (Phase 3 punted; sockets need it) |
| 24 | `dup3(old, new, flags)` | u32, u32, u32 | newfd / -1 | 4 (`O_CLOEXEC` accepted-and-ignored) |
| 25 | `fcntl(fd, cmd, arg)` | u32, u32, u32 | per-cmd | 4 (`F_GETFL`, `F_SETFL` for `O_NONBLOCK`) |
| 59 | `pipe2(fds, flags)` | u32, u32 | 0 / -1 | 4 |
| 198 | `socket(domain, type, proto)` | u32, u32, u32 | fd / -1 | 4 |
| 200 | `bind(fd, addr, len)` | u32, u32, u32 | 0 / -1 | 4 |
| 201 | `listen(fd, backlog)` | u32, u32 | 0 / -1 | 4 |
| 202 | `accept4(fd, addr, len, flags)` | u32×4 | newfd / -1 | 4 |
| 203 | `connect(fd, addr, len)` | u32, u32, u32 | 0 / -1 | 4 (`addr` is always a numeric `sockaddr_in`; userland resolves names via `dns.resolve` first — `connect` itself never blocks on DNS) |
| 204 | `getsockname(fd, addr, len)` | u32, u32, u32 | 0 / -1 | 4 |
| 205 | `getpeername(fd, addr, len)` | u32, u32, u32 | 0 / -1 | 4 |
| 206 | `sendto(fd, buf, len, flags, addr, alen)` | u32×6 | bytes / -1 | 4 |
| 207 | `recvfrom(fd, buf, len, flags, addr, alen)` | u32×6 | bytes / -1 | 4 |
| 208 | `setsockopt(fd, lvl, name, val, len)` | u32×5 | 0 / -1 | 4 |
| 209 | `getsockopt(fd, lvl, name, val, len)` | u32×5 | 0 / -1 | 4 |
| 210 | `shutdown(fd, how)` | u32, u32 | 0 / -1 | 4 |
| 5002 | `if_query(idx, buf, sz)` | u32, u32, u32 | bytes / -1 | 4 (backs `ifconfig`) |

`setsockopt` levels: `SOL_SOCKET` (`SO_RCVBUF`, `SO_SNDBUF`,
`SO_REUSEADDR`, `SO_KEEPALIVE`, `SO_LINGER`); `IPPROTO_TCP`
(`TCP_NODELAY`); `IPPROTO_IP` (`IP_TTL`).

Read/write/close polymorph through the vtable; no socket-specific
`read`/`write` syscalls.

## Userland

Approximate sizes:

| Binary | LoC | Notes |
|---|---|---|
| `ping` | ~150 | Hostname → `dns.resolve` → `SOCK_RAW IPPROTO_ICMP`. Stats line on `^C`. |
| `nc` | ~300 | `nc HOST PORT` (TCP client), `nc -l PORT` (TCP server, single accept), `-u` (UDP). fork+pipe duplex: parent reads stdin → write socket; child reads socket → write stdout. |
| `host` | ~80 | `host example.com` → calls resolver, prints A records + any CNAME chain. |
| `ifconfig` | ~80 | Read-only: MAC, IPv4, gateway, MTU, RX/TX counters. |

Config files baked into `fs.img`:

- `/etc/network` — single block:
  ```
  iface eth0 static
    ip       10.0.2.2
    netmask  255.255.255.0
    gateway  10.0.2.1
    mtu      1500
    mac      52:54:00:12:34:56
  ```
- `/etc/hosts` — `IP  name [aliases…]`, one per line.
- `/etc/resolv.conf` — `nameserver IP`, one per line; multiple servers
  tried in order.

## Project structure (deltas from Phase 3)

```
ccc/
├── build.zig                                    + nic, slirp, net-peer targets
├── src/
│   ├── devices/
│   │   ├── nic.zig                              NEW (4.A)
│   │   └── slirp/                               NEW (4.A)
│   │       ├── slirp.zig
│   │       ├── tcp.zig
│   │       ├── udp.zig
│   │       ├── icmp.zig
│   │       ├── arp.zig
│   │       └── loss.zig
│   └── …                                         unchanged
├── tests/
│   ├── programs/kernel/
│   │   ├── nic.zig                              NEW
│   │   ├── net/                                 NEW (see Architecture)
│   │   └── userland/                            + ping, nc, host, ifconfig
│   ├── net-peer/                                NEW
│   │   └── echo.zig
│   └── …                                         unchanged
└── docs/superpowers/specs/                      + this spec
```

## CLI

```
ccc [--trace] [--halt-on-trap] [--memory MB] [--disk PATH] [--input PATH]
    [--net slirp|loopback|none] [--net-mac MAC] [--net-ip-range CIDR]
    [--dns SERVER] [--net-drop-pct N] [--net-reorder-pct N] [--net-rtt-ms N]
    <elf>
```

- `--net slirp` — wire SLIRP backend (default once 4.A lands).
- `--net loopback` — backend that echoes every TX'd frame back to the
  guest unchanged. Unit-test backend.
- `--net none` — NIC reports link-down (regression mode for Phase 1-3
  e2e coverage).
- `--net-mac MAC` — override default `52:54:00:12:34:56`.
- `--net-ip-range CIDR` — default `10.0.2.0/24` (gw `.1`, guest `.2`).
  Cosmetic; affects printed addresses, not SLIRP behavior.
- `--dns SERVER` — used by `mkfs` to bake the right nameserver into
  `/etc/resolv.conf` for the test image. Not consulted by SLIRP.
- `--net-{drop,reorder,rtt}-*` — only meaningful with `--net slirp`.

## Implementation plan decomposition

Seven plans:

- **4.A — Emulator: NIC + SLIRP skeleton.**
  NIC MMIO, ARP responder, ICMP echo via host DGRAM, CLI flags,
  loss/reorder/delay injector. Kernel-side stub test program (no
  userland; same shape as 3.A's PLIC test) ARPs and pings; verifies
  the device + backend in isolation. **No kernel changes.**
  Milestone: `e2e-net-link` passes a stub kernel that ARPs the
  gateway and round-trips an ICMP echo.
- **4.B — Kernel: NIC driver + Ethernet/ARP/IPv4.**
  NIC driver, Ethernet framing, ARP cache + req/reply, IPv4 in/out +
  reassembly, route + interface state. Milestone: a kernel-internal
  test loops an IPv4-over-Ethernet datagram through the NIC and out
  via SLIRP, verifies it round-trips. `e2e-arp`, `e2e-icmp` pass.
- **4.C — Kernel: ICMP + UDP + socket layer + `ping`.**
  `icmp.zig`, `udp.zig`, `socket.zig` polymorph, basic socket
  syscalls (`socket`, `bind`, `sendto`, `recvfrom`, `close`),
  `SOCK_RAW`-for-ICMP, `ping` userland, UDP NAT in SLIRP. Milestone:
  `ping 1.1.1.1` works from the shell; `e2e-udp` passes.
- **4.D — TCP base: state machine + reliable in-order data.**
  Full state machine, coarse RTO, fixed window, in-order delivery,
  `connect` / `listen` / `accept4` / `shutdown`, `read`/`write`
  polymorph for STREAM, SLIRP TCP NAT. Milestone: `nc -l 7777` ↔
  `nc localhost 7777` round-trips; `e2e-tcp-handshake`,
  `e2e-tcp-stream` pass.
- **4.E — TCP performance: 5681 + 6298 + 7323 + 2018.**
  Karn + Jacobson RTO, slow start, CA, fast retransmit, fast
  recovery, SACK, timestamps, window scaling. SLIRP loss-injector
  wired into e2e tests. Milestone: `e2e-tcp-loss`, `e2e-tcp-cc` pass;
  cwnd progression in trace matches reference table.
- **4.F — DNS resolver + `nc` polish + `host` + `ifconfig`.**
  Resolver, hosts file, `connect()`-by-name path, three userland
  tools, `/etc/network` parsing. Milestone: `ping example.com`,
  `host example.com`, `ifconfig` work; `e2e-dns` passes.
- **4.G — Pipes + Nagle + final demo.**
  `pipe(2)` syscall + shared buffered-fd machinery, `fcntl`
  `O_NONBLOCK`, Nagle, PSH semantics. Final regression sweep.
  Milestone: hit Definition of Done; `e2e-pipe`, `e2e-net-link`,
  `e2e-arp`, `e2e-icmp`, `e2e-udp` all pass.

## Testing strategy

### 1. Emulator unit tests (in 4.A and onward)

- NIC: TX kick → STATUS bit1 set → IRQ on backend ack → bit1 clear.
  RX: pre-post buffer → backend hands frame → STATUS bit2 set → IRQ →
  `rx-release` clears bit2.
- SLIRP ARP: gateway IP → synthesized reply.
- SLIRP ICMP: round-trips a host echo through the SOCK_DGRAM path on
  macOS; per-OS skip with reason on platforms without unprivileged
  DGRAM ICMP.
- SLIRP loss/reorder/delay: deterministic given a seed.

### 2. Kernel unit tests (in 4.B and onward)

- Internet checksum vectors for IPv4, TCP, UDP pseudo-header.
- ARP: cache eviction, request/reply, gratuitous, pending-IP queue
  drain.
- IP reassembly including overlapping fragments per RFC 5722 (drop).
- TCP state machine: SYN/SYN-ACK/ACK round-trip; FIN handshake from
  each side; simultaneous close.
- TCP CC: synthetic RTT samples → SRTT/RTTVAR/RTO matches RFC 6298
  reference values; cwnd progression in SS and CA matches RFC 5681
  examples.
- TCP SACK: encode/decode; sender-side gap retransmit.
- DNS: parse known wire-format responses; CNAME chase; negative
  cache; ID-mismatch drop.

### 3. `riscv-tests` integration

rv32{ui,um,ua,mi,si}-p-* unchanged from Phase 3. Must still pass after
every Phase 4 plan lands.

### 4. Kernel e2e (`zig build e2e-*`)

| Test | What it asserts | Plan |
|---|---|---|
| `e2e-net-link` | NIC ARPs the gateway via SLIRP, gets a reply. | 4.A |
| `e2e-arp` | Gratuitous ARP collision detection on boot. | 4.B |
| `e2e-icmp` | Kernel-internal ICMP echo round-trips through SLIRP. | 4.B |
| `e2e-udp` | UDP socket sendto / recvfrom round-trip via host test peer. | 4.C |
| `e2e-tcp-handshake` | connect/accept/close, three-way + FIN, no data. | 4.D |
| `e2e-tcp-stream` | 64 KB stream both directions; byte-checksum match. | 4.D |
| `e2e-tcp-loss` | `--net-drop-pct 5`: CC kicks in; same checksum match; cwnd visible in trace. | 4.E |
| `e2e-tcp-cc` | `--net-rtt-ms 100`: SS curve matches reference cwnd table. | 4.E |
| `e2e-dns` | Resolver answers from cache + upstream; CNAME chase works. | 4.F |
| `e2e-pipe` | parent/child round-trip via `pipe2`. | 4.G |

### 5. Host test peer

`tests/net-peer/echo.zig`. Two modes: TCP echo (accept loop, splice
bytes back) and UDP echo (recv → send to source). The e2e harness
launches it on a localhost ephemeral port before spawning `ccc`, kills
it after. Deterministic: only loss/reorder/delay come from SLIRP
knobs.

### 6. Regression coverage

All Phase 1 e2e (`e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`),
Phase 2 (`e2e-kernel`), and Phase 3 (`e2e-multiproc-stub`, `e2e-fork`,
`e2e-fs`, `e2e-shell`, `e2e-editor`, `e2e-persist`) pass after every
Phase 4 plan.

## Risks and open questions

- **Unprivileged ICMP availability.** macOS and most Linux distros
  allow `SOCK_DGRAM IPPROTO_ICMP` for non-root; FreeBSD and some
  hardened Linux distros need root or the `IcmpSendEcho` helper on
  Windows. macOS-primary, Linux-secondary; per-OS fallback path
  documented but not gated on for Phase 4 sign-off.
- **SLIRP terminates guest TCP locally.** Guest CC code only sees real
  loss when we inject it. The `--net-{drop,reorder,rtt}-*` knobs are
  load-bearing for `e2e-tcp-loss` / `e2e-tcp-cc` — re-evaluate after
  4.E lands; if the synthetic environment isn't testing what we want,
  consider an additional UDP-tunnel mode that hands raw frames to a
  real Linux peer in CI.
- **TIME_WAIT churn.** With `NTCP = 64` and 2MSL = 60 s, a test loop
  opening many short connections can starve socket slots. If
  `e2e-tcp-stream` ever flakes, drop 2MSL to 5 s in test mode (gated
  on a `setsockopt` extension we keep internal).
- **No `select` / `poll`.** Any in-process multi-fd userland is
  impossible; everything multiplexes via `fork` + `pipe`. Documented;
  Phase 5's browser will retest the assumption.
- **Reassembly amplification.** 4 buffers × 16 KB; 30 s timeout.
  We're behind SLIRP, so the realistic attack surface is what we send
  ourselves. Acceptable.
- **Resolver-blocking `connect`.** A bad `/etc/resolv.conf` plus an
  unreachable server blocks `connect("name", port)` for ~5 s.
  Acceptable; documented; `^C` cancels via the kill-flag path.
- **Demo flakiness from upstream.** `ping 1.1.1.1` and `host
  example.com` depend on the host's internet. CI uses the test peer
  for determinism; the interactive demo accepts upstream variance.
- **Frame pool starvation.** `NFRAME = 32` with 2 KB slots = 64 KB. A
  burst that simultaneously fills `snd_rtx` across many sockets could
  exhaust the pool. Mitigation: `tcp_output` honors pool availability
  and queues a "send-when-pool-frees" wakeup. Spec at top of `nic.zig`.
- **Zig version churn.** Same as every phase. Re-pin `build.zig.zon`
  at Phase 4 start.

## Roughly what success looks like at the end of Phase 4

```
$ zig build test                   # all unit tests pass (Phase 1+2+3+4)
$ zig build riscv-tests            # rv32{ui,um,ua,mi,si}-p-* all pass
$ zig build e2e                    # Phase 1+2+3 e2e + e2e-net-link
                                   #  + e2e-arp + e2e-icmp + e2e-udp
                                   #  + e2e-tcp-handshake + e2e-tcp-stream
                                   #  + e2e-tcp-loss + e2e-tcp-cc
                                   #  + e2e-dns + e2e-pipe all pass

$ zig build kernel && zig build fs-img
$ zig build run -- --disk zig-out/fs.img --net slirp zig-out/bin/kernel.elf
$ ifconfig
eth0: link UP
  ether 52:54:00:12:34:56
  inet 10.0.2.2/24  gw 10.0.2.1  mtu 1500
  RX 28 packets 3360 bytes  TX 12 packets 1240 bytes

$ ping 1.1.1.1
PING 1.1.1.1 (1.1.1.1) 56 bytes
64 bytes from 1.1.1.1: icmp_seq=1 ttl=56 time=8.4 ms
64 bytes from 1.1.1.1: icmp_seq=2 ttl=56 time=8.1 ms
^C
2 packets transmitted, 2 received, 0% packet loss

$ host example.com
example.com has address 93.184.216.34

$ ping example.com
PING example.com (93.184.216.34) 56 bytes
64 bytes from 93.184.216.34: icmp_seq=1 ttl=53 time=24.2 ms
^C

$ nc 93.184.216.34 80
GET / HTTP/1.0
Host: example.com

HTTP/1.0 200 OK
…
$ exit
```

…and you understand every byte from the NIC's first ARP request
through TCP slow-start, retransmit, SACK recovery, and the DNS
resolver's CNAME chase.
