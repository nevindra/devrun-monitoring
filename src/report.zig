//! What a Session is doing, rendered for a reader who is not looking at a TUI.
//!
//! The control socket answers `status` in tab-separated columns (see
//! `control.zig`). That is the wire format and it is deliberately dumb. This
//! file turns it into the two views a reader outside the TUI actually wants:
//!
//! **`devrun status`** — one compact line per Worker, or one JSON object per
//! Worker for something parsing it.
//!
//! **`devrun errors`** — the answer to "did anything break", in one call and
//! bounded output. This is the command that exists because the alternative is
//! a reader spending a few thousand tokens on `status` plus a `logs` call per
//! Worker to find out that the answer was "no".
//!
//! Nothing here talks to a Supervisor. It parses a reply and reads Archives,
//! which is what lets both views work against a Session in another terminal.

const std = @import("std");
const logs = @import("logs.zig");

/// One Worker's row from a `status` reply. Slices point into the caller's
/// reply buffer and do not outlive it.
pub const Row = struct {
    name: []const u8 = "",
    state: []const u8 = "",
    pgid: i64 = 0,
    restarts: u32 = 0,
    bytes: u64 = 0,
    /// `-`, `exit:N`, or `sig:NAME`.
    exit: []const u8 = "-",
    uptime_ms: ?u64 = null,
    /// `none`, `probe`, `pending`, or `met`. Empty from a Session too old to
    /// send it, which `settledEnough` reads as `none`.
    readiness: []const u8 = "",

    /// Whether this Worker is a reason to worry. `pending` is not: it is a
    /// Worker waiting its turn, which is a normal thing to catch mid-startup.
    pub fn broken(self: Row) bool {
        return std.mem.eql(u8, self.state, "failed") or
            std.mem.eql(u8, self.state, "skipped");
    }

    /// Whether the Session has finished with this Worker one way or another.
    pub fn settled(self: Row) bool {
        return std.mem.eql(u8, self.state, "exited") or
            std.mem.eql(u8, self.state, "stopped") or
            self.broken();
    }

    /// `exit 1`, `killed by KILL`, or empty. The wire form is compact; this is
    /// the one a person reads.
    pub fn writeExit(self: Row, out: *std.Io.Writer) !void {
        if (std.mem.startsWith(u8, self.exit, "exit:")) {
            try out.print("exit {s}", .{self.exit[5..]});
        } else if (std.mem.startsWith(u8, self.exit, "sig:")) {
            try out.print("killed by {s}", .{self.exit[4..]});
        }
    }

    pub fn hasExit(self: Row) bool {
        return !std.mem.eql(u8, self.exit, "-") and self.exit.len > 0;
    }

    /// Whether this Worker is as ready as it is ever going to get, which is
    /// what `devrun wait` and `up --detach` block on.
    ///
    /// The subtlety is `running`. A Worker with a readiness probe is not ready
    /// until the probe says so, and returning early there is the whole bug
    /// `wait` exists to prevent. A Worker with nothing to wait for has no
    /// further state to reach, so waiting for `ready` would wait forever.
    /// `readiness` is the column that tells the two apart.
    pub fn settledEnough(self: Row) bool {
        if (std.mem.eql(u8, self.state, "ready")) return true;
        // A Gate that did its job, and a Worker someone stopped on purpose.
        if (std.mem.eql(u8, self.state, "exited")) return true;
        if (std.mem.eql(u8, self.state, "stopped")) return true;
        if (!std.mem.eql(u8, self.state, "running")) return false;

        return std.mem.eql(u8, self.readiness, "none") or
            std.mem.eql(u8, self.readiness, "met") or
            // A Session too old to send the column had no way to express
            // "still coming up" either, so running was all it ever meant.
            self.readiness.len == 0;
    }
};

/// Walks a `status` reply. A malformed row is skipped rather than failing the
/// whole listing: a reader asking what broke should not be told nothing
/// because one column was unreadable.
pub const Rows = struct {
    it: std.mem.SplitIterator(u8, .scalar),

    pub fn init(reply: []const u8) Rows {
        return .{ .it = std.mem.splitScalar(u8, reply, '\n') };
    }

    pub fn next(self: *Rows) ?Row {
        while (self.it.next()) |line| {
            if (line.len == 0) continue;
            var f = std.mem.splitScalar(u8, line, '\t');
            var row: Row = .{};
            row.name = f.next() orelse continue;
            row.state = f.next() orelse continue;
            if (row.name.len == 0 or row.state.len == 0) continue;
            // Everything past the state is optional, so a reply from an older
            // Session still lists its Workers instead of vanishing.
            if (f.next()) |v| row.pgid = std.fmt.parseInt(i64, v, 10) catch 0;
            if (f.next()) |v| row.restarts = std.fmt.parseInt(u32, v, 10) catch 0;
            if (f.next()) |v| row.bytes = std.fmt.parseInt(u64, v, 10) catch 0;
            if (f.next()) |v| row.exit = v;
            if (f.next()) |v| row.uptime_ms = std.fmt.parseInt(u64, v, 10) catch null;
            if (f.next()) |v| row.readiness = v;
            return row;
        }
        return null;
    }
};

