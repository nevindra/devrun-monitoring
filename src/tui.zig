//! The interactive view: a Worker list, a log pane, line picking, and copy.
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
//!
//! ## What the view is for
//!
//! Three jobs, and the layout is spent on those three: read the log, take
//! lines out of it, and see which Worker is working. Everything drawn beside
//! the log earns its columns against one of them or is not drawn.
//!
//! Two rules keep it legible on a terminal whose colours belong to somebody
//! else. **Hue carries meaning** — a Worker's state, and the lines the reader
//! picked — and nothing else is allowed a colour. **Structure is dim**: the
//! divider, every label, every key, so they recede into whatever theme the
//! terminal already has instead of fighting it. And every state is said three
//! ways at once, as a shape, a word and a colour, so none of the three has to
//! be the one that works.

const std = @import("std");
const os = @import("os.zig");
const term = @import("term.zig");
const control = @import("control.zig");
const supervisor = @import("supervisor.zig");
const sample_mod = @import("sample.zig");

const Supervisor = supervisor.Supervisor;
const esc = term.esc;
const Allocator = std.mem.Allocator;

/// Hue is reserved for meaning. These are the only colours the view emits,
/// and every one of them answers "what is true of this Worker?" or "what did
/// the reader pick?" — never "where does this box end?".
const paint = struct {
    const waiting = "\x1b[38;5;103m";
    const running = "\x1b[38;5;111m";
    const ready = "\x1b[38;5;78m";
    const stopping = "\x1b[38;5;179m";
    const finished = "\x1b[38;5;108m";
    const stopped = "\x1b[38;5;245m";
    const failed = "\x1b[38;5;210m";
    const skipped = "\x1b[38;5;240m";

    /// The lines the reader picked. Purple appears nowhere else in the view,
    /// so a lilac mark down the log's margin can only mean one thing.
    const picked = "\x1b[38;5;141m";

    /// The selected row of the table, as a bar across it. The same purple
    /// family as `picked`, because it is the same idea — this is the one you
    /// chose. Background *and* foreground are set together so the bar reads
    /// the same on a light terminal as on a dark one.
    const row_on = "\x1b[48;5;60m\x1b[38;5;255m";
    /// Back to the bar's own foreground after a cell has coloured itself.
    const row_fg = "\x1b[38;5;255m";

    /// The load rail, warming as a Group works harder. It shares its top end
    /// with `failed` on purpose: hot and broken are both "look here".
    const load_low = "\x1b[38;5;65m";
    const load_mid = "\x1b[38;5;179m";
    const load_high = "\x1b[38;5;210m";
};

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

/// What the footer offers and what a click on it does. Named for the thing
/// that happens, not for the key that triggers it — the key is a shortcut to
/// the action, not the other way round.
const Action = enum { copy, next, restart, stop, help, quit };

const Chip = struct {
    key: []const u8,
    label: []const u8,
    action: Action,

    fn width(self: Chip) usize {
        return self.key.len + 1 + self.label.len;
    }
};

/// The control surface, in the order a reader meets it. Copy is first because
/// it is the job most people opened this for.
const chips = [_]Chip{
    .{ .key = "y", .label = "Copy", .action = .copy },
    .{ .key = "Tab", .label = "Switch", .action = .next },
    .{ .key = "r", .label = "Restart", .action = .restart },
    .{ .key = "s", .label = "Stop", .action = .stop },
    .{ .key = "?", .label = "Keys", .action = .help },
    .{ .key = "q", .label = "Quit", .action = .quit },
};

/// Which chips give up their columns first on a narrow terminal, least useful
/// first. Copy, Keys and Quit are never dropped: the first is the point of the
/// view, and the other two are how someone gets un-stuck.
const chip_drop_order = [_]usize{ 3, 2, 1 };

