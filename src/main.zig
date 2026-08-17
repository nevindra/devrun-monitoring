const std = @import("std");
const config = @import("config.zig");
const os = @import("os.zig");
const archive = @import("archive.zig");
const probe = @import("probe.zig");
const supervisor = @import("supervisor.zig");
const plain = @import("plain.zig");
const control = @import("control.zig");
const logs_mod = @import("logs.zig");
const report = @import("report.zig");
const tui = @import("tui.zig");
const term = @import("term.zig");
const sample = @import("sample.zig");
const update = @import("update.zig");

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
    \\  devrun up [--detach]            Start every process and supervise them
    \\  devrun run CMD...               Supervise one command, with no config file
    \\  devrun down                     Shut a running Session down
    \\  devrun wait [--timeout D]       Block until everything is ready, or fail
    \\  devrun logs [NAME...]           Every process's output, merged by time
    \\  devrun errors                   What broke, and the log under it
    \\  devrun status [--json]          What each process is doing right now
    \\  devrun samples                  Per-process CPU, memory, and disk I/O
    \\  devrun config [FILE]            What devrun understood from a config
    \\  devrun start|stop|restart NAME  Act on one process of a running Session
    \\  devrun init [-o FILE]           Write the agent instructions into AGENTS.md
    \\  devrun update                   Replace this binary with the latest release
    \\  devrun version                  Print the version and exit
    \\
    \\Options for `logs` and `errors`:
    \\  --since D          Only what was written in the last D (30s, 2m, 1h, 1d)
    \\  --tail N           Only the last N lines (default 100, 1000 with --since)
    \\  --all              No line limit
    \\  --grep P           Keep lines containing any of P, `|`-separated
    \\  -i                 Make --grep case-insensitive
    \\  --json             One ndjson object per line: {"ts","w","msg"}
    \\  --raw              Byte-for-byte: keep ANSI, collapse nothing, clip nothing
    \\  --no-time          Drop the leading timestamp
    \\  --max-line N       Clip a line past N bytes (default 1200, 0 to disable)
    \\  --path             Print the Archives' paths instead of their contents
    \\
    \\Options for `run` (they go before the command):
    \\  --name NAME        What to call it (default: the program's name)
    \\  --cwd DIR          Working directory
    \\  --restart POLICY   no, always, on_failure, exit_on_failure (default: no)
    \\  --ready-log TEXT   Count it ready once this appears in its output
    \\  --shell            Let the shell split the words, for `--shell 'a; b'`
    \\
    \\`devrun run` exits with the command's own exit status. Its words are
    \\passed through untouched, so `devrun run pnpm dev --json` gives --json to
    \\pnpm. Use `--` first if the command's own name starts with a dash.
    \\
    \\Other options:
    \\  -f FILE            Config to read (default: process-compose.yaml)
    \\  --plain            Never draw the TUI, even on a terminal
    \\  --detach, -d       Run the Session in the background and return once
    \\                     every process is ready
    \\  --timeout D        How long `wait` and `up --detach` give it (default 2m)
    \\  --window-bytes N   In-memory log cache across all processes (default 1M).
    \\                     Accepts K/M/G. Scrollback past it is read from the
    \\                     log file, so this trades RSS for nothing much.
    \\
    \\Logs are files. `.devrun/logs/<name>.log` is a plain file being appended
    \\to right now — tail it, grep it, open it in an editor. `devrun logs`
    \\merges them by time and trims the noise; `--raw --all` gives them back.
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
    var positional: [64][]const u8 = undefined;
    const is_run = args.len > 1 and std.mem.eql(u8, args[1], "run");
    const rest = cli.parseFlags(args[2..], &positional, is_run) catch |e| {
        switch (e) {
            error.BadWindowBytes => try err(
                io,
                "devrun: --window-bytes needs a size, like 1M, 512K, or 262144\n",
                .{},
            ),
            error.BadDuration => try err(
                io,
                "devrun: --since and --timeout need a duration, like 30s, 2m, or 1h\n",
                .{},
            ),
            error.BadCount => try err(io, "devrun: --tail and --max-line need a number\n", .{}),
            error.BadRestart => try err(
                io,
                "devrun: --restart takes no, always, on_failure, or exit_on_failure\n",
                .{},
            ),
            error.UnknownFlag => try err(
                io,
                "devrun: unknown option \"{s}\". `devrun` with no arguments lists them.\n",
                .{cli.bad_flag},
            ),
            else => try err(io, "devrun: {s} needs a value\n", .{cli.bad_flag}),
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
    if (std.mem.eql(u8, cmd, "run")) {
        if (rest.len == 0) {
            try err(io, "devrun: run needs a command, like `devrun run pnpm dev`\n", .{});
            return 2;
        }
        return cli.runCommand(out, rest);
    }
    if (std.mem.eql(u8, cmd, "logs")) return cli.showLogs(out, rest);
    if (std.mem.eql(u8, cmd, "errors")) return cli.showErrors(out);
    if (std.mem.eql(u8, cmd, "wait")) return cli.waitReady(out);
    if (std.mem.eql(u8, cmd, "down")) return cli.ask(out, "down", null);
    if (std.mem.eql(u8, cmd, "init")) return cli.writeAgentDoc(out);
    if (std.mem.eql(u8, cmd, "update")) return update.run(gpa, io, init.environ_map, out);
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version")) {
        return update.printVersion(out);
    }
    if (std.mem.eql(u8, cmd, "status")) return cli.showStatus(out);
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

    detach: bool = false,
    timeout_ms: u64 = 2 * 60 * 1000,

    // `run`.
    name: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    restart: config.Restart = .no,
    ready_log: ?[]const u8 = null,
    /// Join the command's words raw and let the shell split them again,
    /// instead of quoting each one.
    shell_mode: bool = false,

    // `logs` and `errors`. Two of these are three-state: `tail` and `max_line`
    // each need to tell "the user said 100" from "the user said nothing", so
    // the default can depend on the other flags.
    since_ms: ?u64 = null,
    tail: ?usize = null,
    tail_given: bool = false,
    all: bool = false,
    grep: ?[]const u8 = null,
    ignore_case: bool = false,
    json: bool = false,
    raw: bool = false,
    no_time: bool = false,
    want_path: bool = false,
    max_line: ?usize = null,
    out_path: ?[]const u8 = null,

    /// The flag that made `parseFlags` fail, so the message can name it.
    bad_flag: []const u8 = "",

    /// Pulls the options out and hands back whatever was positional, written
    /// into `into` so the result outlives this frame. Every slice points at
    /// argv, which outlives every command.
    ///
    /// An unrecognised `-` argument is an error rather than a positional. The
    /// config loader already refuses fields it does not understand for the
    /// same reason: `devrun logs --tial 5` silently reading `--tial` as a
    /// process name, finding no such process, and printing nothing is a worse
    /// afternoon than being told which word was wrong.
    fn parseFlags(
        self: *Cli,
        args: []const []const u8,
        into: [][]const u8,
        /// `devrun run` mode: stop at the first thing that is not a devrun
        /// flag and hand back the rest untouched. Without this,
        /// `devrun run pnpm dev --json` would have `--json` taken as devrun's
        /// own, and a command could never be given a flag devrun also uses.
        /// An explicit `--` ends the flags too, for a command whose own name
        /// begins with a dash.
        stop_at_command: bool,
    ) ![]const []const u8 {
        var n: usize = 0;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            self.bad_flag = a;

            if (stop_at_command and std.mem.eql(u8, a, "--")) {
                return args[i + 1 ..];
            }
            if (stop_at_command and !(a.len > 1 and a[0] == '-')) {
                return args[i..];
            }

            if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--file")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                self.path = args[i];
            } else if (std.mem.eql(u8, a, "-o") or std.mem.eql(u8, a, "--output")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                self.out_path = args[i];
            } else if (std.mem.eql(u8, a, "--name")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                self.name = args[i];
            } else if (std.mem.eql(u8, a, "--cwd")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                self.cwd = args[i];
            } else if (std.mem.eql(u8, a, "--ready-log")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                self.ready_log = args[i];
            } else if (std.mem.eql(u8, a, "--restart")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                self.restart = std.meta.stringToEnum(config.Restart, args[i]) orelse
                    return error.BadRestart;
            } else if (std.mem.eql(u8, a, "--shell")) {
                self.shell_mode = true;
            } else if (std.mem.eql(u8, a, "--plain")) {
                self.force_plain = true;
            } else if (std.mem.eql(u8, a, "-d") or std.mem.eql(u8, a, "--detach")) {
                self.detach = true;
            } else if (std.mem.eql(u8, a, "--json")) {
                self.json = true;
            } else if (std.mem.eql(u8, a, "--raw")) {
                self.raw = true;
            } else if (std.mem.eql(u8, a, "--no-time")) {
                self.no_time = true;
            } else if (std.mem.eql(u8, a, "--path")) {
                self.want_path = true;
            } else if (std.mem.eql(u8, a, "--all")) {
                self.all = true;
            } else if (std.mem.eql(u8, a, "-i") or std.mem.eql(u8, a, "--ignore-case")) {
                self.ignore_case = true;
            } else if (std.mem.eql(u8, a, "--grep")) {
                i += 1;
                if (i >= args.len) return error.MissingValue;
                self.grep = args[i];
            } else if (std.mem.eql(u8, a, "--since")) {
                i += 1;
                if (i >= args.len) return error.BadDuration;
                self.since_ms = logs_mod.parseDuration(args[i]) orelse return error.BadDuration;
            } else if (std.mem.eql(u8, a, "--timeout")) {
                i += 1;
                if (i >= args.len) return error.BadDuration;
                self.timeout_ms = logs_mod.parseDuration(args[i]) orelse return error.BadDuration;
            } else if (std.mem.eql(u8, a, "--tail")) {
                i += 1;
                if (i >= args.len) return error.BadCount;
                self.tail = std.fmt.parseInt(usize, args[i], 10) catch return error.BadCount;
                self.tail_given = true;
            } else if (std.mem.eql(u8, a, "--max-line")) {
                i += 1;
                if (i >= args.len) return error.BadCount;
                self.max_line = std.fmt.parseInt(usize, args[i], 10) catch return error.BadCount;
            } else if (std.mem.eql(u8, a, "--window-bytes")) {
                i += 1;
                if (i >= args.len) return error.BadWindowBytes;
                self.window_bytes = parseSize(args[i]) orelse return error.BadWindowBytes;
            } else if (a.len > 1 and a[0] == '-') {
                return error.UnknownFlag;
            } else if (n < into.len) {
                into[n] = a;
                n += 1;
            }
        }
        self.bad_flag = "";
        return into[0..n];
    }

    /// How many lines to print, folding the three flags that decide it into
    /// one answer. Bounded unless asked otherwise: `devrun logs` has to be safe
    /// to run without knowing how big the log is.
    fn tailLimit(self: Cli) ?usize {
        if (self.all) return null;
        if (self.tail_given) return if (self.tail.? == 0) null else self.tail.?;
        // A time window is a real request, so it gets far more room than the
        // bare default. It is still a cap, because "the last hour" of a
        // firehose is not an answer either.
        if (self.since_ms != null) return logs_mod.Options.windowed_tail;
        return logs_mod.Options.default_tail;
    }

    fn logOptions(self: Cli) logs_mod.Options {
        return .{
            .since_ms = if (self.since_ms) |d| os.realtimeMs() -| d else null,
            .tail = self.tailLimit(),
            .grep = self.grep,
            .ignore_case = self.ignore_case,
            .json = self.json,
            // `--raw` means what it says: every escape back, nothing folded,
            // nothing clipped. One flag to undo all of the trimming, because
            // remembering four is how people end up not trusting any of it.
            .raw = self.raw,
            .collapse = !self.raw,
            .max_line_bytes = if (self.raw) 0 else self.max_line orelse 1200,
            .timestamps = !self.no_time,
        };
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

    /// Every named Worker's output, merged by time. With no names, every
    /// Worker in the config — which is the whole point, and the thing you
    /// cannot get by running one dev server in one terminal.
    ///
    /// This used to print the Archive's path and stop. That was right for a
    /// person, who wanted a filename to paste into a message. It is one wasted
    /// round trip for anything reading the log itself, so the path moved to
    /// `--path` and the contents became the default.
    fn showLogs(self: Cli, out: *std.Io.Writer, names: []const []const u8) !u8 {
        const dir = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.baseDir(), log_dir_suffix });
        defer self.gpa.free(dir);

        const known = self.knownWorkers(dir) catch |e| {
            switch (e) {
                error.NoWorkers => try err(self.io,
                    "devrun: nothing to show. No config here, no Session running,\n" ++
                    "        and no logs in {s}.\n",
                    .{dir},
                ),
                else => try err(self.io, "devrun: cannot list processes: {t}\n", .{e}),
            }
            return 1;
        };
        defer freeNames(self.gpa, known);

        const selected = self.select(known, names) catch return 1;
        defer self.gpa.free(selected);

        if (self.want_path) {
            for (selected) |name| try out.print("{s}/{s}.log\n", .{ dir, name });
            return 0;
        }

        const sources = try logs_mod.openSources(self.gpa, dir, selected);
        defer logs_mod.closeSources(self.gpa, sources);

        const opts = self.logOptions();
        const r = try logs_mod.run(sources, opts, out);
        try out.flush();

        // The note goes to stderr so that `devrun logs --json | jq` is not fed
        // a line of prose, and so a reader piping the output still sees it.
        var note_buf: [512]u8 = undefined;
        var note: std.Io.Writer = .fixed(&note_buf);
        logs_mod.writeNote(r, opts, &note) catch {};
        if (r.missing_index) {
            note.writeAll(
                "devrun: some logs have no .idx sidecar, so their lines carry " ++
                    "no time and sort last. Restart the Session to index them.\n",
            ) catch {};
        }
        if (note.buffered().len > 0) try err(self.io, "{s}", .{note.buffered()});
        return 0;
    }

    /// The names this invocation is about: the ones asked for, or all of them.
    /// An unknown name is refused rather than skipped — printing three of four
    /// requested logs and saying nothing about the fourth is how you conclude
    /// a service is quiet when it is actually misspelled.
    fn select(self: Cli, known: []const []const u8, names: []const []const u8) ![][]const u8 {
        if (names.len == 0) return self.gpa.dupe([]const u8, known);
        for (names) |name| {
            for (known) |k| {
                if (std.mem.eql(u8, k, name)) break;
            } else {
                try err(self.io, "devrun: \"{s}\" is not a process here.\n", .{name});
                try err(self.io, "        Known: ", .{});
                for (known, 0..) |k, i| {
                    try err(self.io, "{s}{s}", .{ if (i > 0) ", " else "", k });
                }
                try err(self.io, "\n", .{});
                return error.NoSuchWorker;
            }
        }
        return self.gpa.dupe([]const u8, names);
    }

    /// Every Worker this directory knows about, from whichever source can
    /// answer. Caller owns the result; free it with `freeNames`.
    ///
    /// Three sources, in the order they are trustworthy:
    ///
    /// 1. **The config**, when there is one. It is the declared truth, and it
    ///    gives the Workers in the order their author wrote them.
    /// 2. **A running Session.** `devrun run` makes a Session with no file
    ///    behind it, so this is the only source that knows about ad-hoc
    ///    commands while they are running.
    /// 3. **The log directory.** Works when neither of the others does, which
    ///    is exactly the case of reading back an ad-hoc run that has already
    ///    finished. Last because it also lists Archives from Workers that have
    ///    since been deleted from the config: their files are not cleaned up,
    ///    only truncated per Session.
    fn knownWorkers(self: Cli, log_dir: []const u8) ![][]const u8 {
        var diag: config.Diagnostic = .{};
        defer diag.deinit(self.gpa);
        if (self.load(&diag)) |loaded| {
            var cfg = loaded;
            defer cfg.deinit();
            if (cfg.workers.len > 0) {
                const all = try self.gpa.alloc([]const u8, cfg.workers.len);
                errdefer self.gpa.free(all);
                var made: usize = 0;
                errdefer for (all[0..made]) |n| self.gpa.free(n);
                for (cfg.workers, all) |w, *slot| {
                    slot.* = try self.gpa.dupe(u8, w.name);
                    made += 1;
                }
                return all;
            }
        } else |_| {}

        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| self.gpa.free(n);
            names.deinit(self.gpa);
        }

        var reply_buf: [64 << 10]u8 = undefined;
        if (self.askQuiet("status\n", &reply_buf)) |reply| {
            var rows = report.Rows.init(reply);
            while (rows.next()) |row| {
                try names.append(self.gpa, try self.gpa.dupe(u8, row.name));
            }
            if (names.items.len > 0) return names.toOwnedSlice(self.gpa);
        }

        const dir_z = try self.gpa.dupeZ(u8, log_dir);
        defer self.gpa.free(dir_z);
        var it = os.DirIter.open(dir_z.ptr) catch return error.NoWorkers;
        defer it.close();
        while (it.next()) |entry| {
            if (!std.mem.endsWith(u8, entry, ".log")) continue;
            try names.append(self.gpa, try self.gpa.dupe(u8, entry[0 .. entry.len - 4]));
        }
        if (names.items.len == 0) return error.NoWorkers;

        // Alphabetical, because a directory hands them back in whatever order
        // the filesystem felt like and a listing that reshuffles between runs
        // is one a reader cannot skim twice.
        std.mem.sort([]const u8, names.items, {}, lessThanName);
        return names.toOwnedSlice(self.gpa);
    }

    /// `askRaw` without the "no Session is running" message, for callers that
    /// have somewhere else to look.
    fn askQuiet(self: Cli, line: []const u8, buf: []u8) ?[]const u8 {
        const dirs = Dirs.init(self.gpa, self.baseDir()) catch return null;
        defer dirs.deinit(self.gpa);
        return control.ask(dirs.sock, line, buf) catch null;
    }

    // ----------------------------------------------------------- status

    fn showStatus(self: Cli, out: *std.Io.Writer) !u8 {
        var reply_buf: [64 << 10]u8 = undefined;
        const reply = self.askRaw("status\n", &reply_buf) catch return 1;
        try report.writeStatus(reply, self.json, out);
        try out.flush();
        return 0;
    }

    /// "Did anything break?" in one call. Exits 1 when something did, so a
    /// script or an agent can branch on the status code without reading a word.
    fn showErrors(self: Cli, out: *std.Io.Writer) !u8 {
        var reply_buf: [64 << 10]u8 = undefined;
        const reply = self.askRaw("status\n", &reply_buf) catch return 1;

        const dir = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ self.baseDir(), log_dir_suffix });
        defer self.gpa.free(dir);

        const broken = try report.writeErrors(self.gpa, reply, .{
            .since_ms = if (self.since_ms) |d| os.realtimeMs() -| d else null,
            .tail = self.tail orelse report.tail_lines,
            .log_dir = dir,
        }, out);
        try out.flush();
        return if (broken) 1 else 0;
    }

    // ----------------------------------------------------------- wait

    const Outcome = enum { ready, broken, timed_out, no_session };

    /// Blocks until every Worker has settled one way or the other. This is the
    /// command that turns "start it, sleep, hope" into something with an exit
    /// code — the shape every caller that is not a person needs.
    fn waitReady(self: Cli, out: *std.Io.Writer) !u8 {
        var reply_buf: [64 << 10]u8 = undefined;
        const outcome = self.pollUntilSettled(&reply_buf, null);
        return self.reportOutcome(out, outcome, &reply_buf);
    }

    /// Polls `status` until it settles. `watch_pid`, when given, is a child
    /// this process forked: if it dies, waiting for its socket to answer is
    /// waiting for something that will never happen.
    fn pollUntilSettled(
        self: Cli,
        reply_buf: []u8,
        watch_pid: ?os.Pid,
    ) Outcome {
        const dirs = Dirs.init(self.gpa, self.baseDir()) catch return .no_session;
        defer dirs.deinit(self.gpa);

        const deadline = os.nowMs() + self.timeout_ms;
        var ever_answered = false;

        while (os.nowMs() < deadline) {
            if (watch_pid != null) {
                if (os.reap()) |r| {
                    _ = r;
                    return if (ever_answered) .broken else .no_session;
                }
            }
            const reply = control.ask(dirs.sock, "status\n", reply_buf) catch {
                // No socket yet. Normal for the first moments of `up --detach`,
                // and terminal for a `wait` with nothing running — the deadline
                // separates the two without needing to know which this is.
                os.sleepMs(poll_interval_ms);
                continue;
            };
            ever_answered = true;

            var settled = true;
            var rows = report.Rows.init(reply);
            while (rows.next()) |row| {
                if (row.broken()) return .broken;
                if (!row.settledEnough()) settled = false;
            }
            if (settled) return .ready;
            os.sleepMs(poll_interval_ms);
        }
        return if (ever_answered) .timed_out else .no_session;
    }

    fn reportOutcome(self: Cli, out: *std.Io.Writer, outcome: Outcome, reply_buf: []u8) !u8 {
        switch (outcome) {
            .no_session => {
                try err(self.io, "devrun: no Session is running here\n", .{});
                return 1;
            },
            .timed_out => {
                try err(self.io, "devrun: still not ready after ", .{});
                try err(self.io, "{d}s. `devrun status` says what is holding it up.\n", .{
                    self.timeout_ms / 1000,
                });
                return 1;
            },
            .ready, .broken => {},
        }
        // Re-ask rather than reuse the polling reply: between the last poll and
        // here a Worker may have moved, and a summary that disagrees with
        // `devrun status` run a second later is worse than one round trip.
        const reply = self.askRaw("status\n", reply_buf) catch return 1;
        try report.writeStatus(reply, self.json, out);
        try out.flush();
        if (outcome == .broken) {
            try err(self.io, "devrun: something failed. `devrun errors` has the log.\n", .{});
            return 1;
        }
        return 0;
    }

    // ----------------------------------------------------------- init

    /// Writes the command vocabulary into the repo's agent instructions.
    ///
    /// This is not documentation for its own sake. An agent reads `AGENTS.md`
    /// before it does anything; a tool that is not named there does not exist
    /// to it, however good the tool is. Everything else in this release is
    /// pointless without this file, which is why it is a command rather than a
    /// paragraph in a README nobody's agent will read.
    ///
    /// The block is delimited, so running this twice replaces it rather than
    /// stacking copies, and anything the reader wrote around it survives.
    fn writeAgentDoc(self: Cli, out: *std.Io.Writer) !u8 {
        const target = self.out_path orelse self.pickAgentFile();

        const existing = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            target,
            self.gpa,
            .limited(4 << 20),
        ) catch "";
        defer if (existing.len > 0) self.gpa.free(existing);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);

        // Everything before the old block, then the new block, then everything
        // after it. A reader who edited around ours keeps their edits.
        var replaced = false;
        if (std.mem.indexOf(u8, existing, begin_marker)) |start| {
            if (std.mem.indexOf(u8, existing[start..], end_marker)) |rel| {
                const stop = start + rel + end_marker.len;
                try buf.appendSlice(self.gpa, existing[0..start]);
                try buf.appendSlice(self.gpa, agent_doc);
                try buf.appendSlice(self.gpa, existing[stop..]);
                replaced = true;
            }
        }
        if (!replaced) {
            try buf.appendSlice(self.gpa, existing);
            if (existing.len > 0 and !std.mem.endsWith(u8, existing, "\n\n")) {
                try buf.appendSlice(
                    self.gpa,
                    if (std.mem.endsWith(u8, existing, "\n")) "\n" else "\n\n",
                );
            }
            try buf.appendSlice(self.gpa, agent_doc);
        }

        std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = target,
            .data = buf.items,
        }) catch |e| {
            try err(self.io, "devrun: cannot write {s}: {t}\n", .{ target, e });
            return 1;
        };

        try out.print("devrun: {s} {s}\n", .{
            if (replaced) "updated the devrun section in" else "wrote the devrun section to",
            target,
        });
        return 0;
    }

    /// Whichever agent file this repo already has. Adding to the one that
    /// exists beats creating a second one that says the same thing.
    fn pickAgentFile(self: Cli) []const u8 {
        _ = self;
        // Sentinel-terminated literals, so `os.open` gets a real NUL rather
        // than a slice re-asserting one it was never promised.
        for ([_][:0]const u8{ "AGENTS.md", "CLAUDE.md" }) |candidate| {
            const fd = os.open(candidate.ptr, .{
                .ACCMODE = .RDONLY,
                .CLOEXEC = true,
            }, 0) catch continue;
            os.close(fd);
            return candidate;
        }
        return "AGENTS.md";
    }

    // ----------------------------------------------------------- up

    fn up(self: Cli, out: *std.Io.Writer) !u8 {
        var diag: config.Diagnostic = .{};
        defer diag.deinit(self.gpa);
        var cfg = self.load(&diag) catch |e| return self.reportLoadFailure(diag, e);
        defer cfg.deinit();
        return self.supervise(out, &cfg, null);
    }

    /// One ad-hoc command, supervised as if it had been a line in a config.
    ///
    /// The point is not to add a feature to the Session, it is to remove the
    /// config file as an entry requirement. Most repos do not have a
    /// `process-compose.yaml`, and until now that meant devrun did nothing at
    /// all in them. `devrun run pnpm dev` gets the Archive, the Index, and
    /// therefore `devrun logs`, `errors`, `wait` and `--detach` in any repo.
    fn runCommand(self: Cli, out: *std.Io.Writer, argv: []const []const u8) !u8 {
        // `--shell` hands the words over untouched for the shell to split.
        // The default quotes them, because the caller's own shell has already
        // done that job once and doing it twice corrupts anything quoted.
        const command = if (self.shell_mode)
            try std.mem.join(self.gpa, " ", argv)
        else
            try config.shellJoin(self.gpa, argv);
        defer self.gpa.free(command);

        // The program name, which is the word the caller will look for in the
        // output. `--name` overrides, and has to when two runs would collide.
        const name = self.name orelse std.fs.path.basename(argv[0]);
        if (name.len == 0) {
            try err(self.io, "devrun: run needs a command, like `devrun run pnpm dev`\n", .{});
            return 2;
        }

        var cfg = config.adhoc(self.gpa, .{
            .name = name,
            .command = command,
            .working_dir = self.cwd,
            .restart = self.restart,
            .ready_log_line = self.ready_log,
        }) catch {
            try err(self.io, "devrun: out of memory\n", .{});
            return 1;
        };
        defer cfg.deinit();

        // A Session of one exists to run that one thing, so its exit status is
        // the answer. Collapsing "exit 3" to a bare 1 would make `devrun run`
        // useless as a wrapper in a script or a Makefile.
        return self.supervise(out, &cfg, 0);
    }

    /// Everything `up` and `run` share: spawn, detach if asked, and pick a
    /// view. `exit_of` names the Worker whose exit status becomes devrun's.
    fn supervise(
        self: Cli,
        out: *std.Io.Writer,
        cfg: *const config.Config,
        exit_of: ?usize,
    ) !u8 {
        const base = self.baseDir();
        const dirs = try Dirs.init(self.gpa, base);
        defer dirs.deinit(self.gpa);

        // The config is parsed *before* the fork so that a bad file is an
        // error on the terminal that typed the command, not a line in a log
        // the caller has not been told about yet.
        var detached = false;
        if (self.detach) {
            switch (try os.fork()) {
                .parent => |pid| {
                    var reply_buf: [64 << 10]u8 = undefined;
                    const outcome = self.pollUntilSettled(&reply_buf, pid);
                    if (outcome == .no_session) {
                        try err(self.io,
                            "devrun: the Session did not come up. {s} has why.\n",
                            .{dirs.session_log},
                        );
                        return 1;
                    }
                    return self.reportOutcome(out, outcome, &reply_buf);
                },
                .child => detached = true,
            }
        }

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

        var opts: supervisor.Options = .{
            .io = self.io,
            .environ = self.environ,
            .base_dir = base,
            .log_dir = dirs.logs,
            .project = project,
        };
        if (self.window_bytes > 0) opts.window_budget = self.window_bytes;

        var sup = supervisor.Supervisor.init(self.gpa, cfg, opts, &sup_diag) catch |e| {
            if (sup_diag.message) |m| {
                try err(self.io, "devrun: {s}\n", .{m});
            } else {
                try err(self.io, "devrun: cannot start: {t}\n", .{e});
            }
            return 1;
        };
        defer sup.deinit();

        // Two Sessions in one directory would truncate each other's Archives
        // on startup and fight over every port their Workers bind, so a live
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

        if (detached) {
            // Only now: leaving the session before the socket is bound would
            // race the parent, which is watching for that socket to decide
            // whether this child is alive.
            os.setsid();
            const log = os.open(dirs.session_log.ptr, .{
                .ACCMODE = .WRONLY,
                .CREAT = true,
                .TRUNC = true,
            }, 0o644) catch -1;
            if (log >= 0) {
                os.redirectStdio(log);
                os.close(log);
            }
            return runPlain(self.gpa, &sup, if (server) |*s| s else null, out, self.io, true, exit_of);
        }

        // A Session of one is a wrapper, not a dashboard. Drawing a table and
        // a log pane around a single `pnpm dev` is worse than the output that
        // command already produces, so `run` takes the plain view unless the
        // caller asks otherwise.
        const interactive = !self.force_plain and exit_of == null and
            (std.Io.File.stdout().isTty(self.io) catch false);
        if (interactive) {
            // stdout can be a terminal while stdin is not — `devrun up < /dev/null`
            // is the usual way. There is nothing to drive a TUI with then, so
            // fall through to the plain view rather than failing.
            return tui.run(self.gpa, &sup, if (server) |*s| s else null, self.io) catch |e| switch (e) {
                error.NotATerminal => runPlain(
                    self.gpa,
                    &sup,
                    if (server) |*s| s else null,
                    out,
                    self.io,
                    false,
                    exit_of,
                ),
                else => e,
            };
        }
        return runPlain(self.gpa, &sup, if (server) |*s| s else null, out, self.io, false, exit_of);
    }

    // ----------------------------------------------------------- control

    fn ask(self: Cli, out: *std.Io.Writer, verb: []const u8, arg: ?[]const u8) !u8 {
        var line_buf: [512]u8 = undefined;
        const line = if (arg) |a|
            try std.fmt.bufPrint(&line_buf, "{s} {s}\n", .{ verb, a })
        else
            try std.fmt.bufPrint(&line_buf, "{s}\n", .{verb});

        var reply_buf: [64 << 10]u8 = undefined;
        const reply = self.askRaw(line, &reply_buf) catch return 1;
        try out.writeAll(reply);
        try out.flush();
        return 0;
    }

    /// One request, one reply, and the same "nothing is running" message
    /// wherever it is asked from.
    fn askRaw(self: Cli, line: []const u8, buf: []u8) ![]const u8 {
        const dirs = try Dirs.init(self.gpa, self.baseDir());
        defer dirs.deinit(self.gpa);

        return control.ask(dirs.sock, line, buf) catch |e| {
            try err(self.io,
                "devrun: no Session is running here (no {s}).\n" ++
                "        Start one with `devrun up --detach`.\n",
                .{dirs.sock},
            );
            return e;
        };
    }
};

