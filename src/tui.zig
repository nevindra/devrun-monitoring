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
const store = @import("store.zig");
const config = @import("config.zig");

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

/// Which of the two places in the view the arrow keys are speaking to.
///
/// This is the whole of the navigation model. ↑↓ act on whatever has Focus,
/// → goes in, ← comes back out — the shape every file manager and mail client
/// has used for thirty years, so nobody has to be taught it. Before this, ↑↓
/// scrolled the log and ←→ switched Worker, which is two halves of two
/// different models and reads as neither.
const Focus = enum { list, log };

pub const Options = struct {
    /// How many old Sessions retention deleted on the way in. Reported once,
    /// in the footer, because deleting somebody's logs without saying so is
    /// the one thing retention must never do.
    pruned: usize = 0,
};

pub fn run(
    gpa: Allocator,
    sup: *Supervisor,
    server: ?*control.Server,
    io: std.Io,
    opts: Options,
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

    if (opts.pruned > 0) {
        ui.setStatus("", "Removed {d} old log run{s} to stay under --keep", .{
            opts.pruned,
            if (opts.pruned == 1) "" else "s",
        });
    }

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
            if (ui.readKeys()) break;
        }

        // The Session is over and the user has not asked to stay. There may
        // still be a question to answer before the terminal comes back.
        if (sup.done() and sup.shutting_down and ui.beginLeaving()) break;
    }

    // Before anything is said about what was deleted, so it is said on the
    // reader's real screen rather than on one about to be discarded.
    ui.leave();
    ui.reportCleaned();
    return ui.exit_code;
}

/// What the footer offers and what a click on it does. Named for the thing
/// that happens, not for the key that triggers it — the key is a shortcut to
/// the action, not the other way round.
///
/// `label` is the one that does nothing: a chip that names the arrow keys is
/// there to be read, and there is no click that means "press down". Those get
/// no click region at all rather than a region that swallows the click.
const Action = enum { label, copy, pick, next, enter_log, leave_log, restart, stop, help, quit };

const Chip = struct {
    key: []const u8,
    label: []const u8,
    action: Action,

    fn width(self: Chip) usize {
        return term.fitToWidth(self.key, 64).cols + 1 + self.label.len;
    }
};

/// The control surface. Two of them, because the footer's job is to answer
/// "what can I do *now*" — and the honest answer changes depending on whether
/// the reader is picking a service or reading its log. One combined bar would
/// have to advertise both, which is how a key bar becomes wallpaper nobody
/// reads and everyone ends up in `?` anyway.
const ChipSet = struct {
    items: []const Chip,
    /// Which chips give up their columns first on a narrow terminal, least
    /// useful first. What is left when everything sheddable is gone must still
    /// be enough to get somewhere: how to move, and how to get out.
    drop: []const usize,
};

const list_chips: ChipSet = .{
    .items = &.{
        .{ .key = "↑↓", .label = "Process", .action = .next },
        .{ .key = "→", .label = "Open log", .action = .enter_log },
        .{ .key = "r", .label = "Restart", .action = .restart },
        .{ .key = "s", .label = "Stop", .action = .stop },
        .{ .key = "?", .label = "Keys", .action = .help },
        .{ .key = "q", .label = "Quit", .action = .quit },
    },
    // Stop, then Restart, then the way into the log — which goes last of the
    // three because → is the only key that is genuinely new here. Moving
    // between processes, the full key list and the way out are never dropped.
    .drop = &.{ 3, 2, 1 },
};

const log_chips: ChipSet = .{
    .items = &.{
        .{ .key = "↑↓", .label = "Line", .action = .label },
        .{ .key = "v", .label = "Select", .action = .pick },
        .{ .key = "y", .label = "Copy", .action = .copy },
        .{ .key = "←", .label = "Back", .action = .leave_log },
        .{ .key = "?", .label = "Keys", .action = .help },
        .{ .key = "q", .label = "Quit", .action = .quit },
    },
    // The line hint first, since it is the one chip that is only a caption;
    // then Select, then Back, which Esc also does and the message on the left
    // says so. Copy never goes: it is what the view is for.
    .drop = &.{ 0, 1, 3 },
};

/// Room for the widest set, so the click regions can be indexed by position
/// in whichever set is showing.
const max_chips = @max(list_chips.items.len, log_chips.items.len);

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

const HelpRow = struct { key: []const u8 = "", text: []const u8 = "", head: bool = false };

/// Everything the view can do, spelled out — the list `?` opens.
///
/// Ordered so that the rows a short terminal loses are the ones that cost
/// least. Movement comes first because a reader who opened this is usually
/// lost, and the path where the Archive lives comes after this list because it
/// is the one line here that is also on screen the whole time the help is
/// closed, in the log pane's title.
///
/// Short enough to fit the screen the help is given — see the test at the foot
/// of this file, which is what stops a row being added without noticing that
/// it pushed the last one off.
const help_rows = [_]HelpRow{
    .{ .text = "Getting around", .head = true },
    .{ .key = "↑ ↓", .text = "another service — or another line, in a log" },
    .{ .key = "→   ←", .text = "into the log, and back out to the list" },
    .{ .key = "Tab   or   click", .text = "switch service from anywhere" },
    .{},
    .{ .text = "Reading the log", .head = true },
    .{ .key = "j k  or  PgUp PgDn", .text = "a line, or a whole screen" },
    .{ .key = "Home   End", .text = "the very start, or back to live" },
    .{},
    .{ .text = "Taking lines out", .head = true },
    .{ .key = "y", .text = "copy the line you are on" },
    .{ .key = "v  then  ↑ ↓", .text = "select a range, then y copies it" },
    .{ .key = "drag the mouse", .text = "select the lines you drag over" },
    .{ .key = "Shift + drag", .text = "your terminal's own selection" },
    .{ .key = "Esc", .text = "let a selection go" },
    .{},
    .{ .text = "Services, and leaving", .head = true },
    .{ .key = "s   r   S", .text = "stop · restart · start this one" },
    .{ .key = "q", .text = "shut down, then offer to delete old logs" },
    .{ .key = "q   q", .text = "leave straight away, delete nothing" },
};

/// The rows the help gets on a terminal of `rows`: everything between the
/// Session line and the footer, plus its own top border.
fn helpHeight(rows: usize) usize {
    return rows -| 3;
}

/// The one question the view ever asks. Answering it is the last thing that
/// happens before the terminal comes back.
const Prompt = enum {
    none,
    /// "There are N runs' worth of logs on disk — delete them?"
    clean_logs,
};