/// `2m 14s`, `3h 02m`, `840ms`. Two units at most: the third is never the one
/// that answers the question.
fn writeDuration(out: *std.Io.Writer, ms: u64) !void {
    if (ms < 1000) return out.print("{d}ms", .{ms});
    const s = ms / 1000;
    if (s < 60) return out.print("{d}s", .{s});
    if (s < 3600) return out.print("{d}m {d:0>2}s", .{ s / 60, s % 60 });
    return out.print("{d}h {d:0>2}m", .{ s / 3600, (s % 3600) / 60 });
}

// ------------------------------------------------------------- status

/// One line per Worker, aligned. Everything a `status` row carries that is not
/// worth a column is left out — a pgid nobody asked for is four tokens.
pub fn writeStatus(reply: []const u8, json: bool, out: *std.Io.Writer) !void {
    if (json) return writeStatusJson(reply, out);

    var width: usize = 0;
    var rows = Rows.init(reply);
    var count: usize = 0;
    while (rows.next()) |r| {
        width = @max(width, r.name.len);
        count += 1;
    }
    if (count == 0) {
        try out.writeAll("devrun: the Session has no services.\n");
        return;
    }

    rows = Rows.init(reply);
    while (rows.next()) |r| {
        try out.writeAll(r.name);
        try out.splatByteAll(' ', width - r.name.len + 1);
        try out.writeAll(r.state);
        try out.splatByteAll(' ', "stopping".len - @min(r.state.len, "stopping".len) + 1);

        if (r.uptime_ms) |ms| {
            try writeDuration(out, ms);
        } else if (r.hasExit()) {
            try r.writeExit(out);
        }
        if (r.restarts > 0) try out.print("  {d} restart{s}", .{
            r.restarts,
            if (r.restarts == 1) "" else "s",
        });
        try out.writeByte('\n');
    }
}

fn writeStatusJson(reply: []const u8, out: *std.Io.Writer) !void {
    var rows = Rows.init(reply);
    while (rows.next()) |r| {
        try out.print("{{\"name\":\"{s}\",\"state\":\"{s}\",\"restarts\":{d},\"bytes\":{d}", .{
            r.name,
            r.state,
            r.restarts,
            r.bytes,
        });
        if (r.uptime_ms) |ms| try out.print(",\"uptime_ms\":{d}", .{ms});
        if (r.hasExit()) try out.print(",\"exit\":\"{s}\"", .{r.exit});
        try out.print(",\"broken\":{s}}}\n", .{if (r.broken()) "true" else "false"});
    }
}

// ------------------------------------------------------------- errors

/// Substrings that make a line worth surfacing without being asked. Matched
/// case-insensitively, and deliberately short: this list is a *hint* that
/// something is worth reading, not a classifier. "failed" is left out on
/// purpose — healthy logs are full of "0 failed" and "retry failed, retrying".
pub const error_needles = "error|panic|fatal|exception|traceback|unhandled|refused";

/// How many lines of a broken Worker's Archive to show. Enough for a panic and
/// the first frames under it, which is where the cause almost always is.
pub const tail_lines: usize = 20;

pub const ErrorsOptions = struct {
    /// How far back to sweep healthy Workers for error-shaped lines.
    since_ms: ?u64 = null,
    /// Lines of log to show under each broken Worker.
    tail: usize = tail_lines,
    /// Where the Archives are.
    log_dir: []const u8,
};

