//! Reads a `devrun.yml` into a Config.
//!
//! Every key is listed by hand and anything else is refused by name. That
//! refusal is the point rather than a limitation: a field quietly ignored is a
//! setting the author believes is in effect, and the first sign otherwise is a
//! service behaving in a way nothing on screen explains. See
//! `docs/adr/0008-devrun-yml.md`.
//!
//! Load order:
//!
//!   1. read `.env` files
//!   2. expand `${VAR}` / `$VAR` over the *raw file text*, .env winning over the
//!      OS environment, unset names becoming empty
//!   3. parse the result as YAML
//!
//! Substituting before parsing is textual and therefore blunt: a value holding
//! a colon or a newline can reshape the document. It stays that way because it
//! is the only form that can reach a key as easily as a value, and the error a
//! broken substitution produces names the expansion as a likely cause.

const std = @import("std");
const Yaml = @import("yaml").Yaml;
const os = @import("os.zig");
/// For `parseDuration` alone, so a duration in the config and a duration on the
/// command line cannot drift into meaning different things.
const logs_mod = @import("logs.zig");

const Allocator = std.mem.Allocator;

/// Everything this module needs from outside. Passed explicitly rather than
/// reached for, so tests can supply a synthetic environment.
pub const Options = struct {
    io: std.Io,
    /// The process environment. `.env` values are checked *first*, which is
    /// the opposite of the usual precedence and deliberate: a `.env` in the
    /// repo is the setting the repo means, and an inherited one is whatever
    /// the terminal happened to be carrying.
    environ: *const std.process.Environ.Map,
};

/// Largest config we will read. A devrun.yml is a few KB; anything past this
/// is a mistake, and refusing it beats allocating it.
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

/// What a service is waiting for. The file says `started`, `ready`, `done` or
/// `ok`; `resolveCondition` turns those four words into these five states,
/// because `ready` alone means two different things depending on how the
/// service it points at defines readiness.
pub const Condition = enum {
    process_started,
    process_completed,
    process_completed_successfully,
    process_healthy,
    process_log_ready,
};

pub const Restart = enum {
    no,
    always,
    on_failure,
    exit_on_failure,
};

pub const HttpGet = struct {
    host: []const u8 = "127.0.0.1",
    scheme: []const u8 = "http",
    path: []const u8 = "/",
    port: u16,
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
    /// Name of the Worker being waited on. Resolved to an index by the caller,
    /// not here — this module does not know the graph, only the text.
    name: []const u8,
    condition: Condition,
};

/// How a Worker is asked to stop, before the ladder escalates to SIGKILL.
pub const Shutdown = struct {
    /// Signal number. The file names its signals (`SIGINT`), because a number
    /// is not portable across platforms; this is what that name resolved to on
    /// the machine doing the reading.
    signal: u8 = 15, // SIGTERM
    /// How long the Group has to exit on its own before it is killed.
    timeout_seconds: u32 = 10,
};

pub const Worker = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    command: []const u8,
    working_dir: ?[]const u8 = null,
    dotenv: []const []const u8 = &.{},
    environment: []const []const u8 = &.{},
    depends_on: []const Dependency = &.{},
    restart: Restart = .no,
    readiness_probe: ?Probe = null,
    /// Substring that, once seen in this Worker's Archive, makes this Worker
    /// Ready. The other half of `readiness_probe`: a Worker has at most one of
    /// the two, because `ready:` in the file holds exactly one of `http`,
    /// `exec` or `log`.
    ready_log_line: ?[]const u8 = null,
    shutdown: Shutdown = .{},
};

pub const Shell = struct {
    command: []const u8 = "bash",
    argument: []const u8 = "-c",
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    shell: Shell,
    workers: []const Worker,
    /// Things worth saying that are not worth refusing over. A config that
    /// loads with warnings is a config that runs; the caller prints these once
    /// and carries on. Allocated from `arena`, so they live as long as the
    /// Config does.
    warnings: []const []const u8 = &.{},

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
    workers[0] = .{
        .name = try arena.dupe(u8, spec.name),
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

/// Reads and validates `path`. `error.Invalid` means the config was rejected
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
            d.message = std.fmt.allocPrint(gpa, "cannot read {s}: {t}", .{ path, err }) catch null;
        }
        return err;
    };
    defer gpa.free(source);
    return loadSource(gpa, source, std.fs.path.dirname(path) orelse ".", opts, diag);
}

/// The half of `load` that does not read the config file itself. `base_dir` is
/// where `.env` files resolve from. Split out so tests can feed source directly.
pub fn loadSource(
    gpa: Allocator,
    source: []const u8,
    base_dir: []const u8,
    opts: Options,
    diag: ?*Diagnostic,
) !Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    const ctx = Ctx{ .arena = a, .gpa = gpa, .diag = diag };

    var env = Env{ .os = opts.environ };
    try env.loadDotenv(a, opts.io, base_dir, ".env");

    const expanded = try expandEnv(ctx, source, &env);

    // Deliberately no `yaml.deinit`. Every string in the tree was allocated
    // from `arena`, and the Workers we return point straight at them rather
    // than copying. Calling deinit would hand those slices to
    // `Allocator.free`, which poisons them with `undefined` in safety-checked
    // builds — the values survive syntactically and turn to 0xaa at runtime.
    // The arena reclaims all of it, on both the success and error paths.
    var yaml = Yaml{ .source = expanded };
    yaml.load(a) catch {
        return ctx.failYaml(&yaml.parse_errors);
    };
    if (yaml.docs.items.len == 0) return ctx.fail("config is empty", .{});
    if (yaml.docs.items.len > 1) {
        return ctx.fail("config has {d} YAML documents; devrun expects exactly one", .{yaml.docs.items.len});
    }

    return mapRoot(ctx, yaml.docs.items[0], &arena);
}

// ------------------------------------------------------------- context

