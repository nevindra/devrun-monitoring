//! Reads a `process-compose.yaml` into a Config.
//!
//! devrun understands a strict subset of process-compose's schema and refuses
//! everything outside it. That refusal is the point, not a limitation: a field
//! we quietly ignored would let two people run the same file and get different
//! behaviour, with nothing on screen to say why. See
//! `docs/adr/0002-read-process-compose-yaml.md`.
//!
//! Load order matches process-compose exactly, because matching it is the whole
//! promise:
//!
//!   1. read `.env` files
//!   2. expand `${VAR}` / `$VAR` over the *raw file text*, .env winning over the
//!      OS environment, unset names becoming empty
//!   3. parse the result as YAML
//!
//! Substituting before parsing is textual and therefore slightly dangerous — a
//! value containing a colon can reshape the document. process-compose does it
//! this way, so we do too.

const std = @import("std");
const Yaml = @import("yaml").Yaml;

const Allocator = std.mem.Allocator;

/// Everything this module needs from outside. Passed explicitly rather than
/// reached for, so tests can supply a synthetic environment.
pub const Options = struct {
    io: std.Io,
    /// The process environment. `.env` values are checked *first*, matching
    /// process-compose — note that is the opposite of the usual precedence.
    environ: *const std.process.Environ.Map,
};

/// Largest config we will read. A process-compose.yaml is a few KB; anything
/// past this is a mistake, and refusing it beats allocating it.
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
};

pub const Shell = struct {
    command: []const u8 = "bash",
    argument: []const u8 = "-c",
};

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    shell: Shell,
    workers: []const Worker,

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
            "{s}: unsupported field \"{s}\". devrun reads a subset of " ++
                "process-compose's schema and refuses fields it would otherwise " ++
                "ignore, so that both tools read this file the same way.",
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
/// rejected rather than passed through, because process-compose rejects it too
/// and a config that works under one tool must work under the other.
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
                        "\"${{{s}}}\" uses shell parameter expansion, which " ++
                            "process-compose rejects and devrun rejects too. Move the " ++
                            "logic into a script and call that instead.",
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
    return v.asMap() orelse ctx.fail("{s}: expected a mapping", .{path});
}