/// The `devrun errors` view. Returns true when something is broken, so the
/// caller can exit non-zero and a script can branch on it without parsing.
pub fn writeErrors(
    gpa: std.mem.Allocator,
    reply: []const u8,
    opts: ErrorsOptions,
    out: *std.Io.Writer,
) !bool {
    var total: usize = 0;
    var broken_count: usize = 0;
    var rows = Rows.init(reply);
    while (rows.next()) |r| {
        total += 1;
        if (r.broken()) broken_count += 1;
    }
    if (total == 0) {
        try out.writeAll("devrun: the Session has no services.\n");
        return false;
    }

    // The headline first, because it is the whole answer most of the time and
    // a reader should not have to scan a log tail to find out there wasn't one.
    if (broken_count == 0) {
        try out.print("devrun: all {d} service{s} healthy.\n", .{
            total,
            if (total == 1) " is" else "s are",
        });
    } else {
        try out.print("devrun: {d} of {d} service{s} broken.\n", .{
            broken_count,
            total,
            if (total == 1) "" else "s",
        });
    }

    // Each broken Worker, with the end of its Archive underneath. This is the
    // part worth spending tokens on.
    rows = Rows.init(reply);
    while (rows.next()) |r| {
        if (!r.broken()) continue;
        try out.print("\n{s}  {s}", .{ r.name, r.state });
        if (r.hasExit()) {
            try out.writeAll("  ");
            try r.writeExit(out);
        }
        if (r.restarts > 0) try out.print("  after {d} restart{s}", .{
            r.restarts,
            if (r.restarts == 1) "" else "s",
        });
        try out.writeByte('\n');

        if (r.bytes == 0) {
            try out.writeAll("  (wrote nothing)\n");
            continue;
        }
        const sources = try logs.openSources(gpa, opts.log_dir, &.{r.name});
        defer logs.closeSources(gpa, sources);
        _ = try logs.run(sources, .{
            .tail = opts.tail,
            // A broken Worker's last words are the point, whatever they look
            // like. Filtering them for the word "error" is how you miss the
            // stack frame that named the file.
            .grep = null,
            .indent = "  ",
        }, out);
    }

    // Then a sweep of everyone still standing, for the failure that has not
    // taken a process down yet. Bounded hard: this is a hint, not a log dump.
    const healthy_hits = try sweepHealthy(gpa, reply, opts, out);

    if (broken_count == 0 and healthy_hits == 0) {
        try out.writeAll("devrun: nothing error-shaped in the logs either.\n");
    }
    return broken_count > 0;
}

fn sweepHealthy(
    gpa: std.mem.Allocator,
    reply: []const u8,
    opts: ErrorsOptions,
    out: *std.Io.Writer,
) !usize {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);

    var rows = Rows.init(reply);
    while (rows.next()) |r| {
        if (r.broken() or r.bytes == 0) continue;
        try names.append(gpa, r.name);
    }
    if (names.items.len == 0) return 0;

    const sources = try logs.openSources(gpa, opts.log_dir, names.items);
    defer logs.closeSources(gpa, sources);

    // Counted first so the heading can say how many there are before printing
    // any of them, and so a clean sweep prints no heading at all.
    var sink: std.Io.Writer.Discarding = .init(&.{});
    const found = try logs.run(sources, .{
        .since_ms = opts.since_ms,
        .grep = error_needles,
        .ignore_case = true,
        .tail = null,
    }, &sink.writer);
    if (found.emitted == 0) return 0;

    try out.print("\ndevrun: {d} error-shaped line{s} from services that are still up.\n", .{
        found.emitted,
        if (found.emitted == 1) "" else "s",
    });
    _ = try logs.run(sources, .{
        .since_ms = opts.since_ms,
        .grep = error_needles,
        .ignore_case = true,
        .tail = opts.tail,
        .indent = "  ",
    }, out);
    return found.emitted;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

const sample_reply =
    "api\tready\t1234\t0\t4096\t-\t134000\tprobe\n" ++
    "db\trunning\t1235\t0\t512\t-\t133000\tnone\n" ++
    "migrate\texited\t0\t0\t64\texit:0\t-\tnone\n" ++
    "worker\tfailed\t0\t3\t900\texit:1\t-\tnone\n";

test "settledEnough tells a Worker that is up from one still coming up" {
    // Both are `running`. Only the readiness column separates them, which is
    // why it exists: `wait` must not return while a probe is still failing,
    // and must not hang forever on a Worker that has no probe to pass.
    const waiting: Row = .{ .state = "running", .readiness = "probe" };
    const arrived: Row = .{ .state = "running", .readiness = "none" };
    try testing.expect(!waiting.settledEnough());
    try testing.expect(arrived.settledEnough());

    // A `ready_log_line` is not satisfied until the line shows up. This is the
    // case `devrun run --ready-log` depends on entirely.
    const looking: Row = .{ .state = "running", .readiness = "pending" };
    const seen: Row = .{ .state = "running", .readiness = "met" };
    try testing.expect(!looking.settledEnough());
    try testing.expect(seen.settledEnough());

    // A probe that passed shows up as the state, not the column.
    try testing.expect((Row{ .state = "ready", .readiness = "probe" }).settledEnough());
    // A Gate that ran, and a Worker someone stopped, are both done.
    try testing.expect((Row{ .state = "exited" }).settledEnough());
    try testing.expect((Row{ .state = "stopped" }).settledEnough());
    // Not yet started is not settled.
    try testing.expect(!(Row{ .state = "pending", .readiness = "none" }).settledEnough());
    try testing.expect(!(Row{ .state = "stopping", .readiness = "none" }).settledEnough());

    // A reply from a Session too old to send the column had no way to say
    // "still coming up" either, so running was all it ever meant.
    var old = Rows.init("api\trunning\t1\t0\t10\n");
    try testing.expect(old.next().?.settledEnough());
}

