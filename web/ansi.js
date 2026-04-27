// web/ansi.js
//
// Minimal ANSI interpreter: enough escape sequences for snake's
// full-redraw rendering and the shell's streaming output. State machine
// walks bytes; CSI sequences recognized:
//   ESC [ 2 J     → clear screen
//   ESC [ H       → cursor (0,0)
//   ESC [ r;c H   → cursor (r-1, c-1)
//   ESC [ ? 25 l  → hide cursor (cursor_visible = false)
//   ESC [ ? 25 h  → show cursor (cursor_visible = true)
// C0 controls handled in GROUND:
//   0x08 (BS)  → cursor left one column (clamped at 0)
//   0x0a (LF)  → line feed (scrolls when at last row)
//   0x0d (CR)  → cursor to column 0
// Other bytes < 0x20 are silently dropped.
// Unrecognized escape sequences are consumed and ignored.
//
// UTF-8 multibyte sequences (lead byte 0xC0–0xF7) are reassembled
// into a single screen cell so box-drawing chars render correctly.

export class Ansi {
  constructor(width, height) {
    this.W = width;
    this.H = height;
    this.screen = new Array(height);
    this._reset();
    this.row = 0;
    this.col = 0;
    this.state = "GROUND";
    this.csiBuf = "";
    this.utf8Pending = null;
    // Tracks ESC[?25h (true, default) / ESC[?25l (false). Read by the
    // demo's render() to show or hide the on-screen cursor — the editor
    // toggles this on entry/exit to raw mode.
    this.cursor_visible = true;
  }

  _reset() {
    for (let r = 0; r < this.H; r++) {
      this.screen[r] = new Array(this.W).fill(" ");
    }
  }

  // Move cursor down one row. If we're already at the bottom row, scroll
  // the screen up by one line: drop row 0, push a blank row at the bottom.
  // Called from the \n branch in _byte. (Future ESC D / IND or NEL would
  // be natural additional callers; cursor-positioning CSI H clamps inline
  // and intentionally doesn't scroll.)
  _lineFeed() {
    if (this.row >= this.H - 1) {
      this.screen.shift();
      this.screen.push(new Array(this.W).fill(" "));
      this.row = this.H - 1;
    } else {
      this.row += 1;
    }
  }

  feed(bytes) {
    for (const b of bytes) this._byte(b);
  }

  _byte(b) {
    if (this.state === "GROUND") {
      if (b === 0x1b) { this.state = "ESC"; return; }
      if (b === 0x0a) { this._lineFeed(); return; }
      if (b === 0x0d) { this.col = 0; return; }
      if (b === 0x08) { this.col = Math.max(0, this.col - 1); return; }
      if (b < 0x20)   return; // other control: ignore
      if (b >= 0xC0 && b <= 0xF7) { this._utf8Start(b); return; }
      if (b >= 0x80)   { this._utf8Continue(b); return; }
      this._writeCell(String.fromCharCode(b));
      return;
    }
    if (this.state === "ESC") {
      if (b === 0x5b) { this.state = "CSI"; this.csiBuf = ""; return; }
      this.state = "GROUND"; // unknown ESC sequence, abort
      return;
    }
    if (this.state === "CSI") {
      // Final byte: any of 0x40–0x7E.
      if (b >= 0x40 && b <= 0x7e) {
        this._csi(String.fromCharCode(b), this.csiBuf);
        this.state = "GROUND";
        this.csiBuf = "";
        return;
      }
      this.csiBuf += String.fromCharCode(b);
      return;
    }
  }

  _utf8Start(lead) {
    let need;
    if      ((lead & 0xE0) === 0xC0) need = 1;
    else if ((lead & 0xF0) === 0xE0) need = 2;
    else if ((lead & 0xF8) === 0xF0) need = 3;
    else { return; } // malformed; ignore
    this.utf8Pending = { bytes: [lead], need };
  }

  _utf8Continue(b) {
    if (!this.utf8Pending) return;
    this.utf8Pending.bytes.push(b);
    this.utf8Pending.need -= 1;
    if (this.utf8Pending.need === 0) {
      const arr = new Uint8Array(this.utf8Pending.bytes);
      const ch = new TextDecoder().decode(arr);
      this.utf8Pending = null;
      this._writeCell(ch);
    }
  }

  _writeCell(ch) {
    if (this.row >= this.H) return;
    if (this.col >= this.W) {
      this.col = 0;
      this.row += 1;
      if (this.row >= this.H) return;
    }
    this.screen[this.row][this.col] = ch;
    this.col += 1;
  }

  _csi(final, params) {
    if (final === "J" && params === "2") { this._reset(); return; }
    if (final === "H") {
      if (params === "" || params === "1;1") {
        this.row = 0; this.col = 0; return;
      }
      const m = params.match(/^(\d+);(\d+)$/);
      if (m) {
        this.row = Math.max(0, Math.min(this.H - 1, parseInt(m[1], 10) - 1));
        this.col = Math.max(0, Math.min(this.W - 1, parseInt(m[2], 10) - 1));
      }
      return;
    }
    if (final === "l" && params === "?25") { this.cursor_visible = false; return; }
    if (final === "h" && params === "?25") { this.cursor_visible = true;  return; }
    // anything else: ignore.
  }

  text() {
    return this.screen.map((row) => row.join("")).join("\n");
  }
}