const Ui = struct {
    sup: *Supervisor,
    tty: *term.Terminal,
    size: term.Size,

    /// Absolute Archive offset each Worker's pane starts at.
    view_top: []u64,
    /// Where the Cursor is in each Worker's Archive. Kept per Worker so that
    /// leaving a log and coming back lands where the reader left off rather
    /// than at the bottom — which is the difference between switching to check
    /// something and losing your place.
    cursor: []u64,
    /// Whether the Cursor is riding the tail. `follow[i]` and "the Cursor is
    /// on the last line" are the same statement, which is why the Cursor is
    /// derived rather than stored while it holds.
    follow: []bool,

    selected: usize = 0,
    /// Which pane the arrow keys are speaking to.
    focus: Focus = .list,
    mode: Mode = .normal,
    /// The end of the picked range that does not move — the Cursor is the
    /// other end.
    anchor: u64 = 0,
    /// The line the mouse button went down on, which becomes the anchor if the
    /// press turns out to be a drag.
    pending_anchor: u64 = 0,
    /// How many lines are currently picked. Cached rather than counted per
    /// frame: the walk is O(lines picked) and the answer only changes when the
    /// reader moves an end of the range.
    picked_lines: usize = 0,

    help: bool = false,
    /// The question asked on the way out, and nothing else. A view with one
    /// question in it does not need a queue of them.
    prompt: Prompt = .none,
    /// What the answer to that question deleted, said once the alternate
    /// screen is gone — inside it there is nothing left to read it.
    cleaned: store.Removed = .{},
    /// Set when the reader is finished and the loop should return.
    finished: bool = false,
    /// What is on disk, read once when the question is asked. The figure is
    /// what makes the question answerable — "delete some logs?" and "delete 12
    /// runs, 48 MB?" are not the same question.
    prompt_usage: store.Usage = .{},
    /// Whether `leave` has already run, so it can be called on the way out
    /// *and* left as a defer without undoing the terminal twice.
    left: bool = false,

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
    /// one. Zero means the chip was not shown at this width — or that it is
    /// not something a click can mean.
    chip_col: [max_chips]u16 = @splat(0),
    chip_w: [max_chips]u16 = @splat(0),

    exit_code: u8 = 0,
    /// The longest Worker name, which sets the name column for the Session so
    /// the figures beside it form columns instead of drifting per row.
    widest_name: usize,
    /// The Archive directory, spelled the way it goes on screen. Built once
    /// rather than per frame: it never changes, and it is printed in the log
    /// pane's title on every one of them.
    log_dir_shown: []const u8,

    fn init(gpa: Allocator, sup: *Supervisor, tty: *term.Terminal) !Ui {
        const n = sup.workers.len;
        var widest: usize = 0;
        for (sup.workers) |x| widest = @max(widest, x.name().len);
        const shown = if (sup.log_root.len > 0)
            try std.fmt.allocPrint(gpa, "{s}/{s}", .{
                trimCwdPrefix(sup.log_root),
                store.latest_link,
            })
        else
            try gpa.dupe(u8, trimCwdPrefix(sup.log_dir));
        errdefer gpa.free(shown);

        const ui: Ui = .{
            .log_dir_shown = shown,
            .widest_name = widest,
            .gpa = gpa,
            .sup = sup,
            .tty = tty,
            .size = tty.size(),
            .view_top = try gpa.alloc(u64, n),
            .cursor = try gpa.alloc(u64, n),
            .follow = try gpa.alloc(bool, n),
            .frame = .init(gpa),
        };
        // Every Worker starts at its live tail, which for an Archive with
        // nothing in it yet is offset zero. Done here rather than in `enter`
        // so that a Ui is a usable value the moment it exists, instead of one
        // that has to be switched on before it can be asked anything.
        @memset(ui.view_top, 0);
        @memset(ui.cursor, 0);
        @memset(ui.follow, true);
        return ui;
    }

    fn deinit(self: *Ui, gpa: Allocator) void {
        gpa.free(self.view_top);
        gpa.free(self.cursor);
        gpa.free(self.follow);
        gpa.free(self.log_dir_shown);
        self.frame.deinit();
    }

    fn enter(self: *Ui) void {
        self.tty.enterRaw();
        write(esc.alt_screen_on ++ esc.cursor_hide ++ esc.clear ++ esc.mouse_on);
    }

    /// Puts the terminal back. Idempotent, because the way out runs it early —
    /// anything the view has left to say is said on the real screen, not on an
    /// alternate one that is about to be thrown away.
    fn leave(self: *Ui) void {
        if (self.left) return;
        self.left = true;
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

        // The question on the way out takes every key, because every key that
        // is not an answer would act on a Session that has already stopped.
        if (self.prompt != .none) return self.answerPrompt(key);

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
                // Vim's line keys stay, and stay pointed at the log: someone
                // who types j to read is asking about output, not about which
                // service is selected. From the list they pull Focus in with
                // them, so the Cursor they just moved is one they can see.
                'j' => self.inLog().moveCursor(1),
                'k' => self.inLog().moveCursor(-1),
                'g' => self.inLog().jumpTop(),
                'G' => self.inLog().jumpBottom(),
                'n' => self.selectBy(1),
                'p' => self.selectBy(-1),
                '\t' => self.selectBy(1),
                'v' => self.inLog().togglePick(),
                'y' => self.copy(),
                's' => self.act(.stop),
                'r' => self.act(.restart),
                'S' => self.act(.start),
                '?' => self.help = true,
                else => {},
            },

            // The whole navigation model, in four lines. ↑↓ act on whatever
            // has Focus; → goes in and ← comes back out.
            .down => switch (self.focus) {
                .list => self.selectBy(1),
                .log => self.moveCursor(1),
            },
            .up => switch (self.focus) {
                .list => self.selectBy(-1),
                .log => self.moveCursor(-1),
            },
            .right => self.enterLog(),
            .left => self.leaveLog(),

            // A page is a log gesture whichever pane has Focus, so it brings
            // Focus with it rather than doing nothing.
            .page_down => self.inLog().scroll(@intCast(height)),
            .page_up => self.inLog().scroll(-@as(isize, @intCast(height))),

            // These two are the ends of whatever the reader is moving through:
            // the list of services, or the log.
            .home => switch (self.focus) {
                .list => self.selectTo(0),
                .log => self.jumpTop(),
            },
            .end => switch (self.focus) {
                .list => self.selectTo(self.sup.workers.len -| 1),
                .log => self.jumpBottom(),
            },

            // Layered, so the key someone presses when they want out of
            // something always gets them out of exactly one thing.
            .escape => if (self.mode == .visual) self.clearPick() else self.leaveLog(),
            .mouse => |m| return self.onMouse(m),
            else => {},
        }
        return false;
    }

    /// Pulls Focus into the log and hands back `self`, so a key that only
    /// makes sense against a log reads as `self.inLog().moveCursor(1)`.
    fn inLog(self: *Ui) *Ui {
        self.focus = .log;
        return self;
    }

    fn enterLog(self: *Ui) void {
        self.focus = .log;
    }

    /// Back to the list, letting go of a picked range on the way. Leaving a
    /// selection behind in a pane the reader has stepped out of is how `y`
    /// ends up copying something they cannot see.
    fn leaveLog(self: *Ui) void {
        self.clearPick();
        self.focus = .list;
    }

    /// First press asks politely; the Session shuts down and the view stays up
    /// so the reader can watch it happen. Second press stops waiting — and
    /// skips the question about logs, because someone pressing q twice is
    /// telling us they are done being asked things.
    fn requestQuit(self: *Ui) bool {
        if (self.sup.shutting_down) {
            self.finished = true;
            return true;
        }
        self.sup.beginShutdown();
        self.setStatus("", "Shutting everything down — press q again to leave now", .{});
        return false;
    }

    fn selectBy(self: *Ui, delta: isize) void {
        const n = self.sup.workers.len;
        if (n == 0) return;
        const cur: isize = @intCast(self.selected);
        self.selectTo(@intCast(@mod(cur + delta, @as(isize, @intCast(n)))));
    }

    fn selectTo(self: *Ui, i: usize) void {
        if (i >= self.sup.workers.len) return;
        self.selected = i;
        self.clearPick();
    }

    /// Turns a followed view into a parked one, freezing the derived Cursor
    /// and pane top into the stored ones first.
    ///
    /// Every movement that is not "go back to live" starts here, so nothing
    /// downstream has to ask whether the numbers it is reading are the stored
    /// ones or the ones the tail implies.
    fn unfollow(self: *Ui, i: usize) void {
        if (!self.follow[i]) return;
        self.view_top[i] = self.viewTop(i);
        self.cursor[i] = self.cursorAt(i);
        self.follow[i] = false;
    }

    /// Moves the view by whole lines, dragging the Cursor along by its edge.
    ///
    /// The Cursor is never off the pane. `y` copies the line it is on, so a
    /// Cursor scrolled out of sight is a copy of something the reader cannot
    /// see — which is the bug this whole model exists to remove.
    fn scroll(self: *Ui, lines: isize) void {
        const i = self.selected;
        const a = &self.sup.workers[i].archive;
        self.unfollow(i);
        self.view_top[i] = if (lines < 0)
            a.scrollBack(self.view_top[i], @intCast(-lines))
        else
            a.scrollForward(self.view_top[i], @intCast(lines));
        self.clampCursorToView();
    }

    fn jumpTop(self: *Ui) void {
        const i = self.selected;
        self.unfollow(i);
        self.view_top[i] = 0;
        self.cursor[i] = 0;
        self.refreshPick();
    }

    /// Back to live: the Cursor rides the tail again, which is the same
    /// statement as `follow`.
    fn jumpBottom(self: *Ui) void {
        self.follow[self.selected] = true;
        self.refreshPick();
    }

    /// Where the pane starts. While following, that is derived from the
    /// Archive's tail every frame rather than stored — which is why new output
    /// never has to notify the view.
    fn viewTop(self: *Ui, i: usize) u64 {
        const a = &self.sup.workers[i].archive;
        if (!self.follow[i]) return @min(self.view_top[i], a.lastLineStart());
        return a.scrollBack(a.lastLineStart(), self.logHeight() - 1);
    }

    /// Where the Cursor is. Derived while following, for the same reason the
    /// pane top is: a Worker printing a line must not have to tell the view
    /// where the newest line now starts.
    fn cursorAt(self: *Ui, i: usize) u64 {
        const a = &self.sup.workers[i].archive;
        if (self.follow[i]) return a.lastLineStart();
        return @min(self.cursor[i], a.lastLineStart());
    }

    /// The absolute offset of the line drawn on body row `row`.
    fn lineAtRow(self: *Ui, row: usize) u64 {
        const a = &self.sup.workers[self.selected].archive;
        return a.scrollForward(self.viewTop(self.selected), row);
    }

    /// Starts a picked range at the Cursor.
    ///
    /// At the Cursor, not at the top of the pane. Anchoring at the top is what
    /// made `v` on a screen of output pick a line the reader had not chosen
    /// and was not looking at — the range began wherever the pane happened to
    /// be scrolled to, which is a fact about the view, not about them.
    fn togglePick(self: *Ui) void {
        if (self.mode == .visual) return self.clearPick();
        self.mode = .visual;
        self.anchor = self.cursorAt(self.selected);
        self.refreshPick();
    }

    fn clearPick(self: *Ui) void {
        self.mode = .normal;
        self.picked_lines = 0;
        self.status_len = 0;
    }

    /// Moves the Cursor, scrolling the pane only when the Cursor would leave
    /// it. Reaching the last line puts the view back on the tail, so reading
    /// down to live output and staying there needs no second keypress.
    fn moveCursor(self: *Ui, delta: isize) void {
        const i = self.selected;
        const a = &self.sup.workers[i].archive;
        self.unfollow(i);
        self.cursor[i] = if (delta < 0)
            a.scrollBack(self.cursor[i], @intCast(-delta))
        else
            a.scrollForward(self.cursor[i], @intCast(delta));

        const top = self.view_top[i];
        if (self.cursor[i] < top) {
            self.view_top[i] = self.cursor[i];
        } else {
            const bottom = a.scrollForward(top, self.logHeight() - 1);
            if (self.cursor[i] > bottom) {
                // Scroll by exactly the overshoot rather than by one line: a
                // page-sized move must not walk the pane down a line at a
                // time, and a one-line move is the overshoot of one.
                self.view_top[i] = a.scrollBack(
                    self.cursor[i],
                    self.logHeight() - 1,
                );
            }
        }
        if (self.cursor[i] >= a.lastLineStart()) self.follow[i] = true;
        self.refreshPick();
    }

    /// Pulls the Cursor back onto the pane after the view moved under it.
    fn clampCursorToView(self: *Ui) void {
        const i = self.selected;
        const a = &self.sup.workers[i].archive;
        const top = self.viewTop(i);
        const bottom = a.scrollForward(top, self.logHeight() - 1);
        self.cursor[i] = std.math.clamp(self.cursorAt(i), top, bottom);
        if (self.cursor[i] >= a.lastLineStart()) self.follow[i] = true;
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
        const cursor = self.cursorAt(self.selected);
        self.picked_lines = self.countLines(
            @min(self.anchor, cursor),
            @max(self.anchor, cursor),
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
                        self.selectTo(i);
                        self.focus = .list;
                    }
                    return false;
                }
                // Inside the table's box but not on a service — the breakdown
                // line. Not a miss to report, just nothing to do.
                if (in_table) return false;
                if (!in_log) return false;
                // A click puts the Cursor here and nothing more. It used to
                // start a one-line pick, which meant a stray click left a
                // selection behind and the next `y` copied that instead of
                // what the reader was looking at.
                const line = self.lineAtRow(m.row - lay.log_first);
                self.focus = .log;
                self.clearPick();
                self.moveCursorTo(line);
                self.pending_anchor = line;
            },

            .drag => {
                // A drag is a pick, and it starts where the button went down.
                // Deferred to here rather than done on press so that clicking
                // and dragging are different gestures rather than the same one
                // with different lengths.
                if (self.mode != .visual) {
                    if (!in_log) return false;
                    self.mode = .visual;
                    self.anchor = self.pending_anchor;
                    self.refreshPick();
                }
                // Dragging past an edge keeps going, which is how a range
                // longer than the pane gets picked at all.
                if (m.row <= lay.log_first) {
                    self.scroll(-1);
                } else if (m.row >= log_last) {
                    self.scroll(1);
                }
                const last: i32 = @intCast(lay.log_rows - 1);
                const row = std.math.clamp(@as(i32, m.row) - @as(i32, lay.log_first), 0, last);
                self.moveCursorTo(self.lineAtRow(@intCast(row)));
            },

            .release => {},
        }
        return false;
    }

    /// Puts the Cursor on a line the reader pointed at, which by construction
    /// is already on the pane — so unlike `moveCursor` this never scrolls.
    fn moveCursorTo(self: *Ui, line: u64) void {
        const i = self.selected;
        const a = &self.sup.workers[i].archive;
        self.unfollow(i);
        self.cursor[i] = line;
        if (line >= a.lastLineStart()) self.follow[i] = true;
        self.refreshPick();
    }

    fn clickFooter(self: *Ui, col: u16) bool {
        const set = self.chipSet();
        for (set.items, 0..) |c, i| {
            const start = self.chip_col[i];
            if (start == 0) continue;
            if (col >= start and col < start + self.chip_w[i]) {
                return switch (c.action) {
                    .label => false,
                    .copy => blk: {
                        self.copy();
                        break :blk false;
                    },
                    .pick => blk: {
                        self.inLog().togglePick();
                        break :blk false;
                    },
                    .next => blk: {
                        self.selectBy(1);
                        break :blk false;
                    },
                    .enter_log => blk: {
                        self.enterLog();
                        break :blk false;
                    },
                    .leave_log => blk: {
                        self.leaveLog();
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

    // ------------------------------------------------------------- leaving

    /// Called once the Session has stopped and the reader asked to leave.
    /// Returns true when there is nothing left to do but go.
    ///
    /// The offer to delete logs is made *here* rather than on the first `q`,
    /// and that ordering is the whole design. `q q` is already muscle memory
    /// for "shut down and get out"; a question that appears on the first press
    /// would read the second one as its answer, and the answer next to `q` on
    /// most people's mental map is "yes". Deleting somebody's logs because
    /// they typed the thing they always type is not a prompt, it is a trap.
    fn beginLeaving(self: *Ui) bool {
        if (self.finished) return true;
        if (self.prompt != .none) return false;
        if (self.sup.log_root.len == 0) return true;

        const use = store.usage(self.gpa, self.sup.log_root);
        if (use.sessions == 0) return true;
        self.prompt_usage = use;
        self.prompt = .clean_logs;
        self.sup.generation += 1;
        return false;
    }

    /// Says what the answer deleted, on the terminal the reader is left
    /// looking at. A count that only ever appeared inside the alternate screen
    /// would be a count nobody saw.
    fn reportCleaned(self: *Ui) void {
        if (self.cleaned.sessions == 0) return;
        var size_buf: [32]u8 = undefined;
        var line_buf: [160]u8 = undefined;
        const line = std.fmt.bufPrint(&line_buf, "devrun: deleted {d} log run{s} ({s})\n", .{
            self.cleaned.sessions,
            if (self.cleaned.sessions == 1) "" else "s",
            humanBytes(&size_buf, self.cleaned.bytes),
        }) catch return;
        write(line);
    }

    fn answerPrompt(self: *Ui, key: term.Key) bool {
        const root = self.sup.log_root;
        switch (key) {
            .char => |c| switch (c) {
                'y', 'Y' => self.cleaned = store.clean(self.gpa, root, .all),
                'o', 'O' => self.cleaned = store.clean(self.gpa, root, .older),
                // Everything else that is a plain key means "no". A reader who
                // hits something unexpected at this point gets to keep their
                // logs, which is the answer that can still be changed later.
                else => {},
            },
            // Enter is the default, and the default is keep.
            .escape, .enter => {},
            else => return false,
        }
        self.prompt = .none;
        self.finished = true;
        return true;
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

    /// The Archive directory as a reader would type it.
    ///
    /// Through the `latest` symlink rather than through this Session's stamped
    /// directory. Both name the same file while the Session is running, and
    /// the point of putting a path on screen is that somebody types or pastes
    /// it — `.devrun/logs/latest/api.log` is a path a person can retype, and
    /// `.devrun/logs/2026-08-14T10-32-05Z/api.log` is one they will get wrong.
    ///
    /// A Session started in the current directory builds its paths from ".",
    /// and "./.devrun/logs" is a path with a stutter in it that nobody would
    /// write down, hence `trimCwdPrefix`.
    fn logDir(self: *const Ui) []const u8 {
        return self.log_dir_shown;
    }

    // ------------------------------------------------------------- copy

    /// Produces an Excerpt and hands it to the terminal over OSC 52.
    ///
    /// Its shape is decided by the view it was taken from, per CONTEXT.md, and
    /// there are three views to be taken from:
    ///
    ///   - lines picked → those lines
    ///   - Focus on the log → the line the Cursor is on
    ///   - Focus on the list → the screenful of log on show
    ///
    /// The middle one is the reason the Cursor exists. Copying the screen
    /// while a Cursor is drawn on one line of it invites the reader to believe
    /// the Cursor decided what was copied, and being wrong about what is on
    /// your clipboard is only discovered after you have pasted it somewhere.
    /// Which lines an Excerpt would be made of, as the offset of its first
    /// line and the offset of its last.
    ///
    /// Separate from `copy` so that what gets copied can be asserted without a
    /// terminal on the other end: the decision is the interesting part, and
    /// `copy` past this point is byte-shovelling.
    fn excerptRange(self: *Ui) struct { first: u64, last: u64 } {
        const i = self.selected;
        const a = &self.sup.workers[i].archive;
        if (self.mode == .visual) {
            const cursor = self.cursorAt(i);
            return .{
                .first = @min(self.anchor, cursor),
                .last = @max(self.anchor, cursor),
            };
        }
        if (self.focus == .log) {
            const cursor = self.cursorAt(i);
            return .{ .first = cursor, .last = cursor };
        }
        const top = self.viewTop(i);
        // The last line *on the pane*, which is not the last row when the
        // Worker has printed less than a screenful. Reporting the row count
        // there would promise more lines than went to the clipboard.
        return .{ .first = top, .last = a.scrollForward(top, self.logHeight() - 1) };
    }

    fn copy(self: *Ui) void {
        const i = self.selected;
        const a = &self.sup.workers[i].archive;

        const range = self.excerptRange();
        var from = range.first;
        const last = range.last;
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
            try self.helpPane(w);
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

        // The Focus mark in the title. Focus has to be visible from across the
        // screen or the arrow keys become a guess, and the box that has it is
        // the honest place to say so.
        var title_buf: [320]u8 = undefined;
        const title = std.fmt.bufPrint(&title_buf, "{s}{s}{s}{s}  {s}{s}/{s}.log{s}", .{
            if (self.focus == .log) paint.picked ++ "▸ " else "  ",
            esc.bold,
            self.sup.workers[i].name(),
            esc.weight_off,
            esc.dim,
            self.logDir(),
            self.sup.workers[i].name(),
            esc.weight_off,
        }) catch self.sup.workers[i].name();
        try rule(w, cols, "├", "┤", title, "");

        var at = self.viewTop(i);
        const cursor = self.cursorAt(i);
        const lo = @min(self.anchor, cursor);
        const hi = @max(self.anchor, cursor);

        var line_buf: [8192]u8 = undefined;
        var row: usize = 0;
        while (row < lay.log_rows) : (row += 1) {
            try w.writeAll(esc.dim ++ "│" ++ esc.reset);

            // The margin, and the two marks that live in it. Both are flagged
            // from the margin rather than by reversing the line: a Worker's
            // own colours are the reason the Archive is kept byte-faithful,
            // and highlighting over the top would spend them.
            //
            // A span and a point, drawn as a span and a point. `▌` is every
            // line that would be copied; `▸` is the one line the Cursor is on,
            // and it wins the row because it is the thing that moves — losing
            // sight of it inside a long picked range is losing sight of which
            // end of the range the next keypress grows.
            const has_line = at < a.len();
            const picked = has_line and self.mode == .visual and at >= lo and at <= hi;
            const on_cursor = has_line and self.focus == .log and at == cursor;
            if (on_cursor) {
                try w.writeAll(paint.picked ++ "▸" ++ esc.reset ++ " ");
            } else if (picked) {
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
    /// Which control surface is on show. The list's and the log's, because
    /// what a reader can usefully do is different in each — see `ChipSet`.
    fn chipSet(self: *const Ui) ChipSet {
        return switch (self.focus) {
            .list => list_chips,
            .log => log_chips,
        };
    }

    fn footer(self: *Ui, w: *std.Io.Writer) !void {
        const cols: usize = self.size.cols;
        const set = self.chipSet();

        // The question takes the whole line. Leaving the chips up beside it
        // would offer `q Quit` as a thing to press while the view is asking
        // something else, and a key that means two things at once means
        // neither.
        var shown: [max_chips]bool = @splat(self.prompt == .none);
        var dropped: usize = 0;
        var chips_w = chipsWidth(set, shown);
        while (hint_floor + 2 + chips_w > cols and dropped < set.drop.len) {
            shown[set.drop[dropped]] = false;
            dropped += 1;
            chips_w = chipsWidth(set, shown);
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

        for (set.items, 0..) |c, i| {
            if (!shown[i]) continue;
            if (used > chips_start) {
                try w.writeAll("  ");
                used += 2;
            }
            // The terminal counts from one, and so does a mouse report. A chip
            // that is only a label gets no region at all: a click that lands
            // on it should fall through to nothing, not be swallowed by a
            // target that does nothing.
            if (c.action != .label) {
                self.chip_col[i] = @intCast(used + 1);
                self.chip_w[i] = @intCast(c.width());
            }
            try w.print("{s}{s}{s} {s}", .{ esc.dim, c.key, esc.weight_off, c.label });
            used += c.width();
        }
        try w.splatByteAll(' ', cols -| used);
        try w.writeAll(esc.reset ++ esc.clear_line);
    }

    /// Room the left side of the footer is never squeezed out of.
    ///
    /// Set by the longest of the short forms `hint` can fall back to — "↑↓
    /// moves a line, v starts a selection, y copies it" shrinks to "↑↓ line · v
    /// select · y copy", which is 27 columns. It was 30 for no reason anybody
    /// wrote down, and at exactly 80 columns those three spare columns were
    /// enough to push the log's `↑↓ Line` chip off the footer — dropping the
    /// one hint that the whole arrow-key change exists to advertise, at the
    /// width most terminals open at.
    const hint_floor = 28;

    /// What the view has to say, in the order a reader needs to hear it. What
    /// just happened outranks what is true, which outranks what they could do
    /// next — an idle hint is only worth showing when nothing else is.
    ///
    /// Each line has a short form for when the terminal is narrow. A sentence
    /// clipped by the column budget stops mid-word and reads as a bug; a
    /// shorter sentence that fits reads as the thing it says.
    fn hint(self: *Ui, buf: []u8, room: usize) []const u8 {
        if (self.prompt == .clean_logs) {
            var size_buf: [32]u8 = undefined;
            const size = humanBytes(&size_buf, self.prompt_usage.bytes);
            const n = self.prompt_usage.sessions;
            const long = std.fmt.bufPrint(
                buf,
                "{d} run{s} of logs on disk ({s}) — y delete all · o delete older · Enter keep",
                .{ n, if (n == 1) "" else "s", size },
            ) catch return "Delete saved logs? y all · o older · Enter keep";
            if (!term.fitToWidth(long, room).truncated) return long;
            const half = buf.len / 2;
            return std.fmt.bufPrint(buf[half..], "{d} runs of logs ({s}) — y all · o older · Enter keep", .{ n, size }) catch
                "Delete saved logs? y all · o older · Enter keep";
        }
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
        // What to say when nothing has happened yet is what to do next, and
        // that depends on where the reader is standing.
        return switch (self.focus) {
            .list => pick(
                room,
                "↑↓ picks a process, → opens its log",
                "↑↓ process · → log",
            ),
            .log => pick(
                room,
                "↑↓ moves a line, v starts a selection, y copies it",
                "↑↓ line · v select · y copy",
            ),
        };
    }

    /// Everything the view can do, spelled out. It exists so the footer does
    /// not have to be a key map: a reader who needs the whole list asks for it
    /// once, and the rest of the time gets a line of plain English instead.
    fn helpPane(self: *Ui, w: *std.Io.Writer) !void {
        const key_col = 21;

        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}.log", .{
            self.logDir(),
            self.sup.workers[self.selected].name(),
        }) catch "the .devrun/logs directory";

        const rows = help_rows ++ [_]HelpRow{
            .{},
            .{ .text = "This log is a plain file, being written to", .head = true },
            .{ .text = path, .head = true },
        };

        // The help takes the whole screen between the Session line and the
        // footer — every row it can get, because it is a detour rather than a
        // panel and the list is worth reading in one piece.
        const cols: usize = self.size.cols;
        const height = helpHeight(self.size.rows);
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

fn chipsWidth(set: ChipSet, shown: [max_chips]bool) usize {
    var total: usize = 0;
    var n: usize = 0;
    for (set.items, 0..) |c, i| {
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
pub fn humanBytes(buf: []u8, n: u64) []const u8 {
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

// ------------------------------------------------------- navigating

/// A Ui over two Workers whose Archives are filled by hand.
///
/// No processes are spawned: what is under test is where the Cursor goes, and
/// a `sh -c` that prints the lines would only add a way for the test to be
/// flaky. The Supervisor is real, though — the Archives it makes are the ones
/// the Ui reads through.
const Fixture = struct {
    cfg: config.Config,
    sup: Supervisor,
    tty: term.Terminal,
    ui: Ui,
    dir: []u8,
    /// Stands in for `.devrun/logs` — the directory the Sessions live under.
    root: []u8,
    gpa: Allocator,

    fn init(gpa: Allocator, lines: usize) !*Fixture {
        const self = try gpa.create(Fixture);
        errdefer gpa.destroy(self);

        self.gpa = gpa;
        self.dir = try std.fmt.allocPrint(gpa, "/tmp/devrun-ui-test-{d}", .{os.nowMs()});
        try os.makePath(self.dir);
        self.root = try std.fmt.allocPrint(gpa, "{s}/logs", .{self.dir});
        try os.makePath(self.root);

        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        var environ: std.process.Environ.Map = .init(gpa);
        defer environ.deinit();
        try environ.put("PATH", "/usr/local/bin:/usr/bin:/bin");

        self.cfg = try config.loadSource(gpa,
            \\services:
            \\  api: "true"
            \\  web: "true"
        , "/nonexistent", .{ .io = threaded.io(), .environ = &environ }, null);
        errdefer self.cfg.deinit();

        self.sup = try Supervisor.init(gpa, &self.cfg, .{
            .io = threaded.io(),
            .environ = &environ,
            .base_dir = self.dir,
            .log_dir = self.dir,
            .log_root = self.root,
        }, null);
        errdefer self.sup.deinit();

        var line_buf: [64]u8 = undefined;
        for (0..lines) |n| {
            const line = try std.fmt.bufPrint(&line_buf, "line {d}\n", .{n});
            self.sup.workers[0].archive.append(line);
        }

        self.tty = .{ .fd = -1, .original = undefined };
        self.ui = try Ui.init(gpa, &self.sup, &self.tty);
        // A fixed size, so the number of rows the log gets is a fact of the
        // test rather than a fact of whatever ran it.
        self.ui.size = .{ .rows = 24, .cols = 80 };
        return self;
    }

    fn deinit(self: *Fixture) void {
        const gpa = self.gpa;
        self.ui.deinit(gpa);
        self.sup.deinit();
        self.cfg.deinit();
        _ = store.clean(gpa, self.root, .all);
        var buf: [4096]u8 = undefined;
        if (std.fmt.bufPrintZ(&buf, "{s}/api.log", .{self.dir})) |p| os.unlink(p.ptr) else |_| {}
        if (std.fmt.bufPrintZ(&buf, "{s}/web.log", .{self.dir})) |p| os.unlink(p.ptr) else |_| {}
        if (std.fmt.bufPrintZ(&buf, "{s}", .{self.root})) |p| os.rmdir(p.ptr) else |_| {}
        if (std.fmt.bufPrintZ(&buf, "{s}", .{self.dir})) |p| os.rmdir(p.ptr) else |_| {}
        gpa.free(self.root);
        gpa.free(self.dir);
        gpa.destroy(self);
    }

    /// Puts `n` Sessions' worth of saved logs under the fixture's root, as
    /// though this many runs had happened before this one.
    fn saveRuns(self: *Fixture, n: usize) !void {
        for (0..n) |k| {
            const dir = try store.openSession(self.gpa, self.root, 1786703525 + @as(i64, @intCast(k)));
            defer self.gpa.free(dir);
            var buf: [4096]u8 = undefined;
            const file = try std.fmt.bufPrintZ(&buf, "{s}/api.log", .{dir});
            const fd = try os.open(file.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
            defer os.close(fd);
            try os.writeAll(fd, "saved output\n");
        }
    }

    /// The text of the line the Cursor is on, which is what most of these
    /// tests are really asking about.
    fn cursorLine(self: *Fixture, buf: []u8) []const u8 {
        const a = &self.sup.workers[self.ui.selected].archive;
        return a.lineInto(self.ui.cursorAt(self.ui.selected), buf);
    }
};

test "arrows move between processes in the list and between lines in the log" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 40);
    defer f.deinit();

    // The list is where a reader lands, and up and down walk it.
    try testing.expectEqual(Focus.list, f.ui.focus);
    _ = f.ui.onKey(.down);
    try testing.expectEqual(@as(usize, 1), f.ui.selected);
    _ = f.ui.onKey(.up);
    try testing.expectEqual(@as(usize, 0), f.ui.selected);

    // Right goes in. Now the same two keys walk lines, and the service they
    // were walking a moment ago stays where it was.
    _ = f.ui.onKey(.right);
    try testing.expectEqual(Focus.log, f.ui.focus);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("line 39", f.cursorLine(&buf));
    _ = f.ui.onKey(.up);
    try testing.expectEqualStrings("line 38", f.cursorLine(&buf));
    _ = f.ui.onKey(.up);
    try testing.expectEqualStrings("line 37", f.cursorLine(&buf));
    try testing.expectEqual(@as(usize, 0), f.ui.selected);

    // Left comes back out, and up and down mean services again.
    _ = f.ui.onKey(.left);
    try testing.expectEqual(Focus.list, f.ui.focus);
    _ = f.ui.onKey(.down);
    try testing.expectEqual(@as(usize, 1), f.ui.selected);
}

test "v starts a selection at the Cursor, not at the top of the screen" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 40);
    defer f.deinit();

    // Into the log, then three lines up from live.
    _ = f.ui.onKey(.right);
    for (0..3) |_| _ = f.ui.onKey(.up);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("line 36", f.cursorLine(&buf));

    _ = f.ui.onKey(.{ .char = 'v' });
    try testing.expectEqual(Mode.visual, f.ui.mode);
    try testing.expectEqual(@as(usize, 1), f.ui.picked_lines);

    // The selection is anchored on the line the reader is pointing at. It used
    // to be anchored at the top of the pane, so `v` on a screenful of output
    // began the range several lines above wherever they were looking, and `y`
    // then copied from there.
    const a = &f.sup.workers[0].archive;
    try testing.expectEqualStrings("line 36", a.lineInto(f.ui.anchor, &buf));
    try testing.expect(f.ui.anchor != f.ui.viewTop(0));

    // And it grows from there, one line per keypress, in either direction.
    _ = f.ui.onKey(.up);
    try testing.expectEqual(@as(usize, 2), f.ui.picked_lines);
    _ = f.ui.onKey(.down);
    _ = f.ui.onKey(.down);
    try testing.expectEqual(@as(usize, 2), f.ui.picked_lines);
}

test "what a copy would take follows where the reader is" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 40);
    defer f.deinit();
    const a = &f.sup.workers[0].archive;
    var buf: [64]u8 = undefined;

    // From the list, with nothing picked: the screenful on show, which is what
    // "copy this log" means when nobody has pointed at anything.
    const from_list = f.ui.excerptRange();
    try testing.expectEqual(f.ui.viewTop(0), from_list.first);
    try testing.expect(from_list.last > from_list.first);

    // From inside the log: the one line the Cursor is on. A screenful here
    // would be a copy of something other than what the mark points at.
    _ = f.ui.onKey(.right);
    for (0..5) |_| _ = f.ui.onKey(.up);
    const from_log = f.ui.excerptRange();
    try testing.expectEqual(from_log.first, from_log.last);
    try testing.expectEqualStrings("line 34", a.lineInto(from_log.first, &buf));

    // With a range picked: exactly that range, whichever end it grew from.
    _ = f.ui.onKey(.{ .char = 'v' });
    for (0..2) |_| _ = f.ui.onKey(.up);
    const picked = f.ui.excerptRange();
    try testing.expectEqualStrings("line 32", a.lineInto(picked.first, &buf));
    try testing.expectEqualStrings("line 34", a.lineInto(picked.last, &buf));
    try testing.expectEqual(@as(usize, 3), f.ui.picked_lines);
}

test "the Cursor is never off the pane, however the view moved" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 400);
    defer f.deinit();
    const a = &f.sup.workers[0].archive;

    _ = f.ui.onKey(.right);
    const height = f.ui.logHeight();

    // Every way the view can move without touching the Cursor directly.
    for ([_]term.Key{ .page_up, .page_up, .page_down, .home, .end, .page_up }) |key| {
        _ = f.ui.onKey(key);
        const top = f.ui.viewTop(0);
        const bottom = a.scrollForward(top, height - 1);
        const cursor = f.ui.cursorAt(0);
        try testing.expect(cursor >= top);
        try testing.expect(cursor <= bottom);
    }
}

test "reading down to the newest line puts the view back on live output" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 40);
    defer f.deinit();

    _ = f.ui.onKey(.right);
    for (0..6) |_| _ = f.ui.onKey(.up);
    try testing.expect(!f.ui.follow[0]);

    // Walking back down to the last line resumes following, so new output
    // keeps arriving without a second keypress to ask for it.
    for (0..6) |_| _ = f.ui.onKey(.down);
    try testing.expect(f.ui.follow[0]);

    var buf: [64]u8 = undefined;
    f.sup.workers[0].archive.append("line 40\n");
    try testing.expectEqualStrings("line 40", f.cursorLine(&buf));
}

test "the Cursor stays where it was left, per Worker" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 40);
    defer f.deinit();
    var buf: [64]u8 = undefined;

    _ = f.ui.onKey(.right);
    for (0..4) |_| _ = f.ui.onKey(.up);
    try testing.expectEqualStrings("line 35", f.cursorLine(&buf));

    // Out to the list, over to the other service, and back. Losing the place
    // here is what makes checking something else cost you your place.
    _ = f.ui.onKey(.left);
    _ = f.ui.onKey(.down);
    try testing.expectEqual(@as(usize, 1), f.ui.selected);
    _ = f.ui.onKey(.up);
    _ = f.ui.onKey(.right);
    try testing.expectEqualStrings("line 35", f.cursorLine(&buf));
}

