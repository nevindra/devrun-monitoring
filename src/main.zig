const std = @import("std");
const config = @import("config.zig");
const os = @import("os.zig");
const archive = @import("archive.zig");
const probe = @import("probe.zig");
const supervisor = @import("supervisor.zig");
const plain = @import("plain.zig");
const control = @import("control.zig");
const tui = @import("tui.zig");
const term = @import("term.zig");
const sample = @import("sample.zig");
const update = @import("update.zig");
const store = @import("store.zig");

/// A byte count as a person would say it. Shared with the TUI rather than
/// written twice: "48 MB" should read the same whether it came from a footer
/// or from `devrun clean`.
const humanBytes = tui.humanBytes;

/// The vendored YAML parser logs every token it sees at `.debug`, which in a
/// Debug build buries anything we print. Its warnings are still worth having.
/// These are all three scopes it uses; re-check after re-syncing the vendor.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .yaml, .level = .warn },
        .{ .scope = .parser, .level = .warn },
        .{ .scope = .tokenizer, .level = .warn },
    },
};

const usage =
    \\devrun — process runner for local development
    \\
    \\Usage:
    \\  devrun up [-f FILE] [--plain]   Start every process and supervise them
    \\  devrun config [FILE]            Print what devrun understood from a config
    \\  devrun logs [-f FILE] NAME      Print the path of a Worker's Archive
    \\  devrun status [-f FILE]         Ask a running Session what it is doing
    \\  devrun samples [-f FILE]        Per-process CPU, memory, and disk I/O
    \\  devrun start|stop|restart NAME  Act on one Worker of a running Session
    \\  devrun clean [--all]            Delete saved logs from previous runs
    \\  devrun update                   Replace this binary with the latest release
    \\  devrun version                  Print the version and exit
    \\
    \\Options:
    \\  -f FILE            Config to read (default: process-compose.yaml)
    \\  --plain            Never draw the TUI, even on a terminal
    \\  --keep N           Log directories to keep from previous runs (default 10).
    \\                     0 keeps every one of them.
    \\  --window-bytes N   In-memory log cache across all processes (default 1M).
    \\                     Accepts K/M/G. Scrollback past it is read from the
    \\                     log file, so this trades RSS for nothing much.
    \\
    \\Logs are files. Every run writes to its own directory, and
    \\`.devrun/logs/latest/<name>.log` is the one being appended to right now —
    \\tail it, grep it, open it in an editor.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [64 << 10]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll(usage);
        return 1;
    }

    var cli: Cli = .{ .environ = init.environ_map, .io = io, .gpa = gpa };
    var positional: [8][]const u8 = undefined;
    const rest = cli.parseFlags(args[2..], &positional) catch |e| {
        switch (e) {
            error.BadWindowBytes => try err(
                io,
                "devrun: --window-bytes needs a size, like 1M, 512K, or 262144\n",
                .{},
            ),
            error.BadKeep => try err(
                io,
                "devrun: --keep needs a count, like 10, or 0 to keep every run\n",
                .{},
            ),
            else => try err(io, "devrun: -f needs a file path\n", .{}),
        }
        return 2;
    };

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "config")) {
        // `devrun config path.yaml` reads more naturally than -f here, and is
        // what the README has always shown.
        if (rest.len > 0) cli.path = rest[0];
        return cli.dumpConfig(out);
    }
    if (std.mem.eql(u8, cmd, "up")) return cli.up(out);
    if (std.mem.eql(u8, cmd, "logs")) {
        if (rest.len == 0) {
            try err(io, "devrun: logs needs a process name\n", .{});
            return 2;
        }
        return cli.logs(out, rest[0]);
    }
    if (std.mem.eql(u8, cmd, "clean")) return cli.clean(out);
    if (std.mem.eql(u8, cmd, "update")) return update.run(gpa, io, init.environ_map, out);
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        return update.printVersion(out);
    }
    if (std.mem.eql(u8, cmd, "status")) return cli.ask(out, "status", null);
    if (std.mem.eql(u8, cmd, "samples")) return cli.ask(out, "samples", null);
    for ([_][]const u8{ "start", "stop", "restart" }) |verb| {
        if (!std.mem.eql(u8, cmd, verb)) continue;
        if (rest.len == 0) {
            try err(io, "devrun: {s} needs a process name\n", .{verb});
            return 2;
        }
        return cli.ask(out, verb, rest[0]);
    }

    try out.print("unknown command \"{s}\"\n\n{s}", .{ cmd, usage });
    return 1;
}