fn expectScalar(ctx: Ctx, v: Yaml.Value, path: []const u8) ![]const u8 {
    return switch (v) {
        .scalar => |s| s,
        // zig-yaml resolves bare `no`/`yes` to booleans; process-compose users
        // write `restart: "no"` quoted, but an unquoted one must not crash.
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

fn expectU16(ctx: Ctx, v: Yaml.Value, path: []const u8) !u16 {
    const s = try expectScalar(ctx, v, path);
    return std.fmt.parseInt(u16, s, 10) catch
        ctx.fail("{s}: expected a port number, got \"{s}\"", .{ path, s });
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

fn mapRoot(ctx: Ctx, doc: Yaml.Value, arena: *std.heap.ArenaAllocator) !Config {
    const root = try expectMap(ctx, doc, "config root");

    var shell = Shell{};
    var workers: []const Worker = &.{};
    var saw_processes = false;

    for (root.keys(), root.values()) |key, value| {
        if (std.mem.eql(u8, key, "version")) {
            // Accepted and ignored: it names process-compose's schema revision,
            // and we already refuse anything we do not understand by field.
        } else if (std.mem.eql(u8, key, "shell")) {
            shell = try mapShell(ctx, value);
        } else if (std.mem.eql(u8, key, "processes")) {
            workers = try mapWorkers(ctx, value);
            saw_processes = true;
        } else {
            return ctx.unsupported("config root", key);
        }
    }

    if (!saw_processes) return ctx.fail("config has no \"processes\" section", .{});
    if (workers.len == 0) return ctx.fail("\"processes\" is empty", .{});

    try checkDependencies(ctx, workers);

    return .{ .arena = arena.*, .shell = shell, .workers = workers };
}

fn mapShell(ctx: Ctx, v: Yaml.Value) !Shell {
    const m = try expectMap(ctx, v, "shell");
    var shell = Shell{};
    for (m.keys(), m.values()) |key, value| {
        if (std.mem.eql(u8, key, "shell_command")) {
            shell.command = try expectScalar(ctx, value, "shell.shell_command");
        } else if (std.mem.eql(u8, key, "shell_argument")) {
            shell.argument = try expectScalar(ctx, value, "shell.shell_argument");
        } else {
            return ctx.unsupported("shell", key);
        }
    }
    return shell;
}

fn mapWorkers(ctx: Ctx, v: Yaml.Value) ![]const Worker {
    const m = try expectMap(ctx, v, "processes");
    const out = try ctx.arena.alloc(Worker, m.count());
    for (m.keys(), m.values(), 0..) |name, value, i| {
        out[i] = try mapWorker(ctx, name, value);
    }
    return out;
}

fn mapWorker(ctx: Ctx, name: []const u8, v: Yaml.Value) !Worker {
    const path = try std.fmt.allocPrint(ctx.arena, "processes.{s}", .{name});
    const m = try expectMap(ctx, v, path);

    var w = Worker{ .name = name, .command = "" };
    var saw_command = false;

    for (m.keys(), m.values()) |key, value| {
        const kp = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, key });
        if (std.mem.eql(u8, key, "command")) {
            w.command = try expectScalar(ctx, value, kp);
            saw_command = true;
        } else if (std.mem.eql(u8, key, "description")) {
            w.description = try expectScalar(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "working_dir")) {
            w.working_dir = try expectScalar(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "dotenv")) {
            w.dotenv = try stringList(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "environment")) {
            w.environment = try stringList(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "depends_on")) {
            w.depends_on = try mapDependsOn(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "availability")) {
            w.restart = try mapAvailability(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "readiness_probe")) {
            w.readiness_probe = try mapProbe(ctx, value, kp);
        } else {
            return ctx.unsupported(path, key);
        }
    }

    if (!saw_command) return ctx.fail("{s}: missing \"command\"", .{path});
    if (w.command.len == 0) return ctx.fail("{s}.command is empty", .{path});
    return w;
}

fn mapDependsOn(ctx: Ctx, v: Yaml.Value, path: []const u8) ![]const Dependency {
    const m = try expectMap(ctx, v, path);
    const out = try ctx.arena.alloc(Dependency, m.count());
    for (m.keys(), m.values(), 0..) |dep_name, value, i| {
        const dp = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, dep_name });
        const dm = try expectMap(ctx, value, dp);
        var condition: Condition = .process_started; // process-compose's default
        for (dm.keys(), dm.values()) |key, cv| {
            if (!std.mem.eql(u8, key, "condition")) return ctx.unsupported(dp, key);
            const text = try expectScalar(ctx, cv, dp);
            condition = std.meta.stringToEnum(Condition, text) orelse
                return ctx.fail("{s}.condition: unknown condition \"{s}\"", .{ dp, text });
        }
        out[i] = .{ .name = dep_name, .condition = condition };
    }
    return out;
}

fn mapAvailability(ctx: Ctx, v: Yaml.Value, path: []const u8) !Restart {
    const m = try expectMap(ctx, v, path);
    var restart: Restart = .no;
    for (m.keys(), m.values()) |key, value| {
        if (!std.mem.eql(u8, key, "restart")) return ctx.unsupported(path, key);
        const text = try expectScalar(ctx, value, path);
        restart = std.meta.stringToEnum(Restart, text) orelse
            return ctx.fail(
                "{s}.restart: unknown policy \"{s}\" (expected no, always, on_failure, exit_on_failure)",
                .{ path, text },
            );
    }
    return restart;
}

fn mapProbe(ctx: Ctx, v: Yaml.Value, path: []const u8) !Probe {
    const m = try expectMap(ctx, v, path);
    var target: ?@FieldType(Probe, "target") = null;
    var probe = Probe{ .target = undefined };

    for (m.keys(), m.values()) |key, value| {
        const kp = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, key });
        if (std.mem.eql(u8, key, "exec")) {
            if (target != null) return ctx.fail("{s}: has both \"exec\" and \"http_get\"", .{path});
            target = .{ .exec = try mapExecProbe(ctx, value, kp) };
        } else if (std.mem.eql(u8, key, "http_get")) {
            if (target != null) return ctx.fail("{s}: has both \"exec\" and \"http_get\"", .{path});
            target = .{ .http_get = try mapHttpGet(ctx, value, kp) };
        } else if (std.mem.eql(u8, key, "initial_delay_seconds")) {
            probe.initial_delay_seconds = try expectU32(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "period_seconds")) {
            probe.period_seconds = try expectU32(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "timeout_seconds")) {
            probe.timeout_seconds = try expectU32(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "success_threshold")) {
            probe.success_threshold = try expectU32(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "failure_threshold")) {
            probe.failure_threshold = try expectU32(ctx, value, kp);
        } else {
            return ctx.unsupported(path, key);
        }
    }

    probe.target = target orelse
        return ctx.fail("{s}: needs either \"exec\" or \"http_get\"", .{path});
    if (probe.period_seconds == 0) return ctx.fail("{s}.period_seconds must be at least 1", .{path});
    return probe;
}

