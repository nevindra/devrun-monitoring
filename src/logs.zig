//! `devrun logs` — reading Archives back out, merged by time and trimmed down
//! to something worth spending a context window on.
//!
//! This is the read half of `docs/adr/0001-logs-through-the-filesystem.md`. The
//! Archives are files, so this needs no running Session and takes no lock: it
//! opens them read-only, preads, and prints. A Session appending to the same
//! files while this runs is not a case to handle, it is the normal one.
//!
//! Two jobs, and they pull in opposite directions.
//!
//! **Merge.** An Archive per Worker answers "what did the API say". Nobody has
//! that question. The question is "what did *everything* say while that request
//! was failing", which needs the Archives interleaved by time — so this walks
//! all of them at once against their Indexes and emits in timestamp order.
//!
//! **Trim.** The reader is often a model, and a model pays by the token for
//! every byte it is handed. So the default is bounded and the noise is dropped
//! on the way out: ANSI escapes, progress-bar rewrites, repeated lines, and the
//! 200 KB minified single line that no reader was ever going to use. None of it
//! touches the Archive — the file on disk stays byte-faithful, and `--raw` puts
//! every escape back. What is trimmed is always *counted*, in a note at the
//! end, because a silent cap reads as "that was everything" when it was not.

const std = @import("std");
const os = @import("os.zig");
const archive = @import("archive.zig");

const IndexReader = archive.IndexReader;

/// Long enough for a stack frame or a fat JSON log line, short enough that a
/// Worker emitting a megabyte without a newline cannot make this allocate.
const max_line = 8192;

/// What one `devrun logs` invocation was asked for.
pub const Options = struct {
    /// Wall-clock cutoff. Null shows from the start of the Session.
    since_ms: ?u64 = null,
    /// Emit only the last N lines. Null means the caller wants everything.
    tail: ?usize = default_tail,
    /// `|`-separated substrings; a line matching any of them is kept.
    grep: ?[]const u8 = null,
    ignore_case: bool = false,
    /// One ndjson object per line instead of the column view.
    json: bool = false,
    /// Byte-for-byte what the Worker wrote: escapes kept, nothing collapsed,
    /// nothing truncated. The escape hatch for when the trimming is wrong.
    raw: bool = false,
    /// Print the leading timestamp. Off when the reader only wants the text.
    timestamps: bool = true,
    /// Truncate a single line past this many bytes. Zero means never.
    max_line_bytes: usize = 1200,
    /// Collapse a run of identical lines from one Worker into one plus a count.
    collapse: bool = true,
    /// Written before every line. Used by `devrun errors` to nest a log tail
    /// under the Worker it belongs to.
    indent: []const u8 = "",

    /// Bounded by default, and this is the whole posture: `devrun logs` with no
    /// arguments must be safe to run without knowing how big the log is.
    pub const default_tail: usize = 100;
    /// The cap that still applies when a time window was named explicitly.
    /// A window is a real request, so it gets a lot more room than the bare
    /// default, but "the last hour" of a firehose is still not an answer.
    pub const windowed_tail: usize = 1000;
};