fn err(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};
    try w.print(fmt, args);
}

const Cli = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    path: []const u8 = "process-compose.yaml",
    force_plain: bool = false,
    /// Zero means "whatever the Supervisor's default is", so the default lives
    /// in one place rather than being restated here.
    window_bytes: usize = 0,
    /// How many previous runs' log directories survive the next `devrun up`.
    /// Zero means all of them; see `store.prune`.
    keep: usize = default_keep,
    /// Whether `devrun clean` takes the newest run with it.
    clean_all: bool = false,

    /// Pulls the options out and hands back whatever was positional, written
    /// into `into` so the result outlives this frame. Every slice points at
    /// argv, which outlives every command.
    fn parseFlags(
        self: *Cli,
        args: []const []const u8,
        into: [][]const u8,
    ) ![]const []const u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--file")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                self.path = args[i];
            } else if (std.mem.eql(u8, a, "--plain")) {
                self.force_plain = true;
            } else if (std.mem.eql(u8, a, "--all")) {
                self.clean_all = true;
            } else if (std.mem.eql(u8, a, "--keep")) {
                i += 1;
                if (i >= args.len) return error.BadKeep;
                self.keep = std.fmt.parseInt(usize, args[i], 10) catch return error.BadKeep;
            } else if (std.mem.eql(u8, a, "--window-bytes")) {
                i += 1;
                if (i >= args.len) return error.BadWindowBytes;
                self.window_bytes = parseSize(args[i]) orelse return error.BadWindowBytes;
            } else if (n < into.len) {
                into[n] = a;
                n += 1;
            }
        }
        return into[0..n];
    }

    fn baseDir(self: Cli) []const u8 {
        return std.fs.path.dirname(self.path) orelse ".";
    }

    fn load(self: Cli, diag: *config.Diagnostic) !config.Config {
        return config.load(self.gpa, self.path, .{
            .io = self.io,
            .environ = self.environ,
        }, diag);
    }

    fn reportLoadFailure(self: Cli, diag: config.Diagnostic, e: anyerror) !u8 {
        if (diag.message) |m| {
            try err(self.io, "devrun: {s}\n", .{m});
        } else {
            try err(self.io, "devrun: {s}: {t}\n", .{ self.path, e });
        }
        return 1;
    }

    // ----------------------------------------------------------- config

    fn dumpConfig(self: Cli, out: *std.Io.Writer) !u8 {
        var diag: config.Diagnostic = .{};
        defer diag.deinit(self.gpa);

        var cfg = self.load(&diag) catch |e| return self.reportLoadFailure(diag, e);
        defer cfg.deinit();

        try out.print("shell: {s} {s}\n\n", .{ cfg.shell.command, cfg.shell.argument });
        for (cfg.workers) |w| {
            try out.print("{s}\n", .{w.name});
            if (w.description) |d| try out.print("  description   {s}\n", .{d});
            try out.print("  command       {s}\n", .{w.command});
            if (w.working_dir) |d| try out.print("  working_dir   {s}\n", .{d});
            try out.print("  restart       {t}\n", .{w.restart});
            try out.print("  shutdown      signal {d}, {d}s grace\n", .{
                w.shutdown.signal,
                w.shutdown.timeout_seconds,
            });
            for (w.dotenv) |f| try out.print("  dotenv        {s}\n", .{f});
            for (w.environment) |e| try out.print("  env           {s}\n", .{e});
            for (w.depends_on) |d| {
                try out.print("  depends_on    {s} ({t})\n", .{ d.name, d.condition });
            }
            if (w.ready_log_line) |l| try out.print("  log ready     \"{s}\"\n", .{l});
            if (w.readiness_probe) |p| {
                switch (p.target) {
                    .exec => |c| try out.print("  probe exec    {s}\n", .{c}),
                    .http_get => |h| try out.print(
                        "  probe http    {s}://{s}:{d}{s}\n",
                        .{ h.scheme, h.host, h.port, h.path },
                    ),
                }
                try out.print(
                    "                delay={d}s period={d}s timeout={d}s failures={d}\n",
                    .{ p.initial_delay_seconds, p.period_seconds, p.timeout_seconds, p.failure_threshold },
                );
            }
            try out.writeAll("\n");
        }
        return 0;
    }

    // ----------------------------------------------------------- logs

    /// Prints the path rather than the contents. The whole point of writing
    /// Archives to disk is that the tools for reading files already exist and
    /// are better than anything devrun would grow — so this hands the reader
    /// off to them.
    fn logs(self: Cli, out: *std.Io.Writer, name: []const u8) !u8 {
        var diag: config.Diagnostic = .{};
        defer diag.deinit(self.gpa);
        var cfg = self.load(&diag) catch |e| return self.reportLoadFailure(diag, e);
        defer cfg.deinit();

        if (cfg.find(name) == null) {
            try err(self.io, "devrun: \"{s}\" is not a process in {s}\n", .{ name, self.path });
            return 1;
        }
        // Through the symlink rather than through the newest run's stamped
        // directory. Both name the same file, but this one is still true
        // tomorrow, which is what makes it worth pasting into a note.
        try out.print("{s}/{s}/{s}/{s}.log\n", .{
            self.baseDir(),
            log_dir_suffix,
            store.latest_link,
            name,
        });
        return 0;
    }

    // ----------------------------------------------------------- clean

    /// Deletes saved logs. The counterpart to the offer the TUI makes on the
    /// way out, for everyone who leaves by Ctrl-C, closes the terminal, or
    /// never sees a TUI at all.
    ///
    /// No prompt: a command someone typed is already the confirmation, and one
    /// that asks again is one that cannot be put in a script.
    fn clean(self: Cli, out: *std.Io.Writer) !u8 {
        const dirs = try Dirs.init(self.gpa, self.baseDir());
        defer dirs.deinit(self.gpa);

        // Deleting the Archives out from under a Session that is writing them
        // leaves it appending to files no path reaches any more. `--all` is
        // the only scope that can do it, so it is the only one that is
        // refused; plain `clean` keeps the newest run, which is that Session.
        if (self.clean_all) {
            var probe_buf: [4096]u8 = undefined;
            if (control.ask(dirs.sock, "status\n", &probe_buf)) |_| {
                try err(self.io,
                    "devrun: a Session is running here — its logs are being written to.\n" ++
                    "        Stop it first, or run `devrun clean` to keep just that one.\n",
                    .{},
                );
                return 1;
            } else |_| {}
        }

        const before = store.usage(self.gpa, dirs.logs);
        if (before.sessions == 0) {
            try out.print("No saved logs in {s}\n", .{dirs.logs});
            return 0;
        }

        const removed = store.clean(self.gpa, dirs.logs, if (self.clean_all) .all else .older);
        if (removed.sessions == 0) {
            try out.print(
                "Kept the only run in {s} — `devrun clean --all` deletes it too\n",
                .{dirs.logs},
            );
            return 0;
        }

        var size_buf: [32]u8 = undefined;
        try out.print("Deleted {d} run{s} ({s}) from {s}\n", .{
            removed.sessions,
            if (removed.sessions == 1) "" else "s",
            humanBytes(&size_buf, removed.bytes),
            dirs.logs,
        });
        return 0;
    }

    // ----------------------------------------------------------- up

    fn up(self: Cli, out: *std.Io.Writer) !u8 {
        var diag: config.Diagnostic = .{};
        defer diag.deinit(self.gpa);
        var cfg = self.load(&diag) catch |e| return self.reportLoadFailure(diag, e);
        defer cfg.deinit();

        const base = self.baseDir();
        const dirs = try Dirs.init(self.gpa, base);
        defer dirs.deinit(self.gpa);

        var sup_diag: supervisor.Diagnostic = .{};
        defer sup_diag.deinit(self.gpa);

        // The directory the config was read from, which is the name a reader
        // already has for this repo. "." means the one they are standing in,
        // so that resolves to the working directory's own name rather than
        // showing a Session called ".".
        var cwd_buf: [4096]u8 = undefined;
        const named = std.fs.path.basename(base);
        const project = if (named.len > 0 and !std.mem.eql(u8, named, "."))
            named
        else if (os.getcwd(&cwd_buf)) |cwd| std.fs.path.basename(cwd) else "";

        // This run's own directory, made before anything spawns so no Worker
        // is writing while the store decides what it may delete.
        const session_dir = store.openSession(self.gpa, dirs.logs, os.wallSeconds()) catch |e| {
            try err(self.io, "devrun: cannot make a log directory under {s}: {t}\n", .{ dirs.logs, e });
            return 1;
        };
        defer self.gpa.free(session_dir);
        const pruned = store.prune(self.gpa, dirs.logs, self.keep);

        var opts: supervisor.Options = .{
            .io = self.io,
            .environ = self.environ,
            .base_dir = base,
            .log_dir = session_dir,
            .log_root = dirs.logs,
            .project = project,
        };
        if (self.window_bytes > 0) opts.window_budget = self.window_bytes;

        var sup = supervisor.Supervisor.init(self.gpa, &cfg, opts, &sup_diag) catch |e| {
            if (sup_diag.message) |m| {
                try err(self.io, "devrun: {s}\n", .{m});
            } else {
                try err(self.io, "devrun: cannot start: {t}\n", .{e});
            }
            return 1;
        };
        defer sup.deinit();

        // Two Sessions in one directory would fight over every port their
        // Workers bind and over which of them `devrun stop` means, so a live
        // socket is a refusal rather than a warning. Any *other* failure to
        // open it is not: losing `devrun stop` is no reason to refuse to
        // start anything.
        var server = control.Server.open(dirs.sock) catch |e| switch (e) {
            error.SessionAlreadyRunning => {
                try err(self.io,
                    "devrun: a Session is already running here ({s}).\n" ++
                    "        Stop it first, or run from another directory.\n",
                    .{dirs.sock},
                );
                return 1;
            },
            else => null,
        };
        defer if (server) |*s| s.close(dirs.sock);

        const interactive = !self.force_plain and
            (std.Io.File.stdout().isTty(self.io) catch false);
        if (interactive) {
            // stdout can be a terminal while stdin is not — `devrun up < /dev/null`
            // is the usual way. There is nothing to drive a TUI with then, so
            // fall through to the plain view rather than failing.
            return tui.run(self.gpa, &sup, if (server) |*s| s else null, self.io, .{
                .pruned = pruned.sessions,
            }) catch |e| switch (e) {
                error.NotATerminal => runPlain(
                    self.gpa,
                    &sup,
                    if (server) |*s| s else null,
                    out,
                    self.io,
                    pruned,
                ),
                else => e,
            };
        }
        return runPlain(self.gpa, &sup, if (server) |*s| s else null, out, self.io, pruned);
    }

    // ----------------------------------------------------------- control

    fn ask(self: Cli, out: *std.Io.Writer, verb: []const u8, arg: ?[]const u8) !u8 {
        const dirs = try Dirs.init(self.gpa, self.baseDir());
        defer dirs.deinit(self.gpa);

        var line_buf: [512]u8 = undefined;
        const line = if (arg) |a|
            try std.fmt.bufPrint(&line_buf, "{s} {s}\n", .{ verb, a })
        else
            try std.fmt.bufPrint(&line_buf, "{s}\n", .{verb});

        var reply_buf: [64 << 10]u8 = undefined;
        const reply = control.ask(dirs.sock, line, &reply_buf) catch {
            try err(self.io, "devrun: no Session is running here (no {s})\n", .{dirs.sock});
            return 1;
        };
        try out.writeAll(reply);
        try out.flush();
        return 0;
    }
};

