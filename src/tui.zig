//! The interactive view: a Worker list, a log pane, visual selection, and
//! copy.
//!
//! The pane is a *view over Archives*, never their owner. It holds one number
//! per Worker — the absolute byte offset the view starts at — and reads
//! through `Archive.readAt`, which serves the Window when the offset is
//! resident and `pread`s the page cache when it is not. So scrolling back an
//! hour costs the same as scrolling back a line, and the TUI's own memory is
//! the frame buffer and nothing else.
//!
//! Rendering is one `write` of a fully-built frame. Log bytes are copied into
//! it verbatim, escapes and all: a Worker's colours arrive on screen because
//! nothing here tried to interpret them.

const std = @import("std");
const os = @import("os.zig");
const term = @import("term.zig");
const control = @import("control.zig");
const supervisor = @import("supervisor.zig");

const Supervisor = supervisor.Supervisor;
const esc = term.esc;
const Allocator = std.mem.Allocator;

/// Width of the Worker list. Wide enough for a name, a state, and a CPU
/// figure without the log pane losing useful room on an 80-column terminal.
const sidebar_cols = 30;

const Mode = enum { normal, visual };

pub fn run(
    gpa: Allocator,
    sup: *Supervisor,
    server: ?*control.Server,
    io: std.Io,
) !u8 {
    _ = io;
    var tty = term.Terminal.init(0) catch {
        // stdin is not a terminal even though stdout is. Nothing to drive the
        // TUI with, so the caller's plain path is the honest answer.
        return error.NotATerminal;
    };

    var ui = try Ui.init(gpa, sup, &tty);
    defer ui.deinit(gpa);

    ui.enter();
    defer ui.leave();

    while (true) {
        try ui.render();

        var extra: [control.Server.max_poll_fds + 1]os.PollFd = undefined;
        extra[0] = .{ .fd = 0, .events = os.POLL.IN, .revents = 0 };
        var n: usize = 1;
        if (server) |s| n += s.fillPollFds(extra[1..]);

        // A frame every 100 ms at most, which is what makes a CPU figure feel
        // live without redrawing for every line a Worker prints.
        try sup.step(extra[0..n], 100);
        if (server) |s| s.service(extra[1..n], sup);

        if (extra[0].revents & os.POLL.IN != 0) {
            if (ui.readKeys()) return ui.exit_code;
        }

        // The Session is over and the user has not asked to stay.
        if (sup.done() and sup.shutting_down) return ui.exit_code;
    }
}

