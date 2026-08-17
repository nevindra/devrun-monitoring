//! The Archive — a Worker's log file — and the Window, the bounded slice of it
//! held in memory.
//!
//! The file is the record and the Window is only a cache, which is what makes
//! `docs/adr/0001-logs-through-the-filesystem.md` work. Bytes go to disk the
//! moment they are read from the Worker's pipe, byte-faithful with their ANSI
//! intact, so `tail -f` and `grep` see exactly what the TUI sees.
//!
//! Because the Archive is truncated once per Session, an absolute byte offset
//! *is* a file offset. That single equality removes every index this would
//! otherwise need: `readAt` serves from the Window when the offset is still
//! resident and `pread`s the page cache when it is not, and no caller has to
//! know which happened.
//!
//! There is deliberately no line index. Finding the previous line start is a
//! backwards scan for `\n`, which costs one line's worth of bytes — so
//! scrolling is O(line length) and the memory cost of navigation is zero. An
//! index over a Window would be a sizeable fraction of the Window itself, to
//! save work that is already too cheap to measure.

const std = @import("std");
const os = @import("os.zig");

const Allocator = std.mem.Allocator;

/// The in-memory cache. Capacity is a power of two so wrapping is a mask
/// rather than a division, and the buffer is allocated once for the Session —
/// a Window never grows, which is what keeps RSS a number chosen up front
/// rather than a consequence of how noisy a Worker turned out to be.
pub const Window = struct {
    buf: []u8,
    mask: usize,
    /// Absolute offset one past the newest byte; also the total ever appended.
    end: u64 = 0,

    pub fn init(gpa: Allocator, capacity: usize) !Window {
        // No sensible-minimum floor here: what a Session should spend is
        // `windowBytesPerWorker`'s decision, and baking a floor in as well
        // would mean this type could not be exercised at a size a test can
        // reason about.
        const cap = std.math.ceilPowerOfTwo(usize, @max(capacity, 2)) catch return error.OutOfMemory;
        const buf = try gpa.alloc(u8, cap);
        return .{ .buf = buf, .mask = cap - 1 };
    }

    pub fn deinit(self: *Window, gpa: Allocator) void {
        gpa.free(self.buf);
        self.* = undefined;
    }

    /// Absolute offset of the oldest byte still resident.
    pub fn start(self: Window) u64 {
        return self.end -| self.buf.len;
    }

    /// Appends, keeping only the newest `buf.len` bytes. A chunk larger than
    /// the whole Window is not an error — the tail of it is what survives,
    /// which is the same answer a stream of smaller chunks would have given.
    pub fn append(self: *Window, data: []const u8) void {
        const bytes = if (data.len > self.buf.len) data[data.len - self.buf.len ..] else data;
        // Where `bytes` lands is fixed by its own absolute offset, not by the
        // chunk's. When a chunk overflows the Window we drop its head, and the
        // surviving tail starts that many bytes further along — writing it at
        // the chunk's offset instead would rotate the Window's contents.
        const dropped = data.len - bytes.len;
        const head = @as(usize, @intCast((self.end + dropped) & self.mask));
        const first = @min(bytes.len, self.buf.len - head);
        @memcpy(self.buf[head..][0..first], bytes[0..first]);
        if (first < bytes.len) {
            @memcpy(self.buf[0 .. bytes.len - first], bytes[first..]);
        }
        self.end += data.len;
    }

    /// Copies out the resident bytes at `off`, returning how many were
    /// available. Zero means the offset has fallen out of the Window and the
    /// caller must go to the Archive.
    pub fn readAt(self: Window, off: u64, dst: []u8) usize {
        if (off < self.start() or off >= self.end) return 0;
        const n = @min(dst.len, @as(usize, @intCast(self.end - off)));
        const head = @as(usize, @intCast(off & self.mask));
        const first = @min(n, self.buf.len - head);
        @memcpy(dst[0..first], self.buf[head..][0..first]);
        if (first < n) {
            @memcpy(dst[first..n], self.buf[0 .. n - first]);
        }
        return n;
    }
};

