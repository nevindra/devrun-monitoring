//! Reads `devrun.toml` into a Config.
//!
//! The schema is devrun's own, and docs/adr/0008-devrun-toml.md is the record
//! of why it looks the way it does. Two rules carry most of it:
//!
//!   - Everything with an identity is a table keyed by name, never a list.
//!     That is what keeps a TOML file flat at forty services as well as at two.
//!   - Every field has a short form and, where it needs one, a long form.
//!     `after = ["db"]` and `after = { db = "ready" }` mean what they look like,
//!     so a small config stays small without capping a large one.
//!
//! A field devrun does not know is refused, never skipped. Names reserved for
//! a later version are refused with a message saying so, which is what lets
//! them be added later without a file that half-worked yesterday changing
//! meaning today.
//!
//! `${VAR}` is expanded per value, after parsing, and only in fields the shell
//! never sees: `env`, `env_file`, `cwd` and `ready.http`. `run` and
//! `ready.exec` go to the shell untouched, which already knows how to expand a
//! variable, and gets the Worker's environment to expand it from.
//!
//! A service that sets `replicas` is expanded into one Worker per replica, and
//! each replica sees `${DEVRUN_REPLICA}`. That is why those four fields are
//! kept raw until a Worker is built, rather than expanded as they are read.
//!
//! A sibling `devrun.local.toml` is merged over the main file before any of
//! this happens, so it can change anything the main file can.

const std = @import("std");
const toml = @import("toml.zig");

const Allocator = std.mem.Allocator;

/// What `devrun up` reads when `-f` does not say otherwise.
pub const default_path = "devrun.toml";

/// Everything this module needs from outside. Passed explicitly rather than
/// reached for, so tests can supply a synthetic environment.
pub const Options = struct {
    io: std.Io,
    /// The process environment, for `${VAR}`.
    environ: *const std.process.Environ.Map,
    /// Named at the front of a syntax error, so it reads `devrun.toml:12:5:`.
    source_name: []const u8 = default_path,
    /// The `[profiles.<name>]` to activate, if any.
    profile: ?[]const u8 = null,
};

/// Largest config or env file we will read. A devrun.toml is a few KB;
/// anything past this is a mistake, and refusing it beats allocating it.
const max_file_bytes = 4 << 20;

/// Carries the human-readable reason a config was rejected. The message is
/// allocated with the caller's allocator and outlives the failed load, so the
/// caller can print it after the loader's arena is gone.
pub const Diagnostic = struct {
    message: ?[]u8 = null,

    pub fn deinit(self: *Diagnostic, gpa: Allocator) void {
        if (self.message) |m| gpa.free(m);
        self.message = null;
    }
};

/// What one Worker waits for in another before it starts.
pub const Condition = enum {
    /// It has been spawned.
    started,
    /// Its `ready` check passed: a probe, or a line in its output.
    ready,
    /// It ran and ended, however it ended.
    exited,
    /// It ran and exited 0. What a Gate is waited on with.
    succeeded,
};

pub const Restart = enum {
    no,
    always,
    on_failure,
    exit_on_failure,
    exit_on_end,

    /// The spelling the config and the CLI use.
    pub fn label(self: Restart) []const u8 {
        return switch (self) {
            .no => "no",
            .always => "always",
            .on_failure => "on-failure",
            .exit_on_failure => "exit-on-failure",
            .exit_on_end => "exit-on-end",
        };
    }

    pub fn parse(text: []const u8) ?Restart {
        for ([_]Restart{ .no, .always, .on_failure, .exit_on_failure, .exit_on_end }) |r| {
            if (std.mem.eql(u8, text, r.label())) return r;
        }
        return null;
    }
};

pub const HttpGet = struct {
    host: []const u8 = "127.0.0.1",
    scheme: []const u8 = "http",
    path: []const u8 = "/",
    port: u16,
    /// The exact status that counts as ready. Null means any 2xx or 3xx.
    status: ?u16 = null,
};

pub const Probe = struct {
    target: union(enum) {
        exec: []const u8,
        http_get: HttpGet,
    },
    initial_delay_seconds: u32 = 0,
    period_seconds: u32 = 10,
    timeout_seconds: u32 = 1,
    success_threshold: u32 = 1,
    failure_threshold: u32 = 3,
};

pub const Dependency = struct {
    /// Name of the Worker being waited on. The Supervisor resolves it to an
    /// index; this module has already checked that it resolves.
    name: []const u8,
    condition: Condition,
};

/// How a Worker is asked to stop, before the ladder escalates to SIGKILL.
pub const Shutdown = struct {
    /// Signal number. The config accepts a name too, and this is what it
    /// resolves to.
    signal: u8 = 15, // SIGTERM
    /// How long the Group has to exit on its own before it is killed.
    timeout_seconds: u32 = 10,
    /// Run instead of sending `signal`, when set. A graceful stop that is a
    /// command (`docker stop x`) rather than a signal to the process.
    command: ?[]const u8 = null,
};

/// Paths whose changes restart a Worker. Resolved against the Worker's working
/// directory by the Supervisor, so they are kept as written.
pub const Watch = struct {
    paths: []const []const u8,
    /// `default_watch_ignore` followed by the user's own patterns.
    ignore: []const []const u8,
    debounce_ms: u32 = 300,
};

/// What a watch never fires on, because it is either devrun's own output, a
/// dependency tree, or the temp files editors write while saving.
pub const default_watch_ignore = [_][]const u8{ ".git", ".devrun", "node_modules", "__pycache__", ".venv", ".zig-cache", "zig-out", "*.swp", "*.swx", "*~", "4913", ".#*" };

pub const Worker = struct {
    name: []const u8,
    /// The service's name as written. Equal to `name` unless replicated.
    group: []const u8,
    /// 0 when the service does not set `replicas`, else the 1-based index.
    replica: u32 = 0,
    /// Whether this Worker starts in a Session unless `select` says otherwise.
    autostart: bool = true,
    description: ?[]const u8 = null,
    command: []const u8,
    working_dir: ?[]const u8 = null,
    /// Read at spawn, in order, relative to the config's directory.
    env_file: []const []const u8 = &.{},
    /// `KEY=value`, in order. Later entries win, and every entry beats every
    /// env file.
    env: []const []const u8 = &.{},
    depends_on: []const Dependency = &.{},
    restart: Restart = .no,
    /// Set by `ready = { http = ... }` or `{ exec = ... }`.
    readiness_probe: ?Probe = null,
    /// Set by `ready = { log = ... }`. The config never sets both this and
    /// `readiness_probe`; `devrun run --ready-log` sets only this.
    ready_log_line: ?[]const u8 = null,
    shutdown: Shutdown = .{},
    /// Restarts allowed before giving up; 0 is unlimited.
    restart_max: u32 = 0,
    restart_backoff_ms: u32 = 200,
    watch: ?Watch = null,

    /// Whether `after = { x = "ready" }` can ever be satisfied for this one.
    pub fn hasReadyCheck(self: Worker) bool {
        return self.readiness_probe != null or self.ready_log_line != null;
    }
};

pub const Shell = struct {
    command: []const u8 = "bash",
    argument: []const u8 = "-c",
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    shell: Shell,
    workers: []Worker,
    color: bool = true,
    profiles: []const Profile = &.{},
    active_profile: ?[]const u8 = null,
    /// The `devrun.local.toml` that was merged in, if there was one.
    local_path: ?[]const u8 = null,

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }

    /// Index of `name` in `workers`, or null. Linear because a dev config has a
    /// handful of Workers and a map would cost more than it saves.
    pub fn find(self: Config, name: []const u8) ?usize {
        for (self.workers, 0..) |w, i| {
            if (std.mem.eql(u8, w.name, name)) return i;
        }
        return null;
    }
};

pub const Profile = struct {
    name: []const u8,
    /// Service names as written, each a service or a replicated service's name.
    services: []const []const u8,
};

/// Whether `name` means this Worker: its own name, or its service's name.
pub fn matches(w: Worker, name: []const u8) bool {
    return std.mem.eql(u8, w.name, name) or std.mem.eql(u8, w.group, name);
}

pub const Selection = struct {
    names: []const []const u8 = &.{},
    no_deps: bool = false,
};

/// Decides which Workers start in this Session by setting each `autostart`.
/// Explicit names beat the active profile, which beats the config's own
/// `autostart`. Dependencies come along unless `no_deps`, because starting
/// `web` without the `db` it waits on would stall the Session on a condition
/// nothing will ever satisfy.
pub fn select(cfg: *Config, sel: Selection, gpa: Allocator, diag: ?*Diagnostic) !void {
    const want = try gpa.alloc(bool, cfg.workers.len);
    defer gpa.free(want);
    @memset(want, false);

    if (sel.names.len > 0) {
        for (sel.names) |name| {
            var hit = false;
            for (cfg.workers, want) |w, *x| {
                if (matches(w, name)) {
                    x.* = true;
                    hit = true;
                }
            }
            if (!hit) return failSelect(cfg.*, gpa, diag, name);
        }
    } else if (cfg.active_profile) |active| {
        for (cfg.profiles) |prof| {
            if (!std.mem.eql(u8, prof.name, active)) continue;
            for (prof.services) |name| {
                for (cfg.workers, want) |w, *x| {
                    if (matches(w, name)) x.* = true;
                }
            }
        }
    } else {
        for (cfg.workers, want) |w, *x| x.* = w.autostart;
    }

    if (!sel.no_deps) {
        // To a fixed point: a dependency added on one pass may have its own.
        var changed = true;
        while (changed) {
            changed = false;
            for (cfg.workers, 0..) |w, i| {
                if (!want[i]) continue;
                for (w.depends_on) |dep| {
                    const j = cfg.find(dep.name) orelse continue;
                    if (!want[j]) {
                        want[j] = true;
                        changed = true;
                    }
                }
            }
        }
    }

    for (cfg.workers, want) |*w, x| w.autostart = x;
}

fn failSelect(cfg: Config, gpa: Allocator, diag: ?*Diagnostic, name: []const u8) error{Invalid} {
    if (diag) |d| {
        d.deinit(gpa);
        d.message = selectMessage(cfg, gpa, name) catch null;
    }
    return error.Invalid;
}

fn selectMessage(cfg: Config, gpa: Allocator, name: []const u8) ![]u8 {
    var list: std.Io.Writer.Allocating = .init(gpa);
    defer list.deinit();
    for (cfg.workers, 0..) |w, i| {
        // One entry per service, not per replica.
        var seen = false;
        for (cfg.workers[0..i]) |before| {
            if (std.mem.eql(u8, before.group, w.group)) seen = true;
        }
        if (seen) continue;
        if (list.written().len > 0) try list.writer.writeAll(", ");
        try list.writer.writeAll(w.group);
    }
    return std.fmt.allocPrint(gpa, "there is no service \"{s}\". Services: {s}", .{ name, list.written() });
}

/// A Config built in memory rather than read from a file — what `devrun run`
/// hands the Supervisor.
///
/// There is no parsing here and no new concept: a `Worker` is a plain struct
/// whose every field has a default, so an ad-hoc command is one of those with
/// two fields filled in. That is the whole reason `devrun run` is cheap. The
/// Supervisor cannot tell the difference and does not need to.
pub const Adhoc = struct {
    name: []const u8,
    /// Already assembled into one string for the shell. See `shellJoin`.
    command: []const u8,
    working_dir: ?[]const u8 = null,
    restart: Restart = .no,
    ready_log_line: ?[]const u8 = null,
};

pub fn adhoc(gpa: Allocator, spec: Adhoc) !Config {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const workers = try arena.alloc(Worker, 1);
    const name = try arena.dupe(u8, spec.name);
    workers[0] = .{
        .name = name,
        .group = name,
        .command = try arena.dupe(u8, spec.command),
        .working_dir = if (spec.working_dir) |d| try arena.dupe(u8, d) else null,
        .restart = spec.restart,
        .ready_log_line = if (spec.ready_log_line) |l| try arena.dupe(u8, l) else null,
    };
    return .{ .arena = arena_state, .shell = .{}, .workers = workers };
}

/// Joins argv into the single string the shell will be handed.
///
/// Every argument is quoted, because by the time devrun sees them the user's
/// own shell has already split and unquoted them. Joining with plain spaces
/// would let the shell split a second time, so `node -e "print('a b')"` would
/// arrive as two arguments and fail in a way that looks like the program's
/// fault rather than devrun's.
///
/// Arguments made only of characters no shell reacts to are left bare, so the
/// common case stays readable in `devrun config` and in the TUI's title.
pub fn shellJoin(gpa: Allocator, argv: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    for (argv, 0..) |arg, i| {
        if (i > 0) try out.append(gpa, ' ');
        if (arg.len > 0 and isBareSafe(arg)) {
            try out.appendSlice(gpa, arg);
            continue;
        }
        // Single quotes suspend every other kind of expansion, so the only
        // byte needing care is a single quote itself: close, escape, reopen.
        try out.append(gpa, '\'');
        for (arg) |c| {
            if (c == '\'') {
                try out.appendSlice(gpa, "'\\''");
            } else {
                try out.append(gpa, c);
            }
        }
        try out.append(gpa, '\'');
    }
    return out.toOwnedSlice(gpa);
}