/// How the screen is divided this frame. Recomputed rather than stored,
/// because it is arithmetic over the terminal size and a stale copy of it is a
/// click landing on the wrong Worker.
const Layout = struct {
    /// Every row is a 1-based terminal row, so a mouse report can be compared
    /// against these directly.
    ///
    ///     1              the Session line
    ///     table_top      ┌─ services ─────┐
    ///     table_header     NAME  STATUS …
    ///     service_first  │ ● api  running │   × service_rows
    ///     log_top        ├─ api · path ───┤
    ///     log_first      │ log bytes …    │   × log_rows
    ///     rows           the footer
    table_top: u16,
    table_header: u16,
    service_first: u16,
    service_rows: usize,
    log_top: u16,
    log_first: u16,
    log_rows: usize,

    /// Which columns of the table survived this width.
    name_w: usize,
    status: bool,
    uptime: bool,
    memory: bool,
    proc: bool,
    restarts: bool,
    exit: bool,

    /// Whether there is a row to spare for the memory breakdown under the
    /// table.
    detail: bool,

    /// Columns the log text itself gets, inside the border and the margin the
    /// picked-line mark lives in.
    log_w: usize,

    /// `│ ` on the left and ` │` on the right of every row inside a box.
    const frame = 4;
    /// The state shape and the space after it.
    const glyph = 2;

    /// Column widths, each including the single space that separates it from
    /// the one before. Sized to their widest possible contents: "stopping",
    /// "999d 23h", "128 MB", "300.5%" behind its meter, and a signal name.
    const status_w = 9;
    const uptime_w = 9;
    const memory_w = 10;
    /// How many processes the memory figure beside it is a total over. Narrow
    /// on purpose: it is there so a Group total cannot be mistaken for one
    /// process's, not because the count itself is interesting.
    const proc_w = 6;
    const cpu_w = 9;
    const restarts_w = 9;
    /// Wide enough for the words rather than the numbers. "killed" is what
    /// happened; `137` is what a shell would have said about it, and needing
    /// to look that up is the whole problem.
    const exit_w = 11;

    fn tableWidth(self: Layout) usize {
        return glyph + self.name_w + cpu_w +
            (if (self.status) @as(usize, status_w) else 0) +
            (if (self.uptime) @as(usize, uptime_w) else 0) +
            (if (self.memory) @as(usize, memory_w) else 0) +
            (if (self.proc) @as(usize, proc_w) else 0) +
            (if (self.restarts) @as(usize, restarts_w) else 0) +
            (if (self.exit) @as(usize, exit_w) else 0);
    }
};

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
    /// First line of the picked range, as an absolute offset.
    anchor: u64 = 0,
    /// Line the cursor is on while picking.
    cursor: u64 = 0,
    /// How many lines are currently picked. Cached rather than counted per
    /// frame: the walk is O(lines picked) and the answer only changes when the
    /// reader moves an end of the range.
    picked_lines: usize = 0,

    help: bool = false,

    frame: std.Io.Writer.Allocating,
    gpa: Allocator,

    /// Redrawn only when something changed. Compared against the supervisor's
    /// generation counter, so a quiet Session costs one poll wake-up and no
    /// terminal traffic at all.
    drawn_generation: u64 = std.math.maxInt(u64),
    /// When the last frame was built, for the rate cap in `render`.
    last_frame_ms: u64 = 0,

    /// The transient line in the footer — what just happened, in words. Held
    /// in the Ui rather than pointed at, because most of these are formatted
    /// with a count or a path in them.
    status_buf: [320]u8 = undefined,
    status_len: usize = 0,
    status_tone: []const u8 = "",

    /// Where each chip was drawn last frame, so a click can be matched back to
    /// one. Zero means the chip was not shown at this width.
    chip_col: [chips.len]u16 = @splat(0),
    chip_w: [chips.len]u16 = @splat(0),

    exit_code: u8 = 0,
    /// The longest Worker name, which sets the name column for the Session so
    /// the figures beside it form columns instead of drifting per row.
    widest_name: usize,

    fn init(gpa: Allocator, sup: *Supervisor, tty: *term.Terminal) !Ui {
        const n = sup.workers.len;
        var widest: usize = 0;
        for (sup.workers) |x| widest = @max(widest, x.name().len);
        return .{
            .widest_name = widest,
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
        write(esc.alt_screen_on ++ esc.cursor_hide ++ esc.clear ++ esc.mouse_on);
    }

    fn leave(self: *Ui) void {
        write(esc.mouse_off ++ esc.alt_screen_off ++ esc.cursor_show ++ esc.reset);
        self.tty.restore();
    }

    fn logHeight(self: Ui) usize {
        return self.layout().log_rows;
    }

    /// Divides the screen: a table of services above, that Worker's log below.
    ///
    /// The log takes the full width because that is what it is for — a JSON
    /// line or a stack trace is long, and the columns a list of names was
    /// holding onto were columns the content needed. Going wide costs rows
    /// instead, so the table is capped: it never takes more than a third of
    /// what is left, and scrolls within that when a config has more Workers
    /// than the cap.
    ///
    /// Table columns give way right-to-left as the terminal narrows, in order
    /// of how often a reader acts on them. CPU and the name never go.
    fn layout(self: Ui) Layout {
        const cols: usize = @max(self.size.cols, 24);
        const rows: usize = @max(self.size.rows, 6);
        // Every column carries the space that separates it from the next one,
        // so a name that fills its cell exactly still has a gap after it.
        // Without the extra column, "migrate" ran straight into "finished".
        const min_name = 7;

        var l: Layout = .{
            .table_top = 2,
            .table_header = 3,
            .service_first = 4,
            .service_rows = 0,
            .log_top = 0,
            .log_first = 0,
            .log_rows = 0,
            .name_w = std.math.clamp(self.widest_name + 1, min_name, 19),
            .status = true,
            .uptime = true,
            .memory = true,
            .proc = true,
            .restarts = true,
            .exit = true,
            .detail = false,
            .log_w = 0,
        };

        while (l.tableWidth() + Layout.frame > cols) {
            if (l.exit) {
                l.exit = false;
            } else if (l.restarts) {
                l.restarts = false;
            } else if (l.proc) {
                // Goes before uptime, and always before memory: it explains
                // the memory figure rather than carrying anything of its own,
                // so it must never be the column left standing alone.
                l.proc = false;
            } else if (l.uptime) {
                l.uptime = false;
            } else if (l.memory) {
                l.memory = false;
            } else if (l.status) {
                l.status = false;
            } else if (l.name_w > min_name) {
                l.name_w -= 1;
            } else break;
        }

        // One row under the table for what the selected Worker's memory is
        // made of. It is the first thing to go on a short terminal: the log is
        // what the view is for, and an explanation of a figure is worth less
        // than another line of the thing being explained.
        l.detail = rows >= 14;

        // The Session line, the table's border and header, the log's border,
        // the footer, and the breakdown when it is shown. Everything else is
        // content.
        const chrome: usize = if (l.detail) 6 else 5;
        const content = rows -| chrome;
        const cap = @max(3, content / 3);
        l.service_rows = @min(self.sup.workers.len, @min(cap, content -| 1));
        l.service_rows = @max(l.service_rows, 1);

        l.log_top = @intCast(l.service_first + l.service_rows + @intFromBool(l.detail));
        l.log_first = l.log_top + 1;
        l.log_rows = @max(1, content -| l.service_rows);
        // The margin the picked-line mark lives in, inside the border.
        l.log_w = cols -| (Layout.frame + 1);
        return l;
    }

    // ------------------------------------------------------------- input

    /// Returns true when the user is finished with the Session.
    fn readKeys(self: *Ui) bool {
        var buf: [4096]u8 = undefined;
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

        // The help pane is a detour, not a mode: anything that is not "go
        // back" would otherwise act on a view the reader cannot see.
        if (self.help) {
            switch (key) {
                .escape => self.help = false,
                .char => |c| switch (c) {
                    '?', 'q' => self.help = false,
                    else => {},
                },
                .mouse => |m| if (m.kind == .press) {
                    self.help = false;
                },
                else => {},
            }
            return false;
        }

        switch (key) {
            .char => |c| switch (c) {
                'q' => return self.requestQuit(),
                'j' => self.scroll(1),
                'k' => self.scroll(-1),
                'g' => self.jumpTop(),
                'G' => self.jumpBottom(),
                'n' => self.selectBy(1),
                'p' => self.selectBy(-1),
                '\t' => self.selectBy(1),
                'v' => self.togglePick(),
                'y' => self.copy(),
                's' => self.act(.stop),
                'r' => self.act(.restart),
                'S' => self.act(.start),
                '?' => self.help = true,
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
            .escape => self.clearPick(),
            .mouse => |m| return self.onMouse(m),
            else => {},
        }
        return false;
    }

    /// First press asks politely; the Session shuts down and the view stays up
    /// so the reader can watch it happen. Second press stops waiting.
    fn requestQuit(self: *Ui) bool {
        if (self.sup.shutting_down) return true;
        self.sup.beginShutdown();
        self.setStatus("", "Shutting everything down — press q again to leave now", .{});
        return false;
    }

    fn selectBy(self: *Ui, delta: isize) void {
        const n = self.sup.workers.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.selected);
        self.selected = @intCast(@mod(cur + delta, @as(isize, @intCast(n))));
        self.clearPick();
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

    /// The absolute offset of the line drawn on body row `row`.
    fn lineAtRow(self: *Ui, row: usize) u64 {
        const a = &self.sup.workers[self.selected].archive;
        return a.scrollForward(self.viewTop(self.selected), row);
    }

    fn togglePick(self: *Ui) void {
        if (self.mode == .visual) return self.clearPick();
        self.mode = .visual;
        self.anchor = self.viewTop(self.selected);
        self.cursor = self.anchor;
        self.refreshPick();
    }

    fn clearPick(self: *Ui) void {
        self.mode = .normal;
        self.picked_lines = 0;
        self.status_len = 0;
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
        self.refreshPick();
    }

    fn clampCursor(self: *Ui) void {
        const a = &self.sup.workers[self.selected].archive;
        self.cursor = @min(self.cursor, a.lastLineStart());
        self.refreshPick();
    }

    /// Recounts the picked lines. Called when an end of the range moves, never
    /// per frame — the count is what the footer promises the reader is about
    /// to land on their clipboard, so it has to be a real count rather than an
    /// estimate, and a real count means walking.
    fn refreshPick(self: *Ui) void {
        if (self.mode != .visual) {
            self.picked_lines = 0;
            return;
        }
        self.picked_lines = self.countLines(
            @min(self.anchor, self.cursor),
            @max(self.anchor, self.cursor),
        );
        self.status_len = 0;
    }

    /// Lines from the one starting at `lo` through the one starting at `hi`,
    /// counted rather than estimated: this number is the promise the footer
    /// makes about what is going to land on the clipboard.
    ///
    /// The range only ever grows a line at a time or a screen at a time, so
    /// the cap is unreachable in practice. It is here so that no sequence of
    /// keystrokes can turn a redraw into an unbounded walk.
    fn countLines(self: *Ui, lo: u64, hi: u64) usize {
        const a = &self.sup.workers[self.selected].archive;
        var count: usize = 1;
        var at = lo;
        while (at < hi and count < 10_000) : (count += 1) at = a.lineEnd(at);
        return count;
    }

    // ------------------------------------------------------------- mouse

    /// Hit-tests a pointer event against the grid the last frame was drawn on.
    ///
    /// Worth the code: reaching for the mouse is the first thing someone does
    /// in a window they have not been taught, and a view that answers that
    /// with nothing has told them it is not for them.
    fn onMouse(self: *Ui, m: term.Mouse) bool {
        const lay = self.layout();
        const rows = self.size.rows;

        // Two ranges, because the table's box is taller than its rows: the
        // breakdown line sits inside the border but names no Worker. The wheel
        // treats the whole box as the table, while a click only lands on a row
        // that actually has a service on it — otherwise clicking the breakdown
        // would select whichever Worker happened to be next in a scrolled list.
        const in_table = m.row >= lay.service_first and m.row < lay.log_top;
        const service_last: u16 = lay.service_first +| @as(u16, @intCast(lay.service_rows)) -| 1;
        const on_service = m.row >= lay.service_first and m.row <= service_last;
        const log_last: u16 = rows -| 1;
        const in_log = m.row >= lay.log_first and m.row <= log_last;

        switch (m.kind) {
            // Over the table the wheel walks the table; over the log it
            // scrolls the log. Each does what the thing under the pointer is
            // made of.
            .wheel_up, .wheel_down => {
                const down = m.kind == .wheel_down;
                if (in_table) {
                    self.selectBy(if (down) 1 else -1);
                } else {
                    self.scroll(if (down) 3 else -3);
                }
            },

            .press => {
                if (m.row == rows) return self.clickFooter(m.col);
                if (on_service) {
                    const i = self.serviceTop(lay.service_rows) + (m.row - lay.service_first);
                    if (i < self.sup.workers.len) {
                        self.selected = i;
                        self.clearPick();
                    }
                    return false;
                }
                // Inside the table's box but not on a service — the breakdown
                // line. Not a miss to report, just nothing to do.
                if (in_table) return false;
                if (!in_log) return false;
                const line = self.lineAtRow(m.row - lay.log_first);
                self.mode = .visual;
                self.anchor = line;
                self.cursor = line;
                self.refreshPick();
            },

            .drag => {
                if (self.mode != .visual) return false;
                // Dragging past an edge keeps going, which is how a range
                // longer than the pane gets picked at all.
                if (m.row <= lay.log_first) {
                    self.scroll(-1);
                } else if (m.row >= log_last) {
                    self.scroll(1);
                }
                const last: i32 = @intCast(lay.log_rows - 1);
                const row = std.math.clamp(@as(i32, m.row) - @as(i32, lay.log_first), 0, last);
                self.cursor = self.lineAtRow(@intCast(row));
                self.refreshPick();
            },

            .release => {},
        }
        return false;
    }

    fn clickFooter(self: *Ui, col: u16) bool {
        for (chips, 0..) |c, i| {
            const start = self.chip_col[i];
            if (start == 0) continue;
            if (col >= start and col < start + self.chip_w[i]) {
                return switch (c.action) {
                    .copy => blk: {
                        self.copy();
                        break :blk false;
                    },
                    .next => blk: {
                        self.selectBy(1);
                        break :blk false;
                    },
                    .restart => blk: {
                        self.act(.restart);
                        break :blk false;
                    },
                    .stop => blk: {
                        self.act(.stop);
                        break :blk false;
                    },
                    .help => blk: {
                        self.help = true;
                        break :blk false;
                    },
                    .quit => self.requestQuit(),
                };
            }
        }
        return false;
    }

    // ------------------------------------------------------------- acting

    const Act = enum { start, stop, restart };

    fn act(self: *Ui, what: Act) void {
        const i = self.selected;
        const name = self.sup.workers[i].name();
        switch (what) {
            .start => self.sup.startWorker(i),
            .stop => self.sup.stopWorker(i),
            .restart => self.sup.restartWorker(i),
        }
        switch (what) {
            .start => self.setStatus("", "Starting {s}", .{name}),
            .stop => self.setStatus("", "Stopping {s}", .{name}),
            .restart => self.setStatus("", "Restarting {s}", .{name}),
        }
    }

    fn setStatus(self: *Ui, tone: []const u8, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.status_buf, fmt, args) catch {
            self.status_len = 0;
            return;
        };
        self.status_len = s.len;
        self.status_tone = tone;
    }

    fn status(self: *const Ui) []const u8 {
        return self.status_buf[0..self.status_len];
    }

    /// The Archive directory as a reader would type it. A Session started in
    /// the current directory builds its paths from ".", and "./.devrun/logs"
    /// is a path with a stutter in it that nobody would write down.
    fn logDir(self: *const Ui) []const u8 {
        return trimCwdPrefix(self.sup.log_dir);
    }

    // ------------------------------------------------------------- copy

    /// Produces an Excerpt and hands it to the terminal over OSC 52.
    ///
    /// Its shape is decided by the view it was taken from, per CONTEXT.md:
    /// with lines picked it is those lines, otherwise it is exactly what is on
    /// screen. There is no setting, because there is no second answer a reader
    /// would want.
    fn copy(self: *Ui) void {
        const i = self.selected;
        const a = &self.sup.workers[i].archive;

        var from: u64 = undefined;
        var last: u64 = undefined;
        if (self.mode == .visual) {
            from = @min(self.anchor, self.cursor);
            last = @max(self.anchor, self.cursor);
        } else {
            from = self.viewTop(i);
            // The last line *on the pane*, which is not the last row when the
            // Worker has printed less than a screenful. Reporting the row
            // count there would promise more lines than went to the clipboard.
            last = a.scrollForward(from, self.logHeight() - 1);
        }
        const to = a.lineEnd(last);
        const lines = if (self.mode == .visual) self.picked_lines else self.countLines(from, last);

        const truncated = to - from > term.max_clipboard_bytes;
        if (truncated) from = to - term.max_clipboard_bytes;

        self.frame.clearRetainingCapacity();
        const w = &self.frame.writer;
        var filter: term.AnsiFilter = .{};
        var chunk: [8192]u8 = undefined;
        var at = from;
        while (at < to) {
            const want = @min(chunk.len, @as(usize, @intCast(to - at)));
            const got = a.readAt(at, chunk[0..want]);
            if (got == 0) break;
            filter.feed(w, chunk[0..got]) catch break;
            at += got;
        }

        // Straight to the tty in chunks: nothing here holds the encoded form.
        term.writeOsc52Fd(1, self.frame.written());

        const name = self.sup.workers[i].name();
        if (to <= from) {
            self.setStatus(paint.failed, "Nothing to copy yet — {s} has not printed anything", .{name});
        } else if (truncated) {
            // Say which end survived. A reader who wanted the start of a long
            // run and silently got the end would paste the wrong thing.
            self.setStatus(
                paint.stopping,
                "Copied the last 96 KB — too much to fit. The whole log is at {s}/{s}.log",
                .{ self.logDir(), name },
            );
        } else {
            self.setStatus(paint.picked, "Copied {d} line{s} — the whole log is at {s}/{s}.log", .{
                lines,
                if (lines == 1) "" else "s",
                self.logDir(),
                name,
            });
        }
        self.mode = .normal;
        self.picked_lines = 0;
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

        const lay = self.layout();
        self.frame.clearRetainingCapacity();
        const w = &self.frame.writer;

        try w.writeAll(esc.home);
        try self.sessionLine(w);
        if (self.help) {
            try self.helpPane(w, lay);
        } else {
            try self.table(w, lay);
            try self.logPane(w, lay);
        }
        try self.footer(w);

        write(self.frame.written());
    }

    /// The Session at a glance: what it is, and what the whole of it costs.
    ///
    /// The totals are the reading a per-Worker table cannot give — "is this
    /// repo the reason the fan is on" is a question about the sum, and adding
    /// a column of figures in your head is not answering it.
    fn sessionLine(self: *Ui, w: *std.Io.Writer) !void {
        var running: usize = 0;
        var ram: u64 = 0;
        var cpu: f32 = 0;
        for (self.sup.workers, self.sup.samples) |x, s| {
            if (!x.state.alive()) continue;
            running += 1;
            ram += s.memory_bytes;
            cpu += s.cpu_percent;
        }

        var left_buf: [256]u8 = undefined;
        var left: std.Io.Writer = .fixed(&left_buf);
        try left.print(" {s}devrun{s}", .{ esc.bold, esc.weight_off });
        if (self.sup.project.len > 0) {
            try left.print("  {s}{s}{s}", .{ esc.dim, self.sup.project, esc.weight_off });
        }

        var right_buf: [256]u8 = undefined;
        var right: std.Io.Writer = .fixed(&right_buf);
        var ram_buf: [32]u8 = undefined;
        try right.print("{d} of {d} {s}running{s}   {s}RAM{s} {s}   {s}CPU{s} {d:.1}% ", .{
            running,                 self.sup.workers.len,
            esc.dim,                 esc.weight_off,
            esc.dim,                 esc.weight_off,
            humanBytes(&ram_buf, ram),
            esc.dim,                 esc.weight_off,
            cpu,
        });

        const cols: usize = self.size.cols;
        var used = try printClamped(w, cols, left.buffered());
        const want = term.fitToWidth(right.buffered(), cols).cols;
        if (used + want + 2 <= cols) {
            try w.splatByteAll(' ', cols - used - want);
            used = cols - want;
            used += try printClamped(w, want, right.buffered());
        }
        try w.splatByteAll(' ', cols -| used);
        try w.writeAll(esc.reset ++ esc.clear_line ++ "\n");
    }

    /// The services, as a table: one row each, columns that line up, and a
    /// header saying what they are. Reading down a column is the point — which
    /// is busiest, which has restarted, which never came up.
    fn table(self: *Ui, w: *std.Io.Writer, lay: Layout) !void {
        const cols: usize = self.size.cols;
        const n = self.sup.workers.len;

        var title_buf: [64]u8 = undefined;
        const top = self.serviceTop(lay.service_rows);
        // Say so when the list is longer than the box, and where in it we are.
        const title = if (n > lay.service_rows)
            std.fmt.bufPrint(&title_buf, "services {d}-{d} of {d}", .{
                top + 1,
                @min(top + lay.service_rows, n),
                n,
            }) catch "services"
        else
            "services";
        try rule(w, cols, "┌", "┐", title, "");

        // Column headers, dim: they label the data without competing with it.
        try w.writeAll(esc.dim ++ "│ ");
        var used: usize = 0;
        try w.splatByteAll(' ', Layout.glyph);
        used += Layout.glyph;
        used += try heading(w, lay.name_w, "NAME", .left);
        if (lay.status) used += try heading(w, Layout.status_w, "STATUS", .left);
        if (lay.uptime) used += try heading(w, Layout.uptime_w, "UPTIME", .right);
        if (lay.memory) used += try heading(w, Layout.memory_w, "MEMORY", .right);
        if (lay.proc) used += try heading(w, Layout.proc_w, "PROC", .right);
        used += try heading(w, Layout.cpu_w, "CPU", .right);
        if (lay.restarts) used += try heading(w, Layout.restarts_w, "RESTARTS", .right);
        if (lay.exit) used += try heading(w, Layout.exit_w, "EXIT", .right);
        try w.splatByteAll(' ', cols -| (used + Layout.frame));
        try w.writeAll(" │" ++ esc.reset ++ esc.clear_line ++ "\n");

        var row: usize = 0;
        while (row < lay.service_rows) : (row += 1) {
            try self.serviceRow(w, top + row, lay);
        }
        if (lay.detail) try self.detailRow(w);
    }

    /// What the selected Worker's memory figure is made of.
    ///
    /// A total over a tree with nothing visible under it is a number a reader
    /// has to take on faith, and this one is easy to disbelieve: a service
    /// whose launcher holds 38 MB reports 1.6 GB, because the two Python
    /// processes it started hold the rest. Naming them turns the figure from
    /// something that looks wrong into something that reads as obvious.
    ///
    /// The parts add up to the total exactly — both are PSS, summed over the
    /// same live set — so a reader who checks the arithmetic finds it holds.
    fn detailRow(self: *Ui, w: *std.Io.Writer) !void {
        const cols: usize = self.size.cols;
        try w.writeAll(esc.dim ++ "│  memory" ++ esc.weight_off);
        var used: usize = 9;

        const i = self.selected;
        const x = &self.sup.workers[i];

        if (!x.state.alive()) {
            try w.writeAll(esc.dim);
            used += 2 + try printClamped(w, cols -| (used + 4), "  nothing running");
            try w.writeAll(esc.weight_off);
        } else {
            var procs: [8]sample_mod.ProcInfo = undefined;
            const n = self.sup.sampler.breakdown(i, &procs);

            var total: u64 = 0;
            for (procs[0..n]) |p| total += p.memory_bytes;

            var head_buf: [96]u8 = undefined;
            var size_buf: [24]u8 = undefined;
            const head = if (n == 0)
                "  measuring"
            else if (n == 1)
                std.fmt.bufPrint(&head_buf, "  {s} in one process", .{
                    humanBytes(&size_buf, total),
                }) catch "  ?"
            else
                std.fmt.bufPrint(&head_buf, "  {s} across {d} processes", .{
                    humanBytes(&size_buf, total), n,
                }) catch "  ?";
            used += try printClamped(w, cols -| (used + 2), head);

            // Named largest-first, and only as many as the width will take
            // whole: a part cut in half would be read as a figure rather than
            // as a truncation. Formatted before any are written, because
            // whether the last one fits depends on whether an ellipsis has to
            // follow it — a list that quietly stops is a list claiming to be
            // complete.
            if (n > 1) {
                var item_buf: [procs.len][48]u8 = undefined;
                var items: [procs.len][]const u8 = undefined;
                for (procs[0..n], 0..) |p, k| {
                    var each_buf: [24]u8 = undefined;
                    items[k] = std.fmt.bufPrint(&item_buf[k], "   {s} {s}", .{
                        p.name(), humanBytes(&each_buf, p.memory_bytes),
                    }) catch "";
                }

                var fits: usize = 0;
                var width: usize = 0;
                while (fits < n) {
                    // Two columns held back for " …" whenever parts remain.
                    const tail: usize = if (fits + 1 < n) 2 else 0;
                    if (used + width + items[fits].len + tail + 2 > cols) break;
                    width += items[fits].len;
                    fits += 1;
                }

                try w.writeAll(esc.dim);
                for (items[0..fits]) |item| {
                    try w.writeAll(item);
                    used += item.len;
                }
                if (fits < n) {
                    try w.writeAll(" …");
                    used += 2;
                }
                try w.writeAll(esc.weight_off);
            }
        }

        try w.splatByteAll(' ', cols -| (used + 1));
        try w.writeAll(esc.dim ++ "│" ++ esc.reset ++ esc.clear_line ++ "\n");
    }

    /// First Worker shown. Scrolls only as far as it must to keep the
    /// selection visible, so a config with forty Workers still behaves like a
    /// list rather than a fixed window.
    fn serviceTop(self: Ui, rows: usize) usize {
        const n = self.sup.workers.len;
        if (n <= rows) return 0;
        if (self.selected < rows) return 0;
        return @min(self.selected + 1 - rows, n - rows);
    }

    fn serviceRow(self: *Ui, w: *std.Io.Writer, i: usize, lay: Layout) !void {
        const cols: usize = self.size.cols;
        try w.writeAll(esc.dim ++ "│" ++ esc.reset);

        if (i >= self.sup.workers.len) {
            try w.splatByteAll(' ', cols -| 2);
            try w.writeAll(esc.dim ++ "│" ++ esc.reset ++ esc.clear_line ++ "\n");
            return;
        }
        const x = &self.sup.workers[i];
        const s = self.sup.samples[i];
        const chosen = i == self.selected;
        const busy = x.state.alive();

        // The selected row is a bar all the way across the table. On a list
        // this wide, weight alone stopped being enough to find your place.
        // It opens against the border and closes against it, so the bar is a
        // band rather than something floating inside the box.
        if (chosen) try w.writeAll(paint.row_on);
        try w.writeByte(' ');

        try w.writeAll(stateColour(x.state));
        try w.writeAll(stateGlyph(x.state));
        try w.writeAll(if (chosen) paint.row_fg else esc.fg_off);
        try w.writeByte(' ');
        var used: usize = Layout.glyph;

        used += try cell(w, lay.name_w, x.name(), .left);

        if (lay.status) {
            if (!chosen) try w.writeAll(stateColour(x.state));
            used += try cell(w, Layout.status_w, stateLabel(x.state), .left);
            if (!chosen) try w.writeAll(esc.fg_off);
        }

        var buf: [32]u8 = undefined;
        if (lay.uptime) {
            const since = if (busy)
                os.nowMs() -| x.started_ms
            else if (x.stopped_ms > x.started_ms and x.started_ms > 0)
                x.stopped_ms - x.started_ms
            else
                0;
            const text = if (x.has_started) uptimeText(&buf, since) else "-";
            if (!chosen and !busy) try w.writeAll(esc.dim);
            used += try cell(w, Layout.uptime_w, text, .right);
            if (!chosen and !busy) try w.writeAll(esc.weight_off);
        }
        if (lay.memory) {
            // A Worker that is not running is not using nothing; it is not
            // using. A column of `0 B` down a list of finished Gates is noise
            // on every row saying so.
            const text = if (busy) humanBytes(&buf, s.memory_bytes) else "-";
            if (!chosen and !busy) try w.writeAll(esc.dim);
            used += try cell(w, Layout.memory_w, text, .right);
            if (!chosen and !busy) try w.writeAll(esc.weight_off);
        }
        if (lay.proc) {
            // The count is what stops the memory figure beside it from being
            // read as one process's. A Worker is a tree, and "1.6 GB" over
            // four processes is a different fact from "1.6 GB" over one.
            const text = if (busy)
                std.fmt.bufPrint(&buf, "{d}", .{s.processes}) catch "?"
            else
                "-";
            if (!chosen) try w.writeAll(esc.dim);
            used += try cell(w, Layout.proc_w, text, .right);
            if (!chosen) try w.writeAll(esc.weight_off);
        }

        // CPU is a figure and a meter in one cell. The number is the answer to
        // "how much"; the block beside it is the answer to "which of these",
        // which is the question you actually have when scanning a column.
        {
            const pct = if (busy) s.cpu_percent else 0;
            if (!chosen) try w.writeAll(loadColour(pct));
            try w.writeAll(loadGlyph(pct));
            try w.writeAll(if (chosen) paint.row_fg else esc.fg_off);
            const text = if (busy)
                std.fmt.bufPrint(&buf, "{d:.1}%", .{pct}) catch "?"
            else
                "-";
            if (!chosen and !busy) try w.writeAll(esc.dim);
            used += 1 + try cell(w, Layout.cpu_w - 1, text, .right);
            if (!chosen and !busy) try w.writeAll(esc.weight_off);
        }

        if (lay.restarts) {
            const text = if (x.restarts > 0)
                std.fmt.bufPrint(&buf, "{d}", .{x.restarts}) catch "?"
            else
                "-";
            if (!chosen and x.restarts == 0) try w.writeAll(esc.dim);
            if (!chosen and x.restarts > 0) try w.writeAll(paint.stopping);
            used += try cell(w, Layout.restarts_w, text, .right);
            if (!chosen) try w.writeAll(esc.weight_off ++ esc.fg_off);
        }
        if (lay.exit) {
            const text = exitText(&buf, x.exit);
            const bad = if (x.exit) |e| !e.ok() else false;
            if (!chosen and bad) try w.writeAll(paint.failed);
            if (!chosen and !bad) try w.writeAll(esc.dim);
            used += try cell(w, Layout.exit_w, text, .right);
            if (!chosen) try w.writeAll(esc.weight_off ++ esc.fg_off);
        }

        try w.splatByteAll(' ', cols -| (used + Layout.frame));
        try w.writeAll(" ");
        if (chosen) try w.writeAll(esc.reset);
        try w.writeAll(esc.dim ++ "│" ++ esc.reset ++ esc.clear_line ++ "\n");
    }

    /// The selected Worker's log, full width, in a box that says whose it is
    /// and where it lives. That title is the answer to "can you send me this?"
    /// standing on screen the whole time rather than waiting to be asked for.
    fn logPane(self: *Ui, w: *std.Io.Writer, lay: Layout) !void {
        const cols: usize = self.size.cols;
        const i = self.selected;
        const a = &self.sup.workers[i].archive;

        var title_buf: [320]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s}{s}{s}  {s}{s}/{s}.log{s}", .{
            esc.bold,           self.sup.workers[i].name(), esc.weight_off,
            esc.dim,            self.logDir(),
            self.sup.workers[i].name(), esc.weight_off,
        }) catch self.sup.workers[i].name();
        try rule(w, cols, "├", "┤", title, "");

        var at = self.viewTop(i);
        const lo = @min(self.anchor, self.cursor);
        const hi = @max(self.anchor, self.cursor);

        var line_buf: [8192]u8 = undefined;
        var row: usize = 0;
        while (row < lay.log_rows) : (row += 1) {
            try w.writeAll(esc.dim ++ "│" ++ esc.reset);

            // The margin, and the mark that lives in it. Picked lines are
            // flagged from the margin rather than by reversing the line: a
            // Worker's own colours are the reason the Archive is kept
            // byte-faithful, and highlighting over the top would spend them.
            const has_line = at < a.len();
            if (has_line and self.mode == .visual and at >= lo and at <= hi) {
                try w.writeAll(paint.picked ++ "▌" ++ esc.reset ++ " ");
            } else {
                try w.writeAll("  ");
            }

            var shown: usize = 0;
            if (has_line) {
                const line = a.lineAt(at, &line_buf);
                var fit = term.fitToWidth(line.text, lay.log_w);
                const cut = fit.truncated;
                // Give the last column back so the cut can be marked. A line
                // that silently stops at the edge reads as a line that ended.
                if (cut) fit = term.fitToWidth(line.text, lay.log_w -| 1);
                try w.writeAll(line.text[0..fit.bytes]);
                try w.writeAll(esc.reset);
                if (cut) try w.writeAll(esc.dim ++ "›" ++ esc.reset);
                shown = fit.cols + @intFromBool(cut);
                at = line.end;
            }
            try w.splatByteAll(' ', lay.log_w -| shown);
            try w.writeAll(" " ++ esc.dim ++ "│" ++ esc.reset ++ esc.clear_line ++ "\n");
        }
    }

    /// The footer is the control surface, and it does not move. Whatever the
    /// view has to say goes on the left; the actions stay pinned right, so the
    /// place a reader clicked once is the place it is next time.
    fn footer(self: *Ui, w: *std.Io.Writer) !void {
        const cols: usize = self.size.cols;

        var shown: [chips.len]bool = @splat(true);
        var dropped: usize = 0;
        var chips_w = chipsWidth(shown);
        while (hint_floor + 2 + chips_w > cols and dropped < chip_drop_order.len) {
            shown[chip_drop_order[dropped]] = false;
            dropped += 1;
            chips_w = chipsWidth(shown);
        }
        const chips_start = cols -| chips_w;

        var hint_buf: [320]u8 = undefined;
        const said = self.hint(&hint_buf, chips_start -| 2);
        var used: usize = 1;
        try w.writeByte(' ');
        if (self.status_len > 0 and self.status_tone.len > 0) try w.writeAll(self.status_tone);
        used += try printClamped(w, chips_start -| 2, said);
        try w.writeAll(esc.reset);

        @memset(&self.chip_col, 0);
        @memset(&self.chip_w, 0);
        if (chips_w == 0 or chips_start < used) {
            try w.splatByteAll(' ', cols -| used);
            try w.writeAll(esc.reset ++ esc.clear_line);
            return;
        }
        try w.splatByteAll(' ', chips_start -| used);
        used = chips_start;

        for (chips, 0..) |c, i| {
            if (!shown[i]) continue;
            if (used > chips_start) {
                try w.writeAll("  ");
                used += 2;
            }
            // The terminal counts from one, and so does a mouse report.
            self.chip_col[i] = @intCast(used + 1);
            self.chip_w[i] = @intCast(c.width());
            try w.print("{s}{s}{s} {s}", .{ esc.dim, c.key, esc.weight_off, c.label });
            used += c.width();
        }
        try w.splatByteAll(' ', cols -| used);
        try w.writeAll(esc.reset ++ esc.clear_line);
    }

    /// Room the left side of the footer is never squeezed out of.
    const hint_floor = 30;

    /// What the view has to say, in the order a reader needs to hear it. What
    /// just happened outranks what is true, which outranks what they could do
    /// next — an idle hint is only worth showing when nothing else is.
    ///
    /// Each line has a short form for when the terminal is narrow. A sentence
    /// clipped by the column budget stops mid-word and reads as a bug; a
    /// shorter sentence that fits reads as the thing it says.
    fn hint(self: *Ui, buf: []u8, room: usize) []const u8 {
        if (self.help) return pick(room, "Press Esc to go back to the log", "Esc goes back");
        if (self.status_len > 0) return shedClause(self.status(), room);
        if (self.sup.shutting_down) {
            return pick(
                room,
                "Shutting everything down — press q again to leave now",
                "Shutting down — q to leave",
            );
        }
        if (self.mode == .visual) {
            const plural = if (self.picked_lines == 1) "" else "s";
            const long = std.fmt.bufPrint(buf, "{d} line{s} picked — press y to copy them, Esc to let go", .{ self.picked_lines, plural }) catch return "Lines picked — y copies";
            if (!term.fitToWidth(long, room).truncated) return long;
            // Formatted into the far end of the same buffer, so the short form
            // does not overwrite the long one while it is still being measured.
            const half = buf.len / 2;
            return std.fmt.bufPrint(buf[half..], "{d} line{s} picked — y copies", .{ self.picked_lines, plural }) catch "Lines picked — y copies";
        }
        if (!self.follow[self.selected]) {
            return pick(
                room,
                "Paused in older output — press End to catch up to live",
                "Paused — End for live",
            );
        }
        return pick(room, "Drag across the log to pick lines to copy", "Drag to pick lines");
    }

    /// Everything the view can do, spelled out. It exists so the footer does
    /// not have to be a key map: a reader who needs the whole list asks for it
    /// once, and the rest of the time gets a line of plain English instead.
    fn helpPane(self: *Ui, w: *std.Io.Writer, lay: Layout) !void {
        const Row = struct { key: []const u8 = "", text: []const u8 = "", head: bool = false };
        const key_col = 21;

        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{
            self.logDir(),
            self.sup.workers[self.selected].name(),
        }) catch "the .devrun/logs directory";

        const rows = [_]Row{
            .{ .text = "Reading the log", .head = true },
            .{ .key = "↑ ↓   or   j k", .text = "scroll a line at a time" },
            .{ .key = "PgUp  PgDn", .text = "scroll a whole screen" },
            .{ .key = "Home", .text = "jump to the very start" },
            .{ .key = "End", .text = "jump back to live output" },
            .{},
            .{ .text = "Taking lines out", .head = true },
            .{ .key = "drag the mouse", .text = "pick the lines you drag over" },
            .{ .key = "v  then  ↑ ↓", .text = "pick lines from the keyboard" },
            .{ .key = "y", .text = "copy what you picked, or the screen" },
            .{ .key = "Esc", .text = "let the picked lines go" },
            .{},
            .{ .text = "Services", .head = true },
            .{ .key = "Tab   or   click", .text = "switch to another service" },
            .{ .key = "s   r   S", .text = "stop · restart · start this one" },
            .{},
            .{ .text = "Leaving", .head = true },
            .{ .key = "q", .text = "shut everything down; q again to leave" },
            .{},
            .{ .text = "Every log is a plain file. This one is being written to", .head = true },
            .{ .text = path, .head = true },
        };

        // The help takes the table's rows as well as the log's: it is a
        // detour, not a panel, and the list is worth reading in one piece.
        const cols: usize = self.size.cols;
        const height = lay.service_rows + lay.log_rows + 1;
        try rule(w, cols, "┌", "┐", "keys", esc.bold);

        var drawn: usize = 0;
        while (drawn < height) : (drawn += 1) {
            try w.writeAll(esc.dim ++ "│" ++ esc.reset ++ " ");
            var used: usize = 0;
            if (drawn < rows.len) {
                const r = rows[drawn];
                if (r.head) {
                    try w.writeAll(" " ++ esc.bold);
                    used = 1 + try printClamped(w, cols -| 4, r.text);
                    try w.writeAll(esc.weight_off);
                } else if (r.key.len > 0) {
                    try w.writeAll("   " ++ esc.dim);
                    used = 3 + try printClamped(w, cols -| 6, r.key);
                    try w.writeAll(esc.weight_off);
                    try w.splatByteAll(' ', key_col -| (used -| 3));
                    used = @max(used, 3 + key_col);
                    used += try printClamped(w, cols -| (used + 4), r.text);
                }
            }
            try w.splatByteAll(' ', cols -| (used + Layout.frame));
            try w.writeAll(" " ++ esc.dim ++ "│" ++ esc.reset ++ esc.clear_line ++ "\n");
        }
    }
};