/// The Index — a Worker's `.idx` sidecar, which is the only thing in devrun
/// that knows *when* a byte was written.
///
/// An Archive is byte-faithful, which means it cannot carry a timestamp: the
/// moment you interleave one, `tail -f` and `grep` stop seeing what the Worker
/// actually said. So time is recorded beside the bytes instead of inside them,
/// as fixed-width records of `(wall_ms, offset)` — one per chunk read off the
/// Worker's pipe, not one per line.
///
/// Per chunk is what makes this nearly free. A Worker writing 80 KB/s in 64 KB
/// reads costs 16 bytes a second of Index, against 80 KB of Archive. The price
/// is resolution: every line in one chunk shares that chunk's stamp. For a dev
/// server, a chunk is one burst of output, so the stamp is the burst's — which
/// is the question anyone actually asks ("what did everything say when I hit
/// that endpoint"), not "which of these two adjacent lines was first".
///
/// Fixed-width and sorted is the whole design: both lookups a reader needs
/// (offset-for-a-time, time-for-an-offset) are a binary search of `pread`s, so
/// answering "the last 2 minutes" over a 400 MB Archive reads a few hundred
/// bytes and never scans.
pub const Index = struct {
    pub const magic = "DRIX";
    pub const format_version: u32 = 1;
    pub const header_len: u64 = 16;
    pub const record_len: u64 = 16;

    fd: os.Fd = -1,
    /// The last stamp written, so a chunk landing in the same millisecond as
    /// its predecessor adds nothing. Under a firehose this is most of them.
    last_ms: u64 = 0,
    wrote_any: bool = false,

    pub const Record = struct { ms: u64, offset: u64 };

    /// Truncating, for the same reason the Archive truncates: an Index
    /// describes one Session's bytes, and last run's offsets describe nothing
    /// in this one.
    pub fn create(path: [*:0]const u8) !Index {
        const fd = try os.open(path, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        }, 0o644);
        errdefer os.close(fd);

        var head: [header_len]u8 = @splat(0);
        @memcpy(head[0..4], magic);
        std.mem.writeInt(u32, head[4..8], format_version, .little);
        try os.writeAll(fd, &head);
        return .{ .fd = fd };
    }

    pub fn deinit(self: *Index) void {
        if (self.fd >= 0) os.close(self.fd);
        self.fd = -1;
    }

    /// Records that the chunk at `offset` was read at `ms`. Failures are
    /// swallowed: an Index is an accelerator for a query, and losing it is not
    /// a reason to stop keeping the log it describes.
    pub fn stamp(self: *Index, ms: u64, offset: u64) void {
        if (self.fd < 0) return;
        if (self.wrote_any and ms == self.last_ms) return;
        var rec: [record_len]u8 = undefined;
        std.mem.writeInt(u64, rec[0..8], ms, .little);
        std.mem.writeInt(u64, rec[8..16], offset, .little);
        os.writeAll(self.fd, &rec) catch return;
        self.last_ms = ms;
        self.wrote_any = true;
    }
};