fn isBareSafe(arg: []const u8) bool {
    for (arg) |c| {
        const ok = std.ascii.isAlphanumeric(c) or switch (c) {
            '-', '_', '.', '/', '=', ':', ',', '+', '@', '%' => true,
            else => false,
        };
        if (!ok) return false;
    }
    return true;
}

/// The name a signal number is written as in a config, for showing it back.
pub fn signalName(n: u8) ?[]const u8 {
    const sig: std.os.linux.SIG = @fromBackingInt(@intCast(n));
    return std.enums.tagName(std.os.linux.SIG, sig);
}

/// Reads and validates `path`, with the `devrun.local.toml` beside it merged
/// over it when there is one. `error.Invalid` means the config was rejected
/// and `diag` holds the reason, allocated with `gpa` for the caller to free.
pub fn load(gpa: Allocator, path: []const u8, opts: Options, diag: ?*Diagnostic) !Config {
    const source = std.Io.Dir.cwd().readFileAlloc(
        opts.io,
        path,
        gpa,
        .limited(max_file_bytes),
    ) catch |err| {
        if (diag) |d| {
            d.deinit(gpa);
            d.message = switch (err) {
                error.FileNotFound => std.fmt.allocPrint(
                    gpa,
                    "{s} not found. List your services in it, or supervise a " ++
                        "single command with `devrun run CMD`.",
                    .{path},
                ),
                else => std.fmt.allocPrint(gpa, "cannot read {s}: {t}", .{ path, err }),
            } catch null;
        }
        return err;
    };
    defer gpa.free(source);
    var named = opts;
    named.source_name = path;

    // Personal overrides live next to the shared file and are not committed,
    // so a missing one is the normal case and anything else is a real error.
    const lpath = try localPathFor(gpa, path);
    defer gpa.free(lpath);
    const local_source: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(
        opts.io,
        lpath,
        gpa,
        .limited(max_file_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => {
            if (diag) |d| {
                d.deinit(gpa);
                d.message = std.fmt.allocPrint(gpa, "cannot read {s}: {t}", .{ lpath, err }) catch null;
            }
            return err;
        },
    };
    defer if (local_source) |l| gpa.free(l);

    return loadSources(
        gpa,
        source,
        if (local_source) |l| .{ .source = l, .path = lpath } else null,
        std.fs.path.dirname(path) orelse ".",
        named,
        diag,
    );
}

/// `devrun.toml` -> `devrun.local.toml`; a name without `.toml` gets `.local`.
fn localPathFor(gpa: Allocator, path: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, path, ".toml")) {
        return std.fmt.allocPrint(gpa, "{s}.local.toml", .{path[0 .. path.len - ".toml".len]});
    }
    return std.fmt.allocPrint(gpa, "{s}.local", .{path});
}

/// The half of `load` that does not read the config file itself. `base_dir` is
/// where `env_file` paths resolve from. Split out so tests can feed source
/// directly.
pub fn loadSource(
    gpa: Allocator,
    source: []const u8,
    base_dir: []const u8,
    opts: Options,
    diag: ?*Diagnostic,
) !Config {
    return loadSources(gpa, source, null, base_dir, opts, diag);
}

const LocalSource = struct { source: []const u8, path: []const u8 };

fn loadSources(
    gpa: Allocator,
    source: []const u8,
    local: ?LocalSource,
    base_dir: []const u8,
    opts: Options,
    diag: ?*Diagnostic,
) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const ctx = Ctx{ .arena = a, .gpa = gpa, .diag = diag, .io = opts.io, .base_dir = base_dir };

    // The reader hands out slices of the text it was given, bare keys among
    // them, and `load` frees its buffers when this returns. The Config owns
    // what it points into.
    var tdiag: toml.Diagnostic = .{};
    const root = toml.parse(a, try a.dupe(u8, source), &tdiag) catch |e| switch (e) {
        error.Invalid => return ctx.fail("{s}:{d}:{d}: {s}", .{
            opts.source_name, tdiag.line, tdiag.column, tdiag.message,
        }),
        error.OutOfMemory => return error.OutOfMemory,
    };

    var local_path: ?[]const u8 = null;
    if (local) |l| {
        var ldiag: toml.Diagnostic = .{};
        const over = toml.parse(a, try a.dupe(u8, l.source), &ldiag) catch |e| switch (e) {
            error.Invalid => return ctx.fail("{s}:{d}:{d}: {s}", .{
                l.path, ldiag.line, ldiag.column, ldiag.message,
            }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        try mergeTables(a, root, over);
        local_path = try a.dupe(u8, l.path);
    }

    const mapped = try mapRoot(ctx, root, opts.environ, opts.profile);
    return .{
        .arena = arena,
        .shell = mapped.shell,
        .workers = mapped.workers,
        .color = mapped.color,
        .profiles = mapped.profiles,
        .active_profile = mapped.active_profile,
        .local_path = local_path,
    };
}

/// Lays `over` on `base`: a table on both sides merges key by key, anything
/// else in `over` replaces. So a local file can change one field of one
/// service without restating the service.
fn mergeTables(a: Allocator, base: *toml.Table, over: *const toml.Table) !void {
    for (over.map.keys(), over.map.values()) |key, value| {
        if (base.map.getPtr(key)) |existing| {
            if (existing.* == .table and value == .table) {
                try mergeTables(a, existing.table, value.table);
                continue;
            }
            existing.* = value;
        } else {
            try base.map.put(a, key, value);
        }
    }
}

// ------------------------------------------------------------- context

const Ctx = struct {
    arena: Allocator,
    gpa: Allocator,
    diag: ?*Diagnostic,
    io: std.Io,
    base_dir: []const u8,

    fn fail(self: Ctx, comptime fmt: []const u8, args: anytype) error{Invalid} {
        if (self.diag) |d| {
            d.deinit(self.gpa);
            d.message = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
        }
        return error.Invalid;
    }

    fn wrongType(self: Ctx, path: []const u8, want: []const u8, got: toml.Value) error{Invalid} {
        return self.fail("{s}: expected {s}, got {s}", .{ path, want, got.kindName() });
    }

    fn sub(self: Ctx, path: []const u8, key: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, key });
    }
};

// ------------------------------------------------------------- field sets

/// The fields one table accepts, the ones it will accept later, and what an
/// unknown one was probably meant to be.
const Fields = struct {
    known: []const []const u8,
    reserved: []const []const u8 = &.{},
    /// Pairs of (what was written, what devrun calls it). Mostly the names
    /// another process runner would have used, because that is where a person
    /// writing one of these from memory gets them.
    renames: []const [2][]const u8 = &.{},
};

const root_fields = Fields{
    .known = &.{ "shell", "color", "env", "env_file", "services", "templates", "profiles" },
    .reserved = &.{"include"},
    .renames = &.{
        .{ "processes", "services" },
        .{ "environment", "env" },
        .{ "dotenv", "env_file" },
    },
};

const service_renames = [_][2][]const u8{
    .{ "command", "run" },
    .{ "cmd", "run" },
    .{ "working_dir", "cwd" },
    .{ "workdir", "cwd" },
    .{ "environment", "env" },
    .{ "dotenv", "env_file" },
    .{ "env_files", "env_file" },
    .{ "depends_on", "after" },
    .{ "needs", "after" },
    .{ "availability", "restart" },
    .{ "readiness_probe", "ready" },
    .{ "healthcheck", "ready" },
    .{ "ready_log_line", "ready = { log = ... }" },
    .{ "shutdown", "stop" },
    .{ "template", "extends" },
};

const service_fields = Fields{
    .known = &.{ "run", "description", "cwd", "env", "env_file", "after", "restart", "ready", "stop", "replicas", "autostart", "watch", "extends" },
    .renames = &service_renames,
};

const template_fields = Fields{
    .known = &.{ "run", "description", "cwd", "env", "env_file", "after", "restart", "ready", "stop", "replicas", "autostart", "watch" },
    .renames = &service_renames,
};

const ready_fields = Fields{
    .known = &.{ "http", "exec", "log", "status", "delay", "every", "timeout", "successes", "failures" },
    .reserved = &.{"tcp"},
    .renames = &.{
        .{ "http_get", "http" },
        .{ "command", "exec" },
        .{ "initial_delay_seconds", "delay" },
        .{ "period_seconds", "every" },
        .{ "interval", "every" },
        .{ "timeout_seconds", "timeout" },
        .{ "success_threshold", "successes" },
        .{ "failure_threshold", "failures" },
        .{ "retries", "failures" },
    },
};

const stop_fields = Fields{
    .known = &.{ "signal", "timeout", "command" },
    .renames = &.{.{ "timeout_seconds", "timeout" }},
};

const restart_fields = Fields{
    .known = &.{ "policy", "max", "backoff" },
    .renames = &.{
        .{ "max_restarts", "max" },
        .{ "max_retries", "max" },
        .{ "delay", "backoff" },
        .{ "restart_delay", "backoff" },
    },
};

const watch_fields = Fields{
    .known = &.{ "paths", "ignore", "debounce" },
    .renames = &.{
        .{ "path", "paths" },
        .{ "exclude", "ignore" },
        .{ "ignored", "ignore" },
    },
};

const profile_fields = Fields{
    .known = &.{ "services", "env" },
};

fn checkFields(ctx: Ctx, t: *const toml.Table, path: []const u8, fields: Fields) !void {
    outer: for (t.map.keys()) |key| {
        for (fields.known) |k| if (std.mem.eql(u8, k, key)) continue :outer;
        for (fields.reserved) |k| if (std.mem.eql(u8, k, key)) {
            return ctx.fail(
                "{s}: \"{s}\" is reserved for a later version of devrun and is not supported yet",
                .{ path, key },
            );
        };
        for (fields.renames) |r| if (std.mem.eql(u8, r[0], key)) {
            return ctx.fail("{s}: unknown field \"{s}\". devrun calls it \"{s}\"", .{ path, key, r[1] });
        };
        const list = std.mem.join(ctx.arena, ", ", fields.known) catch "";
        return ctx.fail("{s}: unknown field \"{s}\". Fields here: {s}", .{ path, key, list });
    }
}

// ------------------------------------------------------------- variables

/// Where `${VAR}` looks, highest first: the top-level `env`, then the
/// top-level `env_file`s, then the environment devrun was started in. The same
/// order a Worker's own environment is layered in, so a variable means the
/// same thing in `cwd` as it does to the program.
const Scope = struct {
    os: *const std.process.Environ.Map,
    /// Answers `DEVRUN_REPLICA` while a replica's fields are being expanded.
    replica: ?[]const u8 = null,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,
    globals: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn get(self: *const Scope, name: []const u8) ?[]const u8 {
        if (self.replica) |r| if (std.mem.eql(u8, name, "DEVRUN_REPLICA")) return r;
        if (self.globals.get(name)) |v| return v;
        if (self.files.get(name)) |v| return v;
        return self.os.get(name);
    }
};

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Expands `$NAME`, `${NAME}` and `${NAME:-default}`. Unset becomes empty, or
/// the default. `$$` is a literal dollar. Nothing else of the shell's
/// expansion language is understood, and asking for it is an error rather than
/// a string with a `${` left in it.
fn expand(ctx: Ctx, scope: *const Scope, src: []const u8, path: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, src, '$') == null) return src;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        if (src[i] != '$') {
            try out.append(ctx.arena, src[i]);
            i += 1;
            continue;
        }
        if (i + 1 < src.len and src[i + 1] == '$') {
            try out.append(ctx.arena, '$');
            i += 2;
            continue;
        }
        if (i + 1 < src.len and src[i + 1] == '{') {
            const close = std.mem.indexOfScalarPos(u8, src, i + 2, '}') orelse
                return ctx.fail("{s}: unterminated \"${{\"", .{path});
            const body = src[i + 2 .. close];
            var name = body;
            var default: ?[]const u8 = null;
            if (std.mem.indexOf(u8, body, ":-")) |at| {
                name = body[0..at];
                default = body[at + 2 ..];
            }
            if (name.len == 0 or !isNameStart(name[0])) {
                return ctx.fail("{s}: \"${{{s}}}\" is not a variable name", .{ path, body });
            }
            for (name) |c| if (!isNameChar(c)) {
                return ctx.fail(
                    "{s}: \"${{{s}}}\" is not supported. devrun expands ${{VAR}} and " ++
                        "${{VAR:-default}}; anything more belongs in a script",
                    .{ path, body },
                );
            };
            if (scope.get(name)) |v| {
                if (v.len > 0 or default == null) {
                    try out.appendSlice(ctx.arena, v);
                } else try out.appendSlice(ctx.arena, default.?);
            } else if (default) |d| try out.appendSlice(ctx.arena, d);
            i = close + 1;
            continue;
        }
        if (i + 1 < src.len and isNameStart(src[i + 1])) {
            var end = i + 1;
            while (end < src.len and isNameChar(src[end])) end += 1;
            if (scope.get(src[i + 1 .. end])) |v| try out.appendSlice(ctx.arena, v);
            i = end;
            continue;
        }
        try out.append(ctx.arena, '$');
        i += 1;
    }
    return out.items;
}