test "a status reply parses into rows, and a short row still lists" {
    var rows = Rows.init(sample_reply);

    const api = rows.next().?;
    try testing.expectEqualStrings("api", api.name);
    try testing.expectEqualStrings("ready", api.state);
    try testing.expectEqual(@as(?u64, 134_000), api.uptime_ms);
    try testing.expect(!api.broken());
    try testing.expect(!api.hasExit());

    _ = rows.next();
    const migrate = rows.next().?;
    try testing.expect(migrate.settled());
    try testing.expect(!migrate.broken());

    const worker = rows.next().?;
    try testing.expect(worker.broken());
    try testing.expectEqual(@as(u32, 3), worker.restarts);
    try testing.expect(worker.uptime_ms == null);
    try testing.expect(rows.next() == null);

    // A Session speaking the older five-column format still enumerates. The
    // columns it does not send are absent, not wrong.
    var old = Rows.init("api\tready\t1\t0\t10\n");
    const r = old.next().?;
    try testing.expectEqualStrings("api", r.name);
    try testing.expect(!r.hasExit());
    try testing.expect(r.uptime_ms == null);
}

test "status renders one aligned line per Worker" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStatus(sample_reply, false, &w);

    try testing.expectEqualStrings(
        \\api     ready    2m 14s
        \\db      running  2m 13s
        \\migrate exited   exit 0
        \\worker  failed   exit 1  3 restarts
        \\
    , w.buffered());
}

test "status --json is one object per line, with a broken flag to branch on" {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeStatus(sample_reply, true, &w);

    try testing.expectEqualStrings(
        \\{"name":"api","state":"ready","restarts":0,"bytes":4096,"uptime_ms":134000,"broken":false}
        \\{"name":"db","state":"running","restarts":0,"bytes":512,"uptime_ms":133000,"broken":false}
        \\{"name":"migrate","state":"exited","restarts":0,"bytes":64,"exit":"exit:0","broken":false}
        \\{"name":"worker","state":"failed","restarts":3,"bytes":900,"exit":"exit:1","broken":true}
        \\
    , w.buffered());
}

test "duration reads in the two units that answer the question" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    try writeDuration(&w, 840);
    try testing.expectEqualStrings("840ms", w.buffered());

    w = .fixed(&buf);
    try writeDuration(&w, 45_000);
    try testing.expectEqualStrings("45s", w.buffered());

    w = .fixed(&buf);
    try writeDuration(&w, 134_000);
    try testing.expectEqualStrings("2m 14s", w.buffered());

    w = .fixed(&buf);
    try writeDuration(&w, 3 * 3600 * 1000 + 120_000);
    try testing.expectEqualStrings("3h 02m", w.buffered());
}

test "errors leads with the headline and says so when nothing is wrong" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    // No Archives on disk at this path, so every Worker contributes nothing to
    // read. The headline is still the answer.
    const healthy = "api\tready\t1\t0\t0\t-\t1000\ndb\tready\t2\t0\t0\t-\t1000\n";
    const any = try writeErrors(testing.allocator, healthy, .{
        .log_dir = "/tmp/devrun-no-such-dir",
    }, &w);

    try testing.expect(!any);
    try testing.expectEqualStrings(
        "devrun: all 2 services are healthy.\n" ++
            "devrun: nothing error-shaped in the logs either.\n",
        w.buffered(),
    );
}

test "errors names what broke, its exit, and that it wrote nothing" {
    var buf: [4096]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    const broken = "api\tready\t1\t0\t0\t-\t1000\nworker\tfailed\t0\t3\t0\texit:1\t-\n";
    const any = try writeErrors(testing.allocator, broken, .{
        .log_dir = "/tmp/devrun-no-such-dir",
    }, &w);

    try testing.expect(any);
    try testing.expectEqualStrings(
        "devrun: 1 of 2 services broken.\n" ++
            "\nworker  failed  exit 1  after 3 restarts\n" ++
            "  (wrote nothing)\n",
        w.buffered(),
    );
}