/// Read-only view of an Index written by a Session, possibly one that has
/// already exited. Everything is a `pread`, so nothing is held in memory and a
/// live Session appending to the file is not disturbed.
pub const IndexReader = struct {
    fd: os.Fd = -1,
    count: u64 = 0,

    /// A missing, foreign, or truncated Index is an empty one rather than an
    /// error. The caller degrades to "no timestamps available" and still shows
    /// the log, which beats refusing to print anything over a sidecar.
    pub fn open(path: [*:0]const u8) IndexReader {
        const fd = os.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return .{};
        const size = os.fileSize(fd) orelse {
            os.close(fd);
            return .{};
        };
        if (size < Index.header_len) {
            os.close(fd);
            return .{};
        }
        var head: [Index.header_len]u8 = undefined;
        const n = os.pread(fd, &head, 0) catch 0;
        if (n < Index.header_len or
            !std.mem.eql(u8, head[0..4], Index.magic) or
            std.mem.readInt(u32, head[4..8], .little) != Index.format_version)
        {
            os.close(fd);
            return .{};
        }
        return .{ .fd = fd, .count = (size - Index.header_len) / Index.record_len };
    }

    pub fn close(self: *IndexReader) void {
        if (self.fd >= 0) os.close(self.fd);
        self.fd = -1;
        self.count = 0;
    }

    pub fn at(self: IndexReader, i: u64) ?Index.Record {
        if (i >= self.count) return null;
        var rec: [Index.record_len]u8 = undefined;
        const n = os.pread(self.fd, &rec, Index.header_len + i * Index.record_len) catch return null;
        if (n < Index.record_len) return null;
        return .{
            .ms = std.mem.readInt(u64, rec[0..8], .little),
            .offset = std.mem.readInt(u64, rec[8..16], .little),
        };
    }

    /// Byte offset to start reading from to see everything written at or after
    /// `ms`. Null means nothing was written that recently.
    ///
    /// Rounds *outwards*: the record found is the last one at or before `ms`,
    /// so the first chunk returned may contain a few lines older than asked
    /// for. Showing a little too much is recoverable; silently clipping the
    /// line that explains the failure is not.
    ///
    /// The exception is the final chunk, and it matters more than it looks. A
    /// Worker that said one thing at startup and has been quiet since has an
    /// Index of one record, and rounding outwards there would replay its whole
    /// startup for every `--since 30s` forever after. The last record has no
    /// successor to straddle the cutoff *with*, so if it is older than the
    /// cutoff, everything is.
    pub fn offsetAtOrAfter(self: IndexReader, ms: u64) ?u64 {
        if (self.count == 0) return null;
        const first = self.at(0) orelse return null;
        if (ms <= first.ms) return first.offset;

        // Last record with `rec.ms <= ms`. Its chunk is the one straddling the
        // cutoff, so it is where reading begins.
        var lo: u64 = 0;
        var hi: u64 = self.count; // invariant: every record < lo has ms <= ms
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = self.at(mid) orelse break;
            if (rec.ms <= ms) lo = mid else hi = mid;
        }
        const rec = self.at(lo) orelse return null;
        if (lo == self.count - 1 and rec.ms < ms) return null;
        return rec.offset;
    }

    /// When the bytes at `offset` were written. Null when the Index has
    /// nothing covering it, which is every offset if there is no Index at all.
    pub fn msAt(self: IndexReader, offset: u64) ?u64 {
        if (self.count == 0) return null;
        const first = self.at(0) orelse return null;
        if (offset <= first.offset) return first.ms;

        var lo: u64 = 0;
        var hi: u64 = self.count;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            const rec = self.at(mid) orelse break;
            if (rec.offset <= offset) lo = mid else hi = mid;
        }
        const rec = self.at(lo) orelse return null;
        return rec.ms;
    }
};