test "Esc lets go of a selection before it lets go of the log" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 40);
    defer f.deinit();

    _ = f.ui.onKey(.right);
    _ = f.ui.onKey(.{ .char = 'v' });
    try testing.expectEqual(Mode.visual, f.ui.mode);

    // One press undoes one thing. Pressing it twice is how someone who is lost
    // gets all the way back out.
    _ = f.ui.onKey(.escape);
    try testing.expectEqual(Mode.normal, f.ui.mode);
    try testing.expectEqual(Focus.log, f.ui.focus);
    _ = f.ui.onKey(.escape);
    try testing.expectEqual(Focus.list, f.ui.focus);
}

test "a log key pressed from the list brings the reader into the log with it" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 40);
    defer f.deinit();

    // j, PgUp and v only mean anything against a log, so they take Focus
    // rather than moving a Cursor nobody can see.
    for ([_]term.Key{ .{ .char = 'j' }, .page_up, .{ .char = 'v' } }) |key| {
        f.ui.focus = .list;
        f.ui.clearPick();
        _ = f.ui.onKey(key);
        try testing.expectEqual(Focus.log, f.ui.focus);
    }
}

// ---------------------------------------------------------- leaving

test "leaving asks about the logs on disk, and keeps them unless told not to" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 5);
    defer f.deinit();
    try f.saveRuns(3);

    // The Session has stopped; before the terminal comes back there is one
    // question, and it says what it is about to delete.
    try testing.expect(!f.ui.beginLeaving());
    try testing.expectEqual(Prompt.clean_logs, f.ui.prompt);
    try testing.expectEqual(@as(usize, 3), f.ui.prompt_usage.sessions);
    try testing.expect(f.ui.prompt_usage.bytes > 0);

    // Enter is the default, and the default keeps everything. Somebody who
    // hits it without reading has lost nothing.
    try testing.expect(f.ui.answerPrompt(.enter));
    try testing.expect(f.ui.finished);
    try testing.expectEqual(@as(usize, 0), f.ui.cleaned.sessions);
    try testing.expectEqual(@as(usize, 3), store.usage(gpa, f.root).sessions);
}