/// A byte count with an optional binary suffix: `262144`, `512K`, `4M`. Null
/// rather than a default on anything unparseable — a mistyped size silently
/// becoming 1 MiB is how you spend an afternoon wondering why a flag did
/// nothing.
fn parseSize(text: []const u8) ?usize {
    if (text.len == 0) return null;
    const last = text[text.len - 1];
    const shift: u6 = switch (last) {
        'k', 'K' => 10,
        'm', 'M' => 20,
        'g', 'G' => 30,
        else => 0,
    };
    const digits = if (shift == 0) text else text[0 .. text.len - 1];
    if (digits.len == 0) return null;
    const n = std.fmt.parseInt(usize, digits, 10) catch return null;
    return std.math.shlExact(usize, n, shift) catch null;
}

const log_dir_suffix = ".devrun/logs";

/// Runs whose logs survive the next `devrun up`.
///
/// Ten is enough to answer "what did it say yesterday?" without letting
/// `.devrun` grow for as long as a repo is checked out. Now that every run
/// keeps its own directory instead of overwriting the one before it, something
/// has to be the thing that forgets — and a person who never quits through the
/// TUI would otherwise never delete anything at all.
const default_keep = 10;

/// The per-Session paths, all under `.devrun/` beside the config.
const Dirs = struct {
    logs: []const u8,
    sock: [:0]const u8,

    fn init(gpa: std.mem.Allocator, base: []const u8) !Dirs {
        return .{
            .logs = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, log_dir_suffix }),
            .sock = try std.fmt.allocPrintSentinel(gpa, "{s}/.devrun/control.sock", .{base}, 0),
        };
    }

    fn deinit(self: Dirs, gpa: std.mem.Allocator) void {
        gpa.free(self.logs);
        gpa.free(self.sock);
    }
};