/// A Worker's log file plus its Window. Owns the descriptor for the Session.
pub const Archive = struct {
    fd: os.Fd,
    window: Window,
    /// Time beside the bytes rather than in them. Absent when the caller did
    /// not ask for one, which is every test that only cares about bytes.
    index: Index = .{},
    /// Set when a write to disk failed. The Window keeps working, so the TUI
    /// still shows output — losing the record is worth reporting, not worth
    /// taking the Session down for.
    write_failed: bool = false,

    /// Opens `path`, truncating it: an Archive covers one Session, so the
    /// previous run's bytes are not silently prepended to this one's.
    ///
    /// `index_path` gets the `.idx` sidecar. Null skips it, and a sidecar that
    /// cannot be created is skipped too rather than failing the Archive — the
    /// log is the record, the Index only makes it faster to query.
    pub fn create(
        gpa: Allocator,
        path: [*:0]const u8,
        index_path: ?[*:0]const u8,
        window_bytes: usize,
    ) !Archive {
        // Read-write, not write-only: `readAt` preads this same descriptor to
        // serve scrollback older than the Window, and a write-only fd would
        // make that fall back to returning nothing at all.
        const fd = try os.open(path, .{
            .ACCMODE = .RDWR,
            .CREAT = true,
            .TRUNC = true,
            .CLOEXEC = true,
        }, 0o644);
        errdefer os.close(fd);

        const index: Index = if (index_path) |p| Index.create(p) catch .{} else .{};
        return .{ .fd = fd, .window = try Window.init(gpa, window_bytes), .index = index };
    }

    pub fn deinit(self: *Archive, gpa: Allocator) void {
        if (self.fd >= 0) os.close(self.fd);
        self.index.deinit();
        self.window.deinit(gpa);
        self.fd = -1;
    }

    /// Total bytes this Worker has produced this Session.
    pub fn len(self: Archive) u64 {
        return self.window.end;
    }

    pub fn append(self: *Archive, data: []const u8) void {
        // Stamped before the bytes land, so the recorded offset is where this
        // chunk *starts*. An Index whose offsets point past their own chunk
        // would make every `--since` query miss its first line.
        self.index.stamp(os.realtimeMs(), self.window.end);
        os.writeAll(self.fd, data) catch {
            self.write_failed = true;
        };
        self.window.append(data);
    }

    /// Reads up to `dst.len` bytes at absolute offset `off`. Tries the Window
    /// first; anything older comes from the file, which for bytes written this
    /// Session is a page-cache copy rather than disk I/O.
    pub fn readAt(self: Archive, off: u64, dst: []u8) usize {
        if (off >= self.window.end) return 0;
        const cached = self.window.readAt(off, dst);
        if (cached > 0) return cached;
        const want = @min(dst.len, @as(usize, @intCast(self.window.end - off)));
        // A reopened read descriptor is not needed: pread ignores the write
        // offset, so the same fd serves both directions.
        return os.pread(self.fd, dst[0..want], off) catch 0;
    }

    /// Absolute offset of the start of the line containing `off - 1` — that
    /// is, the start of the line *before* `off`. Returns null at the top of
    /// the Archive.
    ///
    /// Scans backwards a block at a time. The block is stack-allocated, so
    /// walking a screen's worth of scrollback allocates nothing at all.
    pub fn lineStartBefore(self: Archive, off: u64) ?u64 {
        if (off == 0) return null;
        var buf: [512]u8 = undefined;
        // Skip the newline that terminates the previous line, so that calling
        // this repeatedly walks one line per call instead of sticking.
        var end = off - 1;
        if (end == 0) return 0;

        while (end > 0) {
            const block = @min(@as(u64, buf.len), end);
            const from = end - block;
            const n = self.readAt(from, buf[0..@intCast(block)]);
            if (n == 0) return 0;
            if (std.mem.lastIndexOfScalar(u8, buf[0..n], '\n')) |i| {
                return from + i + 1;
            }
            end = from;
        }
        return 0;
    }

    /// Absolute offset just past the newline that ends the line starting at
    /// `off`, or the end of the Archive when the line is still unterminated.
    pub fn lineEnd(self: Archive, off: u64) u64 {
        var buf: [512]u8 = undefined;
        var at = off;
        while (at < self.window.end) {
            const n = self.readAt(at, &buf);
            if (n == 0) break;
            if (std.mem.indexOfScalar(u8, buf[0..n], '\n')) |i| {
                return at + i + 1;
            }
            at += n;
        }
        return self.window.end;
    }

    /// A line and where the next one starts. Returned together because every
    /// caller wants both: a renderer walking down a pane and a printer walking
    /// forward through new output each need the text *and* the offset to
    /// resume at, and asking for them separately means scanning for the same
    /// newline twice.
    pub const Line = struct {
        text: []const u8,
        /// Absolute offset just past this line's newline.
        end: u64,
    };

    /// Copies the line starting at `off` into `dst`, without its newline.
    /// Truncated to `dst.len` — a Worker that emits a megabyte without a
    /// newline must not be able to make the renderer allocate.
    pub fn lineAt(self: Archive, off: u64, dst: []u8) Line {
        const end = self.lineEnd(off);
        const want = @min(dst.len, @as(usize, @intCast(end - off)));
        const n = self.readAt(off, dst[0..want]);
        var line = dst[0..n];
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        return .{ .text = line, .end = end };
    }

    /// `lineAt` for callers that do not need to walk on from here.
    pub fn lineInto(self: Archive, off: u64, dst: []u8) []const u8 {
        return self.lineAt(off, dst).text;
    }

    /// Offset of the start of the last complete line, used to park the view at
    /// the bottom. When the Worker's final byte is not a newline, that partial
    /// line is the one shown.
    pub fn lastLineStart(self: Archive) u64 {
        const end = self.window.end;
        if (end == 0) return 0;
        // If the Archive ends in a newline the cursor belongs on the line
        // before it, not on the empty line after.
        return self.lineStartBefore(end) orelse 0;
    }

    /// Walks `count` line starts back from `from`, returning where the view
    /// should begin. Stops at the top rather than reporting an error, because
    /// scrolling past the beginning is a normal keypress, not a failure.
    pub fn scrollBack(self: Archive, from: u64, count: usize) u64 {
        var at = from;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            at = self.lineStartBefore(at) orelse return 0;
            if (at == 0) return 0;
        }
        return at;
    }

    /// The mirror of `scrollBack`. Never moves past the last line.
    pub fn scrollForward(self: Archive, from: u64, count: usize) u64 {
        const last = self.lastLineStart();
        var at = from;
        var i: usize = 0;
        while (i < count and at < last) : (i += 1) {
            at = self.lineEnd(at);
        }
        return @min(at, last);
    }
};