/// Drops a message's trailing clause when the whole of it will not fit.
///
/// Every status here is written as "what happened — and the detail", so the
/// clause before the dash is the part that has to survive. Cutting there beats
/// letting the column budget cut wherever it lands: "Copied 3 lines" is a
/// complete sentence, and "Copied 3 lines — the whole log is at .dev" is a
/// half-written path that looks like a bug.
fn shedClause(text: []const u8, room: usize) []const u8 {
    if (!term.fitToWidth(text, room).truncated) return text;
    if (std.mem.indexOf(u8, text, " — ")) |cut| {
        if (!term.fitToWidth(text[0..cut], room).truncated) return text[0..cut];
    }
    return text;
}

/// A run of box-drawing dashes, sliced rather than looped, so a border is one
/// `writeAll` instead of a hundred.
const dashes = "─" ** 256;
/// `─` is three bytes, and every slice of `dashes` has to land on a boundary
/// between them — a border cut mid-glyph puts a replacement character on
/// screen and knocks every column after it out of line.
const dash_bytes = 3;
const dashes_max = dashes.len / dash_bytes;

/// Writes `count` dashes, however many that is.
///
/// The lengths are annotated `usize` rather than inferred, and that is the
/// whole point of this function existing. `@min` against a comptime bound
/// gives back the narrowest type that can hold it — `u9` here — and the `* 3`
/// that turns glyphs into bytes then overflows it silently in a release build.
/// The border came out cut mid-glyph on any terminal past 183 columns, which
/// is every terminal nobody tests at.
fn drawDashes(w: *std.Io.Writer, count: usize) !void {
    var left: usize = count;
    while (left > 0) {
        const chunk: usize = @min(left, dashes_max);
        try w.writeAll(dashes[0 .. chunk * dash_bytes]);
        left -= chunk;
    }
}