const Ctx = struct {
    arena: Allocator,
    gpa: Allocator,
    diag: ?*Diagnostic,

    fn fail(self: Ctx, comptime fmt: []const u8, args: anytype) error{Invalid} {
        if (self.diag) |d| {
            d.deinit(self.gpa);
            d.message = std.fmt.allocPrint(self.gpa, fmt, args) catch null;
        }
        return error.Invalid;
    }

    /// Renders the parser's own diagnostics, which carry line and column. A
    /// bare "not valid YAML" would send the reader hunting through a file they
    /// cannot see — the expansion pass means what the parser read is not
    /// byte-for-byte what is on disk.
    fn failYaml(self: Ctx, errors: *std.zig.ErrorBundle) error{Invalid} {
        const generic = "config is not valid YAML";
        var a: std.Io.Writer.Allocating = .init(self.arena);
        const w = &a.writer;
        w.writeAll(generic ++ ":\n") catch return self.fail(generic, .{});
        errors.renderToWriter(
            .{ .include_reference_trace = false, .include_log_text = false },
            w,
        ) catch return self.fail(generic, .{});
        w.writeAll(
            "note: this is checked after ${VAR} expansion, so a substituted " ++
                "value containing a colon or a newline can be the cause.",
        ) catch {};
        return self.fail("{s}", .{a.written()});
    }

    /// The message every unsupported field produces. Named so the wording stays
    /// identical everywhere — this is the error a user is most likely to hit.
    fn unsupported(self: Ctx, path: []const u8, key: []const u8) error{Invalid} {
        return self.fail(
            "{s}: unsupported field \"{s}\". devrun refuses a field it would " ++
                "otherwise ignore, so that nothing in this file is in effect " ++
                "except what it says.",
            .{ path, key },
        );
    }
};

// ------------------------------------------------------------- environment

const Env = struct {
    os: *const std.process.Environ.Map,
    /// Values from .env files, which win over `os`.
    dotenv: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn loadDotenv(self: *Env, arena: Allocator, io: std.Io, dir: []const u8, name: []const u8) !void {
        const path = try std.fs.path.join(arena, &.{ dir, name });
        // An absent .env is the normal case, not an error.
        const text = std.Io.Dir.cwd().readFileAlloc(
            io,
            path,
            arena,
            .limited(max_file_bytes),
        ) catch return;
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
            try self.dotenv.put(arena, key, value);
        }
    }

    fn get(self: Env, name: []const u8) ?[]const u8 {
        if (self.dotenv.get(name)) |v| return v;
        return self.os.get(name);
    }
};

fn isNameStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Expands `${NAME}` and `$NAME` over raw text. Unset names become empty, which
/// is what makes `HTTPS_PROXY=${TRACE_PROXY}` harmless when TRACE_PROXY is not
/// set. Bash parameter expansion (`${VAR:-default}`, `${VAR#prefix}`, …) is
/// rejected rather than passed through: devrun is not a shell, and quietly
/// expanding half of the syntax is worse than expanding none of it.
fn expandEnv(ctx: Ctx, src: []const u8, env: *const Env) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(ctx.arena, src.len);

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
                return ctx.fail("unterminated \"${{\" in config", .{});
            const name = src[i + 2 .. close];
            if (name.len == 0 or !isNameStart(name[0])) {
                return ctx.fail("invalid variable name in \"${{{s}}}\"", .{name});
            }
            for (name) |c| {
                if (!isNameChar(c)) {
                    return ctx.fail(
                        "\"${{{s}}}\" uses shell parameter expansion, which devrun " ++
                            "does not implement. Move the logic into a script and " ++
                            "call that instead.",
                        .{name},
                    );
                }
            }
            if (env.get(name)) |v| try out.appendSlice(ctx.arena, v);
            i = close + 1;
            continue;
        }
        // Bare $NAME.
        if (i + 1 < src.len and isNameStart(src[i + 1])) {
            var end = i + 1;
            while (end < src.len and isNameChar(src[end])) end += 1;
            const name = src[i + 1 .. end];
            if (env.get(name)) |v| try out.appendSlice(ctx.arena, v);
            i = end;
            continue;
        }
        try out.append(ctx.arena, '$');
        i += 1;
    }
    return out.toOwnedSlice(ctx.arena);
}

// ------------------------------------------------------------- yaml walking

fn expectMap(ctx: Ctx, v: Yaml.Value, path: []const u8) !Yaml.Map {
    // The vendored parser reads a flow mapping as nothing at all rather than
    // failing on it, so this is the one place that silence can be turned back
    // into a sentence. See `docs/adr/0008-devrun-yml.md`.
    switch (v) {
        .empty => return ctx.fail(
            "{s}: expected a mapping and found nothing. A mapping written on one " ++
                "line ({{a: b}}) is read as empty here — write it across lines instead.",
            .{path},
        ),
        else => {},
    }
    return v.asMap() orelse ctx.fail("{s}: expected a mapping", .{path});
}

fn expectScalar(ctx: Ctx, v: Yaml.Value, path: []const u8) ![]const u8 {
    return switch (v) {
        .scalar => |s| s,
        // The parser never produces one today, but `restart: no` is a real
        // value in this format and a YAML that resolved it to `false` must not
        // reach a call site expecting text.
        .boolean => |b| if (b) "true" else "false",
        else => ctx.fail("{s}: expected a scalar", .{path}),
    };
}

fn expectList(ctx: Ctx, v: Yaml.Value, path: []const u8) !Yaml.List {
    return v.asList() orelse ctx.fail("{s}: expected a list", .{path});
}

fn expectU32(ctx: Ctx, v: Yaml.Value, path: []const u8) !u32 {
    const s = try expectScalar(ctx, v, path);
    return std.fmt.parseInt(u32, s, 10) catch
        ctx.fail("{s}: expected a whole number, got \"{s}\"", .{ path, s });
}

/// A duration in the units the CLI already takes: `5s`, `2m`, `1h`, or a bare
/// number of seconds. Sub-second is refused rather than rounded, because every
/// field that takes one is counted by the Probe in whole seconds, and silently
/// turning `500ms` into either 0s or 1s is a config that does not do what it
/// says.
fn expectSeconds(ctx: Ctx, v: Yaml.Value, path: []const u8) !u32 {
    const text = try expectScalar(ctx, v, path);
    const ms = logs_mod.parseDuration(text) orelse return ctx.fail(
        "{s}: expected a duration like 5s, 2m or 1h, got \"{s}\"",
        .{ path, text },
    );
    if (ms % 1000 != 0) {
        return ctx.fail("{s}: \"{s}\" is not a whole number of seconds", .{ path, text });
    }
    const seconds = ms / 1000;
    if (seconds > std.math.maxInt(u32)) {
        return ctx.fail("{s}: \"{s}\" is longer than devrun can wait", .{ path, text });
    }
    return @intCast(seconds);
}

/// One string or a list of them. `env_file: .env` is the common case and
/// wrapping it in brackets to say so would be ceremony.
fn scalarOrList(ctx: Ctx, v: Yaml.Value, path: []const u8) ![]const []const u8 {
    switch (v) {
        .scalar => |single| {
            const out = try ctx.arena.alloc([]const u8, 1);
            out[0] = single;
            return out;
        },
        else => return stringList(ctx, v, path),
    }
}