/// Splits a memory budget across Workers. Rounded down to a power of two per
/// Worker so the ring can mask, and floored so that a config with thirty
/// Workers still keeps a useful amount of each one's output.
pub fn windowBytesPerWorker(total_budget: usize, workers: usize) usize {
    const min_per_worker = 64 << 10;
    if (workers == 0) return min_per_worker;
    const share = total_budget / workers;
    return @max(min_per_worker, std.math.floorPowerOfTwo(usize, @max(share, 1)));
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "Window keeps the newest bytes and reports what it dropped" {
    var w = try Window.init(testing.allocator, 8);
    defer w.deinit(testing.allocator);

    w.append("abcdefgh");
    try testing.expectEqual(@as(u64, 0), w.start());

    var buf: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 8), w.readAt(0, &buf));
    try testing.expectEqualStrings("abcdefgh", buf[0..8]);

    // Wrapping: the oldest four bytes fall out and the offsets move with them.
    w.append("ijkl");
    try testing.expectEqual(@as(u64, 4), w.start());
    try testing.expectEqual(@as(u64, 12), w.end);
    try testing.expectEqual(@as(usize, 0), w.readAt(3, &buf)); // evicted
    try testing.expectEqual(@as(usize, 8), w.readAt(4, &buf));
    try testing.expectEqualStrings("efghijkl", buf[0..8]);

    // A chunk bigger than the Window keeps its tail, and the offset accounting
    // still reflects every byte that was ever appended.
    w.append("0123456789ab");
    try testing.expectEqual(@as(u64, 24), w.end);
    try testing.expectEqual(@as(usize, 8), w.readAt(16, &buf));
    try testing.expectEqualStrings("456789ab", buf[0..8]);
}

/// Builds an Archive in a temp file so the pread fallback is exercised for
/// real rather than mocked.
fn testArchive(window_bytes: usize) !struct { Archive, [:0]const u8 } {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/devrun-test-{d}.log", .{os.nowMs()});
    const path = try testing.allocator.dupeZ(u8, name);
    const a = try Archive.create(testing.allocator, path.ptr, null, window_bytes);
    return .{ a, path };
}