/// One horizontal border of a box, with a title set into it.
///
/// `left` and `right` are the corners, which is what makes the same routine
/// draw the top of the table and the seam between the table and the log: a
/// `├…┤` closes one box and opens the next in a single row, and rows are the
/// scarcer resource here.
fn rule(
    w: *std.Io.Writer,
    cols: usize,
    left: []const u8,
    right: []const u8,
    title: []const u8,
    accent: []const u8,
) !void {
    try w.writeAll(esc.dim);
    try w.writeAll(left);
    try w.writeAll("─ ");
    try w.writeAll(esc.weight_off);
    try w.writeAll(accent);
    const shown = try printClamped(w, cols -| 6, title);
    try w.writeAll(esc.reset ++ esc.dim ++ " ");
    // left corner + "─ " + title + " " + fill + right corner == cols.
    try drawDashes(w, cols -| (shown + 5));
    try w.writeAll(right);
    try w.writeAll(esc.reset ++ esc.clear_line ++ "\n");
}

const Align = enum { left, right };

/// One table cell: the text, padded to `width`, with the single space that
/// separates it from its neighbour already inside that budget.
fn cell(w: *std.Io.Writer, width: usize, text: []const u8, side: Align) !usize {
    const room = width -| 1;
    const fit = term.fitToWidth(text, room);
    switch (side) {
        .left => {
            try w.writeAll(text[0..fit.bytes]);
            try w.splatByteAll(' ', room -| fit.cols);
        },
        .right => {
            try w.splatByteAll(' ', room -| fit.cols);
            try w.writeAll(text[0..fit.bytes]);
        },
    }
    try w.writeByte(' ');
    return width;
}