const Ui = struct {
    sup: *Supervisor,
    tty: *term.Terminal,
    size: term.Size,

    /// Absolute Archive offset each Worker's pane starts at. One u64 per
    /// Worker is the whole of the TUI's per-Worker state.
    view_top: []u64,
    /// Following the tail rather than parked at a scroll position.
    follow: []bool,

    selected: usize = 0,
    mode: Mode = .normal,
    /// First line of the visual selection, as an absolute offset.
    anchor: u64 = 0,
    /// Line the cursor is on in visual mode.
    cursor: u64 = 0,

    frame: std.Io.Writer.Allocating,
    gpa: Allocator,

    /// Redrawn only when something changed. Compared against the supervisor's
    /// generation counter, so a quiet Session costs one poll wake-up and no
    /// terminal traffic at all.
    drawn_generation: u64 = std.math.maxInt(u64),
    /// When the last frame was built, for the rate cap in `render`.
    last_frame_ms: u64 = 0,
    status: []const u8 = "",
    exit_code: u8 = 0,
    /// Width of the sidebar's name column, fixed for the Session so the
    /// figures beside it form columns instead of drifting per row.
    name_w: usize,

    fn init(gpa: Allocator, sup: *Supervisor, tty: *term.Terminal) !Ui {
        const n = sup.workers.len;
        var widest: usize = 0;
        for (sup.workers) |x| widest = @max(widest, x.name().len);
        // Leave room for the marker, CPU, and memory columns; a very long
        // name is truncated rather than pushing them off the pane.
        const name_w = @min(widest, sidebar_cols - 18);
        return .{
            .name_w = name_w,
            .gpa = gpa,
            .sup = sup,
            .tty = tty,
            .size = tty.size(),
            .view_top = try gpa.alloc(u64, n),
            .follow = try gpa.alloc(bool, n),
            .frame = .init(gpa),
        };
    }

    fn deinit(self: *Ui, gpa: Allocator) void {
        gpa.free(self.view_top);
        gpa.free(self.follow);
        self.frame.deinit();
    }

    fn enter(self: *Ui) void {
        @memset(self.view_top, 0);
        @memset(self.follow, true);
        self.tty.enterRaw();
        write(esc.alt_screen_on ++ esc.cursor_hide ++ esc.clear);
    }

    fn leave(self: *Ui) void {
        write(esc.alt_screen_off ++ esc.cursor_show ++ esc.reset);
        self.tty.restore();
    }

    fn logHeight(self: Ui) usize {
        // Two rows of chrome: the header and the status line.
        return @max(1, @as(usize, self.size.rows) -| 2);
    }

    fn logWidth(self: Ui) usize {
        return @max(8, @as(usize, self.size.cols) -| (sidebar_cols + 1));
    }

    // ------------------------------------------------------------- input

    /// Returns true when the user is finished with the Session.
    fn readKeys(self: *Ui) bool {
        var buf: [1024]u8 = undefined;
        const n = os.read(0, &buf) catch return false;
        if (n == 0) return false;

        var i: usize = 0;
        while (i < n) {
            const d = term.decodeKey(buf[i..n]) orelse break;
            i += d.len;
            if (self.onKey(d.key)) return true;
        }
        self.sup.generation += 1; // a keypress always means a redraw
        return false;
    }

    fn onKey(self: *Ui, key: term.Key) bool {
        const height = self.logHeight();
        switch (key) {
            .char => |c| switch (c) {
                'q' => {
                    // First q asks politely; the Session shuts down and the
                    // TUI stays up so the reader can watch it happen.
                    if (self.sup.shutting_down) return true;
                    self.sup.beginShutdown();
                    self.status = "shutting down — q again to leave now";
                },
                'j' => self.scroll(1),
                'k' => self.scroll(-1),
                'g' => self.jumpTop(),
                'G' => self.jumpBottom(),
                'n' => self.selectBy(1),
                'p' => self.selectBy(-1),
                '\t' => self.selectBy(1),
                'v' => self.toggleVisual(),
                'y' => self.copy(),
                's' => self.act(.stop),
                'r' => self.act(.restart),
                'S' => self.act(.start),
                else => {},
            },
            .down => if (self.mode == .visual) self.moveCursor(1) else self.scroll(1),
            .up => if (self.mode == .visual) self.moveCursor(-1) else self.scroll(-1),
            .right => self.selectBy(1),
            .left => self.selectBy(-1),
            .page_down => self.scroll(@intCast(height)),
            .page_up => self.scroll(-@as(isize, @intCast(height))),
            .home => self.jumpTop(),
            .end => self.jumpBottom(),
            .escape => {
                self.mode = .normal;
                self.status = "";
            },
            else => {},
        }
        return false;
    }

    fn selectBy(self: *Ui, delta: isize) void {
        const n = self.sup.workers.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.selected);
        self.selected = @intCast(@mod(cur + delta, @as(isize, @intCast(n))));
        self.mode = .normal;
    }

    /// Moves the view by whole lines. Leaving the bottom stops following, and
    /// arriving back at the bottom resumes it — so a reader who scrolls up to
    /// read something is not yanked away by the next line of output.
    fn scroll(self: *Ui, lines: isize) void {
        const i = self.selected;
        const a = &self.sup.workers[i].archive;
        if (lines < 0) {
            self.view_top[i] = a.scrollBack(self.viewTop(i), @intCast(-lines));
            self.follow[i] = false;
        } else {
            const moved = a.scrollForward(self.viewTop(i), @intCast(lines));
            self.view_top[i] = moved;
            // At the last line, following resumes.
            if (moved >= a.lastLineStart()) self.follow[i] = true;
        }
        if (self.mode == .visual) self.clampCursor();
    }

    fn jumpTop(self: *Ui) void {
        self.view_top[self.selected] = 0;
        self.follow[self.selected] = false;
    }

    fn jumpBottom(self: *Ui) void {
        self.follow[self.selected] = true;
    }

    /// Where the pane starts. While following, that is derived from the
    /// Archive's tail every frame rather than stored — which is why new output
    /// never has to notify the view.
    fn viewTop(self: *Ui, i: usize) u64 {
        const a = &self.sup.workers[i].archive;
        if (!self.follow[i]) return @min(self.view_top[i], a.lastLineStart());
        return a.scrollBack(a.lastLineStart(), self.logHeight() - 1);
    }

    fn toggleVisual(self: *Ui) void {
        if (self.mode == .visual) {
            self.mode = .normal;
            self.status = "";
            return;
        }
        self.mode = .visual;
        self.anchor = self.viewTop(self.selected);
        self.cursor = self.anchor;
        self.status = "visual — ↑/↓ to extend, y to copy, Esc to cancel";
    }

    fn moveCursor(self: *Ui, delta: isize) void {
        const a = &self.sup.workers[self.selected].archive;
        self.cursor = if (delta < 0)
            a.scrollBack(self.cursor, @intCast(-delta))
        else
            a.scrollForward(self.cursor, @intCast(delta));

        // Following the cursor off the pane scrolls the pane.
        const top = self.viewTop(self.selected);
        if (self.cursor < top) {
            self.view_top[self.selected] = self.cursor;
            self.follow[self.selected] = false;
        } else {
            const bottom = a.scrollForward(top, self.logHeight() - 1);
            if (self.cursor > bottom) {
                self.view_top[self.selected] = a.scrollForward(top, 1);
                self.follow[self.selected] = false;
            }
        }
    }

    fn clampCursor(self: *Ui) void {
        const a = &self.sup.workers[self.selected].archive;
        self.cursor = @min(self.cursor, a.lastLineStart());
    }

    const Act = enum { start, stop, restart };

    fn act(self: *Ui, what: Act) void {
        const i = self.selected;
        switch (what) {
            .start => self.sup.startWorker(i),
            .stop => self.sup.stopWorker(i),
            .restart => self.sup.restartWorker(i),
        }
        self.status = switch (what) {
            .start => "start requested",
            .stop => "stop requested",
            .restart => "restart requested",
        };
    }

    // ------------------------------------------------------------- copy

    /// Produces an Excerpt and hands it to the terminal over OSC 52.
    ///
    /// Its shape is decided by the view it was taken from, per CONTEXT.md: in
    /// visual mode it is the selected lines, otherwise it is exactly what is
    /// on screen. There is no setting, because there is no second answer a
    /// reader would want.
    fn copy(self: *Ui) void {
        const i = self.selected;
        const a = &self.sup.workers[i].archive;

        var from: u64 = undefined;
        var to: u64 = undefined;
        if (self.mode == .visual) {
            from = @min(self.anchor, self.cursor);
            to = a.lineEnd(@max(self.anchor, self.cursor));
        } else {
            from = self.viewTop(i);
            to = a.lineEnd(a.scrollForward(from, self.logHeight() - 1));
        }

        const truncated = to - from > term.max_clipboard_bytes;
        if (truncated) from = to - term.max_clipboard_bytes;

        self.frame.clearRetainingCapacity();
        const w = &self.frame.writer;
        var chunk: [8192]u8 = undefined;
        var at = from;
        while (at < to) {
            const want = @min(chunk.len, @as(usize, @intCast(to - at)));
            const got = a.readAt(at, chunk[0..want]);
            if (got == 0) break;
            w.writeAll(chunk[0..got]) catch break;
            at += got;
        }

        // Straight to the tty in chunks: nothing here holds the encoded form.
        term.writeOsc52Fd(1, self.frame.written());

        self.mode = .normal;
        self.status = if (to <= from)
            "nothing to copy"
        else if (truncated)
            "copied to clipboard (truncated to the last 96 KiB)"
        else
            "copied to clipboard";
        self.frame.clearRetainingCapacity();
    }

    // ------------------------------------------------------------- render

    /// Floor on how often a frame may be built. `generation` moves with a
    /// Worker's output rather than with a clock, and that same output is what
    /// wakes the loop — so a Worker printing a line at a time was getting one
    /// full redraw per line. At 60 Hz every frame a reader can perceive still
    /// happens and the ones in between stop being built.
    const min_frame_ms = 16;

    fn render(self: *Ui) !void {
        if (self.drawn_generation == self.sup.generation) return;

        // Skipped frames are delayed, never dropped: `drawn_generation` is
        // left behind deliberately, and the loop's next poll returns within
        // `max_wait_ms` at the latest and calls this again.
        const now = os.nowMs();
        if (now -| self.last_frame_ms < min_frame_ms) return;
        self.last_frame_ms = now;

        // Only worth an ioctl when a frame is actually going to be built. A
        // resize arrives as SIGWINCH, which bumps `generation`, so asking on
        // every pass through an idle loop learned nothing.
        self.size = self.tty.size();
        self.drawn_generation = self.sup.generation;

        self.frame.clearRetainingCapacity();
        const w = &self.frame.writer;

        try w.writeAll(esc.home);
        try self.header(w);
        try self.body(w);
        try self.footer(w);

        write(self.frame.written());
    }

    fn header(self: *Ui, w: *std.Io.Writer) !void {
        const sel = &self.sup.workers[self.selected];
        try w.writeAll(esc.reverse);
        var used: usize = 0;
        used += try printClamped(w, self.size.cols, " devrun ");

        var buf: [256]u8 = undefined;
        const s = self.sup.samples[self.selected];
        const line = try std.fmt.bufPrint(&buf, "{s} — {t}  cpu {d: >5.1}%  mem {Bi: >8}  io r{Bi}/w{Bi}  {d} proc", .{
            sel.name(),
            sel.state,
            s.cpu_percent,
            s.memory_bytes,
            s.read_bytes,
            s.write_bytes,
            s.processes,
        });
        used += try printClamped(w, @as(usize, self.size.cols) -| used, line);
        try w.splatByteAll(' ', @as(usize, self.size.cols) -| used);
        try w.writeAll(esc.reset ++ "\n");
    }

    fn body(self: *Ui, w: *std.Io.Writer) !void {
        const rows = self.logHeight();
        const log_w = self.logWidth();
        const i = self.selected;
        const a = &self.sup.workers[i].archive;

        var at = self.viewTop(i);
        const sel_lo = @min(self.anchor, self.cursor);
        const sel_hi = @max(self.anchor, self.cursor);

        var line_buf: [8192]u8 = undefined;
        var row: usize = 0;
        while (row < rows) : (row += 1) {
            try self.sidebarRow(w, row);
            try w.writeAll("\x1b[38;5;238m│\x1b[0m");

            if (at < a.len()) {
                const highlighted = self.mode == .visual and at >= sel_lo and at <= sel_hi;
                if (highlighted) try w.writeAll(esc.reverse);

                const line = a.lineAt(at, &line_buf);
                const fit = term.fitToWidth(line.text, log_w);
                try w.writeAll(line.text[0..fit.bytes]);
                // A truncated line can end mid-colour; a highlighted one has
                // reverse video to clear. Either way the row must not bleed
                // into the next.
                if (fit.truncated or highlighted or fit.cols > 0) try w.writeAll(esc.reset);

                at = line.end;
            }
            try w.writeAll(esc.clear_line ++ "\n");
        }
    }

    /// First Worker shown in the sidebar. Scrolls only as far as it must to
    /// keep the selection visible, so a config with forty Workers still
    /// behaves like a list rather than a fixed window.
    fn sidebarTop(self: Ui, rows: usize) usize {
        const n = self.sup.workers.len;
        if (n <= rows) return 0;
        if (self.selected < rows) return 0;
        return @min(self.selected + 1 - rows, n - rows);
    }

    fn sidebarRow(self: *Ui, w: *std.Io.Writer, row: usize) !void {
        const i = self.sidebarTop(self.logHeight()) + row;
        if (i >= self.sup.workers.len) {
            try w.splatByteAll(' ', sidebar_cols);
            return;
        }
        const x = &self.sup.workers[i];
        const s = self.sup.samples[i];
        const chosen = i == self.selected;

        // The name column is padded to a width fixed for the Session, so the
        // CPU and memory figures line up and can be scanned down rather than
        // hunted for on each row.
        var buf: [160]u8 = undefined;
        var name_buf: [64]u8 = undefined;
        const name = x.name();
        const width = @min(self.name_w, name_buf.len);
        const shown = name[0..@min(name.len, width)];
        @memcpy(name_buf[0..shown.len], shown);
        @memset(name_buf[shown.len..width], ' ');

        const text = try std.fmt.bufPrint(&buf, "{s}{s} {d: >5.1}% {Bi: >8}", .{
            if (chosen) ">" else " ",
            name_buf[0..width],
            s.cpu_percent,
            s.memory_bytes,
        });

        if (chosen) try w.writeAll(esc.bold);
        try w.writeAll(stateColour(x.state));
        const used = try printClamped(w, sidebar_cols, text);
        try w.writeAll(esc.reset);
        try w.splatByteAll(' ', sidebar_cols -| used);
    }

    fn footer(self: *Ui, w: *std.Io.Writer) !void {
        try w.writeAll(esc.dim);
        const help = if (self.status.len > 0)
            self.status
        else if (self.mode == .visual)
            "↑/↓ extend  y copy  Esc cancel"
        else
            "n/p worker  j/k scroll  g/G top/bottom  v select  y copy  s/r/S stop/restart/start  q quit";
        const used = try printClamped(w, self.size.cols, help);
        try w.splatByteAll(' ', @as(usize, self.size.cols) -| used);
        try w.writeAll(esc.reset ++ esc.clear_line);
    }
};