/// Folds an `env:` mapping into the Builder's, so `defaults` and a service's
/// own env end up merged per variable with the service winning.
fn mergeEnv(ctx: Ctx, b: *Builder, v: Yaml.Value, path: []const u8) !void {
    const m = try expectMap(ctx, v, path);
    for (m.keys(), m.values()) |key, value| {
        if (key.len == 0) return ctx.fail("{s}: has a variable with no name", .{path});
        const kp = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, key });
        try b.env.put(ctx.arena, key, try expectScalar(ctx, value, kp));
    }
}

fn stringList(ctx: Ctx, v: Yaml.Value, path: []const u8) ![]const []const u8 {
    const list = try expectList(ctx, v, path);
    const out = try ctx.arena.alloc([]const u8, list.len);
    for (list, 0..) |item, i| {
        var buf: [64]u8 = undefined;
        const item_path = std.fmt.bufPrint(&buf, "{s}[{d}]", .{ path, i }) catch path;
        out[i] = try expectScalar(ctx, item, item_path);
    }
    return out;
}

// ------------------------------------------------------------- mapping

fn mapRoot(ctx: Ctx, doc: Yaml.Value, arena: *std.heap.ArenaAllocator) !Config {
    const root = try expectMap(ctx, doc, "config root");

    var shell = Shell{};
    var defaults: ?Yaml.Map = null;
    var services: ?Yaml.Map = null;

    for (root.keys(), root.values()) |key, value| {
        if (std.mem.eql(u8, key, "shell")) {
            shell = try mapShell(ctx, value);
        } else if (std.mem.eql(u8, key, "defaults")) {
            defaults = try expectMap(ctx, value, "defaults");
        } else if (std.mem.eql(u8, key, "services")) {
            services = try expectMap(ctx, value, "services");
        } else {
            return ctx.unsupported("config root", key);
        }
    }

    const svc = services orelse return ctx.fail("config has no \"services\" section", .{});
    if (svc.count() == 0) return ctx.fail("\"services\" is empty", .{});

    const workers = try ctx.arena.alloc(Worker, svc.count());
    // `after` cannot be resolved while the services are still being read: what
    // `ready` means for a service is decided by that service's own `ready:`
    // block, which may appear later in the file. So the words are kept as
    // written and resolved once every service is known.
    const pending = try ctx.arena.alloc([]const RawDep, svc.count());

    for (svc.keys(), svc.values(), 0..) |name, value, i| {
        if (name.len == 0) return ctx.fail("services has an entry with no name", .{});
        const parsed = try mapService(ctx, name, value, defaults);
        workers[i] = parsed.worker;
        pending[i] = parsed.after;
    }

    var warnings: std.ArrayListUnmanaged([]const u8) = .empty;
    try resolveAfter(ctx, workers, pending, &warnings);
    try checkAcyclic(ctx, workers);

    return .{
        .arena = arena.*,
        .shell = shell,
        .workers = workers,
        .warnings = try warnings.toOwnedSlice(ctx.arena),
    };
}

/// `shell: [bash, -c]`. A pair rather than two named keys, because the two
/// halves are never useful apart and naming them separately invited
/// `shell_command` sitting alone with no argument to go with it.
fn mapShell(ctx: Ctx, v: Yaml.Value) !Shell {
    const list = try expectList(ctx, v, "shell");
    if (list.len != 2) {
        return ctx.fail(
            "shell: expected a command and its argument, like [bash, -c], got {d} item(s)",
            .{list.len},
        );
    }
    return .{
        .command = try expectScalar(ctx, list[0], "shell[0]"),
        .argument = try expectScalar(ctx, list[1], "shell[1]"),
    };
}

/// One entry under `after`, before the config knows what it points at.
const RawDep = struct {
    /// The service being waited on.
    name: []const u8,
    /// The condition word exactly as written.
    word: []const u8,
    /// Where to point when the name or the word turns out to be wrong.
    path: []const u8,
};

const ParsedService = struct {
    worker: Worker,
    after: []const RawDep,
};

/// Everything a service is while it is still being read.
///
/// `env` stays a map here rather than the `KEY=VALUE` list the Supervisor
/// wants, because it is the one key where `defaults` merges instead of being
/// replaced, and merging a list of glued strings means splitting them again.
const Builder = struct {
    worker: Worker,
    after: []const RawDep = &.{},
    saw_run: bool = false,
    env: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn flattenEnv(self: *Builder, ctx: Ctx) ![]const []const u8 {
        const out = try ctx.arena.alloc([]const u8, self.env.count());
        for (self.env.keys(), self.env.values(), 0..) |k, v, i| {
            out[i] = try std.fmt.allocPrint(ctx.arena, "{s}={s}", .{ k, v });
        }
        return out;
    }
};

/// A service is either a string, which is its command and nothing else, or a
/// map. The two are different YAML types rather than two shapes of one, so
/// there is nothing to guess and the error for a third shape can say so.
fn mapService(ctx: Ctx, name: []const u8, v: Yaml.Value, defaults: ?Yaml.Map) !ParsedService {
    const path = try std.fmt.allocPrint(ctx.arena, "services.{s}", .{name});

    var b = Builder{ .worker = .{ .name = name, .command = "" } };
    // Defaults first so that anything the service names overwrites them. There
    // is no merging at depth: a service that writes `stop:` replaces the whole
    // block rather than the fields it happened to mention. `env` is the one
    // exception, and it is a map for exactly that reason.
    //
    // Applied before the shape is known, so that writing a service on one line
    // is a shorter way to say the same thing rather than a quieter way to say
    // something else.
    if (defaults) |d| try applyKeys(ctx, &b, d, "defaults", true);

    switch (v) {
        .scalar => |command| {
            if (command.len == 0) return ctx.fail("{s}: the command is empty", .{path});
            b.worker.command = command;
        },
        .map => {
            try applyKeys(ctx, &b, try expectMap(ctx, v, path), path, false);
            if (!b.saw_run) return ctx.fail("{s}: missing \"run\"", .{path});
            if (b.worker.command.len == 0) return ctx.fail("{s}.run is empty", .{path});
        },
        else => return ctx.fail(
            "{s}: expected a command, or a mapping of settings",
            .{path},
        ),
    }

    b.worker.environment = try b.flattenEnv(ctx);
    return .{ .worker = b.worker, .after = b.after };
}