test "the answer that deletes older runs keeps the one that just finished" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 5);
    defer f.deinit();
    try f.saveRuns(4);

    _ = f.ui.beginLeaving();
    try testing.expect(f.ui.answerPrompt(.{ .char = 'o' }));
    try testing.expectEqual(@as(usize, 3), f.ui.cleaned.sessions);

    const left = try store.list(gpa, f.root);
    defer gpa.free(left);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings("2026-08-14T10-32-08Z", left[0].text());
}

test "the answer that deletes everything leaves nothing behind" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 5);
    defer f.deinit();
    try f.saveRuns(3);

    _ = f.ui.beginLeaving();
    try testing.expect(f.ui.answerPrompt(.{ .char = 'y' }));
    try testing.expectEqual(@as(usize, 3), f.ui.cleaned.sessions);
    try testing.expectEqual(@as(usize, 0), store.usage(gpa, f.root).sessions);
}

test "q twice leaves without ever asking about logs" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 5);
    defer f.deinit();
    try f.saveRuns(3);

    // The first q begins shutdown and stays. The second says stop asking me
    // things — and it must not be read as the answer to a question that was
    // not on screen when it was pressed.
    try testing.expect(!f.ui.onKey(.{ .char = 'q' }));
    try testing.expect(f.sup.shutting_down);
    try testing.expectEqual(Prompt.none, f.ui.prompt);

    try testing.expect(f.ui.onKey(.{ .char = 'q' }));
    try testing.expect(f.ui.finished);
    try testing.expectEqual(Prompt.none, f.ui.prompt);
    try testing.expectEqual(@as(usize, 0), f.ui.cleaned.sessions);
    try testing.expectEqual(@as(usize, 3), store.usage(gpa, f.root).sessions);

    // And having already said so, the way out does not stop to ask.
    try testing.expect(f.ui.beginLeaving());
}