/// `KEY=value` lines, as written by every tool that writes a .env file.
pub fn parseDotenv(
    arena: Allocator,
    text: []const u8,
    map: *std.StringHashMapUnmanaged([]const u8),
) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const body = if (std.mem.startsWith(u8, line, "export "))
            std.mem.trimStart(u8, line["export ".len..], " \t")
        else
            line;
        const eq = std.mem.indexOfScalar(u8, body, '=') orelse continue;
        const key = std.mem.trim(u8, body[0..eq], " \t");
        if (key.len == 0) continue;
        var value = std.mem.trim(u8, body[eq + 1 ..], " \t");
        if (value.len >= 2) {
            const q = value[0];
            if ((q == '"' or q == '\'') and value[value.len - 1] == q) {
                value = value[1 .. value.len - 1];
            }
        }
        try map.put(arena, key, value);
    }
}

// ------------------------------------------------------------- value shapes

fn expectTable(ctx: Ctx, v: toml.Value, path: []const u8) !*toml.Table {
    return switch (v) {
        .table => |t| t,
        else => ctx.wrongType(path, "a table", v),
    };
}

fn expectString(ctx: Ctx, v: toml.Value, path: []const u8) ![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => ctx.wrongType(path, "a string", v),
    };
}

/// One string, or an array of them. `env_file = ".env"` is the short form of
/// `env_file = [".env"]`.
fn stringOrList(ctx: Ctx, v: toml.Value, path: []const u8) ![]const []const u8 {
    switch (v) {
        .string => |s| {
            const one = try ctx.arena.alloc([]const u8, 1);
            one[0] = s;
            return one;
        },
        .array => |arr| {
            const out = try ctx.arena.alloc([]const u8, arr.items.items.len);
            for (arr.items.items, out, 0..) |item, *o, i| {
                const ip = try std.fmt.allocPrint(ctx.arena, "{s}[{d}]", .{ path, i });
                o.* = try expectString(ctx, item, ip);
            }
            return out;
        },
        else => return ctx.wrongType(path, "a string or an array of strings", v),
    }
}

/// A command: one string for the shell, or an array of words that devrun
/// quotes for it. The array form exists for the long `docker run` line with
/// thirty flags, which is easier to read and to diff one word per line.
fn command(ctx: Ctx, v: toml.Value, path: []const u8) ![]const u8 {
    const text = switch (v) {
        .string => |s| s,
        .array => |arr| blk: {
            if (arr.items.items.len == 0) return ctx.fail("{s} is an empty array", .{path});
            const words = try stringOrList(ctx, v, path);
            break :blk try shellJoin(ctx.arena, words);
        },
        else => return ctx.wrongType(path, "a string or an array of strings", v),
    };
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return ctx.fail("{s} is empty", .{path});
    return text;
}

/// Whole seconds, as a number or a string with a unit: `10`, `"10s"`, `"2m"`,
/// `"1h"`. Anything finer than a second is refused rather than rounded,
/// because every timer this feeds counts in seconds.
fn seconds(ctx: Ctx, v: toml.Value, path: []const u8) !u32 {
    switch (v) {
        .integer => |n| {
            if (n < 0 or n > std.math.maxInt(u32)) return ctx.fail("{s}: {d} is out of range", .{ path, n });
            return @intCast(n);
        },
        .string => |s| {
            const bad = "{s}: \"{s}\" is not a duration. Write 30, \"30s\", \"2m\" or \"1h\"";
            if (s.len < 2) return ctx.fail(bad, .{ path, s });
            const mult: u64 = switch (s[s.len - 1]) {
                's' => 1,
                'm' => 60,
                'h' => 3600,
                else => return ctx.fail(bad, .{ path, s }),
            };
            if (std.mem.endsWith(u8, s, "ms")) {
                return ctx.fail("{s}: \"{s}\" is finer than devrun counts; use whole seconds", .{ path, s });
            }
            const n = std.fmt.parseInt(u64, s[0 .. s.len - 1], 10) catch return ctx.fail(bad, .{ path, s });
            const total = std.math.mul(u64, n, mult) catch return ctx.fail("{s}: \"{s}\" is out of range", .{ path, s });
            if (total > std.math.maxInt(u32)) return ctx.fail("{s}: \"{s}\" is out of range", .{ path, s });
            return @intCast(total);
        },
        else => return ctx.wrongType(path, "a duration like \"30s\"", v),
    }
}

/// Like `seconds`, but a string may be finer: `"200ms"`, `"1s"`, `"2m"`,
/// `"1h"`. A bare integer is seconds, as everywhere else. Used where a timer
/// counts in milliseconds (restart backoff, watch debounce).
fn millis(ctx: Ctx, v: toml.Value, path: []const u8) !u32 {
    const bad = "{s}: \"{s}\" is not a duration. Write \"200ms\", \"1s\", \"2m\", or a number of seconds";
    var total: u64 = undefined;
    switch (v) {
        .integer => |n| {
            if (n < 0) return ctx.fail("{s}: {d} is out of range", .{ path, n });
            total = std.math.mul(u64, @intCast(n), 1000) catch return ctx.fail("{s}: {d} is out of range", .{ path, n });
        },
        .string => |s| {
            var digits: []const u8 = undefined;
            var mult: u64 = undefined;
            if (std.mem.endsWith(u8, s, "ms")) {
                digits = s[0 .. s.len - 2];
                mult = 1;
            } else if (s.len >= 2) {
                digits = s[0 .. s.len - 1];
                mult = switch (s[s.len - 1]) {
                    's' => 1000,
                    'm' => 60_000,
                    'h' => 3_600_000,
                    else => return ctx.fail(bad, .{ path, s }),
                };
            } else return ctx.fail(bad, .{ path, s });
            const n = std.fmt.parseInt(u64, digits, 10) catch return ctx.fail(bad, .{ path, s });
            total = std.math.mul(u64, n, mult) catch return ctx.fail("{s}: \"{s}\" is out of range", .{ path, s });
        },
        else => return ctx.wrongType(path, "a duration like \"200ms\"", v),
    }
    if (total > std.math.maxInt(u32)) return ctx.fail("{s}: duration is out of range", .{path});
    if (total == 0) return ctx.fail("{s} must be at least 1ms", .{path});
    return @intCast(total);
}

fn count(ctx: Ctx, v: toml.Value, path: []const u8) !u32 {
    switch (v) {
        .integer => |n| {
            if (n < 1 or n > std.math.maxInt(u32)) return ctx.fail("{s} must be at least 1", .{path});
            return @intCast(n);
        },
        else => return ctx.wrongType(path, "a whole number", v),
    }
}

fn signal(ctx: Ctx, v: toml.Value, path: []const u8) !u8 {
    switch (v) {
        .integer => |n| {
            if (n < 1 or n > 31) return ctx.fail("{s}: {d} is not a signal number", .{ path, n });
            return @intCast(n);
        },
        .string => |s| {
            var buf: [16]u8 = undefined;
            if (s.len > buf.len) return ctx.fail("{s}: \"{s}\" is not a signal", .{ path, s });
            const upper = std.ascii.upperString(&buf, s);
            const name = if (std.mem.startsWith(u8, upper, "SIG")) upper[3..] else upper;
            const sig = std.meta.stringToEnum(std.os.linux.SIG, name) orelse
                return ctx.fail("{s}: \"{s}\" is not a signal. Try \"INT\", \"TERM\" or \"QUIT\"", .{ path, s });
            return @intCast(@backingInt(sig));
        },
        else => return ctx.wrongType(path, "a signal name like \"INT\"", v),
    }
}

/// An `http://host:port/path` URL, split the way the probe needs it.
fn httpUrl(ctx: Ctx, url: []const u8, path: []const u8) !HttpGet {
    if (std.mem.startsWith(u8, url, "https://")) {
        return ctx.fail(
            "{s}: https is not supported; devrun checks plain HTTP only. Probe the " ++
                "plain port, or use exec with curl -k",
            .{path},
        );
    }
    const prefix = "http://";
    if (!std.mem.startsWith(u8, url, prefix)) {
        return ctx.fail("{s}: \"{s}\" is not an http:// URL", .{ path, url });
    }
    const rest = url[prefix.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    var get = HttpGet{ .port = 80, .path = if (slash < rest.len) rest[slash..] else "/" };
    if (std.mem.indexOfScalar(u8, authority, '@') != null) {
        return ctx.fail("{s}: a URL with credentials is not supported", .{path});
    }
    if (authority.len > 0 and authority[0] == '[') {
        return ctx.fail("{s}: IPv6 addresses are not supported; use 127.0.0.1 or localhost", .{path});
    }
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        get.host = authority[0..colon];
        get.port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch
            return ctx.fail("{s}: \"{s}\" is not a port", .{ path, authority[colon + 1 ..] });
        if (get.port == 0) return ctx.fail("{s}: port 0 cannot be probed", .{path});
    } else {
        get.host = authority;
    }
    if (get.host.len == 0) return ctx.fail("{s}: \"{s}\" has no host", .{ path, url });
    return get;
}

// ------------------------------------------------------------- the schema

/// How a Worker is restarted, as written. Kept as one unit so a service that
/// sets `restart` replaces its template's whole policy, not half of it.
const RestartSpec = struct {
    policy: Restart,
    max: u32 = 0,
    backoff_ms: u32 = 200,
};

/// A `ready` check as read, before `${VAR}` is expanded in its URL. The URL
/// waits for `finish` because it may name `${DEVRUN_REPLICA}`.
const RawReady = struct {
    ready: Ready,
    /// Set for an http check. `ready.probe.target` is a placeholder until then.
    url: ?[]const u8 = null,
    url_path: []const u8 = "",
    status: ?u16 = null,
};

/// One `env` entry, before expansion. Numbers and booleans are already text
/// and have nothing to expand.
const RawEnv = struct {
    key: []const u8,
    value: []const u8,
    expand: bool,
};

/// What one service or template table says, with nothing filled in from
/// elsewhere. `null` means "not written here", which is what lets a service
/// override a template field by field.
///
/// `cwd`, `env`, `env_file` and the ready URL are raw strings: `finish`
/// expands them once per replica.
const Partial = struct {
    run: ?[]const u8 = null,
    description: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: []const RawEnv = &.{},
    env_file: []const []const u8 = &.{},
    after: ?[]const RawDep = null,
    restart: ?RestartSpec = null,
    ready: ?RawReady = null,
    stop_signal: ?u8 = null,
    stop_timeout: ?u32 = null,
    stop_command: ?[]const u8 = null,
    replicas: ?u32 = null,
    autostart: ?bool = null,
    watch: ?Watch = null,
    extends: ?[]const u8 = null,
};

const RawDep = struct {
    name: []const u8,
    /// Null for the short form, `after = ["db"]`, which waits for `ready`
    /// when the target has a ready check and `started` when it does not.
    condition: ?Condition,
};

const Ready = union(enum) {
    probe: Probe,
    log: []const u8,
};

const Mapped = struct {
    shell: Shell,
    workers: []Worker,
    color: bool,
    profiles: []const Profile,
    active_profile: ?[]const u8,
};

