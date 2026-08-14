//! The terminal: raw mode, the alternate screen, key decoding, and OSC 52.
//!
//! Written directly against the escape sequences rather than through a TUI
//! library, for one reason that outweighs the rest: an Archive is kept
//! byte-faithful *with its ANSI intact*, and the log pane's job is to put
//! those bytes on screen. A cell-grid library would require every SGR
//! sequence a Worker emitted to be parsed into typed styles and re-encoded on
//! the way out — work that can only lose fidelity, done per frame, to arrive
//! back where the bytes started. Writing them through costs nothing and
//! cannot be wrong.
//!
//! See `docs/adr/0005-render-log-bytes-through.md`.

const std = @import("std");
const os = @import("os.zig");
const linux = os.linux;

// x86_64 ioctl numbers. Named here because `std.os.linux` does not export
// them, and they are ABI rather than configuration.
const TCGETS = 0x5401;
const TCSETS = 0x5402;
const TIOCGWINSZ = 0x5413;

const Winsize = extern struct {
    row: u16,
    col: u16,
    xpixel: u16,
    ypixel: u16,
};

pub const Size = struct {
    rows: u16 = 24,
    cols: u16 = 80,
};

pub const esc = struct {
    pub const alt_screen_on = "\x1b[?1049h";
    pub const alt_screen_off = "\x1b[?1049l";
    pub const cursor_hide = "\x1b[?25l";
    pub const cursor_show = "\x1b[?25h";
    pub const clear = "\x1b[2J";
    pub const clear_line = "\x1b[K";
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const reverse = "\x1b[7m";
    pub const home = "\x1b[H";
};

pub const Terminal = struct {
    fd: os.Fd,
    original: linux.termios,
    raw: bool = false,

    pub fn init(fd: os.Fd) !Terminal {
        var t: Terminal = .{ .fd = fd, .original = undefined };
        if (linux.errno(linux.ioctl(fd, TCGETS, @intFromPtr(&t.original))) != .SUCCESS) {
            return error.NotATerminal;
        }
        return t;
    }

    /// Raw mode, minus the parts a log viewer wants to keep. Output
    /// processing (`OPOST`) stays *on*: the renderer writes `\n` and expects
    /// the terminal to turn it into a carriage return and line feed.
    pub fn enterRaw(self: *Terminal) void {
        var t = self.original;
        t.lflag.ECHO = false;
        t.lflag.ICANON = false;
        t.lflag.ISIG = false;
        t.lflag.IEXTEN = false;
        t.iflag.IXON = false;
        t.iflag.ICRNL = false;
        t.iflag.BRKINT = false;
        t.iflag.INPCK = false;
        t.iflag.ISTRIP = false;
        // A read may return with nothing; the poll loop decides when to read.
        t.cc[@intFromEnum(linux.V.MIN)] = 0;
        t.cc[@intFromEnum(linux.V.TIME)] = 0;
        _ = linux.ioctl(self.fd, TCSETS, @intFromPtr(&t));
        self.raw = true;
    }

    pub fn restore(self: *Terminal) void {
        if (!self.raw) return;
        _ = linux.ioctl(self.fd, TCSETS, @intFromPtr(&self.original));
        self.raw = false;
    }

    pub fn size(self: Terminal) Size {
        var ws: Winsize = undefined;
        if (linux.errno(linux.ioctl(self.fd, TIOCGWINSZ, @intFromPtr(&ws))) != .SUCCESS) {
            return .{};
        }
        if (ws.row == 0 or ws.col == 0) return .{};
        return .{ .rows = ws.row, .cols = ws.col };
    }
};

// ------------------------------------------------------------- input

pub const Key = union(enum) {
    char: u21,
    up,
    down,
    left,
    right,
    page_up,
    page_down,
    home,
    end,
    escape,
    enter,
    backspace,
    /// Something arrived that this does not decode. Ignored by the caller,
    /// but distinct from "nothing arrived".
    unknown,
};