/// One Worker's files, opened for reading.
pub const Source = struct {
    name: []const u8,
    fd: os.Fd = -1,
    index: IndexReader = .{},
    /// Size at the moment this was opened. Frozen so that the counting pass
    /// and the printing pass see the same bytes even while a Session appends.
    end: u64 = 0,

    /// Cursor state during a walk.
    at: u64 = 0,
    /// Timestamp of the line at `at`, or null past the end.
    head_ms: ?u64 = null,
    live: bool = false,

    fn open(log_path: [*:0]const u8, index_path: [*:0]const u8, name: []const u8) Source {
        const fd = os.open(log_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch {
            return .{ .name = name };
        };
        const size = os.fileSize(fd) orelse 0;
        return .{
            .name = name,
            .fd = fd,
            .index = IndexReader.open(index_path),
            .end = size,
        };
    }

    pub fn close(self: *Source) void {
        if (self.fd >= 0) os.close(self.fd);
        self.fd = -1;
        self.index.close();
    }

    pub const Line = struct {
        /// As much of the line as fit in the caller's buffer.
        text: []const u8,
        /// Absolute offset to resume at: just past this line's newline.
        end: u64,
        /// How long the line really is, whether or not it fit. A Worker that
        /// emits a 10 MB minified bundle on one line must not be able to make
        /// this allocate, and must not be able to make the "+N bytes clipped"
        /// marker quietly report the size of the buffer instead of the line.
        full_len: u64,
    };

    /// Reads the line starting at `off`, without its terminator. Mirrors
    /// `Archive.lineAt` but over a plain descriptor: this side has no Window,
    /// because a reader has no reason to cache what it is streaming past once.
    ///
    /// Filling the buffer is not the same as finding the line's end. Once
    /// `dst` is full this keeps reading through a small scratch buffer until
    /// it finds the newline — otherwise a line longer than `dst` would leave
    /// the cursor pointing at end-of-file, and every line after it would
    /// silently disappear from the output.
    fn lineAt(self: Source, off: u64, dst: []u8) Line {
        var scan = off;
        var filled: usize = 0;
        var newline: ?u64 = null;
        var scratch: [512]u8 = undefined;

        while (scan < self.end) {
            const room = dst.len - filled;
            const into = if (room > 0) dst[filled..] else scratch[0..];
            const want = @min(into.len, self.end - scan);
            const n = os.pread(self.fd, into[0..@intCast(want)], scan) catch 0;
            if (n == 0) break;
            if (std.mem.indexOfScalar(u8, into[0..n], '\n')) |i| {
                newline = scan + i;
                if (room > 0) filled += i;
                scan += i + 1;
                break;
            }
            if (room > 0) filled += n;
            scan += n;
        }

        const text_end = newline orelse self.end;
        var full_len = text_end - off;
        var text = dst[0..filled];
        // Drop a CRLF's carriage return, so a Worker writing Windows line
        // endings does not print a stray CR. Only checkable when the line fit;
        // being one byte out on a line already too long to print is not worth
        // a second read.
        if (text.len > 0 and text[text.len - 1] == '\r') {
            text = text[0 .. text.len - 1];
            full_len -|= 1;
        }
        return .{
            .text = text,
            .end = if (newline != null) scan else self.end,
            .full_len = full_len,
        };
    }

    /// Walks back `count` line starts from the end of the file. Used to place
    /// the cursor for a `--tail` with no time window, so a 400 MB Archive costs
    /// a few hundred bytes of reading rather than a full scan.
    fn backFromEnd(self: Source, count: usize) u64 {
        if (self.end == 0) return 0;
        var buf: [512]u8 = undefined;
        var at = self.end;
        // A trailing newline terminates the last line rather than starting an
        // empty one, so it does not count against the budget.
        if (at > 0) {
            var last: [1]u8 = undefined;
            if ((os.pread(self.fd, &last, at - 1) catch 0) == 1 and last[0] == '\n') at -= 1;
        }
        var found: usize = 0;
        while (at > 0) {
            const block = @min(@as(u64, buf.len), at);
            const from = at - block;
            const n = os.pread(self.fd, buf[0..@intCast(block)], from) catch return 0;
            if (n == 0) return 0;
            var i: usize = n;
            while (i > 0) {
                i -= 1;
                if (buf[i] != '\n') continue;
                found += 1;
                if (found >= count) return from + i + 1;
            }
            at = from;
        }
        return 0;
    }

    /// Positions the cursor and reads the timestamp of whatever it landed on.
    fn seed(self: *Source, start: u64) void {
        self.at = @min(start, self.end);
        self.refresh();
    }

    fn refresh(self: *Source) void {
        self.live = self.fd >= 0 and self.at < self.end;
        // No Index means no timestamps: the Worker still gets merged, just at
        // the back of every tie. Better than dropping it from the output.
        self.head_ms = if (self.live) self.index.msAt(self.at) else null;
    }
};

// ------------------------------------------------------------- sanitising

/// Strips the bytes a terminal was meant to act on rather than show.
///
/// Three things go, and each is pure cost to a reader that is not a terminal:
/// ANSI escapes (a coloured line can be 40% escape bytes, and they tokenise
/// atrociously), everything before the last carriage return (a progress bar
/// rewriting itself in place — only the final state was ever visible), and the
/// remaining C0 controls. Tabs and printable bytes survive untouched.
///
/// Writes into `dst` and returns the prefix used. `dst` must be as long as the
/// input; the output is never longer.
pub fn sanitize(line: []const u8, dst: []u8) []const u8 {
    // Only the segment after the final CR was ever on screen. A line with no
    // CR is entirely its own last segment, so this is a no-op for normal logs.
    var src = line;
    if (std.mem.lastIndexOfScalar(u8, src, '\r')) |i| src = src[i + 1 ..];

    var n: usize = 0;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == 0x1b) {
            i += 1;
            if (i >= src.len) break;
            switch (src[i]) {
                // CSI: parameters, then a byte in 0x40..0x7e ends it.
                '[' => {
                    i += 1;
                    while (i < src.len and (src[i] < 0x40 or src[i] > 0x7e)) i += 1;
                    if (i < src.len) i += 1;
                },
                // OSC: runs to BEL or to ST (ESC \). Hyperlinks and window
                // titles both arrive this way and both are noise here.
                ']' => {
                    i += 1;
                    while (i < src.len) {
                        if (src[i] == 0x07) {
                            i += 1;
                            break;
                        }
                        if (src[i] == 0x1b and i + 1 < src.len and src[i + 1] == '\\') {
                            i += 2;
                            break;
                        }
                        i += 1;
                    }
                },
                // Anything else is a two-byte escape.
                else => i += 1,
            }
            continue;
        }
        // Tab survives; it is load-bearing in aligned output. The rest of C0
        // and a bare DEL are not printable and not information.
        if ((c < 0x20 and c != '\t') or c == 0x7f) {
            i += 1;
            continue;
        }
        dst[n] = c;
        n += 1;
        i += 1;
    }

    // Trailing whitespace is invisible and still costs tokens.
    var out = dst[0..n];
    while (out.len > 0 and (out[out.len - 1] == ' ' or out[out.len - 1] == '\t')) {
        out = out[0 .. out.len - 1];
    }
    return out;
}