fn mapRoot(
    ctx: Ctx,
    root: *const toml.Table,
    os_env: *const std.process.Environ.Map,
    want_profile: ?[]const u8,
) !Mapped {
    try checkFields(ctx, root, "the top level", root_fields);

    var shell = Shell{};
    if (root.get("shell")) |v| shell = try mapShell(ctx, v);

    var color = true;
    if (root.get("color")) |v| color = switch (v) {
        .boolean => |b| b,
        else => return ctx.wrongType("color", "a boolean", v),
    };

    var scope = Scope{ .os = os_env };

    var global_files: []const []const u8 = &.{};
    if (root.get("env_file")) |v| {
        const files = try stringOrList(ctx, v, "env_file");
        const out = try ctx.arena.alloc([]const u8, files.len);
        for (files, out) |f, *o| {
            o.* = try expand(ctx, &scope, f, "env_file");
            // Read now as well as at spawn, because `${VAR}` elsewhere in this
            // file may name something only an env file defines.
            const full = try std.fs.path.join(ctx.arena, &.{ ctx.base_dir, o.* });
            const text = std.Io.Dir.cwd().readFileAlloc(ctx.io, full, ctx.arena, .limited(max_file_bytes)) catch
                return ctx.fail("env_file: cannot read {s}", .{full});
            try parseDotenv(ctx.arena, text, &scope.files);
        }
        global_files = out;
    }

    var global_env: []const []const u8 = &.{};
    if (root.get("env")) |v| {
        // In order, and into the scope as each is read, so a later entry may
        // build on an earlier one: `PATH = "${ROOT}/bin:${PATH}"`.
        global_env = try mapEnv(ctx, &scope, v, "env");
    }

    // Profiles come right after the global env, because the active one's env
    // is layered on top of it: same scope, and later in the list so it wins.
    var profiles: []Profile = &.{};
    var active_profile: ?[]const u8 = null;
    if (root.get("profiles")) |v| {
        const t = try expectTable(ctx, v, "profiles");
        profiles = try ctx.arena.alloc(Profile, t.map.count());
        for (t.map.keys(), t.map.values(), profiles) |pname, pv, *pr| {
            const pp = try ctx.sub("profiles", pname);
            const pt = try expectTable(ctx, pv, pp);
            try checkFields(ctx, pt, pp, profile_fields);
            const sp = try ctx.sub(pp, "services");
            const names = try stringOrList(ctx, pt.get("services") orelse return ctx.fail(
                "{s}: missing \"services\", the services this profile starts",
                .{pp},
            ), sp);
            if (names.len == 0) return ctx.fail("{s} is empty", .{sp});
            pr.* = .{ .name = pname, .services = names };
            if (pt.get("env")) |ev| {
                const ep = try ctx.sub(pp, "env");
                if (want_profile != null and std.mem.eql(u8, want_profile.?, pname)) {
                    const extra = try mapEnv(ctx, &scope, ev, ep);
                    global_env = try std.mem.concat(ctx.arena, []const u8, &.{ global_env, extra });
                } else {
                    // Not active, but a typo in it should not wait for the day
                    // someone activates it.
                    _ = try rawEnv(ctx, ev, ep);
                }
            }
        }
    }
    if (want_profile) |want| {
        for (profiles) |pr| {
            if (std.mem.eql(u8, pr.name, want)) active_profile = pr.name;
        }
        if (active_profile == null) {
            if (profiles.len == 0) {
                return ctx.fail("unknown profile \"{s}\": this config has no [profiles]", .{want});
            }
            const names = try ctx.arena.alloc([]const u8, profiles.len);
            for (profiles, names) |pr, *n| n.* = pr.name;
            return ctx.fail("unknown profile \"{s}\". Profiles: {s}", .{
                want, try std.mem.join(ctx.arena, ", ", names),
            });
        }
    }

    var templates: std.StringArrayHashMapUnmanaged(Partial) = .empty;
    if (root.get("templates")) |v| {
        const t = try expectTable(ctx, v, "templates");
        for (t.map.keys(), t.map.values()) |name, tv| {
            const path = try ctx.sub("templates", name);
            try templates.put(ctx.arena, name, try mapPartial(ctx, tv, path, template_fields));
        }
    }

    const services_v = root.get("services") orelse return ctx.fail(
        "no [services] in the config. Each service is a table like:\n\n" ++
            "  [services.api]\n  run = \"pnpm dev\"\n",
        .{},
    );
    const services = try expectTable(ctx, services_v, "services");
    if (services.map.count() == 0) return ctx.fail("[services] is empty", .{});

    var workers: std.ArrayList(Worker) = .empty;
    var raw_deps: std.ArrayList([]const RawDep) = .empty;
    for (services.map.keys(), services.map.values()) |name, sv| {
        const path = try ctx.sub("services", name);
        try checkName(ctx, name, path);
        var p = try mapPartial(ctx, sv, path, service_fields);
        if (p.extends) |base_name| {
            const base = templates.get(base_name) orelse {
                const known = std.mem.join(ctx.arena, ", ", templates.keys()) catch "";
                return ctx.fail("{s}.extends: there is no template \"{s}\"{s}{s}", .{
                    path,
                    base_name,
                    if (known.len > 0) ". Templates: " else "",
                    known,
                });
            };
            p = try merge(ctx, base, p);
        }
        const total: u32 = p.replicas orelse 1;
        var k: u32 = 1;
        while (k <= total) : (k += 1) {
            const wname = if (total > 1)
                try std.fmt.allocPrint(ctx.arena, "{s}.{d}", .{ name, k })
            else
                name;
            if (indexOf(workers.items, wname) != null) {
                return ctx.fail("{s}: replica name \"{s}\" collides with another service", .{ path, wname });
            }
            const w = try finish(ctx, &scope, wname, name, if (p.replicas != null) k else 0, path, p, global_env, global_files);
            try workers.append(ctx.arena, w);
            try raw_deps.append(ctx.arena, p.after orelse &.{});
        }
    }

    for (profiles) |pr| {
        for (pr.services) |sname| {
            for (workers.items) |w| {
                if (matches(w, sname)) break;
            } else return ctx.fail(
                "profiles.{s}.services: \"{s}\" is not a service in this config",
                .{ pr.name, sname },
            );
        }
    }

    try resolveDependencies(ctx, workers.items, raw_deps.items);
    try checkAcyclic(ctx, workers.items);
    return .{
        .shell = shell,
        .workers = workers.items,
        .color = color,
        .profiles = profiles,
        .active_profile = active_profile,
    };
}

/// A service's name becomes a file name under `.devrun/logs/`, and a word
/// typed on the command line. Both go wrong with a slash or a space in it.
fn checkName(ctx: Ctx, name: []const u8, path: []const u8) !void {
    const ok = name.len > 0 and name[0] != '.' and name[0] != '-' and for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.')) break false;
    } else true;
    if (!ok) {
        return ctx.fail(
            "{s}: a service name may use letters, digits, \"-\", \"_\" and \".\", " ++
                "and cannot start with \".\" or \"-\"",
            .{path},
        );
    }
}

fn mapShell(ctx: Ctx, v: toml.Value) !Shell {
    const words = try stringOrList(ctx, v, "shell");
    if (words.len != 2) {
        return ctx.fail("shell: expected a program and its flag, like [\"bash\", \"-c\"]", .{});
    }
    return .{ .command = words[0], .argument = words[1] };
}

/// Checks an `env` table and turns every value into text, without expanding.
fn rawEnv(ctx: Ctx, v: toml.Value, path: []const u8) ![]RawEnv {
    const t = try expectTable(ctx, v, path);
    const out = try ctx.arena.alloc(RawEnv, t.map.count());
    for (t.map.keys(), t.map.values(), out) |key, value, *o| {
        const kp = try ctx.sub(path, key);
        if (key.len == 0 or std.mem.indexOfAny(u8, key, "=\x00") != null) {
            return ctx.fail("{s}: \"{s}\" cannot be an environment variable name", .{ path, key });
        }
        o.* = switch (value) {
            .string => |s| .{ .key = key, .value = s, .expand = true },
            .integer => |n| .{ .key = key, .value = try std.fmt.allocPrint(ctx.arena, "{d}", .{n}), .expand = false },
            .boolean => |b| .{ .key = key, .value = if (b) "true" else "false", .expand = false },
            else => return ctx.wrongType(kp, "a string", value),
        };
    }
    return out;
}

/// A global env table: expanded as it is read and added to `scope`, so later
/// entries, and every service's `${VAR}`, can use it.
fn mapEnv(ctx: Ctx, scope: *Scope, v: toml.Value, path: []const u8) ![]const []const u8 {
    const raw = try rawEnv(ctx, v, path);
    const out = try ctx.arena.alloc([]const u8, raw.len);
    for (raw, out) |r, *o| {
        const text = if (r.expand)
            try expand(ctx, scope, r.value, try ctx.sub(path, r.key))
        else
            r.value;
        try scope.globals.put(ctx.arena, r.key, text);
        o.* = try std.fmt.allocPrint(ctx.arena, "{s}={s}", .{ r.key, text });
    }
    return out;
}

fn mapPartial(ctx: Ctx, v: toml.Value, path: []const u8, fields: Fields) !Partial {
    const t = try expectTable(ctx, v, path);
    try checkFields(ctx, t, path, fields);

    var p = Partial{};
    if (t.get("run")) |x| p.run = try command(ctx, x, try ctx.sub(path, "run"));
    if (t.get("description")) |x| p.description = try expectString(ctx, x, try ctx.sub(path, "description"));
    if (t.get("cwd")) |x| p.cwd = try expectString(ctx, x, try ctx.sub(path, "cwd"));
    if (t.get("env")) |x| p.env = try rawEnv(ctx, x, try ctx.sub(path, "env"));
    if (t.get("env_file")) |x| p.env_file = try stringOrList(ctx, x, try ctx.sub(path, "env_file"));
    if (t.get("after")) |x| p.after = try mapAfter(ctx, x, try ctx.sub(path, "after"));
    if (t.get("restart")) |x| p.restart = try mapRestart(ctx, x, try ctx.sub(path, "restart"));
    if (t.get("ready")) |x| p.ready = try mapReady(ctx, x, try ctx.sub(path, "ready"));
    if (t.get("stop")) |x| {
        const kp = try ctx.sub(path, "stop");
        const st = try expectTable(ctx, x, kp);
        try checkFields(ctx, st, kp, stop_fields);
        if (st.get("signal")) |s| p.stop_signal = try signal(ctx, s, try ctx.sub(kp, "signal"));
        if (st.get("timeout")) |s| p.stop_timeout = try seconds(ctx, s, try ctx.sub(kp, "timeout"));
        if (st.get("command")) |s| p.stop_command = try command(ctx, s, try ctx.sub(kp, "command"));
    }
    if (t.get("replicas")) |x| {
        const kp = try ctx.sub(path, "replicas");
        switch (x) {
            .integer => |n| {
                if (n < 1 or n > max_replicas) {
                    return ctx.fail("{s}: {d} is out of range. Use 1 to {d}", .{ kp, n, max_replicas });
                }
                p.replicas = @intCast(n);
            },
            else => return ctx.wrongType(kp, "a whole number", x),
        }
    }
    if (t.get("autostart")) |x| {
        p.autostart = switch (x) {
            .boolean => |b| b,
            else => return ctx.wrongType(try ctx.sub(path, "autostart"), "a boolean", x),
        };
    }
    if (t.get("watch")) |x| p.watch = try mapWatch(ctx, x, try ctx.sub(path, "watch"));
    if (t.get("extends")) |x| p.extends = try expectString(ctx, x, try ctx.sub(path, "extends"));
    return p;
}

/// More than this is a typo for a port number, not a deliberate fan-out.
const max_replicas = 64;

/// `watch = "src"`, `watch = ["src", "lib"]`, or the table with ignore and
/// debounce. The user's ignore patterns come after the defaults, which are
/// never optional: a watch that fires on its own log directory loops forever.
fn mapWatch(ctx: Ctx, v: toml.Value, path: []const u8) !Watch {
    var w = Watch{ .paths = undefined, .ignore = &default_watch_ignore };
    var paths_v = v;
    switch (v) {
        .string, .array => {},
        .table => |t| {
            try checkFields(ctx, t, path, watch_fields);
            paths_v = t.get("paths") orelse return ctx.fail(
                "{s}: needs \"paths\", what to watch. For example watch = {{ paths = [\"src\"] }}",
                .{path},
            );
            if (t.get("ignore")) |x| {
                const extra = try stringOrList(ctx, x, try ctx.sub(path, "ignore"));
                w.ignore = try std.mem.concat(ctx.arena, []const u8, &.{ &default_watch_ignore, extra });
            }
            if (t.get("debounce")) |x| w.debounce_ms = try millis(ctx, x, try ctx.sub(path, "debounce"));
        },
        else => return ctx.wrongType(path, "a path, a list of paths, or a table", v),
    }
    const pp = if (v == .table) try ctx.sub(path, "paths") else path;
    w.paths = try stringOrList(ctx, paths_v, pp);
    if (w.paths.len == 0) return ctx.fail("{s} is empty", .{pp});
    for (w.paths) |one| if (one.len == 0) return ctx.fail("{s} has an empty path", .{pp});
    return w;
}

