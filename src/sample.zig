//! Per-Group CPU, memory, and disk I/O.
//!
//! A Sample is one reading of a Group at one instant, taken on a timer and
//! never per frame. The unit is the Group, not the pid devrun spawned: a
//! Worker that is `npm run dev` is a shell, a node, and four workers, and the
//! number a reader wants is all of them.
//!
//! ## Why per-pid, and why an accumulator
//!
//! `docs/adr/0004-portability-posture.md` settled this. cgroup v2 could give
//! CPU and memory directly, but its `io` controller is not delegated to user
//! sessions, so disk I/O has to be summed from `/proc/<pid>/io` regardless.
//! Once that per-pid path exists it is also the path macOS needs, so CPU goes
//! through it too rather than maintaining two.
//!
//! Summing live pids alone is wrong, and wrong in a way that looks like a bug
//! in the program being watched: `/proc/<pid>` counters are cumulative and
//! vanish with the pid. A Worker that forks a compiler every second would show
//! its totals lurching backwards and its rates going negative. So a pid's last
//! reading is retired into the Group's running total when it disappears, and
//! the Group's cumulative counter only ever increases.
//!
//! One scan serves every Worker. `/proc` is read once per tick, not once per
//! Worker — that is the difference between one pass and N passes over a few
//! hundred directories.

const std = @import("std");
const os = @import("os.zig");

const Allocator = std.mem.Allocator;
const Pid = os.Pid;

/// `/proc` reports CPU in USER_HZ, which is 100 on Linux regardless of the
/// kernel's own tick rate. It is part of the ABI, not a build option.
const user_hz = 100;

/// What a reader sees. Rates are already differentiated; totals are not, so a
/// caller can render either without keeping state of its own.
pub const Sample = struct {
    /// Percent of one core. A Group using two cores fully reads 200.
    cpu_percent: f32 = 0,
    /// Summed RSS across the Group.
    ///
    /// RSS rather than PSS: PSS means reading `smaps_rollup`, which makes the
    /// kernel walk the page tables of every process on every tick. For a
    /// Worker that forked eight children that is a measurable cost imposed on
    /// the thing being measured, to refine a number nobody acts on.
    memory_bytes: u64 = 0,
    /// Bytes actually fetched from and sent to the block layer, cumulative
    /// across the Session — including pids that have already exited.
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
    /// How many OS processes the Group currently contains.
    processes: u32 = 0,
};

/// A Group's cumulative counters. Monotonic by construction.
const Totals = struct {
    cpu_ticks: u64 = 0,
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
};

/// What one pid contributed at its last reading, kept so that the contribution
/// survives the pid.
const PidState = struct {
    group: u32,
    seen_tick: u64,
    counters: Totals,
};

