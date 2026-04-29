# Phase 5 — HTTP/1.0 Client + Text Browser (Design)

**Project:** From-Scratch Computer (directory `ccc/`).
**Phase:** 5 of 6 — see `2026-04-23-from-scratch-computer-roadmap.md`.
**Status:** Approved design, ready for implementation planning.

## Goal

Add a from-scratch HTTP/1.0 client and a tiny text-mode browser on top of
Phase 4's socket layer. Browse plain-HTTP pages by typing link numbers.
Render real-world plain HTML — UTF-8 passthrough, redirects, chunked
transfer-encoding, forgiving parser tolerance — against both a known-good
real-world site (info.cern.ch) and a deterministic host-side test peer.
**No kernel changes:** Phase 4 already shipped sockets, pipes, `fcntl`,
and the DNS resolver as a callable library; Phase 5 lives entirely in
userland plus a host-side HTTP server for e2e determinism.

## Definition of done

- `zig build kernel` produces `kernel.elf`. `fs.img` (built by Phase 3's
  `mkfs`) gains `/bin/browse`. `tests/web-peer/serve.zig` builds as a
  host binary the e2e harness launches.
- `ccc --disk fs.img --net slirp kernel.elf` boots, reaches `$ ` with
  Phase 4's network stack live, and the seven-line interactive demo
  passes:
  1. `browse http://test-server/` — index renders with inline `[N]`
     markers + numbered footer.
  2. `1<Enter>` — follows that link; the new page renders.
  3. `b` — previous page redraws **from cache** (no second fetch —
     verified against the test peer's request log).
  4. `r` — current page re-fetches (test peer log shows a fresh
     request).
  5. `:url http://info.cern.ch/` — opens the restored first-ever
     website over the actual internet through Phase 4's stack;
     redirects (if any) follow automatically; `<title>` is rendered
     in the heading.
  6. `q` — clean exit; `^C` mid-load also exits cleanly via Phase 4's
     kill-flag path.
  7. `browse http://test-server/missing` — server's 404 HTML body
     renders as the page (not treated as a fatal error).
- All Phase 1 e2e (`e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`),
  Phase 2 (`e2e-kernel`), Phase 3 (`e2e-multiproc-stub`, `e2e-fork`,
  `e2e-fs`, `e2e-shell`, `e2e-editor`, `e2e-persist`), and Phase 4
  (`e2e-net-link`, `e2e-arp`, `e2e-icmp`, `e2e-udp`,
  `e2e-tcp-handshake`, `e2e-tcp-stream`, `e2e-tcp-loss`, `e2e-tcp-cc`,
  `e2e-dns`, `e2e-pipe`) still pass.
- New e2e tests pass: `e2e-url`, `e2e-http-200`, `e2e-http-redirect`,
  `e2e-http-chunked`, `e2e-http-error`, `e2e-http-charset`,
  `e2e-http-timeout`, `e2e-html-parse`, `e2e-render`, `e2e-browse-nav`.
- `riscv-tests` (rv32{ui,um,ua,mi,si} all `-p-*`) still pass.

## Scope

### In scope

- **Userland: `tests/programs/userland/browse/` (subdir, multi-file).**
  Five focused files:
  - `main.zig` — nav loop. Cooked-input prompt: `<n>` follow link N,
    `b` back, `r` reload, `:url URL` navigate, `:title` print current
    `<title>`, `q` quit.
  - `url.zig` — RFC 3986 lite: `http://host[:port]/path?query`. Parse
    + relative-URL resolution against a base URL (RFC 3986 §5.3
    behavior, hand-implemented). Percent-encoding pass-through.
    `#fragment` stripped (no in-page anchors). No userinfo, no IDN /
    punycode.
  - `http.zig` — HTTP/1.0 client. `GET` only. `Host`,
    `User-Agent: ccc/0.5`, `Accept: */*`, `Connection: close` request
    headers. Status-line + headers + body parse. `Content-Length` and
    `Transfer-Encoding: chunked` decoded. `Content-Type: text/html;
    charset=…` parsed: `utf-8` / `iso-8859-1` / `windows-1252` /
    `us-ascii` (and absent header) pass through; anything else
    returns `EUNSUPPCHARSET`. Redirects 301/302/303/307/308
    auto-followed up to 5 hops; same-URL self-redirect detected at
    hop 1. 4xx/5xx body returned as the page (not a fatal error).
    New TCP socket per request — no keep-alive.
  - `html.zig` — Tokenize-and-stack parser. Recognized tags: `<html>`,
    `<head>`, `<title>`, `<body>`, `<p>`, `<h1>`–`<h6>`, `<a>`,
    `<br>`, `<hr>`, `<pre>`, `<code>`, `<ul>`/`<ol>`/`<li>`,
    `<b>`/`<strong>`, `<i>`/`<em>`, `<blockquote>`. `<script>` and
    `<style>` enter raw-text mode (read-until-close-tag,
    case-insensitive; body discarded). Comments (`<!--…-->`) and
    `<!DOCTYPE …>` skipped. Mismatched close: pop until match (no-op
    on miss). Unknown tags: render children as text, drop the tag.
    Entity decoding: ~250-entry HTML5 named-entity short list
    (sorted, binary-searched) + numeric (`&#NNN;` decimal,
    `&#xNN;` hex); unrecognized passes through verbatim.
  - `render.zig` — Layout + ANSI emit. Hard-wrap text at 78 cols.
    Headings: ANSI bold + a `═══` rule for `<h1>`. Links: ANSI
    underline + inline `[N]` brackets around the visible anchor
    text. `<pre>`/`<code>`: no wrapping. Lists: `  - ` prefix
    (`<ul>`) or `  N. ` (`<ol>`). Blockquotes: `  > ` per line.
    After body: blank line + `Links:` + numbered absolute URLs.

- **Test peer: `tests/web-peer/serve.zig`.** Host-side Zig HTTP/1.0
  server, ~250 LoC, accept-loop on a localhost ephemeral port (passed
  via `--port`). Hand-authored static corpus (~12 routes — see the
  **Test peer** subsection under Architecture). Stable per-request log
  on stderr (one `GET /path` line per request) so e2e tests can assert
  "fetched once" / "fetched twice."

- **Build glue:** `zig build browse` builds the userland binary;
  `zig build web-peer` builds the host server; `zig build e2e-browse-*`
  plumbs them together via the harness.

- **`fs.img` config:**
  - `/etc/hosts` gains an entry the e2e harness rewrites at boot:
    `test-server` → the address SLIRP forwards to the host peer's
    port (same trick `host` uses in Phase 4 for hostname → IP).
  - No new `/etc` files specific to `browse`.

### Out of scope (deferred or never)

- HTTPS / TLS — never in this project. Roadmap calls it out.
- HTTP/1.1 features beyond chunked + redirects: pipelining,
  `Expect: 100-continue`, range requests, conditional requests,
  `Vary` / cache headers, persistent connections, `Connection:
  Upgrade`.
- POST / PUT / DELETE / forms — GET-only browser.
- Cookies — neither the test corpus nor info.cern.ch needs them.
- JavaScript / CSS / images / `<iframe>` / `<frame>` — text-mode only.
- HTML5 insertion-mode quirks (auto-closing `<p>`, the adoption
  agency algorithm, `<table>` quirks) — the parser is a simple
  tokenize-and-stack, not a full HTML5 tree builder.
- `winsize` / `ioctl(TIOCGWINSZ)` — text wraps at fixed 78 cols.
- Bookmarks file / persistent history — history lives in-process
  only; lost on `q`.
- In-OS `httpd` — there is no kernel-side HTTP server in Phase 5.
- Pager / raw-mode TUI / `j`/`k` scrolling — `browse` uses
  cooked-input only and relies on terminal scrollback for long
  pages.
- Charset transcoding (full ICU-style decode for Big5, GBK, etc.) —
  the four whitelisted charsets pass through; anything else errors.
- `<meta http-equiv="refresh">` and form auto-submit — silently
  ignored.
- IDN / punycode hostnames — `connect()` only takes IPv4 + ASCII
  names.
- `select` / `poll` / non-blocking multiplexing in `browse` — every
  fetch is a blocking GET; `^C` interrupts via Phase 4's kill-flag.

## Architecture

### Module shape (`tests/programs/userland/browse/`)

```
main.zig                  nav loop, prompt, history stack, dispatch
├── url.zig               Url, parse(), resolve(base, ref), encode_path()
├── http.zig              fetch(url) -> Response { status, headers, body, final_url }
├── html.zig              parse(bytes, base) -> Document { title, blocks, links }
└── render.zig            render(doc, w) emits ANSI text + numbered link footer
```

Public types (sketches):

```zig
// url.zig
pub const Url = struct {
    scheme: []const u8,    // "http" only
    host:   []const u8,
    port:   u16,           // default 80
    path:   []const u8,    // includes leading "/"; default "/"
    query:  ?[]const u8,   // raw, percent-encoding preserved
};
pub fn parse(s: []const u8) !Url;
pub fn resolve(base: Url, ref: []const u8) !Url;   // RFC 3986 §5.3 lite

// http.zig
pub const Charset = enum { utf8, iso_8859_1, windows_1252, us_ascii };

pub const Response = struct {
    status:    u16,
    final_url: Url,                 // after redirects
    headers:   HeaderMap,           // case-insensitive lookup, ~16 entries
    body:      []u8,                // already chunk-decoded, owned
    charset:   Charset,
};
pub fn fetch(allocator: std.mem.Allocator, url: Url) !Response;

// html.zig
pub const Block = union(enum) {
    Heading: struct { level: u3, runs: []Run },
    Para:    []Run,
    Pre:     []const u8,
    List:    struct { ordered: bool, items: [][]Run },
    Quote:   []Run,
    Rule,                           // <hr>
};
pub const Run = struct {
    text:  []const u8,
    style: Style,                   // .{ bold, italic, code, link_idx: ?u16 }
};
pub const Document = struct {
    title:  []const u8,
    blocks: []Block,
    links:  []Url,                  // absolute, in order — Run.link_idx indexes here
};
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, base: Url) !Document;

// render.zig
pub fn render(w: std.io.AnyWriter, doc: Document) !void;
```

### Data flow (one fetch)

```
user types "1<Enter>"
       │
       ▼
main: nav.followLink(1)
       │
       ▼
url.resolve(current.url, current.doc.links[0])
       │
       ▼
http.fetch(resolved_url)            ← Phase 4: connect / read / close
       │  redirects loop ≤5
       ▼
html.parse(response.body, final_url)
       │
       ▼
render.render(stdout, doc)          ← ANSI to UART
       │
       ▼
push onto history stack (doc + url + cached bytes)
       │
       ▼
prompt "browse> "
```

### HTTP fetch (one request)

Every fetch:

1. `dns.resolve(url.host)` → first A record (skipped if `url.host`
   parses as a dotted-quad).
2. `socket(AF_INET, SOCK_STREAM, 0)`; `fcntl(F_SETFL, O_NONBLOCK)`.
3. `connect(sock, sockaddr_in{ip, url.port})`. Watch the clock —
   `EAGAIN`-then-yield until `connect` completes or the budget
   elapses.
4. Build request:
   ```
   GET <path>[?<query>] HTTP/1.0\r\n
   Host: <host>[:<port>]\r\n
   User-Agent: ccc/0.5\r\n
   Accept: */*\r\n
   Connection: close\r\n
   \r\n
   ```
   Single `write`.
5. Read loop into a 4 KB peek buffer; parse status line + headers
   up to `\r\n\r\n`. Branch:
   - `Transfer-Encoding: chunked` → decode loop (read length line in
     hex, read N bytes, repeat until terminator `0\r\n`).
   - `Content-Length: N` → exact `N`-byte read.
   - Neither → read until peer-close (HTTP/1.0 fallback).
6. `close(sock)`. No keep-alive.
7. Status `30x` with `Location:` → `url.resolve(current, location)`,
   bump hop counter, restart from step 1; cap at 5 hops with
   `EREDIRECTLOOP`. Same-URL self-redirect detected at hop 1 by
   URL equality check (fail fast).

Per-request budget: 8 s (configurable via env `BROWSE_TIMEOUT_MS`),
enforced by clock-watch on the non-blocking socket. Phase 4 already
exposes `O_NONBLOCK` via `fcntl`, so this needs no kernel work; the
busy-yield loop calls a 10 ms `nanosleep` (or yields via the existing
scheduler `yield` syscall — implementation-pinned at plan time).

### HTML parser shape

Two passes: tokenizer → tree builder.

**Tokenizer states** (small enum machine, no insertion-mode
complexity): `Data`, `TagOpen`, `TagName`, `BeforeAttr`, `AttrName`,
`AttrValue`, `Comment`, `Doctype`, `RawText`. `RawText` is entered
when `<script>` or `<style>` is parsed, and stays there until the
matching close tag (case-insensitive); contents are discarded.
Entities (named + numeric) are decoded inline during tokenization
into a scratch byte buffer.

**Tree builder.** Linear pass over tokens, single tag stack (max
depth 32). Open tag: push, attach to current node. Close tag: pop
until match; no-op if unmatched. Inline tags (`<a>`, `<b>`,
`<strong>`, `<i>`, `<em>`, `<code>`) become `Run` style spans inside
the current block. Block tags start a new `Block`. Anchors collect
`href` (resolved against `base`) and append to `Document.links`; the
`Run` carries the link index.

### Renderer shape

Single pass over `Document.blocks`. State: `col` cursor,
line-buffer up to 78 chars.

| Block | Output |
|---|---|
| `Heading{1}` | blank · ANSI-bold heading text · blank · `═══…` rule (78 cols) · blank |
| `Heading{2..6}` | blank · ANSI-bold heading text · blank |
| `Para` | runs reflowed at 78 cols · blank |
| `Pre` | text verbatim, no wrapping · blank |
| `List{ordered=false}` | each item: `  - ` + run text reflowed (continuation indented to col 4) |
| `List{ordered=true}` | each item: `  N. ` + run text reflowed (continuation indented) |
| `Quote` | each line prefixed `  > ` |
| `Rule` | `────…` (78 cols) · blank |

Inline run styles emit ANSI:

- `bold` / `strong` → `\x1b[1m` … `\x1b[22m`.
- `italic` / `em` → `\x1b[3m` … `\x1b[23m`.
- `code` → `\x1b[7m` … `\x1b[27m` (reverse video — italic is
  unreliable in terminals).
- Anchor → `\x1b[4m[N]<anchor text>[N]\x1b[24m` (underline +
  bracket markers around the visible link text; the visible `[N]`
  is what the user types at the prompt).

After the last block, the renderer emits:

```

Links:
  [1] <absolute URL>
  [2] <absolute URL>
  ...
```

If `Document.links` is empty, the `Links:` block is omitted.

### Nav loop and history

```zig
const HistEntry = struct {
    url:            Url,
    doc:            Document,
    rendered_bytes: u32,        // for memory accounting
};

pub const Browser = struct {
    history:            BoundedDeque(HistEntry, 8),  // most-recent at back
    cursor:             u8,                          // index into history
    total_cached_bytes: u32,                         // soft cap 512 KB
};
```

- Forward navigation pushes a new entry; if `total_cached_bytes`
  exceeds 512 KB, evict from the front.
- `b` decrements `cursor` and re-renders the cached doc — no fetch.
- `r` re-fetches the URL at `cursor`; replaces the entry in place.
- `:url X` resets `cursor` to the back of the deque + new entry
  (truncating any forward history past the cursor, like a real
  browser).
- `q` exits cleanly; `^C` routes through Phase 4's kill-flag,
  aborting any blocking `read` on the socket; the fetch returns
  `EINTR`; the nav loop catches the error, redraws the previous
  page, and re-prompts. At the idle prompt, `^C` exits the binary.

Per-document memory: `Document` holds slices into a single
parser-arena page-allocator allocation; eviction frees the entire
arena per page, so the 512 KB cap is loose at the edges (rounded up
to whole arenas), which is acceptable.

### Test peer (`tests/web-peer/serve.zig`)

Host-side, ~250 LoC. `accept` loop on a localhost ephemeral port
(passed in via `--port`). Serves a hard-coded route table:

| Path | Behavior |
|---|---|
| `/` | Index — links to all the others. |
| `/about` | A short paragraph + a few inline tags + one link back. |
| `/articles` | Two `<h2>` sections + paragraphs + a link list. |
| `/redirect` | 302 → `/about`. |
| `/redirect-loop` | 302 → `/redirect-loop` (loop-detection test, expects `EREDIRECTLOOP`). |
| `/entities` | `&amp;`, `&lt;`, `&#x2603;`, `&copy;`, etc. |
| `/utf8` | UTF-8 chars in body and `<title>`. |
| `/chunked` | `Transfer-Encoding: chunked`, three chunks. |
| `/script` | Page with `<script>` containing `<` chars + `<style>` with `{` — torture for raw-text mode. |
| `/pre` | `<pre>` block of ASCII art (no wrapping required). |
| `/missing` | 404 with HTML body. |
| `/slow` | Holds the connection 3 s before responding (timeout testing — under our 8 s budget). |
| `/unsupported-charset` | `Content-Type: text/html; charset=Big5` (expects `EUNSUPPCHARSET`). |

Stable per-request log on stderr: `GET /path` per line. The harness
reads the log to assert request counts (e.g. `b` causes no log line;
`r` causes one).

## CLI

**No new kernel CLI flags.** Phase 4's `--net slirp`, `--disk`,
`--trace`, `--memory`, etc. are all that's needed.

The e2e harness gains an internal `--web-peer-port N` argument plumbed
via env when launching the test peer; the harness then rewrites
`/etc/hosts` inside `fs.img` so `test-server` resolves to `10.0.2.2`
(SLIRP forwards that address's TCP traffic to the host peer's
ephemeral port). No user-visible CLI surface.

`browse` userland CLI:

```
browse [URL]                           # if URL omitted, prints usage and exits 1

interactive prompt:
  N             follow link N (1-based)
  b             back (cached redraw, no fetch)
  r             reload (fresh fetch)
  :url URL      navigate to URL (absolute or relative to current)
  :title        print current document <title>
  q             quit
  ^C            cancel in-flight fetch; redraws current page;
                if at idle prompt, exits the binary
```

## Project structure (deltas from Phase 4)

```
ccc/
├── build.zig                                + browse + web-peer + e2e-* targets
├── tests/
│   ├── programs/userland/
│   │   └── browse/                          NEW
│   │       ├── main.zig                     ~150 LoC — nav loop, prompt, dispatch
│   │       ├── url.zig                      ~150 LoC — parse + resolve
│   │       ├── http.zig                     ~250 LoC — fetch + redirects + chunked + charset
│   │       ├── html.zig                     ~300 LoC — tokenize + tree + entities
│   │       └── render.zig                   ~200 LoC — ANSI emit + link footer
│   ├── web-peer/                            NEW
│   │   └── serve.zig                        ~250 LoC — host HTTP/1.0 server with canned routes
│   └── e2e/                                 + e2e-url, e2e-http-*, e2e-html-parse,
│                                              e2e-render, e2e-browse-nav
└── docs/superpowers/specs/                  + this spec
```

Approximate total: ~1300 LoC userland + ~250 LoC host peer + ~500
LoC e2e harness glue. Smallest phase since 1.A.

## Implementation plan decomposition

Five plans (Phase 5 is smaller than Phase 4's seven):

- **5.A — `url.zig` + test peer skeleton.**
  Build `tests/web-peer/serve.zig` with all routes from the **Test
  peer** table under Architecture, plus `url.zig` (parse + relative
  resolution). No kernel changes, no
  network use yet — `url.zig` is pure parsing tested in-process via
  `zig build test`. Test peer runs as a host binary; the e2e harness
  pokes it directly with the host's `curl` to confirm the route
  table. Milestone: `e2e-url` passes (parse + resolve vector
  table); `web-peer/serve.zig` answers all routes.

- **5.B — `http.zig` (200 + Content-Length only).**
  Minimal HTTP/1.0 client: GET, `Host` + `User-Agent` +
  `Connection: close` headers, status-line + headers parse,
  `Content-Length` body, no redirects, no chunked, no charset.
  Wired into a stub `browse-fetch` userland tool (`browse-fetch URL`
  dumps the response body to stdout — small CLI for testing only,
  removed in 5.E). Milestone: `e2e-http-200` passes against the
  test peer's `/` and `/articles`.

- **5.C — `http.zig` polish: redirects + chunked + charset + error
  bodies.** Add 30x redirect-following (max 5 hops + same-URL
  detection at hop 1), `Transfer-Encoding: chunked` decode,
  `Content-Type` charset parse + four-charset whitelist, 4xx/5xx
  body returned as page (not error). Timeout via `O_NONBLOCK` +
  clock-watch. Milestone: `e2e-http-redirect`, `e2e-http-chunked`,
  `e2e-http-error`, `e2e-http-charset`, `e2e-http-timeout` pass.

- **5.D — `html.zig` + `render.zig`.**
  Tokenizer + tree builder + entity table + ANSI renderer. Wired
  into a stub `browse-render` userland tool (`browse-render FILE`
  reads HTML from a file in `fs.img` and renders to stdout —
  bypasses the network for golden-output testing; removed in 5.E).
  The test peer's `/entities`, `/script`, `/pre`, `/utf8` are
  exercised here via fetched-then-rendered tests. Milestone:
  `e2e-html-parse` (tree shape on canned input), `e2e-render`
  (golden ANSI output) pass.

- **5.E — `main.zig` (nav loop) + history + final demo.**
  Glue layer: prompt parser, history deque with cached docs +
  512 KB soft cap, `b`/`r`/`:url`/`:title`/`q` dispatch, `^C`
  handling. The e2e harness's `/etc/hosts` rewrite trick to point
  `test-server` at the host peer. The two stub binaries from 5.B
  and 5.D get folded into the single `browse` binary;
  `browse-fetch` and `browse-render` are removed. Milestone:
  `e2e-browse-nav` passes (script-driven full demo flow); the
  seven Definition-of-Done demo lines pass interactively; all
  pre-Phase-5 e2e + `riscv-tests` still pass.

## Testing strategy

### 1. Userland unit tests (Zig `test` blocks)

Compiled with `zig build test`. Run on the host, no kernel boot.

- `url.zig`: 30+ vectors for `parse` + `resolve`. RFC 3986 §5.4
  example table + corner cases (empty path, double slash, `..`
  normalization, percent-encoded host, missing scheme).
- `html.zig`: tokenizer state-transition table; entity decode (named
  + numeric + hex); raw-text mode for `<script>`/`<style>` with
  embedded `<` and `</`; mismatched-tag pop; unknown-tag children
  pass-through.
- `http.zig`: parse known wire-format responses (multiple status
  lines, header continuation, chunked decode vectors, charset header
  parse, redirect headers).
- `render.zig`: golden output — given `Document` X, produce ANSI
  bytes Y. Strip ANSI + check text shape; assert ANSI escape
  positions for headings and links.

### 2. Kernel e2e tests (`zig build e2e-*`)

The harness boots `ccc --disk fs.img --net slirp kernel.elf` after
launching `tests/web-peer/serve.zig` on a host ephemeral port; the
kernel runs a scripted `browse` (or `browse-fetch` / `browse-render`
in earlier plans) invocation; the harness asserts on stdout content
+ test-peer request log.

| Test | What it asserts | Plan |
|---|---|---|
| `e2e-url` | URL `parse` + `resolve` against vector table (in-process, no kernel boot). | 5.A |
| `e2e-http-200` | `browse-fetch http://test-server/` prints expected body. | 5.B |
| `e2e-http-redirect` | `/redirect` follows 302; final response is `/about`. Peer log shows two GETs. `/redirect-loop` errors with `EREDIRECTLOOP`. | 5.C |
| `e2e-http-chunked` | `/chunked` reassembles three chunks correctly. | 5.C |
| `e2e-http-error` | `/missing` returns the 404 body, exits 0 (not a fatal error). | 5.C |
| `e2e-http-charset` | `/utf8` body bytes pass through unchanged; `/unsupported-charset` errors with `EUNSUPPCHARSET`. | 5.C |
| `e2e-http-timeout` | `/slow` succeeds (3 s < 8 s budget); a never-responding port times out and errors. | 5.C |
| `e2e-html-parse` | Tree shape on a hand-authored HTML fixture matches expected `Document`. | 5.D |
| `e2e-render` | `browse-render /etc/test/sample.html` produces golden ANSI output (escape positions asserted). | 5.D |
| `e2e-browse-nav` | Script feeds `1\n`, `b\n`, `r\n`, `q\n`. Asserts: cached redraw on `b` (peer log unchanged), fresh fetch on `r` (peer log +1). | 5.E |

### 3. Real-internet smoke (manual, not in CI)

`browse http://info.cern.ch/` is run interactively as part of the
end-of-phase demo. **Not gated by CI** because of upstream variance
(same policy as Phase 4's `ping 1.1.1.1` / `host example.com`).

### 4. `riscv-tests` integration

rv32{ui,um,ua,mi,si}-p-* unchanged from Phase 4. Must still pass
after every Phase 5 plan lands.

### 5. Regression coverage

All Phase 1 e2e (`e2e`, `e2e-mul`, `e2e-trap`, `e2e-hello-elf`),
Phase 2 (`e2e-kernel`), Phase 3 (`e2e-multiproc-stub`, `e2e-fork`,
`e2e-fs`, `e2e-shell`, `e2e-editor`, `e2e-persist`), and Phase 4
(`e2e-net-link`, `e2e-arp`, `e2e-icmp`, `e2e-udp`,
`e2e-tcp-handshake`, `e2e-tcp-stream`, `e2e-tcp-loss`, `e2e-tcp-cc`,
`e2e-dns`, `e2e-pipe`) pass after every Phase 5 plan.

## Risks and open questions

- **Real-world target drift.** info.cern.ch is plain HTTP today
  (April 2026); CERN could redirect it to HTTPS at any time.
  Mitigation: the demo target is a soft commitment — any
  plain-HTTP page that exercises tier-(c) features is acceptable.
  Fallbacks if info.cern.ch goes HTTPS: `httpforever.com`,
  `neverssl.com`, or a deliberately-plain hobbyist page. The e2e
  matrix doesn't depend on it.
- **Charset whitelist is "pass through and hope."** We don't
  transcode iso-8859-1 / windows-1252 to UTF-8 — we hand the bytes
  to the terminal. Modern terminals usually render the printable
  Latin-1 subset as expected because of overlap. If a target page
  uses 0x80–0xFF bytes (em-dashes, smart quotes), they'll render
  as garbage. Acceptable — tier (c) commits to "real-world plain
  HTML works" but not "every byte byte-correct"; documented as a
  known limitation. Easy follow-up: a 256-entry CP1252→UTF-8 table.
- **Timeout via `O_NONBLOCK` + clock-watch is coarse.** No
  `select` / `poll` (Phase 4 deferred them). The fetch loop spins
  on `read` with `EAGAIN`-then-yield via a 10 ms `nanosleep`
  (or the existing `yield` syscall — pinned at plan time). A real
  `poll(2)` would be ~30 lines of kernel work; deferring as
  Phase 5.5.
- **Cached document memory accounting is approximate.** `Document`
  holds slices into a parser arena. Eviction frees the whole arena
  per-page, so the 512 KB soft cap rounds up to whole arenas.
  Acceptable; documented.
- **Redirect loops.** Hop counter (5) catches them eventually.
  Same-URL self-redirect detected at hop 1 by URL equality check
  (small extra guard so we error fast).
- **`<script>` / `<style>` raw-text close-tag matching is
  case-insensitive.** Both `</script>` and `</SCRIPT>` close;
  ASCII-lowercase comparison.
- **Inline styles in real-world HTML.** `<a href="..." style="...">`
  — we parse and ignore the `style` attribute. Anchor without
  `href` (e.g. `<a name="...">`) — generates no link entry, just
  inlines the text.
- **Long pages.** No paging within `browse`. A 500-line HTML page
  produces 500 lines of terminal output and the user relies on
  terminal scrollback. Acceptable for the demo; `less`-style pager
  is a Phase 5.5 polish item if needed.
- **HTTP/1.0 + chunked is technically inconsistent.** Tier (c)
  commits to handling chunked even though we put `HTTP/1.0` on the
  request line. Real servers will sometimes do this if the response
  generator is dynamic or the response goes through middleware. We
  accept it silently.
- **`^C` semantics during a fetch.** Phase 4's kill-flag interrupts
  the blocking syscall; the fetch returns `EINTR`; the nav loop
  catches and redraws the previous page (not a fatal error). At
  the idle `browse>` prompt, `^C` exits the binary — same shape
  as Phase 3's shell.
- **`/etc/hosts` rewrite at boot.** The harness rewrites
  `/etc/hosts` inside `fs.img` before each e2e run to point
  `test-server` at the SLIRP-side address that maps to the host
  peer's port. If `mkfs` ever changes its layout, the rewrite
  helper needs to track. Documented in `tests/e2e/web/README.md`.
- **Zig version churn.** Same as every phase. Re-pin `build.zig.zon`
  at Phase 5 start.

## Roughly what success looks like at the end of Phase 5

```
$ zig build test                   # all unit tests pass (Phase 1+2+3+4+5)
$ zig build riscv-tests            # rv32{ui,um,ua,mi,si}-p-* all pass
$ zig build e2e                    # all prior e2e + e2e-url + e2e-http-200
                                   #  + e2e-http-redirect + e2e-http-chunked
                                   #  + e2e-http-error + e2e-http-charset
                                   #  + e2e-http-timeout + e2e-html-parse
                                   #  + e2e-render + e2e-browse-nav all pass

$ zig build kernel && zig build fs-img
$ zig build run -- --disk zig-out/fs.img --net slirp zig-out/bin/kernel.elf
$ browse http://test-server/

ccc test corpus
═══════════════════════════════════════════════════════════════════════════════

Welcome. This is a small test corpus served from the host peer. Try [1]about[1]
or [2]articles[2] to navigate. There's also an [3]entities torture[3] page and
a [4]UTF-8 sampler[4].

Links:
  [1] http://test-server/about
  [2] http://test-server/articles
  [3] http://test-server/entities
  [4] http://test-server/utf8

browse> 1

About ccc
═══════════════════════════════════════════════════════════════════════════════

ccc is a from-scratch RISC-V computer: emulator, kernel, networking, and now
a [1]text-mode browser[1].

Links:
  [1] http://test-server/

browse> b
[ cached: ccc test corpus ]

ccc test corpus
═══════════════════════════════════════════════════════════════════════════════
…

browse> :url http://info.cern.ch/
Connecting to info.cern.ch …

The World Wide Web project
═══════════════════════════════════════════════════════════════════════════════

The WorldWideWeb (W3) is a wide-area hypermedia information retrieval
initiative aiming to give universal access to a large universe of documents.
Everything there is online about W3 is linked directly or indirectly to this
document, including an [1]executive summary[1] of the project, [2]Mailing
lists[2] …

browse> q
$
```

…and you understand every byte: from typing `1` at the prompt, through
`url.resolve`, `dns.resolve`, the `connect()` to the test peer or
info.cern.ch, the GET we put on the wire, the chunk-decode and
entity-decode passes, all the way back out through the renderer's ANSI
escapes to the terminal — every layer written by you over five phases.