fn mapAfter(ctx: Ctx, v: toml.Value, path: []const u8) ![]const RawDep {
    switch (v) {
        .string, .array => {
            const names = try stringOrList(ctx, v, path);
            const out = try ctx.arena.alloc(RawDep, names.len);
            for (names, out) |n, *o| o.* = .{ .name = n, .condition = null };
            return out;
        },
        .table => |t| {
            const out = try ctx.arena.alloc(RawDep, t.map.count());
            for (t.map.keys(), t.map.values(), out) |name, cv, *o| {
                const kp = try ctx.sub(path, name);
                const text = try expectString(ctx, cv, kp);
                o.* = .{ .name = name, .condition = std.meta.stringToEnum(Condition, text) orelse {
                    const hint: ?[]const u8 = if (std.mem.eql(u8, text, "process_started"))
                        "started"
                    else if (std.mem.eql(u8, text, "process_healthy") or std.mem.eql(u8, text, "process_log_ready") or std.mem.eql(u8, text, "healthy"))
                        "ready"
                    else if (std.mem.eql(u8, text, "process_completed") or std.mem.eql(u8, text, "completed"))
                        "exited"
                    else if (std.mem.eql(u8, text, "process_completed_successfully") or std.mem.eql(u8, text, "completed_successfully"))
                        "succeeded"
                    else
                        null;
                    if (hint) |h| return ctx.fail("{s}: unknown condition \"{s}\". devrun calls it \"{s}\"", .{ kp, text, h });
                    return ctx.fail(
                        "{s}: unknown condition \"{s}\". Conditions: started, ready, exited, succeeded",
                        .{ kp, text },
                    );
                } };
            }
            return out;
        },
        else => return ctx.wrongType(path, "a list of service names, or a table of name = condition", v),
    }
}

/// A policy name. The table form's `policy` and the plain string are the same
/// thing, so they share the spelling hints.
fn restartPolicy(ctx: Ctx, v: toml.Value, path: []const u8) !Restart {
    switch (v) {
        .string => |s| {
            if (Restart.parse(s)) |r| return r;
            if (std.mem.indexOfScalar(u8, s, '_') != null) {
                const dashed = try ctx.arena.dupe(u8, s);
                std.mem.replaceScalar(u8, dashed, '_', '-');
                if (Restart.parse(dashed) != null) {
                    return ctx.fail("{s}: \"{s}\" is spelled \"{s}\"", .{ path, s, dashed });
                }
            }
            return ctx.fail(
                "{s}: unknown policy \"{s}\". Policies: no, always, on-failure, exit-on-failure, exit-on-end",
                .{ path, s },
            );
        },
        .boolean => |b| return ctx.fail(
            "{s}: write \"{s}\" as a string",
            .{ path, if (b) "always" else "no" },
        ),
        else => return ctx.wrongType(path, "a string", v),
    }
}

fn mapRestart(ctx: Ctx, v: toml.Value, path: []const u8) !RestartSpec {
    const t = switch (v) {
        .table => |t| t,
        else => return .{ .policy = try restartPolicy(ctx, v, path) },
    };
    try checkFields(ctx, t, path, restart_fields);
    const pp = try ctx.sub(path, "policy");
    const pv = t.get("policy") orelse return ctx.fail(
        "{s}: needs \"policy\". For example restart = {{ policy = \"on-failure\", max = 5 }}",
        .{path},
    );
    var spec = RestartSpec{ .policy = try restartPolicy(ctx, pv, pp) };
    const tunable = spec.policy == .always or spec.policy == .on_failure;
    if (t.get("max")) |x| {
        const kp = try ctx.sub(path, "max");
        if (!tunable) return ctx.fail("{s}: only applies to the policies \"always\" and \"on-failure\"", .{kp});
        switch (x) {
            .integer => |n| {
                if (n < 1 or n > std.math.maxInt(u32)) return ctx.fail("{s} must be at least 1", .{kp});
                spec.max = @intCast(n);
            },
            else => return ctx.wrongType(kp, "a whole number", x),
        }
    }
    if (t.get("backoff")) |x| {
        const kp = try ctx.sub(path, "backoff");
        if (!tunable) return ctx.fail("{s}: only applies to the policies \"always\" and \"on-failure\"", .{kp});
        spec.backoff_ms = try millis(ctx, x, kp);
    }
    return spec;
}

fn mapReady(ctx: Ctx, v: toml.Value, path: []const u8) !RawReady {
    switch (v) {
        // The short form is a URL, because that is the check most services
        // want and the only one a bare string could unambiguously mean.
        .string => |s| {
            if (!std.mem.startsWith(u8, s, "http://") and !std.mem.startsWith(u8, s, "https://")) {
                return ctx.fail(
                    "{s}: a ready check written as a string must be an http:// URL. " ++
                        "For anything else write {{ exec = \"...\" }} or {{ log = \"...\" }}",
                    .{path},
                );
            }
            return httpReady(ctx, s, path, null);
        },
        .table => {},
        else => return ctx.wrongType(path, "a URL or a table", v),
    }
    const t = v.table;
    try checkFields(ctx, t, path, ready_fields);

    var which: ?[]const u8 = null;
    for ([_][]const u8{ "http", "exec", "log" }) |k| {
        if (t.get(k) == null) continue;
        if (which) |w| return ctx.fail("{s}: has both \"{s}\" and \"{s}\"; pick one", .{ path, w, k });
        which = k;
    }
    const kind = which orelse return ctx.fail("{s}: needs one of \"http\", \"exec\" or \"log\"", .{path});

    var status: ?u16 = null;
    if (t.get("status")) |x| {
        const kp = try ctx.sub(path, "status");
        if (!std.mem.eql(u8, kind, "http")) {
            return ctx.fail(
                "{s} applies to http checks. An {s} check passes or fails on its own",
                .{ kp, kind },
            );
        }
        switch (x) {
            .integer => |n| {
                if (n < 100 or n > 599) return ctx.fail("{s}: {d} is not an HTTP status. Use 100 to 599", .{ kp, n });
                status = @intCast(n);
            },
            else => return ctx.wrongType(kp, "a status code like 200", x),
        }
    }

    if (std.mem.eql(u8, kind, "log")) {
        for ([_][]const u8{ "delay", "every", "timeout", "successes", "failures" }) |k| {
            if (t.get(k) != null) {
                return ctx.fail(
                    "{s}.{s} applies to http and exec checks. A log check passes " ++
                        "the moment the line appears",
                    .{ path, k },
                );
            }
        }
        const kp = try ctx.sub(path, "log");
        const line = try expectString(ctx, t.get("log").?, kp);
        if (line.len == 0) return ctx.fail("{s} is empty", .{kp});
        if (std.mem.indexOfScalar(u8, line, '\n') != null) {
            return ctx.fail("{s} must fit on one line; it is matched within a line of output", .{kp});
        }
        return .{ .ready = .{ .log = line } };
    }

    var probe = Probe{ .target = .{ .exec = "" } };
    var raw = RawReady{ .ready = undefined };
    if (std.mem.eql(u8, kind, "http")) {
        const kp = try ctx.sub(path, "http");
        raw = try httpReady(ctx, try expectString(ctx, t.get("http").?, kp), kp, status);
        probe = raw.ready.probe;
    } else {
        probe.target = .{ .exec = try command(ctx, t.get("exec").?, try ctx.sub(path, "exec")) };
    }
    if (t.get("delay")) |x| probe.initial_delay_seconds = try seconds(ctx, x, try ctx.sub(path, "delay"));
    if (t.get("every")) |x| {
        const kp = try ctx.sub(path, "every");
        probe.period_seconds = try seconds(ctx, x, kp);
        if (probe.period_seconds == 0) return ctx.fail("{s} must be at least 1s", .{kp});
    }
    if (t.get("timeout")) |x| {
        const kp = try ctx.sub(path, "timeout");
        probe.timeout_seconds = try seconds(ctx, x, kp);
        if (probe.timeout_seconds == 0) return ctx.fail("{s} must be at least 1s", .{kp});
    }
    if (t.get("successes")) |x| probe.success_threshold = try count(ctx, x, try ctx.sub(path, "successes"));
    if (t.get("failures")) |x| probe.failure_threshold = try count(ctx, x, try ctx.sub(path, "failures"));
    raw.ready = .{ .probe = probe };
    return raw;
}

/// An http check whose URL is expanded later. A URL with no `$` in it cannot
/// change, so it is checked now, which keeps an unused template honest.
fn httpReady(ctx: Ctx, url: []const u8, path: []const u8, status: ?u16) !RawReady {
    if (std.mem.indexOfScalar(u8, url, '$') == null) _ = try httpUrl(ctx, url, path);
    return .{
        .ready = .{ .probe = .{ .target = .{ .exec = "" } } },
        .url = url,
        .url_path = path,
        .status = status,
    };
}

/// A service on top of its template. Lists that add up do (`env`,
/// `env_file`); everything else is replaced whole, except `stop`, whose
/// fields are separate settings and are replaced one at a time.
fn merge(ctx: Ctx, base: Partial, over: Partial) !Partial {
    return .{
        .run = over.run orelse base.run,
        .description = over.description orelse base.description,
        .cwd = over.cwd orelse base.cwd,
        .env = try std.mem.concat(ctx.arena, RawEnv, &.{ base.env, over.env }),
        .env_file = try std.mem.concat(ctx.arena, []const u8, &.{ base.env_file, over.env_file }),
        .after = over.after orelse base.after,
        .restart = over.restart orelse base.restart,
        .ready = over.ready orelse base.ready,
        .stop_signal = over.stop_signal orelse base.stop_signal,
        .stop_timeout = over.stop_timeout orelse base.stop_timeout,
        .stop_command = over.stop_command orelse base.stop_command,
        .replicas = over.replicas orelse base.replicas,
        .autostart = over.autostart orelse base.autostart,
        .watch = over.watch orelse base.watch,
        .extends = over.extends,
    };
}

/// Builds one Worker. The fields the shell never sees are expanded here, with
/// a scope that also answers `DEVRUN_REPLICA`, so each replica gets its own.
fn finish(
    ctx: Ctx,
    scope: *const Scope,
    name: []const u8,
    group: []const u8,
    replica: u32,
    path: []const u8,
    p: Partial,
    global_env: []const []const u8,
    global_files: []const []const u8,
) !Worker {
    const run = p.run orelse return ctx.fail("{s}: missing \"run\", the command to start it with", .{path});

    var sc = scope.*;
    if (replica > 0) sc.replica = try std.fmt.allocPrint(ctx.arena, "{d}", .{replica});

    var env: std.ArrayList([]const u8) = .empty;
    try env.appendSlice(ctx.arena, global_env);
    if (sc.replica) |r| try env.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "DEVRUN_REPLICA={s}", .{r}));
    const env_path = try ctx.sub(path, "env");
    for (p.env) |e| {
        const text = if (e.expand) try expand(ctx, &sc, e.value, try ctx.sub(env_path, e.key)) else e.value;
        try env.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}={s}", .{ e.key, text }));
    }

    const file_path = try ctx.sub(path, "env_file");
    const files = try ctx.arena.alloc([]const u8, p.env_file.len);
    for (p.env_file, files) |f, *o| o.* = try expand(ctx, &sc, f, file_path);

    var w = Worker{
        .name = name,
        .group = group,
        .replica = replica,
        .autostart = p.autostart orelse true,
        .description = p.description,
        .command = run,
        .working_dir = if (p.cwd) |c| try expand(ctx, &sc, c, try ctx.sub(path, "cwd")) else null,
        .env_file = try std.mem.concat(ctx.arena, []const u8, &.{ global_files, files }),
        .env = env.items,
        .watch = p.watch,
    };
    if (p.restart) |r| {
        w.restart = r.policy;
        w.restart_max = r.max;
        w.restart_backoff_ms = r.backoff_ms;
    }
    if (p.stop_signal) |s| w.shutdown.signal = s;
    if (p.stop_timeout) |s| w.shutdown.timeout_seconds = s;
    w.shutdown.command = p.stop_command;
    if (p.ready) |rr| switch (rr.ready) {
        .probe => |probe0| {
            var probe = probe0;
            if (rr.url) |raw_url| {
                const url = try expand(ctx, &sc, raw_url, rr.url_path);
                var get = try httpUrl(ctx, url, rr.url_path);
                get.status = rr.status;
                probe.target = .{ .http_get = get };
            }
            w.readiness_probe = probe;
        },
        .log => |line| w.ready_log_line = line,
    };
    return w;
}

/// Turns each `after` into Dependencies on concrete Workers, now that every
/// service's ready check is known and the short form's default can be decided.
/// A name that means a replicated service becomes one Dependency per replica.
/// Everything about the graph that can be decided from the text is decided
/// here, so a broken graph fails before anything is spawned rather than
/// halfway through a Session.
fn resolveDependencies(ctx: Ctx, workers: []Worker, raw: []const []const RawDep) !void {
    for (workers, raw) |*w, deps| {
        var out: std.ArrayList(Dependency) = .empty;
        for (deps) |d| {
            if (std.mem.eql(u8, d.name, w.name) or std.mem.eql(u8, d.name, w.group)) {
                return ctx.fail("services.{s} waits for itself", .{w.group});
            }
            var found = false;
            for (workers) |target| {
                if (!matches(target, d.name)) continue;
                found = true;
                const has_ready = target.hasReadyCheck();
                const condition = d.condition orelse if (has_ready) Condition.ready else Condition.started;
                // A condition the target can never reach would stall the Session
                // with no error, which is the failure this project exists to avoid.
                if (condition == .ready and !has_ready) {
                    return ctx.fail(
                        "services.{s}.after.{s}: waits for \"ready\", but \"{s}\" has no " ++
                            "ready check, so it can never become ready. Give it a `ready`, " ++
                            "or wait for \"started\"",
                        .{ w.group, d.name, d.name },
                    );
                }
                try out.append(ctx.arena, .{ .name = target.name, .condition = condition });
            }
            if (!found) return ctx.fail(
                "services.{s}.after: \"{s}\" is not a service in this config",
                .{ w.group, d.name },
            );
        }
        w.depends_on = out.items;
    }
}