fn freeNames(gpa: std.mem.Allocator, names: [][]const u8) void {
    for (names) |n| gpa.free(n);
    gpa.free(names);
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// How often `wait` and the parent of `up --detach` ask again. Short enough
/// that a fast Session does not feel padded, long enough that a slow one is
/// not answering a socket a hundred times a second for no reason.
const poll_interval_ms: u64 = 100;

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

const begin_marker = "<!-- devrun:begin -->";
const end_marker = "<!-- devrun:end -->";

/// What `devrun init` writes. Deliberately short: this lands in a file that is
/// read on every single turn, so every line of it is paid for repeatedly. It
/// says what the tool is for and gives the four commands that matter, and
/// leaves the flag reference to `devrun` with no arguments.
const agent_doc = begin_marker ++
    \\
    \\## Running this project's services
    \\
    \\`devrun` runs every service in `process-compose.yaml` at once and keeps
    \\each one's output in a plain file under `.devrun/logs/`. Prefer it over
    \\running a single dev server in the background: with one server you only
    \\see that server's output, and the error is usually in another one.
    \\
    \\```console
    \\$ devrun up --detach      # start everything; returns once all are ready
    \\$ devrun errors           # did anything break, and the log under it
    \\$ devrun logs --since 2m  # every service's output, merged by time
    \\$ devrun down             # stop everything
    \\```
    \\
    \\With no `process-compose.yaml`, supervise one command instead. The same
    \\`logs`, `errors` and `down` work against it.
    \\
    \\```console
    \\$ devrun run --detach --ready-log "listening on" pnpm dev
    \\```
    \\
    \\`devrun run` exits with the command's own exit status. Its words pass
    \\through untouched, so devrun's flags go before the command.
    \\
    \\`devrun up --detach` exits non-zero if a service fails to come up, and
    \\`devrun errors` exits non-zero while anything is broken, so both can be
    \\branched on without reading their output.
    \\
    \\Useful flags on `logs` and `errors`: `--grep 'panic|ERROR'`, `--tail N`,
    \\`--since 30s`, `--json`, and `--raw` to defeat the trimming. Output is
    \\bounded by default and says at the end what it left out. Run `devrun`
    \\with no arguments for the rest.
    \\
++ end_marker ++ "\n";

/// The per-Session paths, all under `.devrun/` beside the config.
const Dirs = struct {
    logs: []const u8,
    sock: [:0]const u8,
    /// Where a detached Session's own output goes. Not the Workers' output —
    /// that is in the Archives — only devrun's state transitions and anything
    /// that went wrong before there was a Session to report it.
    session_log: [:0]const u8,

    fn init(gpa: std.mem.Allocator, base: []const u8) !Dirs {
        return .{
            .logs = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, log_dir_suffix }),
            .sock = try std.fmt.allocPrintSentinel(gpa, "{s}/.devrun/control.sock", .{base}, 0),
            .session_log = try std.fmt.allocPrintSentinel(gpa, "{s}/.devrun/session.log", .{base}, 0),
        };
    }

    fn deinit(self: Dirs, gpa: std.mem.Allocator) void {
        gpa.free(self.logs);
        gpa.free(self.sock);
        gpa.free(self.session_log);
    }
};