/// A column heading, aligned the way its column's values will be, so the label
/// sits over the digits rather than beside them.
fn heading(w: *std.Io.Writer, width: usize, text: []const u8, side: Align) !usize {
    return cell(w, width, text, side);
}

/// How long a Worker has been up, in the two largest units that say anything.
/// A dev Session runs for minutes to hours, so seconds stop being interesting
/// once there is a minute to report, and days are the ceiling worth printing.
fn uptimeText(buf: []u8, ms: u64) []const u8 {
    const s = ms / 1000;
    if (s < 60) return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
    if (s < 3600) return std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ s / 60, s % 60 }) catch "?";
    if (s < 86_400) return std.fmt.bufPrint(buf, "{d}h {d:0>2}m", .{ s / 3600, (s % 3600) / 60 }) catch "?";
    return std.fmt.bufPrint(buf, "{d}d {d:0>2}h", .{ s / 86_400, (s % 86_400) / 3600 }) catch "?";
}

/// How a Worker ended. A signal is named rather than numbered where the name
/// is the thing a reader recognises — "killed" is what happened, `137` is
/// what the shell would have told them about it.
fn exitText(buf: []u8, exit: ?os.Exit) []const u8 {
    const e = exit orelse return "-";
    return switch (e) {
        .exited => |code| std.fmt.bufPrint(buf, "{d}", .{code}) catch "?",
        .signaled => |sig| switch (sig) {
            .KILL => "killed",
            .TERM => "stopped",
            .INT => "interrupt",
            .SEGV => "segfault",
            .ABRT => "aborted",
            else => std.fmt.bufPrint(buf, "signal {d}", .{@intFromEnum(sig)}) catch "?",
        },
    };
}