fn runPlain(
    gpa: std.mem.Allocator,
    sup: *supervisor.Supervisor,
    server: ?*control.Server,
    out: *std.Io.Writer,
    io: std.Io,
    pruned: store.Removed,
) !u8 {
    var printer = try plain.Printer.init(gpa, sup, std.Io.File.stdout().isTty(io) catch false);
    defer printer.deinit(gpa);

    // Said before any Worker's output, because after it nobody would see it.
    // Deleting somebody's logs silently is the one thing retention must not do.
    if (pruned.sessions > 0) {
        var size_buf: [32]u8 = undefined;
        try out.print("devrun: deleted {d} old log run{s} ({s})\n", .{
            pruned.sessions,
            if (pruned.sessions == 1) "" else "s",
            humanBytes(&size_buf, pruned.bytes),
        });
    }

    while (!sup.done()) {
        var extra: [control.Server.max_poll_fds]os.PollFd = undefined;
        const n = if (server) |s| s.fillPollFds(&extra) else 0;
        try sup.step(extra[0..n], 200);
        if (server) |s| s.service(extra[0..n], sup);
        try printer.flush(sup, out);
    }
    try printer.flush(sup, out);
    try printer.summary(sup, out);
    return if (sup.failed_hard or anyFailed(sup)) 1 else 0;
}