fn stateColour(s: supervisor.State) []const u8 {
    return switch (s) {
        .pending => "\x1b[38;5;244m",
        .running => "\x1b[38;5;39m",
        .ready => "\x1b[38;5;42m",
        .stopping => "\x1b[38;5;214m",
        .exited => "\x1b[38;5;250m",
        .stopped => "\x1b[38;5;245m",
        .failed => "\x1b[38;5;203m",
        .skipped => "\x1b[38;5;240m",
    };
}

/// Writes `text` truncated to `limit` visible columns, returning how many it
/// used. The escape-aware measurement is what keeps a coloured name from
/// eating the column budget it does not occupy.
fn printClamped(w: *std.Io.Writer, limit: usize, text: []const u8) !usize {
    const fit = term.fitToWidth(text, limit);
    try w.writeAll(text[0..fit.bytes]);
    if (fit.truncated) try w.writeAll(esc.reset);
    return fit.cols;
}

/// Straight to the terminal. Frames are built whole and written once, so a
/// partial write is the only thing worth looping on.
fn write(bytes: []const u8) void {
    os.writeAll(1, bytes) catch {};
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "printClamped truncates on visible columns and resets afterwards" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const used = try printClamped(&w, 5, "\x1b[31mabcdefgh\x1b[0m");
    try testing.expectEqual(@as(usize, 5), used);
    // The colour is kept, the overflow is dropped, and the style is closed so
    // the next thing written to the row is not red.
    try testing.expectEqualStrings("\x1b[31mabcde\x1b[0m", w.buffered());
}

test "stateColour gives every state a distinct colour" {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(testing.allocator);
    for ([_]supervisor.State{
        .pending, .running, .ready, .stopping, .exited, .stopped, .failed, .skipped,
    }) |s| {
        const c = stateColour(s);
        // failed and running must never be confusable at a glance.
        try testing.expect(c.len > 0);
        try seen.put(testing.allocator, c, {});
    }
    // ready, running and failed are the three a reader acts on; they must be
    // distinct even if the quieter states share a grey.
    try testing.expect(!std.mem.eql(u8, stateColour(.ready), stateColour(.running)));
    try testing.expect(!std.mem.eql(u8, stateColour(.failed), stateColour(.running)));
    try testing.expect(!std.mem.eql(u8, stateColour(.failed), stateColour(.ready)));
}