test "reading past the Window falls through to the Archive" {
    var a, const path = try testArchive(4096);
    defer {
        a.deinit(testing.allocator);
        os.unlink(path.ptr);
        testing.allocator.free(path);
    }

    // More than the 4 KiB Window, so the early bytes exist only on disk.
    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var line: [32]u8 = undefined;
        a.append(try std.fmt.bufPrint(&line, "line {d}\n", .{i}));
    }

    // The first line is long gone from memory; the Archive still has it.
    try testing.expect(a.window.start() > 0);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("line 0", a.lineInto(0, &buf));

    // And the newest line comes from the Window without touching the file.
    const last = a.lastLineStart();
    try testing.expect(last >= a.window.start());
    try testing.expectEqualStrings("line 1999", a.lineInto(last, &buf));
}

test "scrolling walks lines in both directions and stops at the ends" {
    var a, const path = try testArchive(4096);
    defer {
        a.deinit(testing.allocator);
        os.unlink(path.ptr);
        testing.allocator.free(path);
    }

    for ([_][]const u8{ "one\n", "two\n", "three\n", "four\n", "five\n" }) |s| a.append(s);

    var buf: [16]u8 = undefined;
    const bottom = a.lastLineStart();
    try testing.expectEqualStrings("five", a.lineInto(bottom, &buf));

    const up2 = a.scrollBack(bottom, 2);
    try testing.expectEqualStrings("three", a.lineInto(up2, &buf));

    // Past the top clamps to the first line rather than erroring.
    try testing.expectEqual(@as(u64, 0), a.scrollBack(bottom, 99));
    try testing.expectEqualStrings("one", a.lineInto(0, &buf));

    try testing.expectEqualStrings("four", a.lineInto(a.scrollForward(up2, 1), &buf));
    // Past the bottom clamps to the last line.
    try testing.expectEqual(bottom, a.scrollForward(0, 99));
}

test "bytes are kept byte-faithful, ANSI and all" {
    var a, const path = try testArchive(4096);
    defer {
        a.deinit(testing.allocator);
        os.unlink(path.ptr);
        testing.allocator.free(path);
    }

    const coloured = "\x1b[31mERROR\x1b[0m: it broke\n";
    a.append(coloured);

    // What the TUI reads back is what a pager reading the file would see:
    // the escapes survive, and only the line terminator is trimmed.
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "\x1b[31mERROR\x1b[0m: it broke",
        a.lineInto(0, &buf),
    );

    // A CRLF line is trimmed of both, so Windows-y output does not render a
    // stray carriage return into the middle of the pane.
    a.append("carriage\r\n");
    var buf2: [64]u8 = undefined;
    try testing.expectEqualStrings("carriage", a.lineInto(a.lastLineStart(), &buf2));
}

test "an Index answers both directions, and rounds outwards on time" {
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/devrun-idx-{d}.idx", .{os.nowMs()});
    const path = try testing.allocator.dupeZ(u8, name);
    defer {
        os.unlink(path.ptr);
        testing.allocator.free(path);
    }

    var idx = try Index.create(path.ptr);
    // Chunks at t=1000/1100/1200, each 50 bytes long.
    idx.stamp(1000, 0);
    idx.stamp(1100, 50);
    // Same millisecond as the last: skipped, because sub-millisecond ordering
    // is not a question this format is claiming to answer.
    idx.stamp(1100, 75);
    idx.stamp(1200, 100);
    idx.deinit();

    var r = IndexReader.open(path.ptr);
    defer r.close();
    try testing.expectEqual(@as(u64, 3), r.count);

    // Exactly on a boundary starts at that chunk.
    try testing.expectEqual(@as(?u64, 50), r.offsetAtOrAfter(1100));
    // Between two chunks rounds back to the one straddling the cutoff, so the
    // first lines returned may slightly predate the request. Deliberate.
    try testing.expectEqual(@as(?u64, 50), r.offsetAtOrAfter(1150));
    // Older than everything: the whole Archive qualifies.
    try testing.expectEqual(@as(?u64, 0), r.offsetAtOrAfter(1));
    // Exactly the last stamp still includes that chunk.
    try testing.expectEqual(@as(?u64, 100), r.offsetAtOrAfter(1200));
    // Past the last stamp is nothing. Rounding outwards here would hand back
    // the final chunk forever, so a Worker that went quiet an hour ago would
    // keep answering `--since 30s` with its last words.
    try testing.expect(r.offsetAtOrAfter(1201) == null);
    try testing.expect(r.offsetAtOrAfter(99_999) == null);

    // And the reverse lookup, which is what puts a clock on a printed line.
    try testing.expectEqual(@as(?u64, 1000), r.msAt(0));
    try testing.expectEqual(@as(?u64, 1000), r.msAt(49));
    try testing.expectEqual(@as(?u64, 1100), r.msAt(50));
    try testing.expectEqual(@as(?u64, 1100), r.msAt(99));
    try testing.expectEqual(@as(?u64, 1200), r.msAt(100));
    try testing.expectEqual(@as(?u64, 1200), r.msAt(1_000_000));
}