fn matches(text: []const u8, pattern: []const u8, ignore_case: bool) bool {
    var it = std.mem.splitScalar(u8, pattern, '|');
    while (it.next()) |needle| {
        if (needle.len == 0) continue;
        if (ignore_case) {
            if (indexOfIgnoreCase(text, needle) != null) return true;
        } else {
            if (std.mem.indexOf(u8, text, needle) != null) return true;
        }
    }
    return false;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    outer: while (i + needle.len <= haystack.len) : (i += 1) {
        for (needle, haystack[i..][0..needle.len]) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) continue :outer;
        }
        return i;
    }
    return null;
}

// ------------------------------------------------------------- emitting

/// What a walk produced, whether or not it printed anything.
pub const Report = struct {
    /// Lines that survived every filter, within the range that was scanned.
    emitted: usize = 0,
    /// Lines dropped by `--tail` because they fell off the front of the
    /// scanned range. Exact; see `more_before` for what was never scanned.
    dropped_older: usize = 0,
    /// Whether output begins part-way through the Session. True either because
    /// `--tail` cut lines, or because the tail was answered by seeking rather
    /// than scanning and there is no count for what lies behind that seek.
    more_before: bool = false,
    /// Repeats folded into a count rather than printed.
    collapsed: usize = 0,
    /// Lines clipped by `--max-line`.
    truncated: usize = 0,
    /// Whether any Worker had no Index, so its lines carry no time.
    missing_index: bool = false,
    /// Set when `--tail` was answered by seeking rather than scanning, so
    /// whatever lies before the seek was never counted. Feeds `more_before`.
    sought_past_front: bool = false,
};

/// Runs the merge, either counting (`out` null) or printing. Holding one line
/// back is what makes `--collapse` possible: a repeat count is only knowable
/// once the run has ended, so the pending line is printed when the next one
/// turns out to differ.
const Emitter = struct {
    opts: Options,
    out: ?*std.Io.Writer,
    /// Emitted lines to discard from the front, so a second pass can print
    /// only the tail without buffering the whole result.
    skip: usize,
    name_width: usize,
    show_names: bool,

    report: Report = .{},

    pending: [max_line]u8 = undefined,
    pending_len: usize = 0,
    /// What the line was before `max_line` clamped it. Kept so the "+N bytes"
    /// marker counts what the *Worker* wrote, not what survived this buffer —
    /// a marker that under-reports its own clipping is worse than no marker.
    pending_full_len: usize = 0,
    /// Bytes of this line that the read buffer never reached.
    pending_unread: u64 = 0,
    pending_ms: ?u64 = null,
    pending_name: []const u8 = "",
    pending_repeats: usize = 0,
    has_pending: bool = false,

    /// `unread` is how many bytes of this line never reached `text` because
    /// the line was longer than the read buffer. Carried separately because it
    /// is the one part of the clipping that cannot be measured from `text`.
    fn feed(self: *Emitter, name: []const u8, ms: ?u64, text: []const u8, unread: u64) !void {
        if (self.opts.collapse and self.has_pending and
            std.mem.eql(u8, self.pending[0..self.pending_len], text) and
            std.mem.eql(u8, self.pending_name, name))
        {
            self.pending_repeats += 1;
            self.report.collapsed += 1;
            return;
        }
        try self.flushPending();

        const keep = @min(text.len, max_line);
        @memcpy(self.pending[0..keep], text[0..keep]);
        self.pending_len = keep;
        self.pending_full_len = text.len;
        self.pending_unread = unread;
        self.pending_ms = ms;
        self.pending_name = name;
        self.pending_repeats = 0;
        self.has_pending = true;
    }

    fn flushPending(self: *Emitter) !void {
        if (!self.has_pending) return;
        self.has_pending = false;

        // Counted before the skip is applied: `dropped_older` is how many the
        // tail cut, which is only meaningful against the full total.
        self.report.emitted += 1;
        if (self.skip > 0) {
            self.skip -= 1;
            self.report.dropped_older += 1;
            return;
        }
        const out = self.out orelse return;

        var text = self.pending[0..self.pending_len];
        if (self.opts.max_line_bytes > 0 and text.len > self.opts.max_line_bytes) {
            text = text[0..self.opts.max_line_bytes];
        }
        // Everything the Worker wrote on this line that is not on screen: what
        // `--max-line` cut, plus what the read buffer never reached. Stripped
        // escapes are not counted — they were removed, not withheld.
        const clipped = (self.pending_full_len - text.len) + self.pending_unread;
        if (clipped > 0) self.report.truncated += 1;

        if (self.opts.json) {
            try out.writeAll("{");
            if (self.pending_ms) |ms| try out.print("\"ts\":{d},", .{ms});
            try out.writeAll("\"w\":");
            try writeJsonString(out, self.pending_name);
            try out.writeAll(",\"msg\":");
            try writeJsonString(out, text);
            if (clipped > 0) try out.print(",\"clipped\":{d}", .{clipped});
            if (self.pending_repeats > 0) try out.print(",\"repeat\":{d}", .{self.pending_repeats + 1});
            try out.writeAll("}\n");
            return;
        }

        try out.writeAll(self.opts.indent);
        if (self.opts.timestamps) {
            if (self.pending_ms) |ms| {
                try writeClock(out, ms);
            } else {
                // Same width as a clock, so the columns still line up when one
                // Worker has an Index and another does not.
                try out.writeAll("        ");
            }
            try out.writeByte(' ');
        }
        if (self.show_names) {
            try out.writeAll(self.pending_name);
            try out.splatByteAll(' ', self.name_width - self.pending_name.len + 1);
        }
        try out.writeAll(text);
        if (clipped > 0) try out.print(" …+{d}B", .{clipped});
        if (self.pending_repeats > 0) try out.print(" ×{d}", .{self.pending_repeats + 1});
        try out.writeByte('\n');
    }
};