fn runPlain(
    gpa: std.mem.Allocator,
    sup: *supervisor.Supervisor,
    server: ?*control.Server,
    out: *std.Io.Writer,
    io: std.Io,
    quiet: bool,
    /// Worker whose exit status becomes devrun's own. `devrun run` sets it so
    /// that wrapping a command does not throw away what the command said.
    exit_of: ?usize,
) !u8 {
    var printer = try plain.Printer.init(
        gpa,
        sup,
        !quiet and (std.Io.File.stdout().isTty(io) catch false),
    );
    printer.quiet = quiet;
    // A wrapper's job is the command's output, not a running commentary on it.
    printer.announce = exit_of == null;
    defer printer.deinit(gpa);

    while (!sup.done()) {
        var extra: [control.Server.max_poll_fds]os.PollFd = undefined;
        const n = if (server) |s| s.fillPollFds(&extra) else 0;
        try sup.step(extra[0..n], 200);
        if (server) |s| s.service(extra[0..n], sup);
        try printer.flush(sup, out);
    }
    try printer.flush(sup, out);
    if (exit_of) |i| {
        // Faithful to what the command did, including death by signal, which
        // shells report as 128 + the signal number.
        const w = &sup.workers[i];
        const e = w.exit orelse return 1;
        try out.flush();
        return switch (e) {
            .exited => |code| code,
            .signaled => |s| @intCast(128 +| @intFromEnum(s)),
        };
    }
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
    _ = logs_mod;
    _ = report;
    _ = tui;
    _ = term;
    _ = sample;
    _ = update;
}