fn anyFailed(sup: *supervisor.Supervisor) bool {
    for (sup.workers) |w| {
        if (w.state == .failed) return true;
    }
    return false;
}

test "parseSize reads binary suffixes and refuses anything else" {
    const testing = std.testing;
    try testing.expectEqual(@as(?usize, 262144), parseSize("262144"));
    try testing.expectEqual(@as(?usize, 512 << 10), parseSize("512K"));
    try testing.expectEqual(@as(?usize, 512 << 10), parseSize("512k"));
    try testing.expectEqual(@as(?usize, 4 << 20), parseSize("4M"));
    try testing.expectEqual(@as(?usize, 2 << 30), parseSize("2G"));

    // A typo is a refusal, not a default: silently reading "1MB" as 1 byte —
    // or as anything at all — is worse than saying no.
    try testing.expect(parseSize("1MB") == null);
    try testing.expect(parseSize("") == null);
    try testing.expect(parseSize("K") == null);
    try testing.expect(parseSize("-1") == null);
    try testing.expect(parseSize("lots") == null);
    // And a size that cannot be represented is refused rather than wrapped.
    try testing.expect(parseSize("99999999999G") == null);
}

test {
    _ = config;
    _ = os;
    _ = archive;
    _ = probe;
    _ = supervisor;
    _ = plain;
    _ = control;
    _ = tui;
    _ = term;
    _ = sample;
    _ = update;
    _ = store;
}