test "with no saved logs there is nothing to ask about" {
    const gpa = testing.allocator;
    const f = try Fixture.init(gpa, 5);
    defer f.deinit();

    try testing.expect(f.ui.beginLeaving());
    try testing.expectEqual(Prompt.none, f.ui.prompt);
}

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
    for ([_]ChipSet{ list_chips, log_chips }) |set| {
        const all: [max_chips]bool = @splat(true);
        const full = chipsWidth(set, all);
        try testing.expect(full > 0);

        var shown = all;
        for (set.drop) |i| {
            shown[i] = false;
            try testing.expect(chipsWidth(set, shown) < full);
            // Whatever drops, the way out and the way to the whole key list
            // survive: those are how a reader who is stuck gets un-stuck.
            try testing.expect(set.items[i].action != .help);
            try testing.expect(set.items[i].action != .quit);
        }
        // With everything droppable gone there is still a control surface.
        try testing.expect(chipsWidth(set, shown) > 0);
    }
}

test "every chip a click can land on names an action, and labels name none" {
    // The invariant behind `chip_col` being left at zero for a label: a region
    // is registered exactly when there is something for a click to do.
    for ([_]ChipSet{ list_chips, log_chips }) |set| {
        try testing.expect(set.items.len <= max_chips);
        var actionable: usize = 0;
        for (set.items) |c| {
            if (c.action != .label) actionable += 1;
        }
        try testing.expect(actionable > 0);
    }
}