fn applyKeys(ctx: Ctx, b: *Builder, m: Yaml.Map, path: []const u8, is_defaults: bool) !void {
    for (m.keys(), m.values()) |key, value| {
        const kp = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, key });
        if (std.mem.eql(u8, key, "run")) {
            if (is_defaults) return ctx.fail(
                "defaults.run: every service needs its own command, so \"run\" cannot be a default",
                .{},
            );
            b.worker.command = try expectScalar(ctx, value, kp);
            b.saw_run = true;
        } else if (std.mem.eql(u8, key, "description")) {
            b.worker.description = try expectScalar(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "dir")) {
            b.worker.working_dir = try expectScalar(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "env_file")) {
            b.worker.dotenv = try scalarOrList(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "env")) {
            try mergeEnv(ctx, b, value, kp);
        } else if (std.mem.eql(u8, key, "after")) {
            if (is_defaults) return ctx.fail(
                "defaults.after: a dependency belongs to one service, so \"after\" cannot be a default",
                .{},
            );
            b.after = try mapAfter(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "restart")) {
            b.worker.restart = try mapRestart(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "ready")) {
            // Cleared first so a service's own `ready:` replaces the one it
            // inherited rather than half of it: the two fields are the two
            // shapes readiness comes in, and holding both would be a state no
            // file can express.
            b.worker.readiness_probe = null;
            b.worker.ready_log_line = null;
            try mapReady(ctx, b, value, kp);
        } else if (std.mem.eql(u8, key, "stop")) {
            b.worker.shutdown = try mapStop(ctx, value, kp);
        } else {
            return ctx.unsupported(path, key);
        }
    }
}

fn mapRestart(ctx: Ctx, v: Yaml.Value, path: []const u8) !Restart {
    const text = try expectScalar(ctx, v, path);
    return std.meta.stringToEnum(Restart, text) orelse ctx.fail(
        "{s}: unknown policy \"{s}\" (expected no, always, on_failure or exit_on_failure)",
        .{ path, text },
    );
}

/// `after: [db, migrate]` waits for both to be Ready. `after: {db: ready}`
/// says which state to wait for. A list and a map are different YAML types, so
/// the two forms cannot be confused for one another.
fn mapAfter(ctx: Ctx, v: Yaml.Value, path: []const u8) ![]const RawDep {
    switch (v) {
        .list => |list| {
            const out = try ctx.arena.alloc(RawDep, list.len);
            for (list, 0..) |item, i| {
                const ip = try std.fmt.allocPrint(ctx.arena, "{s}[{d}]", .{ path, i });
                out[i] = .{
                    .name = try expectScalar(ctx, item, ip),
                    .word = "ready",
                    .path = ip,
                };
            }
            return out;
        },
        .map => |m| {
            const out = try ctx.arena.alloc(RawDep, m.count());
            for (m.keys(), m.values(), 0..) |dep_name, value, i| {
                const dp = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, dep_name });
                out[i] = .{
                    .name = dep_name,
                    .word = try expectScalar(ctx, value, dp),
                    .path = dp,
                };
            }
            return out;
        },
        // `.empty` lands here when someone writes `after: {db: ready}`, which
        // the vendored parser reads as nothing rather than refusing.
        else => return ctx.fail(
            "{s}: expected a list of service names, or a mapping of name to " ++
                "condition written across lines — a mapping on one line " ++
                "({{db: ready}}) is read as empty here.",
            .{path},
        ),
    }
}

/// `ready:` holds exactly one of `http`, `exec` or `log`, plus the timing that
/// applies to a probe. The one-of is checked here rather than left to the
/// Supervisor, because two of them is a file whose author believed something
/// that is not true about their own service.
fn mapReady(ctx: Ctx, b: *Builder, v: Yaml.Value, path: []const u8) !void {
    const m = try expectMap(ctx, v, path);

    var probe = Probe{ .target = undefined };
    var target: ?@FieldType(Probe, "target") = null;
    var log_line: ?[]const u8 = null;
    // The first timing key seen, so that pairing one with `log` can name it.
    var timing: ?[]const u8 = null;

    for (m.keys(), m.values()) |key, value| {
        const kp = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, key });
        if (std.mem.eql(u8, key, "http")) {
            try onlyOne(ctx, path, target != null or log_line != null);
            target = .{ .http_get = try mapUrl(ctx, value, kp) };
        } else if (std.mem.eql(u8, key, "exec")) {
            try onlyOne(ctx, path, target != null or log_line != null);
            target = .{ .exec = try expectScalar(ctx, value, kp) };
        } else if (std.mem.eql(u8, key, "log")) {
            try onlyOne(ctx, path, target != null or log_line != null);
            log_line = try expectScalar(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "delay")) {
            probe.initial_delay_seconds = try expectSeconds(ctx, value, kp);
            timing = timing orelse key;
        } else if (std.mem.eql(u8, key, "every")) {
            probe.period_seconds = try expectSeconds(ctx, value, kp);
            timing = timing orelse key;
        } else if (std.mem.eql(u8, key, "timeout")) {
            probe.timeout_seconds = try expectSeconds(ctx, value, kp);
            timing = timing orelse key;
        } else if (std.mem.eql(u8, key, "passes")) {
            probe.success_threshold = try expectU32(ctx, value, kp);
            timing = timing orelse key;
        } else if (std.mem.eql(u8, key, "fails")) {
            probe.failure_threshold = try expectU32(ctx, value, kp);
            timing = timing orelse key;
        } else {
            return ctx.unsupported(path, key);
        }
    }

    if (log_line) |line| {
        if (line.len == 0) return ctx.fail("{s}.log is empty", .{path});
        // Refused rather than ignored: a log line is matched as the Archive is
        // written, so there is no period to set and no attempt to time out.
        if (timing) |t| return ctx.fail(
            "{s}: \"{s}\" has no meaning next to \"log\", which is matched as the " ++
                "output arrives rather than polled",
            .{ path, t },
        );
        b.worker.ready_log_line = line;
        return;
    }

    probe.target = target orelse return ctx.fail(
        "{s}: needs one of \"http\", \"exec\" or \"log\"",
        .{path},
    );
    if (probe.period_seconds == 0) return ctx.fail("{s}.every must be at least 1s", .{path});
    if (probe.timeout_seconds == 0) return ctx.fail("{s}.timeout must be at least 1s", .{path});
    if (probe.success_threshold == 0) return ctx.fail("{s}.passes must be at least 1", .{path});
    if (probe.failure_threshold == 0) return ctx.fail("{s}.fails must be at least 1", .{path});
    b.worker.readiness_probe = probe;
}

fn onlyOne(ctx: Ctx, path: []const u8, already: bool) !void {
    if (already) return ctx.fail(
        "{s}: give exactly one of \"http\", \"exec\" or \"log\"",
        .{path},
    );
}