/// Decodes one key from the front of `buf`, reporting how many bytes it used.
///
/// Returns null when `buf` holds the beginning of a sequence but not all of
/// it — a bare ESC at the end of a read is genuinely ambiguous, and guessing
/// is how a terminal UI ends up treating a paste as a hundred keystrokes.
pub fn decodeKey(buf: []const u8) ?struct { key: Key, len: usize } {
    if (buf.len == 0) return null;
    const b = buf[0];

    if (b == 0x1b) {
        if (buf.len == 1) return .{ .key = .escape, .len = 1 };
        if (buf[1] != '[' and buf[1] != 'O') return .{ .key = .escape, .len = 1 };
        if (buf.len == 2) return null; // incomplete CSI

        // CSI: parameters, then a final byte in 0x40..0x7e.
        var i: usize = 2;
        while (i < buf.len and buf[i] >= 0x30 and buf[i] <= 0x3f) i += 1;
        if (i >= buf.len) return null;
        const final = buf[i];
        const params = buf[2..i];
        const len = i + 1;

        const key: Key = switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            '~' => blk: {
                const n = std.fmt.parseInt(u8, params, 10) catch break :blk Key.unknown;
                break :blk switch (n) {
                    1, 7 => .home,
                    4, 8 => .end,
                    5 => .page_up,
                    6 => .page_down,
                    else => .unknown,
                };
            },
            else => .unknown,
        };
        return .{ .key = key, .len = len };
    }

    if (b == '\r' or b == '\n') return .{ .key = .enter, .len = 1 };
    if (b == 0x7f or b == 0x08) return .{ .key = .backspace, .len = 1 };

    // UTF-8, so a multi-byte character is one key rather than several.
    const seq_len = std.unicode.utf8ByteSequenceLength(b) catch
        return .{ .key = .{ .char = b }, .len = 1 };
    if (buf.len < seq_len) return null;
    const cp = std.unicode.utf8Decode(buf[0..seq_len]) catch
        return .{ .key = .{ .char = b }, .len = 1 };
    return .{ .key = .{ .char = cp }, .len = seq_len };
}

// ------------------------------------------------------------- output

/// How many columns `bytes` occupies, and how many bytes fit in `limit`
/// columns — computed together because the renderer always wants both.
///
/// ANSI escapes are counted as zero width and copied through, which is what
/// lets a coloured log line be truncated at the right *visible* column
/// instead of somewhere inside a colour code.
pub const Fit = struct {
    bytes: usize,
    cols: usize,
    /// True when the text was cut short, so the caller knows to append a
    /// reset — a truncated line can end mid-colour.
    truncated: bool,
};

pub fn fitToWidth(bytes: []const u8, limit: usize) Fit {
    var i: usize = 0;
    var cols: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];

        if (b == 0x1b) {
            i += escapeLen(bytes[i..]);
            continue;
        }
        if (b < 0x20) {
            // Control bytes other than escapes are not printed at all.
            i += 1;
            continue;
        }

        const seq = std.unicode.utf8ByteSequenceLength(b) catch 1;
        if (i + seq > bytes.len) break;
        const cp = std.unicode.utf8Decode(bytes[i..][0..seq]) catch b;
        const w = charWidth(cp);
        if (cols + w > limit) return .{ .bytes = i, .cols = cols, .truncated = true };
        cols += w;
        i += seq;
    }
    return .{ .bytes = i, .cols = cols, .truncated = false };
}

/// Length of the escape sequence starting at `bytes[0]`, which is assumed to
/// be ESC. Handles CSI and the string sequences (OSC, DCS, …) that a Worker
/// might legitimately emit.
fn escapeLen(bytes: []const u8) usize {
    if (bytes.len < 2) return bytes.len;
    switch (bytes[1]) {
        '[' => {
            var i: usize = 2;
            while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x3f) i += 1;
            return @min(i + 1, bytes.len);
        },
        ']', 'P', 'X', '^', '_' => {
            // Terminated by BEL or ST (ESC \).
            var i: usize = 2;
            while (i < bytes.len) : (i += 1) {
                if (bytes[i] == 0x07) return i + 1;
                if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '\\') return i + 2;
            }
            return bytes.len;
        },
        else => return 2,
    }
}