/// The longer line when it fits, the shorter when it does not.
///
/// Measured in visible columns rather than bytes: these sentences are full of
/// em dashes, which are three bytes and one column each, and counting bytes
/// would drop to the short form several words before it was needed.
fn pick(room: usize, long: []const u8, short: []const u8) []const u8 {
    return if (term.fitToWidth(long, room).truncated) short else long;
}

fn chipsWidth(shown: [chips.len]bool) usize {
    var total: usize = 0;
    var n: usize = 0;
    for (chips, 0..) |c, i| {
        if (!shown[i]) continue;
        total += c.width();
        n += 1;
    }
    return if (n == 0) 0 else total + 2 * (n - 1);
}

// ------------------------------------------------------------- vocabulary

/// A shape per state, so the view still reads on a terminal with no colour, in
/// a screenshot that lost it, or to someone who cannot tell two of them apart.
/// The filled ones are alive; the flat ones are over.
fn stateGlyph(s: supervisor.State) []const u8 {
    return switch (s) {
        .pending => "○",
        .running => "●",
        .ready => "◉",
        .stopping => "◐",
        .exited => "✓",
        .stopped => "■",
        .failed => "✗",
        .skipped => "·",
    };
}

/// The same states in words a reader has not had to be taught. `pending` is
/// what the state machine calls it; "waiting" is what is happening. `exited`
/// is a status code; a Gate that ran and stopped is "finished".
fn stateLabel(s: supervisor.State) []const u8 {
    return switch (s) {
        .pending => "waiting",
        .running => "running",
        .ready => "ready",
        .stopping => "stopping",
        .exited => "finished",
        .stopped => "stopped",
        .failed => "failed",
        .skipped => "skipped",
    };
}