fn indexOf(workers: []const Worker, name: []const u8) ?usize {
    for (workers, 0..) |w, i| {
        if (std.mem.eql(u8, w.name, name)) return i;
    }
    return null;
}

/// Kahn's algorithm: repeatedly retire a Worker with nothing left to wait on.
/// Whatever cannot be retired is in a cycle or behind one, and a cycle means
/// the Session would sit forever with every Worker waiting on another.
///
/// Iterative rather than a recursive depth-first search, so a pathological
/// config cannot overflow the stack — the config is only bounded at 4 MB, and
/// that is a lot of one-line Workers.
fn checkAcyclic(ctx: Ctx, workers: []const Worker) !void {
    const n = workers.len;
    const remaining = try ctx.arena.alloc(u32, n);
    for (workers, remaining) |w, *r| r.* = @intCast(w.depends_on.len);

    // A ready queue over the same allocation the visit order uses: each Worker
    // enters exactly once, so `n` slots is the exact bound.
    const queue = try ctx.arena.alloc(usize, n);
    var head: usize = 0;
    var tail: usize = 0;
    for (remaining, 0..) |r, i| {
        if (r == 0) {
            queue[tail] = i;
            tail += 1;
        }
    }

    var retired: usize = 0;
    while (head < tail) {
        const done = queue[head];
        head += 1;
        retired += 1;
        // Anything waiting on `done` now has one fewer reason to wait.
        for (workers, 0..) |w, i| {
            for (w.depends_on) |dep| {
                if (!std.mem.eql(u8, dep.name, workers[done].name)) continue;
                remaining[i] -= 1;
                if (remaining[i] == 0) {
                    queue[tail] = i;
                    tail += 1;
                }
            }
        }
    }

    if (retired == n) return;

    var names: std.Io.Writer.Allocating = .init(ctx.arena);
    var first = true;
    for (remaining, workers) |r, w| {
        if (r == 0) continue;
        if (!first) names.writer.writeAll(", ") catch {};
        names.writer.writeAll(w.name) catch {};
        first = false;
    }
    return ctx.fail(
        "`after` has a cycle: {s} can never start, because each is waiting " ++
            "on another of them.",
        .{names.written()},
    );
}

// ------------------------------------------------------------- tests

const testing = std.testing;

/// Builds a Config from source with a synthetic environment, so tests never
/// depend on what the machine running them happens to export.
fn loadForTest(
    src: []const u8,
    vars: []const [2][]const u8,
    diag: ?*Diagnostic,
) !Config {
    return loadForTestIn(src, "/nonexistent-devrun-test-dir", vars, diag);
}

fn loadForTestIn(
    src: []const u8,
    base_dir: []const u8,
    vars: []const [2][]const u8,
    diag: ?*Diagnostic,
) !Config {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    for (vars) |kv| try environ.put(kv[0], kv[1]);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    return loadSource(
        testing.allocator,
        src,
        base_dir,
        .{ .io = threaded.io(), .environ = &environ },
        diag,
    );
}

/// Loads `src` expecting a rejection, and checks the message says `needle`.
fn expectRejected(src: []const u8, needle: []const u8) !void {
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    if (loadForTest(src, &.{}, &diag)) |cfg| {
        var c = cfg;
        c.deinit();
        std.debug.print("expected a rejection mentioning \"{s}\"\n", .{needle});
        return error.TestUnexpectedResult;
    } else |e| try testing.expectEqual(error.Invalid, e);
    const msg = diag.message orelse return error.TestUnexpectedResult;
    if (std.mem.indexOf(u8, msg, needle) == null) {
        std.debug.print("message did not mention \"{s}\":\n{s}\n", .{ needle, msg });
        return error.TestUnexpectedResult;
    }
}

test "shellJoin quotes what a second round of splitting would break" {
    const gpa = testing.allocator;

    // The common case stays bare, so `devrun config` and the TUI's title show
    // the command the way it was typed.
    {
        const s = try shellJoin(gpa, &.{ "pnpm", "run", "dev" });
        defer gpa.free(s);
        try testing.expectEqualStrings("pnpm run dev", s);
    }
    // A flag with a path or an equals sign is still bare.
    {
        const s = try shellJoin(gpa, &.{ "go", "run", "./cmd/api", "--addr=:8080" });
        defer gpa.free(s);
        try testing.expectEqualStrings("go run ./cmd/api --addr=:8080", s);
    }
    // Runs of spaces survive. The caller's shell already collapsed the ones it
    // was going to; what is left is inside an argument and belongs there.
    {
        const s = try shellJoin(gpa, &.{ "echo", "a  b" });
        defer gpa.free(s);
        try testing.expectEqualStrings("echo 'a  b'", s);
    }
    // The only byte single quotes cannot carry is a single quote: close,
    // escape, reopen. This is the case that breaks a naive join.
    {
        const s = try shellJoin(gpa, &.{ "node", "-e", "print('hi')" });
        defer gpa.free(s);
        try testing.expectEqualStrings("node -e 'print('\\''hi'\\'')'", s);
    }
    // Shell metacharacters inside an argument stay data rather than becoming
    // syntax, which is the difference between passing a glob to a program and
    // having the shell expand it first.
    {
        const s = try shellJoin(gpa, &.{ "grep", "-E", "panic|ERROR", "*.log" });
        defer gpa.free(s);
        try testing.expectEqualStrings("grep -E 'panic|ERROR' '*.log'", s);
    }
    // An empty argument is a real argument and must survive as one.
    {
        const s = try shellJoin(gpa, &.{ "sh", "-c", "" });
        defer gpa.free(s);
        try testing.expectEqualStrings("sh -c ''", s);
    }
    // And the shapes that would let a value escape into the command line.
    {
        const s = try shellJoin(gpa, &.{ "echo", "a; rm -rf /", "$HOME", "`id`" });
        defer gpa.free(s);
        try testing.expectEqualStrings("echo 'a; rm -rf /' '$HOME' '`id`'", s);
    }
}

test "adhoc builds a Config the Supervisor cannot tell from a parsed one" {
    var cfg = try adhoc(testing.allocator, .{
        .name = "web",
        .command = "pnpm run dev",
        .restart = .always,
        .ready_log_line = "listening on",
    });
    defer cfg.deinit();

    try testing.expectEqual(@as(usize, 1), cfg.workers.len);
    try testing.expectEqualStrings("web", cfg.workers[0].name);
    try testing.expectEqualStrings("pnpm run dev", cfg.workers[0].command);
    try testing.expectEqual(Restart.always, cfg.workers[0].restart);
    try testing.expectEqualStrings("listening on", cfg.workers[0].ready_log_line.?);
    try testing.expectEqual(@as(?usize, 0), cfg.find("web"));

    // Defaults come from the same struct a parsed Worker gets, so an ad-hoc
    // run shuts down the way every other Worker does.
    try testing.expectEqual(@as(u8, 15), cfg.workers[0].shutdown.signal);
    try testing.expectEqual(@as(u32, 10), cfg.workers[0].shutdown.timeout_seconds);
    try testing.expectEqualStrings("bash", cfg.shell.command);

    // Strings are owned by the Config's arena, not borrowed from the caller.
    // `devrun run` frees the joined command right after building this.
    try testing.expect(cfg.workers[0].command.ptr != @as([*]const u8, "pnpm run dev"));
}

test "the smallest config is one table and one line" {
    var cfg = try loadForTest(
        \\[services.web]
        \\run = "pnpm dev"
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 1), cfg.workers.len);
    try testing.expectEqualStrings("pnpm dev", cfg.workers[0].command);
    try testing.expectEqual(Restart.no, cfg.workers[0].restart);
    try testing.expectEqualStrings("bash", cfg.shell.command);
}

test "a monorepo: templates, globals, gates, probes and every short form" {
    var cfg = try loadForTest(
        \\shell = ["sh", "-c"]
        \\
        \\[env]
        \\ROOT = "/repo"
        \\PATH = "${ROOT}/bin:${PATH}"
        \\
        \\[templates.node]
        \\restart = "on-failure"
        \\env = { NODE_ENV = "development" }
        \\stop = { signal = "INT", timeout = "15s" }
        \\
        \\[services.postgres]
        \\run = ["docker", "run", "--rm", "-p", "5432:5432",
        \\       "-e", "POSTGRES_PASSWORD=dev", "postgres:16"]
        \\ready = { exec = "pg_isready -h localhost", every = 2, failures = 30 }
        \\stop.timeout = "30s"
        \\
        \\[services.migrate]
        \\description = "schema migrations"
        \\run = "pnpm db:migrate"
        \\after = ["postgres"]
        \\
        \\[services.api]
        \\extends = "node"
        \\run = "pnpm dev"
        \\cwd = "${ROOT}/apps/api"
        \\env = { PORT = 3000, DEBUG = true }
        \\after = { migrate = "succeeded", postgres = "ready" }
        \\ready = "http://localhost:3000/health"
        \\stop = { timeout = "1m" }
        \\
        \\[services.web]
        \\extends = "node"
        \\run = "pnpm dev --port 5173"
        \\after = "api"
        \\ready.log = "Local:"
        \\
    , &.{.{ "PATH", "/usr/bin" }}, null);
    defer cfg.deinit();

    try testing.expectEqualStrings("sh", cfg.shell.command);
    try testing.expectEqual(@as(usize, 4), cfg.workers.len);
    // File order is display order.
    try testing.expectEqualStrings("postgres", cfg.workers[0].name);
    try testing.expectEqualStrings("web", cfg.workers[3].name);

    const pg = cfg.workers[0];
    try testing.expectEqualStrings(
        "docker run --rm -p 5432:5432 -e POSTGRES_PASSWORD=dev postgres:16",
        pg.command,
    );
    try testing.expectEqualStrings("pg_isready -h localhost", pg.readiness_probe.?.target.exec);
    try testing.expectEqual(@as(u32, 2), pg.readiness_probe.?.period_seconds);
    try testing.expectEqual(@as(u32, 30), pg.readiness_probe.?.failure_threshold);
    // Unset probe fields keep their defaults, not zero.
    try testing.expectEqual(@as(u32, 1), pg.readiness_probe.?.timeout_seconds);
    try testing.expectEqual(@as(u32, 30), pg.shutdown.timeout_seconds);
    try testing.expectEqual(@as(u8, 15), pg.shutdown.signal);
    // Globals reach every service, built in order.
    try testing.expectEqualStrings("ROOT=/repo", pg.env[0]);
    try testing.expectEqualStrings("PATH=/repo/bin:/usr/bin", pg.env[1]);

    // The short form of `after` waits for ready when there is a check.
    const migrate = cfg.workers[1];
    try testing.expectEqual(Condition.ready, migrate.depends_on[0].condition);
    try testing.expectEqualStrings("schema migrations", migrate.description.?);

    const api = cfg.workers[2];
    try testing.expectEqual(Restart.on_failure, api.restart);
    try testing.expectEqualStrings("/repo/apps/api", api.working_dir.?);
    // Template env, then the service's own; numbers and booleans as text.
    try testing.expectEqualStrings("NODE_ENV=development", api.env[2]);
    try testing.expectEqualStrings("PORT=3000", api.env[3]);
    try testing.expectEqualStrings("DEBUG=true", api.env[4]);
    // `stop` merges field by field: the template's signal, the service's grace.
    try testing.expectEqual(@as(u8, 2), api.shutdown.signal);
    try testing.expectEqual(@as(u32, 60), api.shutdown.timeout_seconds);
    try testing.expectEqual(Condition.succeeded, api.depends_on[0].condition);
    try testing.expectEqual(Condition.ready, api.depends_on[1].condition);
    const http = api.readiness_probe.?.target.http_get;
    try testing.expectEqualStrings("localhost", http.host);
    try testing.expectEqual(@as(u16, 3000), http.port);
    try testing.expectEqualStrings("/health", http.path);

    const web = cfg.workers[3];
    try testing.expectEqualStrings("Local:", web.ready_log_line.?);
    try testing.expect(web.readiness_probe == null);
    try testing.expectEqual(Condition.ready, web.depends_on[0].condition);
    try testing.expectEqual(@as(u32, 15), web.shutdown.timeout_seconds);
}