/// `HH:MM:SS`, UTC. No date, because every line in one view is from the same
/// run and the date would be the same eight bytes on all of them. UTC rather
/// than local because this has no timezone database and a clock that is
/// silently wrong by seven hours is worse than one that is openly in UTC.
fn writeClock(out: *std.Io.Writer, ms: u64) !void {
    const secs = ms / 1000;
    const day = secs % 86_400;
    try out.print("{d:0>2}:{d:0>2}:{d:0>2}", .{ day / 3600, (day % 3600) / 60, day % 60 });
}

fn writeJsonString(out: *std.Io.Writer, s: []const u8) !void {
    try out.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\t' => try out.writeAll("\\t"),
        else => {
            if (c < 0x20) {
                try out.print("\\u{x:0>4}", .{c});
            } else {
                try out.writeByte(c);
            }
        },
    };
    try out.writeByte('"');
}

// ------------------------------------------------------------- the walk

/// Opens every named Worker's Archive. The caller owns the slice and must
/// `close` each Source.
pub fn openSources(
    gpa: std.mem.Allocator,
    log_dir: []const u8,
    names: []const []const u8,
) ![]Source {
    const sources = try gpa.alloc(Source, names.len);
    errdefer gpa.free(sources);

    for (sources, names) |*s, name| {
        var log_buf: [4096]u8 = undefined;
        var idx_buf: [4096]u8 = undefined;
        const log = std.fmt.bufPrintZ(&log_buf, "{s}/{s}.log", .{ log_dir, name }) catch {
            s.* = .{ .name = name };
            continue;
        };
        const idx = std.fmt.bufPrintZ(&idx_buf, "{s}/{s}.idx", .{ log_dir, name }) catch {
            s.* = .{ .name = name };
            continue;
        };
        s.* = Source.open(log.ptr, idx.ptr, name);
    }
    return sources;
}

pub fn closeSources(gpa: std.mem.Allocator, sources: []Source) void {
    for (sources) |*s| s.close();
    gpa.free(sources);
}

/// Merges and prints. Two passes over the same frozen byte ranges: the first
/// counts what survives the filters, the second prints only the last `tail` of
/// them. Two passes rather than a buffer because the result set is unbounded
/// and the memory here must not be — a `--tail 50` over a gigabyte holds one
/// line, not fifty thousand.
pub fn run(sources: []Source, opts: Options, out: *std.Io.Writer) !Report {
    const counting = try walk(sources, opts, null, 0);

    const skip = if (opts.tail) |t| counting.emitted -| t else 0;
    var printed = if (skip == 0 and counting.emitted == 0)
        counting
    else
        try walk(sources, opts, out, skip);

    printed.missing_index = missingIndex(sources);
    printed.dropped_older = skip;
    printed.more_before = skip > 0 or counting.sought_past_front;
    return printed;
}

fn missingIndex(sources: []const Source) bool {
    for (sources) |s| {
        if (s.fd >= 0 and s.end > 0 and s.index.count == 0) return true;
    }
    return false;
}