/// Display width, enough for what appears in logs. Not a full Unicode width
/// table: the wide ranges below cover CJK and emoji, which is where getting it
/// wrong is visible, and everything else is one column.
fn charWidth(cp: u21) usize {
    if (cp < 0x300) return 1;
    // Combining marks attach to the previous character.
    if (cp >= 0x300 and cp <= 0x36f) return 0;
    if (cp >= 0x200b and cp <= 0x200f) return 0; // zero-width spaces/marks
    if (cp == 0xfeff) return 0;
    if ((cp >= 0x1100 and cp <= 0x115f) or
        (cp >= 0x2e80 and cp <= 0xa4cf) or
        (cp >= 0xac00 and cp <= 0xd7a3) or
        (cp >= 0xf900 and cp <= 0xfaff) or
        (cp >= 0xfe30 and cp <= 0xfe6f) or
        (cp >= 0xff00 and cp <= 0xff60) or
        (cp >= 0xffe0 and cp <= 0xffe6) or
        (cp >= 0x1f300 and cp <= 0x1f64f) or
        (cp >= 0x1f900 and cp <= 0x1f9ff) or
        (cp >= 0x20000 and cp <= 0x3fffd)) return 2;
    return 1;
}

/// The largest Excerpt worth attempting. Terminals cap how much OSC 52 they
/// will accept and silently drop anything longer, so devrun does the
/// truncating itself and says so, rather than letting the clipboard end up
/// mysteriously empty.
pub const max_clipboard_bytes = 96 << 10;

/// Writes an OSC 52 clipboard sequence. This is what makes "copy this log"
/// work over SSH and inside tmux: the bytes go to the terminal emulator, which
/// puts them on the clipboard of the machine the human is sitting at.
pub fn writeOsc52(w: *std.Io.Writer, payload: []const u8) !void {
    try w.writeAll("\x1b]52;c;");
    var it = base64Chunks(payload);
    while (it.next()) |out| try w.writeAll(out);
    try w.writeAll("\x07");
}

/// The same sequence, written straight to a descriptor.
///
/// Not `writeOsc52` over a fixed buffer: base64 is 4 bytes out per 3 in, so a
/// buffer big enough for the largest Excerpt would be a sizeable allocation
/// held for the whole Session to serve a keystroke. Streaming it means the
/// only buffer is the encoder's, and a large Excerpt cannot quietly overflow
/// its way into copying nothing.
pub fn writeOsc52Fd(fd: os.Fd, payload: []const u8) void {
    os.writeAll(fd, "\x1b]52;c;") catch return;
    var it = base64Chunks(payload);
    while (it.next()) |out| os.writeAll(fd, out) catch return;
    os.writeAll(fd, "\x07") catch return;
}

/// Encodes in whole 3-byte groups, so base64 padding can only ever appear at
/// the very end. A chunk boundary mid-group would pad in the middle and make
/// the stream undecodable.
fn base64Chunks(payload: []const u8) Base64Iter {
    return .{ .payload = payload };
}

const Base64Iter = struct {
    payload: []const u8,
    i: usize = 0,
    buf: [4096]u8 = undefined,

    fn next(self: *Base64Iter) ?[]const u8 {
        if (self.i >= self.payload.len) return null;
        const group = 3 * (self.buf.len / 4);
        const take = @min(group, self.payload.len - self.i);
        const out = std.base64.standard.Encoder.encode(&self.buf, self.payload[self.i..][0..take]);
        self.i += take;
        return out;
    }
};

// ------------------------------------------------------------- tests

const testing = std.testing;