fn mapExecProbe(ctx: Ctx, v: Yaml.Value, path: []const u8) ![]const u8 {
    const m = try expectMap(ctx, v, path);
    var command: ?[]const u8 = null;
    for (m.keys(), m.values()) |key, value| {
        if (!std.mem.eql(u8, key, "command")) return ctx.unsupported(path, key);
        command = try expectScalar(ctx, value, path);
    }
    return command orelse ctx.fail("{s}: missing \"command\"", .{path});
}

fn mapHttpGet(ctx: Ctx, v: Yaml.Value, path: []const u8) !HttpGet {
    const m = try expectMap(ctx, v, path);
    var get = HttpGet{ .port = 0 };
    var saw_port = false;
    for (m.keys(), m.values()) |key, value| {
        const kp = try std.fmt.allocPrint(ctx.arena, "{s}.{s}", .{ path, key });
        if (std.mem.eql(u8, key, "host")) {
            get.host = try expectScalar(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "scheme")) {
            get.scheme = try expectScalar(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "path")) {
            get.path = try expectScalar(ctx, value, kp);
        } else if (std.mem.eql(u8, key, "port")) {
            get.port = try expectU16(ctx, value, kp);
            saw_port = true;
        } else {
            return ctx.unsupported(path, key);
        }
    }
    if (!saw_port) return ctx.fail("{s}: missing \"port\"", .{path});
    return get;
}