/// `http://127.0.0.1:3000/health`, split into what the Probe wants.
///
/// Both refusals below are the Probe's limits rather than the format's, and
/// both are caught here so they land on the terminal that typed `devrun up`
/// instead of becoming a service that never turns Ready.
fn mapUrl(ctx: Ctx, v: Yaml.Value, path: []const u8) !HttpGet {
    const text = try expectScalar(ctx, v, path);

    if (std.mem.startsWith(u8, text, "https://")) return ctx.fail(
        "{s}: https is not supported. The probe speaks plain HTTP, and probing " ++
            "an https port over http would report a service ready that is not.",
        .{path},
    );
    if (!std.mem.startsWith(u8, text, "http://")) return ctx.fail(
        "{s}: expected a URL like http://127.0.0.1:3000/health, got \"{s}\"",
        .{ path, text },
    );

    const rest = text["http://".len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const url_path = if (slash == rest.len) "/" else rest[slash..];

    var host = authority;
    var port: u16 = 80;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        const port_text = authority[colon + 1 ..];
        port = std.fmt.parseInt(u16, port_text, 10) catch return ctx.fail(
            "{s}: \"{s}\" is not a port number",
            .{ path, port_text },
        );
        if (port == 0) return ctx.fail("{s}: port 0 is not a port to probe", .{path});
    }
    if (host.len == 0) return ctx.fail("{s}: no host in \"{s}\"", .{ path, text });
    if (!isIp4OrLocalhost(host)) return ctx.fail(
        "{s}: the host must be an IPv4 literal or \"localhost\", not \"{s}\". The " ++
            "probe does not resolve names, because one that waits on DNS is " ++
            "measuring the resolver as much as the service.",
        .{ path, host },
    );

    return .{ .host = host, .scheme = "http", .path = url_path, .port = port };
}

/// Mirrors what `probe.parseIp4` will accept. Kept in step with it deliberately:
/// the point of checking here is that the two agree, so a URL this accepts is a
/// URL that will probe.
fn isIp4OrLocalhost(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost")) return true;
    var seen: usize = 0;
    var it = std.mem.splitScalar(u8, host, '.');
    while (it.next()) |part| {
        seen += 1;
        if (seen > 4) return false;
        if (part.len == 0 or part.len > 3) return false;
        _ = std.fmt.parseInt(u8, part, 10) catch return false;
    }
    return seen == 4;
}

fn mapStop(ctx: Ctx, v: Yaml.Value, path: []const u8) !Shutdown {
    const m = try expectMap(ctx, v, path);
    var out = Shutdown{};
    for (m.keys(), m.values()) |key, value| {
        const kp = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, key });
        if (std.mem.eql(u8, key, "signal")) {
            out.signal = try mapSignal(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "grace")) {
            out.timeout_seconds = try expectSeconds(ctx, value, kp);
        } else {
            return ctx.unsupported(path, key);
        }
    }
    return out;
}

/// Signals are named rather than numbered. A number is what the kernel wants,
/// but it is not portable across the platforms devrun means to run on — SIGUSR1
/// is 10 here and 30 on a Mac — so a file holding `10` would mean two different
/// things on two machines while looking identical.
const signals = [_]struct { name: []const u8, number: u8 }{
    .{ .name = "SIGHUP", .number = @intFromEnum(os.SIG.HUP) },
    .{ .name = "SIGINT", .number = @intFromEnum(os.SIG.INT) },
    .{ .name = "SIGQUIT", .number = @intFromEnum(os.SIG.QUIT) },
    .{ .name = "SIGABRT", .number = @intFromEnum(os.SIG.ABRT) },
    .{ .name = "SIGKILL", .number = @intFromEnum(os.SIG.KILL) },
    .{ .name = "SIGUSR1", .number = @intFromEnum(os.SIG.USR1) },
    .{ .name = "SIGUSR2", .number = @intFromEnum(os.SIG.USR2) },
    .{ .name = "SIGTERM", .number = @intFromEnum(os.SIG.TERM) },
};

/// The name a signal number came from, for printing a config back. Falls back
/// to the number, because a signal devrun cannot name is still a signal that
/// will be sent and hiding it would be worse than showing a bare integer.
pub fn signalName(number: u8) []const u8 {
    for (signals) |s| {
        if (s.number == number) return s.name;
    }
    return "signal";
}

/// The word a Condition is written as. The inverse of `resolveCondition`, and
/// lossy in the one place that inverse cannot be exact: two states are reached
/// by the same word, because what `ready` means is decided by the service being
/// waited on rather than by the waiting.
pub fn conditionWord(c: Condition) []const u8 {
    return switch (c) {
        .process_started => "started",
        .process_completed => "done",
        .process_completed_successfully => "ok",
        .process_healthy, .process_log_ready => "ready",
    };
}

fn mapSignal(ctx: Ctx, v: Yaml.Value, path: []const u8) !u8 {
    const text = try expectScalar(ctx, v, path);
    for (signals) |s| {
        if (std.mem.eql(u8, s.name, text)) return s.number;
    }

    var known: std.Io.Writer.Allocating = .init(ctx.arena);
    for (signals, 0..) |s, i| {
        if (i > 0) known.writer.writeAll(", ") catch {};
        known.writer.writeAll(s.name) catch {};
    }
    return ctx.fail(
        "{s}: unknown signal \"{s}\" (expected one of {s})",
        .{ path, text, known.written() },
    );
}

/// Resolves every `after` entry now that every service is known, and is the
/// only place a condition word becomes a Condition.
fn resolveAfter(
    ctx: Ctx,
    workers: []Worker,
    pending: []const []const RawDep,
    warnings: *std.ArrayListUnmanaged([]const u8),
) !void {
    for (workers, pending, 0..) |*w, raw, self_index| {
        const out = try ctx.arena.alloc(Dependency, raw.len);
        for (raw, 0..) |dep, i| {
            const target = indexOf(workers, dep.name) orelse return ctx.fail(
                "{s}: \"{s}\" is not a service in this config",
                .{ dep.path, dep.name },
            );
            if (target == self_index) {
                return ctx.fail("services.{s} waits on itself", .{w.name});
            }
            out[i] = .{
                .name = dep.name,
                .condition = try resolveCondition(ctx, dep, workers[target], w.name, warnings),
            };
        }
        w.depends_on = out;
    }
}