fn walk(sources: []Source, opts: Options, out: ?*std.Io.Writer, skip: usize) !Report {
    var name_width: usize = 0;
    var with_bytes: usize = 0;
    for (sources) |s| {
        name_width = @max(name_width, s.name.len);
        if (s.end > 0) with_bytes += 1;
    }

    // Seed each cursor. Where it starts is the one place `--since` and `--tail`
    // differ: a time window is answered by the Index, a line count by walking
    // back from the end. With both, the time window wins and the count trims.
    //
    // The walk-back is an optimisation and it is only sound with no filter.
    // `--tail 5` wants the last five lines, so the last five lines are all
    // that needs reading. `--grep ERROR --tail 5` wants the last five
    // *matches*, which may be an hour back — seeking to the last five raw
    // lines there would report "no errors" for a log full of them. So a filter
    // forces the scan to start where it would have anyway, and `--tail` goes
    // back to meaning what it says.
    const seek_for_tail = opts.grep == null;
    var sought_past_front = false;

    for (sources) |*s| {
        if (s.fd < 0) continue;
        var start: u64 = 0;
        if (opts.since_ms) |cutoff| {
            start = s.index.offsetAtOrAfter(cutoff) orelse s.end;
        } else if (opts.tail) |t| {
            if (seek_for_tail) {
                // Each Worker's own last N is a superset of its share of the
                // merged last N, so this can never drop a line the merge
                // wanted — only lines the tail was going to cut regardless.
                start = s.backFromEnd(t);
                if (start > 0) sought_past_front = true;
            }
        }
        s.seed(start);
    }

    var em: Emitter = .{
        .opts = opts,
        .out = out,
        .skip = skip,
        .name_width = name_width,
        // A single Worker needs no column telling you which Worker it is.
        .show_names = sources.len > 1,
    };

    var line_buf: [max_line]u8 = undefined;
    var clean_buf: [max_line]u8 = undefined;

    while (true) {
        // Oldest head wins. A Worker with no Index sorts last, so it appends
        // rather than interleaving at a time nobody recorded.
        var pick: ?usize = null;
        for (sources, 0..) |s, i| {
            if (!s.live) continue;
            const best = pick orelse {
                pick = i;
                continue;
            };
            const a = s.head_ms orelse std.math.maxInt(u64);
            const b = sources[best].head_ms orelse std.math.maxInt(u64);
            if (a < b) pick = i;
        }
        const i = pick orelse break;
        const s = &sources[i];

        const line = s.lineAt(s.at, &line_buf);
        // A line that did not advance the cursor would spin forever. It cannot
        // happen with a non-empty file, but a truncated read is not worth
        // trusting on that.
        if (line.end <= s.at) {
            s.live = false;
            continue;
        }
        const ms = s.head_ms;
        s.at = line.end;
        s.refresh();

        const text = if (opts.raw) line.text else sanitize(line.text, &clean_buf);
        if (text.len == 0 and !opts.raw) continue;
        if (opts.grep) |g| {
            if (!matches(text, g, opts.ignore_case)) continue;
        }
        try em.feed(s.name, ms, text, line.full_len -| line.text.len);
    }

    try em.flushPending();
    if (out) |w| try w.flush();
    em.report.sought_past_front = sought_past_front;
    return em.report;
}

/// A duration: `30s`, `2m`, `1h`, `500ms`, `2d`, or a bare number of seconds.
/// Null on anything else rather than a default, for the reason `--window-bytes`
/// gives: a mistyped window silently becoming "everything" is how you read the
/// wrong hour of a log and believe it.
pub fn parseDuration(text: []const u8) ?u64 {
    if (text.len == 0) return null;
    var i: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    if (i == 0) return null;

    const n = std.fmt.parseInt(u64, text[0..i], 10) catch return null;
    const unit = text[i..];
    // A bare number is seconds, which is what `--since 30` means to everyone
    // who has ever typed it.
    if (unit.len == 0) return std.math.mul(u64, n, 1000) catch null;

    const mult: u64 = if (std.mem.eql(u8, unit, "ms"))
        1
    else if (std.mem.eql(u8, unit, "s"))
        1000
    else if (std.mem.eql(u8, unit, "m"))
        60 * 1000
    else if (std.mem.eql(u8, unit, "h"))
        60 * 60 * 1000
    else if (std.mem.eql(u8, unit, "d"))
        24 * 60 * 60 * 1000
    else
        return null;
    return std.math.mul(u64, n, mult) catch null;
}