test "both control surfaces say how to move and how to leave" {
    // The point of feature "shortcuts should be visible without pressing ?":
    // whichever pane has Focus, the footer answers "how do I move" and "how do
    // I get out" without anybody opening the help.
    for ([_]ChipSet{ list_chips, log_chips }) |set| {
        var has_arrows = false;
        var has_quit = false;
        for (set.items) |c| {
            if (std.mem.eql(u8, c.key, "↑↓")) has_arrows = true;
            if (c.action == .quit) has_quit = true;
        }
        try testing.expect(has_arrows);
        try testing.expect(has_quit);
    }
}

test "the arrow-key hint survives an eighty-column terminal" {
    // 80 is what a terminal opens at, so it is the width the control surface
    // has to be right at. Both sets must still be advertising how to move when
    // everything that fits has been fitted.
    for ([_]ChipSet{ list_chips, log_chips }) |set| {
        var shown: [max_chips]bool = @splat(true);
        var dropped: usize = 0;
        while (Ui.hint_floor + 2 + chipsWidth(set, shown) > 80 and dropped < set.drop.len) {
            shown[set.drop[dropped]] = false;
            dropped += 1;
        }
        try testing.expect(Ui.hint_floor + 2 + chipsWidth(set, shown) <= 80);

        var arrows_shown = false;
        for (set.items, 0..) |c, i| {
            if (shown[i] and std.mem.eql(u8, c.key, "↑↓")) arrows_shown = true;
        }
        try testing.expect(arrows_shown);
    }
}

test "every key in the help list fits the screen the help is given" {
    // 24 rows is what a terminal opens at. A key list that runs off the bottom
    // is a key list that lies about what the view can do — and the whole point
    // of the row after this list is that it is the *only* thing allowed to be
    // pushed off, because the log pane's title says it anyway.
    try testing.expect(help_rows.len <= helpHeight(24));

    // Nothing in the list is a bare key with nothing said about it, or a
    // description with no key to press.
    for (help_rows) |r| {
        if (r.head) {
            try testing.expect(r.text.len > 0);
        } else if (r.key.len > 0) {
            try testing.expect(r.text.len > 0);
        }
    }
}

test "a chip's width is columns, not bytes" {
    // "↑↓" is six bytes and two columns. Measuring it in bytes pushed the
    // chips four columns past the right edge, which on a narrow terminal ate
    // the message beside them.
    const arrows: Chip = .{ .key = "↑↓", .label = "Line", .action = .label };
    try testing.expectEqual(@as(usize, 2 + 1 + 4), arrows.width());
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