pub const Sampler = struct {
    gpa: Allocator,
    /// Cumulative per Group, including retired pids.
    totals: []Totals,
    /// The previous tick's cumulative values, for differentiating.
    previous: []Totals,
    live: std.AutoHashMapUnmanaged(Pid, PidState) = .empty,
    tick: u64 = 0,
    last_ms: u64 = 0,

    pub fn init(gpa: Allocator, groups: usize) !Sampler {
        const totals = try gpa.alloc(Totals, groups);
        @memset(totals, .{});
        const previous = try gpa.alloc(Totals, groups);
        @memset(previous, .{});
        return .{ .gpa = gpa, .totals = totals, .previous = previous };
    }

    pub fn deinit(self: *Sampler) void {
        self.gpa.free(self.totals);
        self.gpa.free(self.previous);
        self.live.deinit(self.gpa);
    }

    /// Reads every Group in one pass over `/proc` and writes the results into
    /// `out`. `pgids[i]` is Group `i`'s process group id, or 0 when that
    /// Worker is not running.
    pub fn sample(self: *Sampler, pgids: []const Pid, out: []Sample) void {
        std.debug.assert(pgids.len == out.len);
        const now = os.nowMs();
        self.tick += 1;

        var live_mem: []u64 = undefined;
        var mem_buf: [64]u64 = undefined;
        var mem_heap: ?[]u64 = null;
        if (pgids.len <= mem_buf.len) {
            live_mem = mem_buf[0..pgids.len];
        } else {
            mem_heap = self.gpa.alloc(u64, pgids.len) catch return;
            live_mem = mem_heap.?;
        }
        defer if (mem_heap) |h| self.gpa.free(h);
        @memset(live_mem, 0);

        var counts: [64]u32 = undefined;
        var count_heap: ?[]u32 = null;
        var live_count: []u32 = undefined;
        if (pgids.len <= counts.len) {
            live_count = counts[0..pgids.len];
        } else {
            count_heap = self.gpa.alloc(u32, pgids.len) catch return;
            live_count = count_heap.?;
        }
        defer if (count_heap) |h| self.gpa.free(h);
        @memset(live_count, 0);

        self.scanProc(pgids, live_mem, live_count);
        self.retireDeadPids();

        // Elapsed time drives the rate. Using the actual interval rather than
        // the nominal one keeps CPU honest when a tick runs late.
        const elapsed_ms = now -| self.last_ms;
        const first = self.last_ms == 0;
        self.last_ms = now;

        for (out, 0..) |*o, i| {
            const total = self.totals[i];
            const prev = self.previous[i];
            o.* = .{
                .memory_bytes = live_mem[i],
                .processes = live_count[i],
                .read_bytes = total.read_bytes,
                .write_bytes = total.write_bytes,
                .cpu_percent = if (first or elapsed_ms == 0) 0 else cpuPercent(
                    total.cpu_ticks -| prev.cpu_ticks,
                    elapsed_ms,
                ),
            };
            self.previous[i] = total;
        }
    }

    /// One pass over `/proc`, attributing each process to a Group by its pgid.
    fn scanProc(self: *Sampler, pgids: []const Pid, live_mem: []u64, live_count: []u32) void {
        var dir = os.DirIter.open("/proc") catch return;
        defer dir.close();

        while (dir.next()) |entry| {
            const pid = std.fmt.parseInt(Pid, entry, 10) catch continue;

            const stat: ProcStat = readStat(pid) orelse continue;
            const group = indexOfPgid(pgids, stat.pgid) orelse continue;

            live_mem[group] += stat.rss_pages * std.heap.pageSize();
            live_count[group] += 1;

            const io = readIo(pid);
            const counters = Totals{
                .cpu_ticks = stat.utime + stat.stime,
                .read_bytes = io.read,
                .write_bytes = io.write,
            };

            const gop = self.live.getOrPut(self.gpa, pid) catch return;
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .group = @intCast(group),
                    .seen_tick = self.tick,
                    .counters = .{},
                };
            }
            const st = gop.value_ptr;

            // A pid is only ever compared against itself, so the delta cannot
            // be polluted by a different process reusing the number: a reused
            // pid arrives as `!found_existing` with a zeroed baseline.
            self.totals[group].cpu_ticks += counters.cpu_ticks -| st.counters.cpu_ticks;
            self.totals[group].read_bytes += counters.read_bytes -| st.counters.read_bytes;
            self.totals[group].write_bytes += counters.write_bytes -| st.counters.write_bytes;

            st.counters = counters;
            st.seen_tick = self.tick;
            st.group = @intCast(group);
        }
    }

    /// Drops pids that were not seen this tick. Their contribution already
    /// lives in `totals`, which is the entire point of accumulating there
    /// rather than re-summing the live set each time.
    fn retireDeadPids(self: *Sampler) void {
        var it = self.live.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.seen_tick == self.tick) continue;
            // `removeByPtr` keeps the iterator valid in Zig's hash map.
            const key = e.key_ptr.*;
            _ = self.live.remove(key);
            it = self.live.iterator();
        }
    }
};

fn cpuPercent(ticks: u64, elapsed_ms: u64) f32 {
    const cpu_ms = ticks * (1000 / user_hz);
    return @as(f32, @floatFromInt(cpu_ms)) * 100.0 / @as(f32, @floatFromInt(elapsed_ms));
}

fn indexOfPgid(pgids: []const Pid, pgid: Pid) ?usize {
    if (pgid == 0) return null;
    for (pgids, 0..) |p, i| {
        if (p != 0 and p == pgid) return i;
    }
    return null;
}

const ProcStat = struct {
    pgid: Pid,
    utime: u64,
    stime: u64,
    rss_pages: u64,
};

/// Parses `/proc/<pid>/stat`.
///
/// The command name is field 2 and may contain spaces *and* parentheses, so
/// the only safe place to start is the last `)` in the line. Splitting on
/// whitespace from the left is the classic way to get this wrong, and it
/// misreads exactly the processes a dev tool sees — `node (worker)`, say.
fn readStat(pid: Pid) ?ProcStat {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch return null;
    var buf: [1024]u8 = undefined;
    const text = readSmallFile(p, &buf) orelse return null;

    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close + 2 >= text.len) return null;

    var it = std.mem.tokenizeScalar(u8, text[close + 2 ..], ' ');
    var field: usize = 0;
    var out = ProcStat{ .pgid = 0, .utime = 0, .stime = 0, .rss_pages = 0 };
    while (it.next()) |tok| : (field += 1) {
        switch (field) {
            // Token 0 is `state`, which procfs calls field 3 — so token N is
            // field N+3. pgrp is 5, utime 14, stime 15, rss 24. The next field
            // after rss is rsslim, which is usually 2^64-1: reading one field
            // late here does not look like a small error, it overflows.
            2 => out.pgid = std.fmt.parseInt(Pid, tok, 10) catch return null,
            11 => out.utime = std.fmt.parseInt(u64, tok, 10) catch 0,
            12 => out.stime = std.fmt.parseInt(u64, tok, 10) catch 0,
            21 => {
                out.rss_pages = std.fmt.parseInt(u64, tok, 10) catch 0;
                return out;
            },
            else => {},
        }
    }
    return out;
}