test "decodeKey reads arrows, page keys, and plain characters" {
    try testing.expectEqual(Key.up, decodeKey("\x1b[A").?.key);
    try testing.expectEqual(Key.down, decodeKey("\x1b[B").?.key);
    try testing.expectEqual(Key.right, decodeKey("\x1b[C").?.key);
    try testing.expectEqual(Key.left, decodeKey("\x1b[D").?.key);
    try testing.expectEqual(Key.page_up, decodeKey("\x1b[5~").?.key);
    try testing.expectEqual(Key.page_down, decodeKey("\x1b[6~").?.key);
    try testing.expectEqual(@as(usize, 4), decodeKey("\x1b[6~").?.len);

    const q = decodeKey("q").?;
    try testing.expectEqual(@as(u21, 'q'), q.key.char);
    try testing.expectEqual(@as(usize, 1), q.len);
}

test "a half-arrived escape sequence decodes to nothing, not to a wrong key" {
    // These are what a read that lands mid-sequence looks like. Guessing here
    // would turn one arrow key into a stray ESC plus a '[' character.
    try testing.expect(decodeKey("\x1b[") == null);
    try testing.expect(decodeKey("\x1b[5") == null);
    // A lone ESC with nothing following it is a real Escape keypress.
    try testing.expectEqual(Key.escape, decodeKey("\x1b").?.key);
}

test "decodeKey treats a multi-byte character as one key" {
    const k = decodeKey("é").?;
    try testing.expectEqual(@as(u21, 0xe9), k.key.char);
    try testing.expectEqual(@as(usize, 2), k.len);
    // Truncated UTF-8 waits for the rest rather than emitting a broken cp.
    try testing.expect(decodeKey("\xc3") == null);
}

test "fitToWidth measures visible columns, not bytes" {
    // Escapes are zero-width and travel with the text.
    const coloured = "\x1b[31mERROR\x1b[0m";
    const fit = fitToWidth(coloured, 80);
    try testing.expectEqual(@as(usize, 5), fit.cols);
    try testing.expectEqual(coloured.len, fit.bytes);
    try testing.expect(!fit.truncated);

    // Truncation happens at a visible column, and never inside a colour code.
    const cut = fitToWidth("\x1b[31mERROR: it broke\x1b[0m", 8);
    try testing.expectEqual(@as(usize, 8), cut.cols);
    try testing.expect(cut.truncated);
    // Eight visible columns is "ERROR: i", and the colour code rides along
    // for free because it costs no width.
    try testing.expectEqualStrings("\x1b[31mERROR: i", "\x1b[31mERROR: it broke\x1b[0m"[0..cut.bytes]);
}

test "fitToWidth counts wide characters as two columns" {
    // Four CJK characters fill eight columns, so a limit of 8 takes all four
    // and a limit of 7 takes three.
    try testing.expectEqual(@as(usize, 8), fitToWidth("日本語版", 8).cols);
    const narrow = fitToWidth("日本語版", 7);
    try testing.expectEqual(@as(usize, 6), narrow.cols);
    try testing.expectEqual(@as(usize, 9), narrow.bytes); // three 3-byte chars
    try testing.expect(narrow.truncated);
}

test "escapeLen spans OSC strings so their payload is not counted" {
    // An OSC 8 hyperlink in a log line must not consume the pane's width.
    const link = "\x1b]8;;https://example.com\x07text\x1b]8;;\x07";
    const fit = fitToWidth(link, 80);
    try testing.expectEqual(@as(usize, 4), fit.cols);
    try testing.expectEqual(link.len, fit.bytes);
}

test "OSC 52 round-trips through base64 without padding in the middle" {
    var buf: [32768]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // Long enough to cross the internal chunk boundary.
    const payload = "log line that should reach the clipboard\n" ** 200;
    try writeOsc52(&w, payload);

    const out = w.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "\x1b]52;c;"));
    try testing.expect(std.mem.endsWith(u8, out, "\x07"));

    const b64 = out["\x1b]52;c;".len .. out.len - 1];
    // Padding may only appear at the very end, or the stream is not decodable.
    try testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOfScalar(u8, b64[0 .. b64.len - 2], '='),
    );

    const dec = std.base64.standard.Decoder;
    const n = try dec.calcSizeForSlice(b64);
    const round = try testing.allocator.alloc(u8, n);
    defer testing.allocator.free(round);
    try dec.decode(round, b64);
    try testing.expectEqualStrings(payload, round);
}