/// The four words a file uses, onto the states the Supervisor tracks.
///
/// `ready` is the only one that needs to look at what it points at. Every
/// service has a Ready state; what reaches it is whatever that service's own
/// `ready:` block says, and a service without one is Ready as soon as it has
/// started. That is said out loud as a warning rather than accepted in silence,
/// because "waits for the database" and "waits for the database's pid" are not
/// the same promise and only one of them is being kept.
fn resolveCondition(
    ctx: Ctx,
    dep: RawDep,
    target: Worker,
    waiter: []const u8,
    warnings: *std.ArrayListUnmanaged([]const u8),
) !Condition {
    if (std.mem.eql(u8, dep.word, "started")) return .process_started;
    if (std.mem.eql(u8, dep.word, "done")) return .process_completed;
    if (std.mem.eql(u8, dep.word, "ok")) return .process_completed_successfully;
    if (!std.mem.eql(u8, dep.word, "ready")) return ctx.fail(
        "{s}: unknown condition \"{s}\" (expected started, ready, done or ok)",
        .{ dep.path, dep.word },
    );

    if (target.readiness_probe != null) return .process_healthy;
    if (target.ready_log_line != null) return .process_log_ready;

    try warnings.append(ctx.arena, try std.fmt.allocPrint(
        ctx.arena,
        "\"{s}\" waits for \"{s}\" to be ready, but \"{s}\" has no \"ready:\" block, " ++
            "so it will only wait for it to start.",
        .{ waiter, dep.name, dep.name },
    ));
    return .process_started;
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
        "depends_on has a cycle: {s} can never start, because each is waiting " ++
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
    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    for (vars) |kv| try environ.put(kv[0], kv[1]);

    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();

    return loadSource(
        testing.allocator,
        src,
        // A directory with no .env, so only `vars` is in scope.
        "/nonexistent-devrun-test-dir",
        .{ .io = threaded.io(), .environ = &environ },
        diag,
    );
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

    // Defaults come from the same struct a YAML Worker gets, so an ad-hoc run
    // shuts down the way every other Worker does.
    try testing.expectEqual(@as(u8, 15), cfg.workers[0].shutdown.signal);
    try testing.expectEqual(@as(u32, 10), cfg.workers[0].shutdown.timeout_seconds);
    try testing.expectEqualStrings("bash", cfg.shell.command);

    // Strings are owned by the Config's arena, not borrowed from the caller.
    // `devrun run` frees the joined command right after building this.
    try testing.expect(cfg.workers[0].command.ptr != @as([*]const u8, "pnpm run dev"));
}

test "parses a whole config, defaults and all" {
    const src =
        \\shell: [bash, "-c"]
        \\defaults:
        \\  env_file: ".env"
        \\  stop:
        \\    signal: SIGTERM
        \\    grace: 10s
        \\services:
        \\  tailwind: "pnpm tailwindcss -w"
        \\  db:
        \\    run: "docker compose up postgres"
        \\    ready:
        \\      log: "database system is ready to accept connections"
        \\  migrate:
        \\    run: "pnpm drizzle-kit migrate"
        \\    dir: "./api"
        \\    after: [db]
        \\  api:
        \\    description: "REST API"
        \\    run: "pnpm dev"
        \\    dir: "./api"
        \\    env_file: [".env", ".env.local"]
        \\    env:
        \\      PORT: "3000"
        \\    after:
        \\      migrate: ok
        \\    restart: on_failure
        \\    ready:
        \\      http: "http://127.0.0.1:3000/health"
        \\      delay: 2s
        \\      every: 5s
        \\      timeout: 1s
        \\      fails: 40
        \\    stop:
        \\      signal: SIGINT
        \\      grace: 5s
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();

    try testing.expectEqualStrings("bash", cfg.shell.command);
    try testing.expectEqualStrings("-c", cfg.shell.argument);
    try testing.expectEqual(@as(usize, 4), cfg.workers.len);
    try testing.expectEqual(@as(usize, 0), cfg.warnings.len);

    // A service written as a string is a command and nothing else, but it
    // still picks up `defaults` — the short form is a shorter way to say the
    // same thing, not a quieter way to say something else.
    const tailwind = cfg.workers[cfg.find("tailwind").?];
    try testing.expectEqualStrings("pnpm tailwindcss -w", tailwind.command);
    try testing.expectEqual(@as(usize, 0), tailwind.depends_on.len);
    try testing.expectEqualStrings(".env", tailwind.dotenv[0]);
    try testing.expectEqual(@as(u32, 10), tailwind.shutdown.timeout_seconds);

    const db = cfg.workers[cfg.find("db").?];
    try testing.expectEqualStrings(
        "database system is ready to accept connections",
        db.ready_log_line.?,
    );
    try testing.expect(db.readiness_probe == null);
    // From `defaults`, which nothing on `db` overrode.
    try testing.expectEqualStrings(".env", db.dotenv[0]);
    try testing.expectEqual(@as(u8, 15), db.shutdown.signal);
    try testing.expectEqual(@as(u32, 10), db.shutdown.timeout_seconds);

    // A list under `after` means Ready, and db defines Ready with a log line.
    const migrate = cfg.workers[cfg.find("migrate").?];
    try testing.expectEqual(@as(usize, 1), migrate.depends_on.len);
    try testing.expectEqualStrings("db", migrate.depends_on[0].name);
    try testing.expectEqual(Condition.process_log_ready, migrate.depends_on[0].condition);

    const api = cfg.workers[cfg.find("api").?];
    try testing.expectEqual(Condition.process_completed_successfully, api.depends_on[0].condition);
    try testing.expectEqual(Restart.on_failure, api.restart);
    try testing.expectEqualStrings("PORT=3000", api.environment[0]);
    // `env_file` replaces what defaults set rather than appending to it.
    try testing.expectEqual(@as(usize, 2), api.dotenv.len);
    try testing.expectEqualStrings(".env.local", api.dotenv[1]);
    // As does `stop`, whole block at a time.
    try testing.expectEqual(@as(u8, 2), api.shutdown.signal);
    try testing.expectEqual(@as(u32, 5), api.shutdown.timeout_seconds);

    const http = api.readiness_probe.?.target.http_get;
    try testing.expectEqualStrings("127.0.0.1", http.host);
    try testing.expectEqual(@as(u16, 3000), http.port);
    try testing.expectEqualStrings("/health", http.path);
    try testing.expectEqual(@as(u32, 2), api.readiness_probe.?.initial_delay_seconds);
    try testing.expectEqual(@as(u32, 5), api.readiness_probe.?.period_seconds);
    try testing.expectEqual(@as(u32, 40), api.readiness_probe.?.failure_threshold);
    // Not set in the file, so the default must apply rather than zero.
    try testing.expectEqual(@as(u32, 1), api.readiness_probe.?.success_threshold);
}