/// The line under the output saying what was left out. Printed to stderr by
/// the caller so it never lands in a pipe that is being parsed.
pub fn writeNote(r: Report, opts: Options, w: *std.Io.Writer) !void {
    var wrote = false;
    if (r.more_before) {
        // An exact count only exists when the whole range was scanned. When
        // the tail was answered by seeking, saying "3 older lines" would be a
        // number invented to look precise, so it says the true thing instead.
        if (r.dropped_older > 0 and !r.sought_past_front) {
            try w.print("devrun: {d} older line{s} not shown", .{
                r.dropped_older,
                if (r.dropped_older == 1) "" else "s",
            });
        } else {
            try w.writeAll("devrun: older lines not shown");
        }
        wrote = true;
    }
    if (r.collapsed > 0) {
        try w.print("{s}{d} repeat{s} folded", .{
            if (wrote) ", " else "devrun: ",
            r.collapsed,
            if (r.collapsed == 1) "" else "s",
        });
        wrote = true;
    }
    if (r.truncated > 0) {
        try w.print("{s}{d} long line{s} clipped", .{
            if (wrote) ", " else "devrun: ",
            r.truncated,
            if (r.truncated == 1) "" else "s",
        });
        wrote = true;
    }
    if (!wrote) return;

    if (r.more_before and opts.tail != null) {
        try w.writeAll(". Use --all, --tail N, or --since 5m for more");
    }
    try w.writeAll(".\n");
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "sanitize drops what only a terminal was going to act on" {
    var buf: [256]u8 = undefined;

    // Colour is the common case and the expensive one: escapes tokenise badly
    // and carry nothing a reader needs.
    try testing.expectEqualStrings(
        "ERROR: it broke",
        sanitize("\x1b[31mERROR\x1b[0m: it broke", &buf),
    );

    // A progress bar rewrote itself in place. Only the last state was ever on
    // screen, so the earlier ones are not output, they are animation frames.
    try testing.expectEqualStrings(
        "installing [####] 100%",
        sanitize("installing [#---] 25%\rinstalling [##--] 50%\rinstalling [####] 100%", &buf),
    );

    // OSC 8 hyperlinks wrap the visible text in two escapes; the text survives.
    try testing.expectEqualStrings(
        "docs",
        sanitize("\x1b]8;;https://example.com\x07docs\x1b]8;;\x07", &buf),
    );

    // Tabs are load-bearing in aligned output; trailing blanks are not.
    try testing.expectEqualStrings("a\tb", sanitize("a\tb   \t", &buf));
    // Other C0 control bytes go.
    try testing.expectEqualStrings("bell", sanitize("be\x07ll", &buf));
    // Plain text is returned untouched.
    try testing.expectEqualStrings("nothing to do", sanitize("nothing to do", &buf));
}

test "grep matches any alternative, and honours case folding" {
    try testing.expect(matches("a panic happened", "panic|ERROR", false));
    try testing.expect(matches("an ERROR happened", "panic|ERROR", false));
    try testing.expect(!matches("all fine", "panic|ERROR", false));

    // Case-sensitive by default: "Error" is not "ERROR".
    try testing.expect(!matches("an Error happened", "ERROR", false));
    try testing.expect(matches("an Error happened", "ERROR", true));

    // An empty alternative would otherwise match everything, which is how a
    // trailing pipe silently turns a filter off.
    try testing.expect(!matches("all fine", "panic|", false));
}

test "parseDuration takes the units people type and refuses the rest" {
    try testing.expectEqual(@as(?u64, 30_000), parseDuration("30s"));
    try testing.expectEqual(@as(?u64, 120_000), parseDuration("2m"));
    try testing.expectEqual(@as(?u64, 3_600_000), parseDuration("1h"));
    try testing.expectEqual(@as(?u64, 500), parseDuration("500ms"));
    try testing.expectEqual(@as(?u64, 86_400_000), parseDuration("1d"));
    // A bare number is seconds, which is what `--since 30` means to everyone.
    try testing.expectEqual(@as(?u64, 30_000), parseDuration("30"));

    try testing.expect(parseDuration("") == null);
    try testing.expect(parseDuration("m") == null);
    try testing.expect(parseDuration("2 minutes") == null);
    try testing.expect(parseDuration("2w") == null);
    try testing.expect(parseDuration("-5m") == null);
}

/// Writes a `.log` and a matching `.idx` so a walk can be exercised end to end
/// against real descriptors rather than a mock.
fn writeFixture(dir: []const u8, name: []const u8, chunks: []const struct { u64, []const u8 }) !void {
    var log_buf: [512]u8 = undefined;
    var idx_buf: [512]u8 = undefined;
    const log_path = try std.fmt.bufPrintZ(&log_buf, "{s}/{s}.log", .{ dir, name });
    const idx_path = try std.fmt.bufPrintZ(&idx_buf, "{s}/{s}.idx", .{ dir, name });

    var a = try archive.Archive.create(testing.allocator, log_path.ptr, null, 4096);
    defer a.deinit(testing.allocator);
    var idx = try archive.Index.create(idx_path.ptr);
    defer idx.deinit();

    var off: u64 = 0;
    for (chunks) |c| {
        const ms, const text = c;
        idx.stamp(ms, off);
        try os.writeAll(a.fd, text);
        off += text.len;
    }
}

fn tempDir(tag: []const u8, buf: []u8) ![]const u8 {
    const dir = try std.fmt.bufPrint(buf, "/tmp/devrun-logs-{s}-{d}", .{ tag, os.nowMs() });
    try os.makePath(dir);
    return dir;
}

test "a walk merges Workers by time rather than by file" {
    var dir_buf: [128]u8 = undefined;
    const dir = try tempDir("merge", &dir_buf);

    // Interleaved in time, but each Worker's own file is contiguous. Reading
    // the files one after another would report these in the wrong order, which
    // is exactly the failure this whole sidecar exists to prevent.
    try writeFixture(dir, "api", &.{
        .{ 1_000, "first\n" },
        .{ 3_000, "third\n" },
    });
    try writeFixture(dir, "db", &.{
        .{ 2_000, "second\n" },
        .{ 4_000, "fourth\n" },
    });

    const sources = try openSources(testing.allocator, dir, &.{ "api", "db" });
    defer closeSources(testing.allocator, sources);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r = try run(sources, .{ .tail = null, .timestamps = false }, &w);

    try testing.expectEqual(@as(usize, 4), r.emitted);
    try testing.expectEqualStrings(
        \\api first
        \\db  second
        \\api third
        \\db  fourth
        \\
    , w.buffered());
}

test "--since starts at the chunk straddling the cutoff, never after it" {
    var dir_buf: [128]u8 = undefined;
    const dir = try tempDir("since", &dir_buf);
    try writeFixture(dir, "api", &.{
        .{ 1_000, "old\n" },
        .{ 5_000, "recent\n" },
        .{ 9_000, "newest\n" },
    });

    const sources = try openSources(testing.allocator, dir, &.{"api"});
    defer closeSources(testing.allocator, sources);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r = try run(sources, .{
        .since_ms = 6_000,
        .tail = null,
        .timestamps = false,
    }, &w);

    // 6000 falls inside the chunk stamped 5000, so that chunk is included
    // whole. Rounding the other way would hide the line that explains what
    // happened at 6000.
    try testing.expectEqual(@as(usize, 2), r.emitted);
    try testing.expectEqualStrings("recent\nnewest\n", w.buffered());
}

test "repeats fold into a count and are reported rather than dropped quietly" {
    var dir_buf: [128]u8 = undefined;
    const dir = try tempDir("collapse", &dir_buf);
    try writeFixture(dir, "web", &.{
        .{ 1_000, "rebuilding…\nrebuilding…\nrebuilding…\nrebuilding…\n" },
        .{ 2_000, "done\n" },
    });

    const sources = try openSources(testing.allocator, dir, &.{"web"});
    defer closeSources(testing.allocator, sources);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r = try run(sources, .{ .tail = null, .timestamps = false }, &w);

    try testing.expectEqualStrings("rebuilding… ×4\ndone\n", w.buffered());
    try testing.expectEqual(@as(usize, 2), r.emitted);
    try testing.expectEqual(@as(usize, 3), r.collapsed);

    // And the note says so, because a fold the reader cannot see is a lie
    // about how much output there was.
    var note_buf: [256]u8 = undefined;
    var nw: std.Io.Writer = .fixed(&note_buf);
    try writeNote(r, .{ .tail = null }, &nw);
    try testing.expectEqualStrings("devrun: 3 repeats folded.\n", nw.buffered());
}

test "--tail keeps the newest lines and counts what it cut" {
    var dir_buf: [128]u8 = undefined;
    const dir = try tempDir("tail", &dir_buf);
    try writeFixture(dir, "api", &.{
        .{ 1_000, "one\ntwo\nthree\nfour\nfive\n" },
    });

    const sources = try openSources(testing.allocator, dir, &.{"api"});
    defer closeSources(testing.allocator, sources);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r = try run(sources, .{ .tail = 2, .timestamps = false }, &w);

    try testing.expectEqualStrings("four\nfive\n", w.buffered());
    // With no filter the tail is answered by seeking, so the three lines in
    // front of it were never read and there is no honest count for them.
    try testing.expect(r.more_before);
    try testing.expect(r.sought_past_front);

    // The note has to say that without inventing a number.
    var note_buf: [256]u8 = undefined;
    var nw: std.Io.Writer = .fixed(&note_buf);
    try writeNote(r, .{ .tail = 2 }, &nw);
    try testing.expectEqualStrings(
        "devrun: older lines not shown. Use --all, --tail N, or --since 5m for more.\n",
        nw.buffered(),
    );
}

test "a filter makes --tail count matches, not raw lines" {
    var dir_buf: [128]u8 = undefined;
    const dir = try tempDir("grep", &dir_buf);
    // The two matches sit at the front, behind five lines of noise. Seeking to
    // the last two lines to satisfy `--tail 2` would find neither and report a
    // clean log, which is the worst possible answer to "did anything break".
    try writeFixture(dir, "api", &.{
        .{ 1_000, "ERROR a\nERROR b\nok 1\nok 2\nok 3\nok 4\nok 5\n" },
    });

    const sources = try openSources(testing.allocator, dir, &.{"api"});
    defer closeSources(testing.allocator, sources);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r = try run(sources, .{
        .grep = "ERROR",
        .tail = 2,
        .timestamps = false,
    }, &w);

    try testing.expectEqualStrings("ERROR a\nERROR b\n", w.buffered());
    try testing.expectEqual(@as(usize, 2), r.emitted);
    // Both matches fit in the tail, so nothing was cut and the note is silent.
    try testing.expect(!r.more_before);

    // And when the tail does cut matches, the count is exact — the whole range
    // was scanned, so there is nothing to be vague about.
    var buf2: [4096]u8 = undefined;
    var w2: std.Io.Writer = .fixed(&buf2);
    const r2 = try run(sources, .{
        .grep = "ERROR",
        .tail = 1,
        .timestamps = false,
    }, &w2);
    try testing.expectEqualStrings("ERROR b\n", w2.buffered());
    try testing.expectEqual(@as(usize, 1), r2.dropped_older);
    try testing.expect(!r2.sought_past_front);

    var note_buf: [256]u8 = undefined;
    var nw: std.Io.Writer = .fixed(&note_buf);
    try writeNote(r2, .{ .tail = 1 }, &nw);
    try testing.expectEqualStrings(
        "devrun: 1 older line not shown. Use --all, --tail N, or --since 5m for more.\n",
        nw.buffered(),
    );
}

test "json output is one object per line, with the timestamp machines want" {
    var dir_buf: [128]u8 = undefined;
    const dir = try tempDir("json", &dir_buf);
    try writeFixture(dir, "api", &.{.{ 1_700_000_000_000, "he said \"hi\"\n" }});

    const sources = try openSources(testing.allocator, dir, &.{"api"});
    defer closeSources(testing.allocator, sources);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    _ = try run(sources, .{ .json = true, .tail = null }, &w);

    try testing.expectEqualStrings(
        "{\"ts\":1700000000000,\"w\":\"api\",\"msg\":\"he said \\\"hi\\\"\"}\n",
        w.buffered(),
    );
}

test "a Worker with no Index still appears, at the back of every tie" {
    var dir_buf: [128]u8 = undefined;
    const dir = try tempDir("noidx", &dir_buf);
    try writeFixture(dir, "api", &.{.{ 1_000, "timed\n" }});

    // A `.log` with no `.idx` beside it: an Archive from an older devrun, or
    // one whose sidecar could not be written. Losing its output entirely would
    // be a much worse answer than losing its position.
    var log_buf: [512]u8 = undefined;
    const log_path = try std.fmt.bufPrintZ(&log_buf, "{s}/legacy.log", .{dir});
    var a = try archive.Archive.create(testing.allocator, log_path.ptr, null, 4096);
    try os.writeAll(a.fd, "untimed\n");
    a.deinit(testing.allocator);

    const sources = try openSources(testing.allocator, dir, &.{ "api", "legacy" });
    defer closeSources(testing.allocator, sources);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r = try run(sources, .{ .tail = null, .timestamps = false }, &w);

    try testing.expectEqual(@as(usize, 2), r.emitted);
    try testing.expect(r.missing_index);
    try testing.expectEqualStrings("api    timed\nlegacy untimed\n", w.buffered());
}

test "a long line is clipped with the byte count that was cut" {
    var dir_buf: [128]u8 = undefined;
    const dir = try tempDir("clip", &dir_buf);
    var long: [200]u8 = @splat('x');
    var chunk: [201]u8 = undefined;
    @memcpy(chunk[0..200], &long);
    chunk[200] = '\n';
    try writeFixture(dir, "api", &.{.{ 1_000, &chunk }});

    const sources = try openSources(testing.allocator, dir, &.{"api"});
    defer closeSources(testing.allocator, sources);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r = try run(sources, .{
        .tail = null,
        .timestamps = false,
        .max_line_bytes = 50,
    }, &w);

    try testing.expectEqual(@as(usize, 1), r.truncated);
    try testing.expectEqualStrings(("x" ** 50) ++ " …+150B\n", w.buffered());
}

test "a line longer than the read buffer does not swallow the lines after it" {
    var dir_buf: [128]u8 = undefined;
    const dir = try tempDir("giant", &dir_buf);

    // A minified bundle on one line, then two ordinary lines. The reader fills
    // its buffer part-way through the giant one, so unless it keeps scanning
    // for the newline the cursor lands at end-of-file and "after one" and
    // "after two" are never printed — a silent hole in the middle of a log.
    const giant_len = max_line * 2 + 33;
    const giant = try testing.allocator.alloc(u8, giant_len + 1);
    defer testing.allocator.free(giant);
    @memset(giant[0..giant_len], 'z');
    giant[giant_len] = '\n';

    try writeFixture(dir, "api", &.{
        .{ 1_000, giant },
        .{ 2_000, "after one\nafter two\n" },
    });

    const sources = try openSources(testing.allocator, dir, &.{"api"});
    defer closeSources(testing.allocator, sources);

    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const r = try run(sources, .{
        .tail = null,
        .timestamps = false,
        .max_line_bytes = 20,
    }, &w);

    try testing.expectEqual(@as(usize, 3), r.emitted);
    // And the marker counts what the *Worker* wrote, not what the buffer held.
    // 20 shown of 16417 means 16397 withheld; reporting the buffer's ceiling
    // instead would claim 8172 and be off by half.
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "{s} …+{d}B\nafter one\nafter two\n",
        .{ "z" ** 20, giant_len - 20 },
    );
    try testing.expectEqualStrings(expected, w.buffered());
}