fn stateColour(s: supervisor.State) []const u8 {
    return switch (s) {
        .pending => paint.waiting,
        .running => paint.running,
        .ready => paint.ready,
        .stopping => paint.stopping,
        .exited => paint.finished,
        .stopped => paint.stopped,
        .failed => paint.failed,
        .skipped => paint.skipped,
    };
}

/// The rail's height. Stepped rather than linear, because the two readings a
/// dev stack actually produces — idling at half a percent and pinning a core —
/// are three orders of magnitude apart, and a linear meter shows both as empty
/// right up until one of them catches fire.
fn loadGlyph(cpu: f32) []const u8 {
    // The figure beside this one is printed to one decimal, so the meter goes
    // dark exactly where that figure stops reading as 1.0% — otherwise a row
    // says "1.0%" next to an empty meter and the two look like they disagree.
    if (!(cpu >= 0.95)) return " ";
    if (cpu < 4) return "▁";
    if (cpu < 10) return "▂";
    if (cpu < 22) return "▃";
    if (cpu < 40) return "▄";
    if (cpu < 65) return "▅";
    if (cpu < 95) return "▆";
    if (cpu < 160) return "▇";
    return "█";
}

fn loadColour(cpu: f32) []const u8 {
    if (!(cpu >= 25)) return paint.load_low;
    if (cpu < 95) return paint.load_mid;
    return paint.load_high;
}

/// A byte count in the units a person says out loud.
///
/// Decimal, and labelled the way the rest of their machine labels it. The
/// control socket still reports exact bytes, so nothing that *parses* devrun
/// ever sees a rounded figure — this rounding is for the one reader who is
/// going to glance at it and decide whether to care.
fn humanBytes(buf: []u8, n: u64) []const u8 {
    const units = [_][]const u8{ "B", "kB", "MB", "GB", "TB", "PB", "EB" };

    // The step is 999.5 rather than 1000 so a figure that would *round* to
    // four digits climbs to the next unit instead. Rounding first and stepping
    // second is how "1000 kB" gets printed into a column six wide.
    var f: f64 = @floatFromInt(n);
    var u: usize = 0;
    while (f >= 999.5 and u + 1 < units.len) : (u += 1) f /= 1000;

    // One decimal only where it says something: below ten, the difference
    // between 1 MB and 1.9 MB is the whole reading. Bytes never get one,
    // because a tenth of a byte is not a quantity.
    if (u > 0 and f < 9.995) return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ f, units[u] }) catch "?";
    return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ f, units[u] }) catch "?";
}

/// Drops a leading "./" so a path reads the way someone would type it.
fn trimCwdPrefix(path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, "./") and path.len > 2) return path[2..];
    return path;
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

test "every state is said as a shape and a word as well as a colour" {
    // Colour is the encoding most likely to be missing — a mono terminal, a
    // pasted screenshot, a reader who cannot separate two of them. The other
    // two carry the meaning on their own, so both must be unique.
    var glyphs: std.StringHashMapUnmanaged(void) = .empty;
    var words: std.StringHashMapUnmanaged(void) = .empty;
    defer glyphs.deinit(testing.allocator);
    defer words.deinit(testing.allocator);

    const all = [_]supervisor.State{
        .pending, .running, .ready, .stopping, .exited, .stopped, .failed, .skipped,
    };
    for (all) |s| {
        try glyphs.put(testing.allocator, stateGlyph(s), {});
        try words.put(testing.allocator, stateLabel(s), {});
        // The word has to fit the column the list reserves for it, and be
        // plain ASCII so its byte length is its width.
        try testing.expect(stateLabel(s).len <= Layout.status_w - 1);
        for (stateLabel(s)) |c| try testing.expect(c >= 'a' and c <= 'z');
    }
    try testing.expectEqual(all.len, glyphs.count());
    try testing.expectEqual(all.len, words.count());
}