test "env merges with defaults per variable, everything else replaces" {
    const src =
        \\defaults:
        \\  env:
        \\    LOG_LEVEL: "info"
        \\    REGION: "local"
        \\services:
        \\  api:
        \\    run: "pnpm dev"
        \\    env:
        \\      LOG_LEVEL: "debug"
        \\      PORT: "3000"
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();

    const env = cfg.workers[0].environment;
    try testing.expectEqual(@as(usize, 3), env.len);
    // The service wins on the key it names; the one it does not name survives.
    try testing.expectEqualStrings("LOG_LEVEL=debug", env[0]);
    try testing.expectEqualStrings("REGION=local", env[1]);
    try testing.expectEqualStrings("PORT=3000", env[2]);
}

test "defaults refuses the two keys that cannot be shared" {
    for ([_][]const u8{ "run", "after" }) |key| {
        const src = try std.fmt.allocPrint(testing.allocator,
            "defaults:\n  {s}: \"x\"\nservices:\n  a:\n    run: \"run a\"\n",
            .{key},
        );
        defer testing.allocator.free(src);

        var diag: Diagnostic = .{};
        defer diag.deinit(testing.allocator);
        try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
        try testing.expect(std.mem.indexOf(u8, diag.message.?, "cannot be a default") != null);
    }
}

test "a comment on the line after a flow sequence is legal" {
    // Pins the local patch in src/vendor/yaml/Parser.zig. A real config has
    // exactly this shape, so a vendor re-sync that drops the patch fails here
    // rather than at 9am on a Monday.
    const src =
        \\services:
        \\  gate:
        \\    env_file: [".env"]
        \\    # Upstream zig-yaml rejects this comment. It is valid YAML.
        \\    run: "bash scripts/wait-postgres.sh"
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();
    try testing.expectEqualStrings("bash scripts/wait-postgres.sh", cfg.workers[0].command);
    try testing.expectEqualStrings(".env", cfg.workers[0].dotenv[0]);

    // The check the patch narrowed must still catch a genuinely unseparated
    // comment, or the patch has simply deleted a rule instead of fixing it.
    const adjacent =
        \\services:
        \\  gate:
        \\    env_file: [".env"]# touching the bracket
        \\    run: "x"
        \\
    ;
    try testing.expectError(error.Invalid, loadForTest(adjacent, &.{}, null));
}

test "expands ${VAR} and $VAR, unset becoming empty" {
    const src =
        \\services:
        \\  go:
        \\    run: "go run ."
        \\    env:
        \\      PATH: "${ROOT}/shims:${PATH}"
        \\      HTTPS_PROXY: "${TRACE_PROXY}"
        \\      BARE: "$ROOT"
        \\
    ;
    var cfg = try loadForTest(src, &.{
        .{ "ROOT", "/repo" },
        .{ "PATH", "/usr/bin" },
    }, null);
    defer cfg.deinit();

    const env = cfg.workers[0].environment;
    try testing.expectEqualStrings("PATH=/repo/shims:/usr/bin", env[0]);
    // TRACE_PROXY is unset: it must vanish, not error and not stay literal.
    try testing.expectEqualStrings("HTTPS_PROXY=", env[1]);
    try testing.expectEqualStrings("BARE=/repo", env[2]);
}

test "rejects shell parameter expansion instead of passing it through" {
    const src =
        \\services:
        \\  go:
        \\    run: "echo ${MISSING:-fallback}"
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "shell parameter expansion") != null);
}

test "rejects an unsupported field rather than ignoring it" {
    const src =
        \\services:
        \\  go:
        \\    run: "go run ."
        \\    log_location: "/tmp/go.log"
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "log_location") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "services.go") != null);
}

test "rejects a dependency on a service that does not exist" {
    const src =
        \\services:
        \\  go:
        \\    run: "go run ."
        \\    after: [db]
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "\"db\" is not a service") != null);
}

test "rejects a dependency cycle instead of stalling on it at runtime" {
    const src =
        \\services:
        \\  a:
        \\    run: "run a"
        \\    after: [c]
        \\  b:
        \\    run: "run b"
        \\    after: [a]
        \\  c:
        \\    run: "run c"
        \\    after: [b]
        \\  free: "run free"
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "cycle") != null);
    // Only the Workers actually stuck are named; the independent one is not.
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "free") == null);
}

test "a chain that is merely deep is not a cycle" {
    const src =
        \\services:
        \\  a: "run a"
        \\  b:
        \\    run: "run b"
        \\    after: [a]
        \\  c:
        \\    run: "run c"
        \\    after: [b]
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();
    try testing.expectEqual(@as(usize, 3), cfg.workers.len);
}

test "waiting on a service with no ready block warns rather than refuses" {
    // The wait is still honoured, it just cannot mean more than "it started".
    // Refusing would make `after` unusable against a service that has no
    // observable ready signal; saying nothing would let "waits for the
    // database" quietly mean "waits for the database's pid".
    const src =
        \\services:
        \\  db: "postgres"
        \\  go:
        \\    run: "go run ."
        \\    after: [db]
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();

    const go = cfg.workers[cfg.find("go").?];
    try testing.expectEqual(Condition.process_started, go.depends_on[0].condition);
    try testing.expectEqual(@as(usize, 1), cfg.warnings.len);
    try testing.expect(std.mem.indexOf(u8, cfg.warnings[0], "no \"ready:\" block") != null);
}

test "the four condition words reach the five states" {
    const src =
        \\services:
        \\  probed:
        \\    run: "a"
        \\    ready:
        \\      exec: "true"
        \\  logged:
        \\    run: "b"
        \\    ready:
        \\      log: "up"
        \\  gate: "c"
        \\  waiter:
        \\    run: "d"
        \\    after:
        \\      probed: ready
        \\      logged: ready
        \\      gate: ok
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();

    const deps = cfg.workers[cfg.find("waiter").?].depends_on;
    try testing.expectEqual(Condition.process_healthy, deps[0].condition);
    try testing.expectEqual(Condition.process_log_ready, deps[1].condition);
    try testing.expectEqual(Condition.process_completed_successfully, deps[2].condition);

    const started =
        \\services:
        \\  a: "run a"
        \\  b:
        \\    run: "run b"
        \\    after:
        \\      a: started
        \\
    ;
    var cfg2 = try loadForTest(started, &.{}, null);
    defer cfg2.deinit();
    try testing.expectEqual(Condition.process_started, cfg2.workers[1].depends_on[0].condition);
    // `started` asked for explicitly is not the fallback, so it does not warn.
    try testing.expectEqual(@as(usize, 0), cfg2.warnings.len);
}