test "the short form of after waits for started when there is no ready check" {
    var cfg = try loadForTest(
        \\[services.db]
        \\run = "postgres"
        \\[services.api]
        \\run = "go run ."
        \\after = ["db"]
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expectEqual(Condition.started, cfg.workers[1].depends_on[0].condition);
}

test "run is handed to the shell untouched, so the shell expands it" {
    var cfg = try loadForTest(
        \\[services.x]
        \\run = "echo $HOME ${USER:-me} | awk '{print $1}'"
        \\
    , &.{.{ "HOME", "/home/x" }}, null);
    defer cfg.deinit();
    try testing.expectEqualStrings("echo $HOME ${USER:-me} | awk '{print $1}'", cfg.workers[0].command);
}

test "variables: unset is empty, defaults apply, and $$ is a dollar" {
    var cfg = try loadForTest(
        \\[env]
        \\A = "${MISSING}"
        \\B = "${MISSING:-fallback}"
        \\C = "${SET:-unused}"
        \\D = "$SET/x"
        \\E = "cost: $$5"
        \\F = "${EMPTY:-was empty}"
        \\[services.x]
        \\run = "true"
        \\
    , &.{ .{ "SET", "yes" }, .{ "EMPTY", "" } }, null);
    defer cfg.deinit();
    const env = cfg.workers[0].env;
    try testing.expectEqualStrings("A=", env[0]);
    try testing.expectEqualStrings("B=fallback", env[1]);
    try testing.expectEqualStrings("C=yes", env[2]);
    try testing.expectEqualStrings("D=yes/x", env[3]);
    try testing.expectEqualStrings("E=cost: $5", env[4]);
    try testing.expectEqualStrings("F=was empty", env[5]);
}

test "a top-level env_file is in scope for variables and reaches every service" {
    const dir = "/tmp/devrun-config-test-envfile";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/.env",
        .data = "API_PORT=4100\nexport TOKEN='abc'\n",
    });

    var cfg = try loadForTestIn(
        \\env_file = ".env"
        \\[services.api]
        \\run = "go run ."
        \\env_file = [".env.api"]
        \\ready = { http = "http://127.0.0.1:${API_PORT}/healthz" }
        \\
    , dir, &.{.{ "API_PORT", "1" }}, null);
    defer cfg.deinit();
    const api = cfg.workers[0];
    // The file beats the environment devrun was started in.
    try testing.expectEqual(@as(u16, 4100), api.readiness_probe.?.target.http_get.port);
    try testing.expectEqualStrings("/healthz", api.readiness_probe.?.target.http_get.path);
    try testing.expectEqualStrings(".env", api.env_file[0]);
    try testing.expectEqualStrings(".env.api", api.env_file[1]);
}

test "a missing top-level env_file is an error, not an empty scope" {
    try expectRejected(
        \\env_file = ".env.does-not-exist"
        \\[services.x]
        \\run = "true"
        \\
    , "cannot read");
}

test "syntax errors name the file, line and column" {
    try expectRejected(
        \\[services.api]
        \\run = "x"
        \\run = "y"
        \\
    , "devrun.toml:3:1: \"run\" is defined twice");
}

test "unknown fields are refused, with a hint when it is a familiar name" {
    try expectRejected(
        \\[services.go]
        \\run = "go run ."
        \\log_location = "/tmp/go.log"
        \\
    , "services.go: unknown field \"log_location\". Fields here: run,");
    try expectRejected(
        \\[services.go]
        \\command = "go run ."
        \\
    , "devrun calls it \"run\"");
    try expectRejected(
        \\[processes.go]
        \\command = "go run ."
        \\
    , "devrun calls it \"services\"");
    try expectRejected(
        \\[services.go]
        \\run = "go run ."
        \\ready = { http = "http://localhost:1", period_seconds = 3 }
        \\
    , "devrun calls it \"every\"");
}

test "reserved names say they are coming rather than unknown" {
    try expectRejected(
        \\include = ["apps/*/devrun.toml"]
        \\[services.w]
        \\run = "x"
        \\
    , "reserved for a later version");
    try expectRejected(
        \\[services.w]
        \\run = "x"
        \\ready = { exec = "x", tcp = 80 }
        \\
    , "reserved for a later version");
}

test "dependencies that could never resolve are refused at load" {
    try expectRejected(
        \\[services.go]
        \\run = "go run ."
        \\after = { db = "ready" }
        \\
    , "\"db\" is not a service");
    try expectRejected(
        \\[services.db]
        \\run = "postgres"
        \\[services.go]
        \\run = "go run ."
        \\after = { db = "ready" }
        \\
    , "has no ready check");
    try expectRejected(
        \\[services.go]
        \\run = "go run ."
        \\after = ["go"]
        \\
    , "waits for itself");
    try expectRejected(
        \\[services.go]
        \\run = "go run ."
        \\after = { db = "process_healthy" }
        \\
    , "devrun calls it \"ready\"");
}

test "a cycle names only the services stuck in it" {
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(
        \\[services.a]
        \\run = "a"
        \\after = ["c"]
        \\[services.b]
        \\run = "b"
        \\after = ["a"]
        \\[services.c]
        \\run = "c"
        \\after = ["b"]
        \\[services.free]
        \\run = "free"
        \\
    , &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "cycle") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "free") == null);
}

test "a chain that is merely deep is not a cycle" {
    var cfg = try loadForTest(
        \\[services.a]
        \\run = "a"
        \\[services.b]
        \\run = "b"
        \\after = ["a"]
        \\[services.c]
        \\run = "c"
        \\after = ["b"]
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 3), cfg.workers.len);
}

test "a ready check is exactly one kind, and log checks take no timing" {
    try expectRejected(
        \\[services.go]
        \\run = "go"
        \\ready = { exec = "true", http = "http://localhost:1" }
        \\
    , "pick one");
    try expectRejected(
        \\[services.go]
        \\run = "go"
        \\ready = { every = "5s" }
        \\
    , "needs one of");
    try expectRejected(
        \\[services.go]
        \\run = "go"
        \\ready = { log = "up", every = "5s" }
        \\
    , "passes the moment the line appears");
    try expectRejected(
        \\[services.go]
        \\run = "go"
        \\ready = "pg_isready"
        \\
    , "must be an http:// URL");
    try expectRejected(
        \\[services.go]
        \\run = "go"
        \\ready = "https://localhost:8443"
        \\
    , "https is not supported");
}

test "the values a person gets wrong get a message that fixes them" {
    try expectRejected(
        \\[services.go]
        \\run = "go"
        \\restart = "on_failure"
        \\
    , "is spelled \"on-failure\"");
    try expectRejected(
        \\[services.go]
        \\run = "go"
        \\ready = { exec = "true", every = "500ms" }
        \\
    , "whole seconds");
    try expectRejected(
        \\[services.go]
        \\run = "go"
        \\stop = { signal = "SIGNOPE" }
        \\
    , "is not a signal");
    try expectRejected(
        \\[services.go]
        \\description = "no run here"
        \\
    , "missing \"run\"");
    try expectRejected(
        \\[services."../etc"]
        \\run = "x"
        \\
    , "a service name may use");
    try expectRejected(
        \\[services.go]
        \\run = "go"
        \\extends = "nope"
        \\
    , "there is no template \"nope\"");
    try expectRejected(
        \\[services]
        \\
    , "[services] is empty");
    try expectRejected(
        \\[env]
        \\A = "1"
        \\
    , "no [services]");
}

test "signals are accepted by name, with or without SIG, or by number" {
    var cfg = try loadForTest(
        \\[services.a]
        \\run = "a"
        \\stop.signal = "sigquit"
        \\[services.b]
        \\run = "b"
        \\stop.signal = 1
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expectEqual(@as(u8, 3), cfg.workers[0].shutdown.signal);
    try testing.expectEqual(@as(u8, 1), cfg.workers[1].shutdown.signal);
    try testing.expectEqualStrings("QUIT", signalName(3).?);
}

/// Like `loadForTest`, with a profile named.
fn loadProfile(src: []const u8, profile: ?[]const u8, diag: ?*Diagnostic) !Config {
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    return loadSource(testing.allocator, src, "/nonexistent-devrun-test-dir", .{
        .io = threaded.io(),
        .environ = &environ,
        .profile = profile,
    }, diag);
}

test "exit-on-end is a restart policy" {
    var cfg = try loadForTest(
        \\[services.a]
        \\run = "a"
        \\restart = "exit-on-end"
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expectEqual(Restart.exit_on_end, cfg.workers[0].restart);
    try testing.expectEqual(Restart.exit_on_end, Restart.parse("exit-on-end").?);
}

test "restart as a table: policy, max and backoff" {
    var cfg = try loadForTest(
        \\[services.a]
        \\run = "a"
        \\restart = { policy = "on-failure", max = 5, backoff = "500ms" }
        \\[services.b]
        \\run = "b"
        \\restart = { policy = "always" }
        \\[services.c]
        \\run = "c"
        \\restart = { policy = "always", backoff = 2 }
        \\[services.d]
        \\run = "d"
        \\restart = "always"
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expectEqual(Restart.on_failure, cfg.workers[0].restart);
    try testing.expectEqual(@as(u32, 5), cfg.workers[0].restart_max);
    try testing.expectEqual(@as(u32, 500), cfg.workers[0].restart_backoff_ms);
    try testing.expectEqual(@as(u32, 0), cfg.workers[1].restart_max);
    try testing.expectEqual(@as(u32, 200), cfg.workers[1].restart_backoff_ms);
    try testing.expectEqual(@as(u32, 2000), cfg.workers[2].restart_backoff_ms);
    try testing.expectEqual(@as(u32, 200), cfg.workers[3].restart_backoff_ms);

    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\restart = { max = 3 }
        \\
    , "needs \"policy\"");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\restart = { policy = "no", max = 3 }
        \\
    , "only applies to the policies");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\restart = { policy = "exit-on-failure", backoff = "1s" }
        \\
    , "only applies to the policies");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\restart = { policy = "always", max = 0 }
        \\
    , "must be at least 1");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\restart = { policy = "always", backoff = "soon" }
        \\
    , "is not a duration");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\restart = { policy = "sometimes" }
        \\
    , "unknown policy");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\restart = { policy = "always", retries = 3 }
        \\
    , "unknown field \"retries\"");
}

test "ready.status is for http checks only" {
    var cfg = try loadForTest(
        \\[services.a]
        \\run = "a"
        \\ready = { http = "http://localhost:80/up", status = 204 }
        \\[services.b]
        \\run = "b"
        \\ready = "http://localhost:81/"
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expectEqual(@as(?u16, 204), cfg.workers[0].readiness_probe.?.target.http_get.status);
    try testing.expectEqual(@as(?u16, null), cfg.workers[1].readiness_probe.?.target.http_get.status);

    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\ready = { exec = "true", status = 200 }
        \\
    , "applies to http checks");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\ready = { log = "up", status = 200 }
        \\
    , "applies to http checks");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\ready = { http = "http://localhost:80/", status = 99 }
        \\
    , "not an HTTP status");
}