const Io = struct { read: u64 = 0, write: u64 = 0 };

/// `read_bytes` / `write_bytes` from `/proc/<pid>/io` — what actually reached
/// the block layer, rather than what the process asked for. Absent or
/// unreadable is not an error: a kernel without `CONFIG_TASK_IO_ACCOUNTING`
/// reports zero, and zero I/O is a better answer than no Sample at all.
fn readIo(pid: Pid) Io {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{d}/io", .{pid}) catch return .{};
    var buf: [512]u8 = undefined;
    const text = readSmallFile(p, &buf) orelse return .{};

    var out = Io{};
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "read_bytes:")) {
            out.read = parseTrailingInt(line) orelse 0;
        } else if (std.mem.startsWith(u8, line, "write_bytes:")) {
            out.write = parseTrailingInt(line) orelse 0;
        }
    }
    return out;
}

fn parseTrailingInt(line: []const u8) ?u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    return std.fmt.parseInt(u64, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch null;
}

/// `/proc` files report a size of zero, so they have to be read rather than
/// stat'd. One `read` is always enough for these.
fn readSmallFile(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = os.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer os.close(fd);
    const n = os.read(fd, buf) catch return null;
    return buf[0..n];
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "readStat survives a command name containing spaces and parentheses" {
    // Our own pid is the one process guaranteed to exist while this runs.
    const me = os.linux.getpid();
    const stat = readStat(me) orelse return error.NoStat;
    // A test binary is its own process group leader or a child of the runner;
    // either way procfs must give a plausible pgid and some resident memory.
    try testing.expect(stat.pgid > 0);
    try testing.expect(stat.rss_pages > 0);
}

test "cpuPercent turns ticks into percent of one core" {
    // 100 ticks is one full second of CPU; over one second that is one core.
    try testing.expectApproxEqAbs(@as(f32, 100.0), cpuPercent(100, 1000), 0.01);
    // Two cores' worth in the same wall-clock second.
    try testing.expectApproxEqAbs(@as(f32, 200.0), cpuPercent(200, 1000), 0.01);
    // Idle.
    try testing.expectApproxEqAbs(@as(f32, 0.0), cpuPercent(0, 1000), 0.01);
    // Half a core over two seconds.
    try testing.expectApproxEqAbs(@as(f32, 50.0), cpuPercent(100, 2000), 0.01);
}

test "parseTrailingInt reads a procfs key: value line" {
    try testing.expectEqual(@as(u64, 4096), parseTrailingInt("read_bytes: 4096").?);
    try testing.expectEqual(@as(u64, 0), parseTrailingInt("write_bytes:    0").?);
    try testing.expect(parseTrailingInt("no colon here") == null);
}

test "a Group's totals never go backwards when a pid exits" {
    var s = try Sampler.init(testing.allocator, 2);
    defer s.deinit();

    // Two pids in Group 0, one of which has already done some work.
    s.tick = 1;
    try s.live.put(testing.allocator, 101, .{
        .group = 0,
        .seen_tick = 1,
        .counters = .{ .cpu_ticks = 50, .read_bytes = 4096, .write_bytes = 0 },
    });
    s.totals[0] = .{ .cpu_ticks = 50, .read_bytes = 4096 };

    // Next tick, pid 101 is gone. Retiring it must leave the total alone —
    // its work already happened and is already counted.
    s.tick = 2;
    s.retireDeadPids();

    try testing.expectEqual(@as(usize, 0), s.live.count());
    try testing.expectEqual(@as(u64, 50), s.totals[0].cpu_ticks);
    try testing.expectEqual(@as(u64, 4096), s.totals[0].read_bytes);
    // And the untouched Group stays at zero.
    try testing.expectEqual(@as(u64, 0), s.totals[1].cpu_ticks);
}

test "indexOfPgid ignores Workers that are not running" {
    const pgids = [_]Pid{ 0, 4242, 0, 99 };
    try testing.expectEqual(@as(usize, 1), indexOfPgid(&pgids, 4242).?);
    try testing.expectEqual(@as(usize, 3), indexOfPgid(&pgids, 99).?);
    // A stopped Worker's zero must never match a real process group.
    try testing.expect(indexOfPgid(&pgids, 0) == null);
    try testing.expect(indexOfPgid(&pgids, 7) == null);
}

test "sampling a live Group sees this process" {
    var s = try Sampler.init(testing.allocator, 1);
    defer s.deinit();

    // The test process's own group is guaranteed to have at least one member.
    const stat = readStat(os.linux.getpid()) orelse return error.NoStat;
    const pgids = [_]Pid{stat.pgid};
    var out: [1]Sample = undefined;

    s.sample(&pgids, &out);
    try testing.expect(out[0].processes >= 1);
    try testing.expect(out[0].memory_bytes > 0);
    // The first Sample has no interval to differentiate against, so its rate
    // is zero rather than a number divided by zero elapsed time.
    try testing.expectEqual(@as(f32, 0), out[0].cpu_percent);
}