test "rejects a condition word that is not one of the four" {
    const src =
        \\services:
        \\  a: "run a"
        \\  b:
        \\    run: "run b"
        \\    after:
        \\      a: process_healthy
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "started, ready, done or ok") != null);
}

test "ready takes exactly one of http, exec and log" {
    const both =
        \\services:
        \\  go:
        \\    run: "go run ."
        \\    ready:
        \\      exec: "true"
        \\      log: "up"
        \\
    ;
    try testing.expectError(error.Invalid, loadForTest(both, &.{}, null));

    const neither =
        \\services:
        \\  go:
        \\    run: "go run ."
        \\    ready:
        \\      every: 5s
        \\
    ;
    try testing.expectError(error.Invalid, loadForTest(neither, &.{}, null));

    // Timing next to `log` is refused rather than ignored: there is no period
    // to set when the match happens as the output arrives.
    const timed_log =
        \\services:
        \\  go:
        \\    run: "go run ."
        \\    ready:
        \\      log: "up"
        \\      every: 5s
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(timed_log, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "no meaning next to") != null);
}

test "a ready URL is split into what the probe needs, and its limits are caught here" {
    const src =
        \\services:
        \\  bare:
        \\    run: "a"
        \\    ready:
        \\      http: "http://localhost:8080"
        \\  defaulted:
        \\    run: "b"
        \\    ready:
        \\      http: "http://10.0.0.1/healthz"
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();

    // No path means "/", not the empty string.
    const bare = cfg.workers[cfg.find("bare").?].readiness_probe.?.target.http_get;
    try testing.expectEqualStrings("localhost", bare.host);
    try testing.expectEqual(@as(u16, 8080), bare.port);
    try testing.expectEqualStrings("/", bare.path);

    // No port means 80.
    const defaulted = cfg.workers[cfg.find("defaulted").?].readiness_probe.?.target.http_get;
    try testing.expectEqual(@as(u16, 80), defaulted.port);
    try testing.expectEqualStrings("/healthz", defaulted.path);

    // Both of the Probe's limits are refused at load rather than at spawn.
    const cases = [_][2][]const u8{
        .{ "https://127.0.0.1:8443/", "https is not supported" },
        .{ "http://db.internal:5432/", "IPv4 literal" },
        .{ "127.0.0.1:8080", "expected a URL" },
        .{ "http://127.0.0.1:notaport/", "not a port number" },
    };
    for (cases) |c| {
        const bad = try std.fmt.allocPrint(testing.allocator,
            "services:\n  go:\n    run: \"x\"\n    ready:\n      http: \"{s}\"\n",
            .{c[0]},
        );
        defer testing.allocator.free(bad);

        var d: Diagnostic = .{};
        defer d.deinit(testing.allocator);
        try testing.expectError(error.Invalid, loadForTest(bad, &.{}, &d));
        try testing.expect(std.mem.indexOf(u8, d.message.?, c[1]) != null);
    }
}

test "durations take the units the command line takes, and refuse the rest" {
    const src =
        \\services:
        \\  go:
        \\    run: "go run ."
        \\    ready:
        \\      exec: "true"
        \\      delay: 2m
        \\      every: 90
        \\      timeout: 1h
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();

    const p = cfg.workers[0].readiness_probe.?;
    try testing.expectEqual(@as(u32, 120), p.initial_delay_seconds);
    // A bare number is seconds, the same as `--since 30` on the command line.
    try testing.expectEqual(@as(u32, 90), p.period_seconds);
    try testing.expectEqual(@as(u32, 3600), p.timeout_seconds);

    // Sub-second is refused rather than rounded to 0s or 1s.
    const sub =
        \\services:
        \\  go:
        \\    run: "go run ."
        \\    ready:
        \\      exec: "true"
        \\      every: 500ms
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(sub, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "whole number of seconds") != null);
}

test "stop names its signal, and an unset one is SIGTERM with a 10s grace" {
    const src =
        \\services:
        \\  db:
        \\    run: "postgres"
        \\    stop:
        \\      signal: SIGINT
        \\      grace: 30s
        \\  go: "go run ."
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();

    const db = cfg.workers[cfg.find("db").?];
    try testing.expectEqual(@as(u8, 2), db.shutdown.signal);
    try testing.expectEqual(@as(u32, 30), db.shutdown.timeout_seconds);

    const go = cfg.workers[cfg.find("go").?];
    try testing.expectEqual(@as(u8, 15), go.shutdown.signal);
    try testing.expectEqual(@as(u32, 10), go.shutdown.timeout_seconds);

    // A number is not a signal name, however much it looks like one.
    const numbered =
        \\services:
        \\  db:
        \\    run: "postgres"
        \\    stop:
        \\      signal: 2
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(numbered, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "unknown signal") != null);
}

test "a missing run is an error, not an empty string" {
    const src =
        \\services:
        \\  go:
        \\    description: "no command here"
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "missing \"run\"") != null);
}

test "shell is a pair, and anything else is refused" {
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(
        "shell: [bash]\nservices:\n  a: \"run a\"\n",
        &.{},
        &diag,
    ));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "[bash, -c]") != null);
}

test "a document ending on a bare key is an error, not a panic" {
    // Pins the second local patch in src/vendor/yaml/Parser.zig. Upstream reads
    // one token past the end and indexes the token array with it, so a config
    // that stops mid-key takes devrun down with a bounds panic instead of
    // telling its author what is wrong.
    try testing.expectError(error.Invalid, loadForTest("services:\n", &.{}, null));
    try testing.expectError(error.Invalid, loadForTest("services:\n  api:\n", &.{}, null));
}

test "a mapping written on one line is refused rather than read as nothing" {
    // The vendored parser resolves `{a: b}` to an empty value instead of a map,
    // so every place that wants a mapping has to turn that silence into a
    // sentence. Without this the dependency below would simply not exist, and
    // nothing would say so.
    const src =
        \\services:
        \\  db: "postgres"
        \\  api:
        \\    run: "pnpm dev"
        \\    after: {db: ready}
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "read as empty here") != null);

    // And the same for a block that is not `after`.
    const stop =
        \\services:
        \\  db:
        \\    run: "postgres"
        \\    stop: {signal: SIGINT}
        \\
    ;
    var diag2: Diagnostic = .{};
    defer diag2.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(stop, &.{}, &diag2));
    try testing.expect(std.mem.indexOf(u8, diag2.message.?, "across lines") != null);
}

test "an empty or absent services section is refused" {
    try testing.expectError(error.Invalid, loadForTest("shell: [bash, \"-c\"]\n", &.{}, null));
    try testing.expectError(error.Invalid, loadForTest("services:\n", &.{}, null));
}