test "a missing or foreign Index reads as empty rather than failing" {
    var r = IndexReader.open("/tmp/devrun-idx-does-not-exist-at-all.idx");
    defer r.close();
    try testing.expectEqual(@as(u64, 0), r.count);
    try testing.expect(r.offsetAtOrAfter(0) == null);
    try testing.expect(r.msAt(0) == null);

    // A file that exists but is not ours: refused by magic, not misread. A
    // wrong offset here would silently print the wrong slice of a log.
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&name_buf, "/tmp/devrun-notidx-{d}", .{os.nowMs()});
    const path = try testing.allocator.dupeZ(u8, name);
    defer {
        os.unlink(path.ptr);
        testing.allocator.free(path);
    }
    const fd = try os.open(path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    try os.writeAll(fd, "not an index, just some bytes that are long enough");
    os.close(fd);

    var foreign = IndexReader.open(path.ptr);
    defer foreign.close();
    try testing.expectEqual(@as(u64, 0), foreign.count);
}

test "an Archive stamps every chunk it appends" {
    var name_buf: [64]u8 = undefined;
    const stem = try std.fmt.bufPrintZ(&name_buf, "/tmp/devrun-arc-{d}", .{os.nowMs()});
    const log = try std.fmt.allocPrintSentinel(testing.allocator, "{s}.log", .{stem}, 0);
    const idx = try std.fmt.allocPrintSentinel(testing.allocator, "{s}.idx", .{stem}, 0);
    defer {
        os.unlink(log.ptr);
        os.unlink(idx.ptr);
        testing.allocator.free(log);
        testing.allocator.free(idx);
    }

    var a = try Archive.create(testing.allocator, log.ptr, idx.ptr, 4096);
    a.append("first\n");
    a.append("second\n");
    const before = a.len();
    a.deinit(testing.allocator);

    var r = IndexReader.open(idx.ptr);
    defer r.close();
    // Two appends inside one millisecond collapse to one record, so what is
    // asserted is coverage, not a count: every byte written has a stamp, and
    // the newest stamp is not in the future of the newest byte.
    try testing.expect(r.count >= 1);
    const first = r.at(0).?;
    try testing.expectEqual(@as(u64, 0), first.offset);
    try testing.expect(r.msAt(before -| 1) != null);
    try testing.expectEqual(@as(?u64, 0), r.offsetAtOrAfter(0));
}

test "window budget splits evenly and never starves a Worker" {
    // 8 MiB across 4 Workers is 2 MiB each.
    try testing.expectEqual(@as(usize, 2 << 20), windowBytesPerWorker(8 << 20, 4));
    // Rounded down to a power of two: 8 MiB / 3 is 2.66 MiB, so 2 MiB.
    try testing.expectEqual(@as(usize, 2 << 20), windowBytesPerWorker(8 << 20, 3));
    // A config with many Workers hits the floor rather than approaching zero.
    try testing.expectEqual(@as(usize, 64 << 10), windowBytesPerWorker(8 << 20, 500));
    try testing.expectEqual(@as(usize, 64 << 10), windowBytesPerWorker(0, 0));
}