test "humanBytes reads like a number a person would say" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0 B", humanBytes(&buf, 0));
    try testing.expectEqualStrings("999 B", humanBytes(&buf, 999));
    try testing.expectEqualStrings("1.0 kB", humanBytes(&buf, 1000));
    try testing.expectEqualStrings("512 kB", humanBytes(&buf, 512_000));
    // Rounding must not be allowed to produce a fourth digit and outgrow the
    // column: this steps up a unit rather than printing "1000 kB".
    try testing.expectEqualStrings("1.0 MB", humanBytes(&buf, 999_900));
    // The old `{Bi}` formatting rendered this as "9.03125MiB".
    try testing.expectEqualStrings("9.5 MB", humanBytes(&buf, 9_470_000));
    try testing.expectEqualStrings("128 MB", humanBytes(&buf, 128_000_000));
    try testing.expectEqualStrings("2.1 GB", humanBytes(&buf, 2_100_000_000));
}

test "humanBytes never outgrows the column reserved for it" {
    // The list right-aligns into a fixed column, so a figure that formats
    // wider than the column would push the whole row sideways.
    var buf: [32]u8 = undefined;
    for ([_]u64{
        0,           999,          1000,             999_999,
        1_000_000,   9_999_999,    10_000_000,       999_999_999,
        1_000_000_000, std.math.maxInt(u64),
    }) |n| {
        try testing.expect(humanBytes(&buf, n).len <= Layout.memory_w - 1);
    }
}

test "the load rail rises with CPU and never skips a level" {
    // A Group idling below one percent leaves the rail empty; anything a
    // reader would call "working" has to be visible.
    try testing.expectEqualStrings(" ", loadGlyph(0));
    try testing.expectEqualStrings(" ", loadGlyph(0.9));
    try testing.expect(!std.mem.eql(u8, " ", loadGlyph(0.96)));
    try testing.expect(!std.mem.eql(u8, " ", loadGlyph(1)));

    var previous: usize = 0;
    for ([_]f32{ 1, 4, 10, 22, 40, 65, 95, 160 }) |cpu| {
        const level = std.mem.indexOf(u8, rail_levels, loadGlyph(cpu)).?;
        try testing.expect(level > previous or previous == 0);
        previous = level;
    }
    // Over a whole core, the rail is full and stays full.
    try testing.expectEqualStrings("█", loadGlyph(200));
    try testing.expectEqualStrings("█", loadGlyph(1600));

    // A NaN reading — a sampler tick that divided by no elapsed time — must
    // fall to the bottom of the scale rather than through every comparison to
    // the top of it.
    const nan = std.math.nan(f32);
    try testing.expectEqualStrings(" ", loadGlyph(nan));
    try testing.expectEqualStrings(paint.load_low, loadColour(nan));
}

const rail_levels = "▁▂▃▄▅▆▇█";

test "the load rail warms only once a Group is really working" {
    try testing.expectEqualStrings(paint.load_low, loadColour(0));
    try testing.expectEqualStrings(paint.load_low, loadColour(24));
    try testing.expectEqualStrings(paint.load_mid, loadColour(25));
    try testing.expectEqualStrings(paint.load_high, loadColour(95));
    // Hot shares its colour with failed on purpose: both mean "look here".
    try testing.expectEqualStrings(paint.failed, loadColour(200));
}

test "uptime reads in the two units that matter and fits its column" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("0s", uptimeText(&buf, 0));
    try testing.expectEqualStrings("59s", uptimeText(&buf, 59_999));
    try testing.expectEqualStrings("1m 00s", uptimeText(&buf, 60_000));
    try testing.expectEqualStrings("2m 14s", uptimeText(&buf, 134_000));
    try testing.expectEqualStrings("1h 00m", uptimeText(&buf, 3_600_000));
    try testing.expectEqualStrings("13h 27m", uptimeText(&buf, 48_420_000));
    try testing.expectEqualStrings("2d 03h", uptimeText(&buf, 183_600_000));

    // The column is right-aligned, so a figure wider than it would shove the
    // whole row sideways.
    for ([_]u64{ 0, 59_000, 3_599_000, 86_399_000, 999 * 86_400_000 }) |ms| {
        try testing.expect(uptimeText(&buf, ms).len <= Layout.uptime_w - 1);
    }
}

test "exit says what happened, not just a number" {
    var buf: [32]u8 = undefined;
    // Still running: there is no exit to report, and a zero here would read
    // as "finished cleanly".
    try testing.expectEqualStrings("-", exitText(&buf, null));
    try testing.expectEqualStrings("0", exitText(&buf, .{ .exited = 0 }));
    try testing.expectEqualStrings("137", exitText(&buf, .{ .exited = 137 }));
    // The signals a dev actually meets are named; the rest keep their number.
    try testing.expectEqualStrings("killed", exitText(&buf, .{ .signaled = .KILL }));
    try testing.expectEqualStrings("stopped", exitText(&buf, .{ .signaled = .TERM }));
    try testing.expectEqualStrings("segfault", exitText(&buf, .{ .signaled = .SEGV }));

    for ([_]?os.Exit{
        null,                        .{ .exited = 0 },      .{ .exited = 255 },
        .{ .signaled = .KILL },      .{ .signaled = .SEGV }, .{ .signaled = .INT },
    }) |e| {
        try testing.expect(exitText(&buf, e).len <= Layout.exit_w - 1);
    }
}

test "a status too long for the footer loses its tail, not its meaning" {
    const copied = "Copied 3 lines — the whole log is at .devrun/logs/api.log";
    // Wide enough for all of it, and it is left alone.
    try testing.expectEqualStrings(copied, shedClause(copied, 80));
    // Too narrow, so the detail goes and the sentence survives whole.
    try testing.expectEqualStrings("Copied 3 lines", shedClause(copied, 41));
    try testing.expectEqualStrings("Copied 3 lines", shedClause(copied, 14));

    // Narrower than even the head: nothing useful to shed, so it is handed
    // back for the renderer to clamp rather than silently emptied.
    try testing.expectEqualStrings(copied, shedClause(copied, 5));
    // A message with no clause to shed is returned untouched.
    try testing.expectEqualStrings("Stopping api", shedClause("Stopping api", 4));
}

test "the footer sheds actions from the least useful end" {
    const all: [chips.len]bool = @splat(true);
    const full = chipsWidth(all);
    try testing.expect(full > 0);

    // Whatever drops, Copy, Keys and Quit survive: the first is what the view
    // is for and the other two are how a reader gets un-stuck.
    var shown = all;
    for (chip_drop_order) |i| {
        shown[i] = false;
        try testing.expect(chipsWidth(shown) < full);
        try testing.expect(chips[i].action != .copy);
        try testing.expect(chips[i].action != .help);
        try testing.expect(chips[i].action != .quit);
    }
    // With everything droppable gone there is still a control surface left.
    try testing.expect(chipsWidth(shown) > 0);
}

test "a border reaches the right edge whatever the terminal is wide" {
    // This is the regression that motivated `drawDashes`. `@min` against a
    // comptime bound handed back a `u9`, the `* 3` that turns glyphs into
    // bytes wrapped inside it, and the border came out short and cut through
    // the middle of a `─` — on every terminal wider than 183 columns, which is
    // most of them, and none of the ones the earlier tests used.
    var buf: [8 * 1024]u8 = undefined;
    for ([_]usize{ 24, 40, 80, 110, 182, 183, 184, 200, 240, 269, 270, 400, 900 }) |cols| {
        var w: std.Io.Writer = .fixed(&buf);
        try rule(&w, cols, "┌", "┐", "services", "");
        const row = w.buffered();

        // A slice that lands mid-glyph shows up here first.
        try testing.expect(std.unicode.utf8ValidateSlice(row));
        // Asking for one column more than the row should need proves it fills
        // exactly `cols` and does not run over into the next line.
        const fit = term.fitToWidth(row, cols + 1);
        try testing.expect(!fit.truncated);
        try testing.expectEqual(cols, fit.cols);
        // The corner is the last thing on the row, not stranded in the middle.
        try testing.expect(std.mem.endsWith(u8, row, "┐" ++ esc.reset ++ esc.clear_line ++ "\n"));
        try testing.expect(std.mem.count(u8, row, "┐") == 1);
    }
}