/// Every dependency must name a Worker that exists. Caught here rather than at
/// startup so a typo fails before anything is spawned.
fn checkDependencies(ctx: Ctx, workers: []const Worker) !void {
    for (workers) |w| {
        for (w.depends_on) |dep| {
            var found = false;
            for (workers) |other| {
                if (std.mem.eql(u8, other.name, dep.name)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                return ctx.fail(
                    "processes.{s}.depends_on: \"{s}\" is not a process in this config",
                    .{ w.name, dep.name },
                );
            }
            if (std.mem.eql(u8, dep.name, w.name)) {
                return ctx.fail("processes.{s} depends on itself", .{w.name});
            }
        }
    }
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

test "parses the athena config shape" {
    const src =
        \\version: "0.5"
        \\shell:
        \\  shell_command: bash
        \\  shell_argument: "-c"
        \\processes:
        \\  wait-postgres:
        \\    description: "wait for Postgres"
        \\    dotenv: [".env"]
        \\    command: "bash scripts/wait-postgres.sh"
        \\    availability:
        \\      restart: "no"
        \\  go:
        \\    description: "Go orchestrator API :8080"
        \\    command: "go run ."
        \\    working_dir: "."
        \\    depends_on:
        \\      wait-postgres:
        \\        condition: process_completed_successfully
        \\    readiness_probe:
        \\      exec:
        \\        command: "exec 3<>/dev/tcp/127.0.0.1/8080"
        \\      initial_delay_seconds: 3
        \\      period_seconds: 3
        \\      timeout_seconds: 2
        \\      failure_threshold: 40
        \\  parser:
        \\    command: "uv run uvicorn app.main:app"
        \\    working_dir: "services/parser-service"
        \\    readiness_probe:
        \\      http_get:
        \\        host: 127.0.0.1
        \\        scheme: http
        \\        path: "/healthz"
        \\        port: 8000
        \\      failure_threshold: 60
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();

    try testing.expectEqualStrings("bash", cfg.shell.command);
    try testing.expectEqualStrings("-c", cfg.shell.argument);
    try testing.expectEqual(@as(usize, 3), cfg.workers.len);

    const gate = cfg.workers[cfg.find("wait-postgres").?];
    try testing.expectEqual(Restart.no, gate.restart);
    try testing.expectEqualStrings(".env", gate.dotenv[0]);

    const go = cfg.workers[cfg.find("go").?];
    try testing.expectEqual(@as(usize, 1), go.depends_on.len);
    try testing.expectEqualStrings("wait-postgres", go.depends_on[0].name);
    try testing.expectEqual(Condition.process_completed_successfully, go.depends_on[0].condition);
    try testing.expectEqualStrings(
        "exec 3<>/dev/tcp/127.0.0.1/8080",
        go.readiness_probe.?.target.exec,
    );
    try testing.expectEqual(@as(u32, 40), go.readiness_probe.?.failure_threshold);
    // Not set in the file, so process-compose's default must apply.
    try testing.expectEqual(@as(u32, 1), go.readiness_probe.?.success_threshold);

    const parser = cfg.workers[cfg.find("parser").?];
    const http = parser.readiness_probe.?.target.http_get;
    try testing.expectEqual(@as(u16, 8000), http.port);
    try testing.expectEqualStrings("/healthz", http.path);
    // Unset timing fields fall back to process-compose's defaults, not zero.
    try testing.expectEqual(@as(u32, 10), parser.readiness_probe.?.period_seconds);
    try testing.expectEqual(@as(u32, 1), parser.readiness_probe.?.timeout_seconds);
    // Omitted availability means "no", which is process-compose's default.
    try testing.expectEqual(Restart.no, parser.restart);
}

test "a comment on the line after a flow sequence is legal" {
    // Pins the local patch in src/vendor/yaml/Parser.zig. athena's config has
    // exactly this shape, so a vendor re-sync that drops the patch fails here
    // rather than at 9am on a Monday.
    const src =
        \\processes:
        \\  gate:
        \\    dotenv: [".env"]
        \\    # Upstream zig-yaml rejects this comment. It is valid YAML.
        \\    command: "bash scripts/wait-postgres.sh"
        \\
    ;
    var cfg = try loadForTest(src, &.{}, null);
    defer cfg.deinit();
    try testing.expectEqualStrings("bash scripts/wait-postgres.sh", cfg.workers[0].command);
    try testing.expectEqualStrings(".env", cfg.workers[0].dotenv[0]);

    // The check the patch narrowed must still catch a genuinely unseparated
    // comment, or the patch has simply deleted a rule instead of fixing it.
    const adjacent =
        \\processes:
        \\  gate:
        \\    dotenv: [".env"]# touching the bracket
        \\    command: "x"
        \\
    ;
    try testing.expectError(error.Invalid, loadForTest(adjacent, &.{}, null));
}

test "expands ${VAR} and $VAR, unset becoming empty" {
    const src =
        \\processes:
        \\  go:
        \\    command: "go run ."
        \\    environment:
        \\      - "PATH=${ROOT}/shims:${PATH}"
        \\      - "HTTPS_PROXY=${TRACE_PROXY}"
        \\      - "BARE=$ROOT"
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
        \\processes:
        \\  go:
        \\    command: "echo ${MISSING:-fallback}"
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "shell parameter expansion") != null);
}

test "rejects an unsupported field rather than ignoring it" {
    const src =
        \\processes:
        \\  go:
        \\    command: "go run ."
        \\    log_location: "/tmp/go.log"
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "log_location") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "processes.go") != null);
}

test "rejects a dependency on a process that does not exist" {
    const src =
        \\processes:
        \\  go:
        \\    command: "go run ."
        \\    depends_on:
        \\      db:
        \\        condition: process_healthy
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "\"db\" is not a process") != null);
}

test "a probe needs exactly one of exec or http_get" {
    const both =
        \\processes:
        \\  go:
        \\    command: "go run ."
        \\    readiness_probe:
        \\      exec:
        \\        command: "true"
        \\      http_get:
        \\        port: 8080
        \\
    ;
    try testing.expectError(error.Invalid, loadForTest(both, &.{}, null));

    const neither =
        \\processes:
        \\  go:
        \\    command: "go run ."
        \\    readiness_probe:
        \\      period_seconds: 5
        \\
    ;
    try testing.expectError(error.Invalid, loadForTest(neither, &.{}, null));
}

test "a missing command is an error, not an empty string" {
    const src =
        \\processes:
        \\  go:
        \\    description: "no command here"
        \\
    ;
    var diag: Diagnostic = .{};
    defer diag.deinit(testing.allocator);
    try testing.expectError(error.Invalid, loadForTest(src, &.{}, &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message.?, "missing \"command\"") != null);
}