test "stop.command is a command like run, and merges per field with a template" {
    var cfg = try loadForTest(
        \\[templates.t]
        \\stop = { signal = "INT", command = "docker stop x" }
        \\[services.a]
        \\run = "a"
        \\stop.command = ["docker", "stop", "a b"]
        \\[services.b]
        \\extends = "t"
        \\run = "b"
        \\stop.timeout = 3
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expectEqualStrings("docker stop 'a b'", cfg.workers[0].shutdown.command.?);
    try testing.expectEqualStrings("docker stop x", cfg.workers[1].shutdown.command.?);
    try testing.expectEqual(@as(u8, 2), cfg.workers[1].shutdown.signal);
    try testing.expectEqual(@as(u32, 3), cfg.workers[1].shutdown.timeout_seconds);
    try testing.expect(cfg.workers[0].shutdown.signal == 15);
}

test "replicas expand to numbered Workers, each with its own DEVRUN_REPLICA" {
    var cfg = try loadForTest(
        \\[env]
        \\G = "global"
        \\[services.db]
        \\run = "db"
        \\[services.api]
        \\run = "api"
        \\replicas = 3
        \\env = { ID = "n${DEVRUN_REPLICA}", PORT = 1 }
        \\cwd = "/srv/${DEVRUN_REPLICA}"
        \\env_file = ".env.${DEVRUN_REPLICA}"
        \\ready = "http://127.0.0.1:300${DEVRUN_REPLICA}/"
        \\[services.one]
        \\run = "one"
        \\replicas = 1
        \\[services.web]
        \\run = "web"
        \\after = ["api", "db"]
        \\[services.last]
        \\run = "last"
        \\after = ["api.2"]
        \\
    , &.{}, null);
    defer cfg.deinit();
    const names = [_][]const u8{ "db", "api.1", "api.2", "api.3", "one", "web", "last" };
    try testing.expectEqual(names.len, cfg.workers.len);
    for (names, cfg.workers) |n, w| try testing.expectEqualStrings(n, w.name);

    const api2 = cfg.workers[2];
    try testing.expectEqualStrings("api", api2.group);
    try testing.expectEqual(@as(u32, 2), api2.replica);
    try testing.expectEqualStrings("G=global", api2.env[0]);
    try testing.expectEqualStrings("DEVRUN_REPLICA=2", api2.env[1]);
    try testing.expectEqualStrings("ID=n2", api2.env[2]);
    try testing.expectEqualStrings("PORT=1", api2.env[3]);
    try testing.expectEqualStrings("/srv/2", api2.working_dir.?);
    try testing.expectEqualStrings(".env.2", api2.env_file[0]);
    try testing.expectEqual(@as(u16, 3002), api2.readiness_probe.?.target.http_get.port);
    try testing.expectEqual(@as(u16, 3003), cfg.workers[3].readiness_probe.?.target.http_get.port);

    // N = 1 keeps the plain name but is still a replica, and sees the variable.
    try testing.expectEqualStrings("one", cfg.workers[4].name);
    try testing.expectEqual(@as(u32, 1), cfg.workers[4].replica);
    try testing.expectEqualStrings("DEVRUN_REPLICA=1", cfg.workers[4].env[1]);
    // A service that does not set replicas gets neither.
    try testing.expectEqual(@as(u32, 0), cfg.workers[0].replica);
    try testing.expectEqual(@as(usize, 1), cfg.workers[0].env.len);

    // `after` a replicated service waits on every replica, with the default
    // condition decided per target: ready for api, started for db.
    const web = cfg.workers[5];
    try testing.expectEqual(@as(usize, 4), web.depends_on.len);
    try testing.expectEqualStrings("api.1", web.depends_on[0].name);
    try testing.expectEqual(Condition.ready, web.depends_on[2].condition);
    try testing.expectEqualStrings("db", web.depends_on[3].name);
    try testing.expectEqual(Condition.started, web.depends_on[3].condition);
    // Naming one replica waits on just that one.
    try testing.expectEqual(@as(usize, 1), cfg.workers[6].depends_on.len);
    try testing.expectEqualStrings("api.2", cfg.workers[6].depends_on[0].name);

    try testing.expect(matches(api2, "api"));
    try testing.expect(matches(api2, "api.2"));
    try testing.expect(!matches(api2, "api.1"));
}

test "replicas: range, type, collisions and waiting on yourself" {
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\replicas = 0
        \\
    , "out of range");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\replicas = 65
        \\
    , "out of range");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\replicas = "2"
        \\
    , "expected a whole number");
    try expectRejected(
        \\[services.x]
        \\run = "x"
        \\replicas = 2
        \\[services."x.2"]
        \\run = "y"
        \\
    , "replica name \"x.2\" collides with another service");
    try expectRejected(
        \\[services.x]
        \\run = "x"
        \\replicas = 2
        \\after = ["x"]
        \\
    , "waits for itself");
}

test "autostart is a boolean and defaults to true" {
    var cfg = try loadForTest(
        \\[services.a]
        \\run = "a"
        \\[services.b]
        \\run = "b"
        \\autostart = false
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expect(cfg.workers[0].autostart);
    try testing.expect(!cfg.workers[1].autostart);
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\autostart = "no"
        \\
    , "expected a boolean");
}

test "watch: short form, long form, and the default ignores always present" {
    var cfg = try loadForTest(
        \\[services.a]
        \\run = "a"
        \\watch = "src"
        \\[services.b]
        \\run = "b"
        \\watch = ["src", "lib"]
        \\[services.c]
        \\run = "c"
        \\watch = { paths = ["src"], ignore = ["*.gen.go"], debounce = "1s" }
        \\[services.d]
        \\run = "d"
        \\
    , &.{}, null);
    defer cfg.deinit();
    const a = cfg.workers[0].watch.?;
    try testing.expectEqual(@as(usize, 1), a.paths.len);
    try testing.expectEqualStrings("src", a.paths[0]);
    try testing.expectEqual(@as(u32, 300), a.debounce_ms);
    try testing.expectEqual(default_watch_ignore.len, a.ignore.len);
    try testing.expectEqualStrings(".git", a.ignore[0]);
    try testing.expectEqual(@as(usize, 2), cfg.workers[1].watch.?.paths.len);

    const c = cfg.workers[2].watch.?;
    try testing.expectEqual(@as(u32, 1000), c.debounce_ms);
    try testing.expectEqual(default_watch_ignore.len + 1, c.ignore.len);
    try testing.expectEqualStrings(".git", c.ignore[0]);
    try testing.expectEqualStrings("*.gen.go", c.ignore[c.ignore.len - 1]);
    try testing.expect(cfg.workers[3].watch == null);

    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\watch = { ignore = ["x"] }
        \\
    , "needs \"paths\"");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\watch = []
        \\
    , "is empty");
    try expectRejected(
        \\[services.a]
        \\run = "a"
        \\watch = { paths = ["src"], debounce = "fast" }
        \\
    , "is not a duration");
}

test "templates carry the new fields, and a service replaces them whole" {
    var cfg = try loadForTest(
        \\[templates.t]
        \\replicas = 2
        \\autostart = false
        \\watch = "src"
        \\restart = { policy = "always", max = 3 }
        \\[services.a]
        \\extends = "t"
        \\run = "a"
        \\[services.b]
        \\extends = "t"
        \\run = "b"
        \\replicas = 1
        \\restart = "no"
        \\
    , &.{}, null);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 3), cfg.workers.len);
    try testing.expectEqualStrings("a.2", cfg.workers[1].name);
    try testing.expect(!cfg.workers[0].autostart);
    try testing.expectEqual(@as(u32, 3), cfg.workers[0].restart_max);
    try testing.expectEqualStrings("src", cfg.workers[0].watch.?.paths[0]);
    try testing.expectEqualStrings("b", cfg.workers[2].name);
    try testing.expectEqual(@as(u32, 0), cfg.workers[2].restart_max);
}

test "profiles: env layers over the global env and wins" {
    const src =
        \\color = false
        \\[env]
        \\MODE = "base"
        \\KEEP = "yes"
        \\[profiles.ci]
        \\services = ["api"]
        \\env = { MODE = "${KEEP}-ci" }
        \\[profiles.dev]
        \\services = "web"
        \\env = { MODE = "dev" }
        \\[services.api]
        \\run = "api"
        \\env = { SEEN = "${MODE}" }
        \\[services.web]
        \\run = "web"
        \\
    ;
    var cfg = try loadProfile(src, "ci", null);
    defer cfg.deinit();
    try testing.expect(!cfg.color);
    try testing.expectEqual(@as(usize, 2), cfg.profiles.len);
    try testing.expectEqualStrings("ci", cfg.active_profile.?);
    const env = cfg.workers[0].env;
    try testing.expectEqualStrings("MODE=base", env[0]);
    try testing.expectEqualStrings("KEEP=yes", env[1]);
    try testing.expectEqualStrings("MODE=yes-ci", env[2]);
    try testing.expectEqualStrings("SEEN=yes-ci", env[3]);

    // No profile asked for: none active, and its env is not applied.
    var plain = try loadProfile(src, null, null);
    defer plain.deinit();
    try testing.expect(plain.active_profile == null);
    try testing.expect(plain.color == false);
    try testing.expectEqual(@as(usize, 2), plain.workers[0].env.len - 1);

    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadProfile(src, "nope", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "unknown profile \"nope\". Profiles: ci, dev") != null);
    try testing.expectError(error.Invalid, loadProfile("[services.a]\nrun = \"a\"\n", "x", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "no [profiles]") != null);

    try expectRejected(
        \\[profiles.p]
        \\services = ["ghost"]
        \\[services.a]
        \\run = "a"
        \\
    , "\"ghost\" is not a service");
    try expectRejected(
        \\[profiles.p]
        \\env = { A = "1" }
        \\[services.a]
        \\run = "a"
        \\
    , "missing \"services\"");
}

test "select: names pull in dependencies, no_deps does not" {
    var cfg = try loadForTest(
        \\[services.db]
        \\run = "db"
        \\[services.api]
        \\run = "api"
        \\replicas = 2
        \\after = ["db"]
        \\[services.web]
        \\run = "web"
        \\after = ["api"]
        \\[services.other]
        \\run = "other"
        \\
    , &.{}, null);
    defer cfg.deinit();
    const gpa = testing.allocator;

    try select(&cfg, .{ .names = &.{"web"} }, gpa, null);
    // db, api.1, api.2, web
    const want = [_]bool{ true, true, true, true, false };
    for (want, cfg.workers) |x, w| try testing.expectEqual(x, w.autostart);

    try select(&cfg, .{ .names = &.{"api.2"}, .no_deps = true }, gpa, null);
    const only = [_]bool{ false, false, true, false, false };
    for (only, cfg.workers) |x, w| try testing.expectEqual(x, w.autostart);

    var diag: Diagnostic = .{};
    defer diag.deinit(gpa);
    try testing.expectError(error.Invalid, select(&cfg, .{ .names = &.{"nope"} }, gpa, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "\"nope\"") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "Services: db, api, web, other") != null);
}

test "select: the active profile, else the config's own autostart" {
    const src =
        \\[profiles.front]
        \\services = ["web"]
        \\[services.db]
        \\run = "db"
        \\[services.web]
        \\run = "web"
        \\after = ["db"]
        \\[services.tool]
        \\run = "tool"
        \\autostart = false
        \\[services.other]
        \\run = "other"
        \\
    ;
    const gpa = testing.allocator;

    var plain = try loadProfile(src, null, null);
    defer plain.deinit();
    try select(&plain, .{}, gpa, null);
    const by_default = [_]bool{ true, true, false, true };
    for (by_default, plain.workers) |x, w| try testing.expectEqual(x, w.autostart);
    // A name overrides autostart = false.
    try select(&plain, .{ .names = &.{"tool"} }, gpa, null);
    try testing.expect(plain.workers[2].autostart);
    try testing.expect(!plain.workers[3].autostart);

    var prof = try loadProfile(src, "front", null);
    defer prof.deinit();
    try select(&prof, .{}, gpa, null);
    const by_profile = [_]bool{ true, true, false, false };
    for (by_profile, prof.workers) |x, w| try testing.expectEqual(x, w.autostart);
    try select(&prof, .{ .no_deps = true }, gpa, null);
    const no_deps = [_]bool{ false, true, false, false };
    for (no_deps, prof.workers) |x, w| try testing.expectEqual(x, w.autostart);
}

test "devrun.local.toml is deep-merged over the main file" {
    const dir = "/tmp/devrun-config-test-local";
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/devrun.toml",
        .data =
        \\[env]
        \\A = "main"
        \\[services.api]
        \\run = "api"
        \\restart = "always"
        \\ready = "http://localhost:1/"
        \\[services.web]
        \\run = "web"
        \\
        ,
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/devrun.local.toml",
        .data =
        \\[env]
        \\B = "local"
        \\[services.api]
        \\restart = "no"
        \\ready = { log = "up" }
        \\[services.extra]
        \\run = "extra"
        \\
        ,
    });
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const opts: Options = .{ .io = std.testing.io, .environ = &environ };

    var cfg = try load(testing.allocator, dir ++ "/devrun.toml", opts, null);
    defer cfg.deinit();
    try testing.expectEqualStrings(dir ++ "/devrun.local.toml", cfg.local_path.?);
    try testing.expectEqual(@as(usize, 3), cfg.workers.len);
    // The table merged key by key: `run` survived, `restart` and `ready` were replaced.
    try testing.expectEqualStrings("api", cfg.workers[0].command);
    try testing.expectEqual(Restart.no, cfg.workers[0].restart);
    try testing.expect(cfg.workers[0].readiness_probe == null);
    try testing.expectEqualStrings("up", cfg.workers[0].ready_log_line.?);
    try testing.expectEqualStrings("A=main", cfg.workers[1].env[0]);
    try testing.expectEqualStrings("B=local", cfg.workers[1].env[1]);
    try testing.expectEqualStrings("extra", cfg.workers[2].name);

    // Without a local file nothing changes and nothing is reported.
    try std.Io.Dir.cwd().deleteFile(std.testing.io, dir ++ "/devrun.local.toml");
    var bare = try load(testing.allocator, dir ++ "/devrun.toml", opts, null);
    defer bare.deinit();
    try testing.expect(bare.local_path == null);
    try testing.expectEqual(@as(usize, 2), bare.workers.len);

    // A syntax error in it is named with its own file.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = dir ++ "/devrun.local.toml",
        .data = "[services.api\n",
    });
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, load(testing.allocator, dir ++ "/devrun.toml", opts, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "devrun.local.toml:1:") != null);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, dir ++ "/devrun.local.toml");
}

test "localPathFor swaps .toml for .local.toml" {
    const a = try localPathFor(testing.allocator, "x/devrun.toml");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("x/devrun.local.toml", a);
    const b = try localPathFor(testing.allocator, "cfg");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("cfg.local", b);
}
