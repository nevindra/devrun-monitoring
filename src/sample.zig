//! Per-Group CPU, memory, and disk I/O.
//!
//! A Sample is one reading of a Group at one instant, taken on a timer and
//! never per frame. The unit is the Group, not the pid devrun spawned: a
//! Worker that is `npm run dev` is a shell, a node, and four workers, and the
//! number a reader wants is all of them.
//!
//! ## Why per-pid
//!
//! `docs/adr/0004-portability-posture.md` settled this. cgroup v2 could give
//! CPU and memory directly, but its `io` controller is not delegated to user
//! sessions, so disk I/O has to be summed from `/proc/<pid>/io` regardless.
//! Once that per-pid path exists it is also the path macOS needs, so CPU goes
//! through it too rather than maintaining two.
//!
//! ## Why CPU counts the dead, and how
//!
//! `/proc/<pid>` counters vanish with the pid, and a tick is a snapshot. A
//! Worker that forks a compiler per file — `make`, `tsc`, a test runner — has
//! most of its children born and buried between two ticks, so a sampler that
//! reads only what is alive reports a Worker pinning a core as idle. That is
//! not a rounding error; it is the reading being wrong about the thing a
//! reader most wants to know.
//!
//! The kernel already keeps the answer. `cutime` and `cstime` are the CPU of
//! children a process has *reaped*, and they are recursive: burying a child
//! folds in that child's own `cutime` too. So a live process carries the whole
//! history of its dead descendants.
//!
//! That gives a rule with no bookkeeping in it. **A live pid is in nobody's
//! `cutime`** — only reaped children are — so
//!
//!     Group CPU = Σ over live pids of (utime + stime + cutime + cstime)
//!
//! counts every tick exactly once, and needs no accumulator to survive a pid
//! disappearing. It is also race-free across a reap, which is the part that
//! makes it worth preferring to sampling faster: catch the child as a zombie
//! and its own `utime` is still there to read; catch it after the reap and the
//! same ticks are in its parent's `cutime`. There is no instant at which they
//! are in both, and none at which they are in neither.
//!
//! Two things this does not reach. A Group whose leader dies while a
//! descendant survives loses the leader's `cutime` — the orphan reparents to
//! devrun, and devrun's own `cutime` is not attributed to any Worker — so the
//! Group's cumulative figure can step down as it tears down. The rate is
//! computed with a saturating subtraction, so that reads as one tick of 0%
//! rather than as a negative. And disk I/O has no `cutime` of its own, so it
//! still needs the accumulator below and still cannot see a pid it never met.
//!
//! ## Why the walk is our own subtree
//!
//! One scan serves every Worker, and it visits our descendants rather than
//! every process on the machine. Reading all of `/proc` to find the dozen pids
//! that are ours meant an open, a read and a close of `/proc/<pid>/stat` for
//! several hundred unrelated processes every second — 97% of every syscall
//! devrun made while idle, and a cost that grew with how busy the *machine*
//! was rather than with how much devrun was supervising.
//!
//! Our own subtree is complete by construction: each Worker is a Group we
//! forked, and `becomeSubreaper` keeps a daemonising Worker's orphans on our
//! branch instead of letting them reparent to PID 1. A kernel without
//! `CONFIG_PROC_CHILDREN` cannot be walked that way, so the full scan stays as
//! the fallback.

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
    /// Summed PSS across the Group — what the machine actually gave it.
    ///
    /// PSS rather than RSS, because this is a *sum*. RSS counts a shared page
    /// once in every process mapping it, so a Worker that forks — and every
    /// page a parent and child still share is one page — reports a total far
    /// above what it holds. Measured against a real Session: a Python service
    /// summed to 1.9 GB of RSS and 1.6 GB of PSS. PSS divides each page by the
    /// number of processes mapping it, which is precisely the property a total
    /// over several processes needs.
    ///
    /// It is not free — see `readPss` for what it costs and how that cost is
    /// kept off the tick.
    memory_bytes: u64 = 0,
    /// Bytes actually fetched from and sent to the block layer, cumulative
    /// across the Session — including pids that have already exited.
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
    /// How many OS processes the Group currently contains.
    processes: u32 = 0,
};

/// A Group's cumulative figures.
const Totals = struct {
    /// Assigned from the live set each tick rather than accumulated — see the
    /// module header. Falls back to zero while a Group is not running, which
    /// is why the rate is taken with a saturating subtraction.
    cpu_ticks: u64 = 0,
    /// Accumulated, because `/proc/<pid>/io` has no `cutime` to carry the
    /// bytes of a pid that has already gone.
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
};

/// What one pid's I/O counters read when it was last seen, kept so that its
/// contribution survives the pid.
const PidState = struct {
    group: u32,
    seen_tick: u64,
    io: Io,
    /// This tick's RSS. Cheap, read every tick, and what the Group's total
    /// falls back to for a pid whose PSS has not been measured yet.
    rss_bytes: u64 = 0,
    /// The last PSS reading, and the tick it was taken on. A `pss_tick` of
    /// zero means never measured, which sorts it to the front of the queue.
    pss_bytes: u64 = 0,
    pss_tick: u64 = 0,
    /// `comm`, so a reader can be told *which* processes hold the memory
    /// without a second pass over `/proc` at render time.
    comm: [comm_max]u8 = @splat(0),
    comm_len: u8 = 0,

    /// The figure this pid contributes to its Group's total.
    fn memory(self: PidState) u64 {
        return if (self.pss_tick == 0) self.rss_bytes else self.pss_bytes;
    }
};

/// `TASK_COMM_LEN - 1`. A longer name is the kernel's to truncate, not ours.
const comm_max = 15;

/// One process inside a Group, for the breakdown a reader can ask for.
pub const ProcInfo = struct {
    pid: Pid = 0,
    memory_bytes: u64 = 0,
    comm: [comm_max]u8 = @splat(0),
    comm_len: u8 = 0,

    pub fn name(self: *const ProcInfo) []const u8 {
        return self.comm[0..self.comm_len];
    }
};

/// What this tick found alive. Sized once at init — the number of Groups is
/// fixed for the Session, so a tick allocates nothing and cannot fail
/// halfway through a walk for want of scratch space.
const Current = struct {
    memory_bytes: u64 = 0,
    cpu_ticks: u64 = 0,
    processes: u32 = 0,
};

/// Stops a pathological tree — or a `children` file that somehow cycles — from
/// turning one tick into an unbounded walk.
const max_visited = 4096;

pub const Sampler = struct {
    gpa: Allocator,
    /// Cumulative per Group.
    totals: []Totals,
    /// The previous tick's cumulative CPU, and nothing else: it is the only
    /// figure reported as a rate, so it is the only one that needs a baseline
    /// to differentiate against.
    previous_cpu: []u64,
    /// This tick's live findings, refilled from scratch every time.
    current: []Current,
    live: std.AutoHashMapUnmanaged(Pid, PidState) = .empty,
    tick: u64 = 0,
    last_ms: u64 = 0,

    /// Work list for the descendant walk, and the pids to retire after one.
    /// Both are kept across ticks so a steady-state tick allocates nothing.
    frontier: std.ArrayListUnmanaged(Pid) = .empty,
    doomed: std.ArrayListUnmanaged(Pid) = .empty,
    /// Whether this kernel exposes `/proc/<pid>/task/<tid>/children`. When it
    /// does, a tick visits our own descendants — a handful of processes —
    /// instead of every process on the machine.
    walk_children: bool,

    pub fn init(gpa: Allocator, groups: usize) !Sampler {
        const totals = try gpa.alloc(Totals, groups);
        @memset(totals, .{});
        errdefer gpa.free(totals);
        const previous_cpu = try gpa.alloc(u64, groups);
        @memset(previous_cpu, 0);
        errdefer gpa.free(previous_cpu);
        const current = try gpa.alloc(Current, groups);
        @memset(current, .{});
        return .{
            .gpa = gpa,
            .totals = totals,
            .previous_cpu = previous_cpu,
            .current = current,
            .walk_children = childrenSupported(),
        };
    }

    pub fn deinit(self: *Sampler) void {
        self.gpa.free(self.totals);
        self.gpa.free(self.previous_cpu);
        self.gpa.free(self.current);
        self.live.deinit(self.gpa);
        self.frontier.deinit(self.gpa);
        self.doomed.deinit(self.gpa);
    }

    /// Reads every Group in one pass over `/proc` and writes the results into
    /// `out`. `pgids[i]` is Group `i`'s process group id, or 0 when that
    /// Worker is not running.
    pub fn sample(self: *Sampler, pgids: []const Pid, out: []Sample) void {
        std.debug.assert(pgids.len == out.len);
        std.debug.assert(pgids.len == self.current.len);
        const now = os.nowMs();
        self.tick += 1;
        @memset(self.current, .{});

        if (self.walk_children) {
            self.scanDescendants(pgids);
        } else {
            self.scanProc(pgids);
        }
        self.retireDeadPids();
        self.foldMemory();

        // Elapsed time drives the rate. Using the actual interval rather than
        // the nominal one keeps CPU honest when a tick runs late.
        const elapsed_ms = now -| self.last_ms;
        const first = self.last_ms == 0;
        self.last_ms = now;

        for (out, 0..) |*o, i| {
            // Assigned, not accumulated: the live set's `cutime` already
            // carries every pid this Group has buried, so adding a delta on
            // top would count a reaped child once as itself and again as its
            // parent's inheritance.
            self.totals[i].cpu_ticks = self.current[i].cpu_ticks;
            const total = self.totals[i];
            o.* = .{
                .memory_bytes = self.current[i].memory_bytes,
                .processes = self.current[i].processes,
                .read_bytes = total.read_bytes,
                .write_bytes = total.write_bytes,
                // Saturating: a Group that restarts, or that loses the leader
                // holding its `cutime`, steps its cumulative figure down. One
                // tick reading 0% is the honest answer there; a negative rate
                // is not an answer at all.
                .cpu_percent = if (first or elapsed_ms == 0) 0 else cpuPercent(
                    total.cpu_ticks -| self.previous_cpu[i],
                    elapsed_ms,
                ),
            };
            self.previous_cpu[i] = total.cpu_ticks;
        }
    }

    /// Our own process tree, walked breadth-first from this pid.
    ///
    /// This is the whole reason a tick is cheap. Everything a Group contains
    /// is a descendant of devrun — we spawn each Worker ourselves, and
    /// `becomeSubreaper` means even a daemonising Worker's orphans come back
    /// to us rather than escaping to PID 1 — so reading our own subtree finds
    /// exactly the same processes that reading all of `/proc` would, having
    /// looked at a dozen of them instead of several hundred.
    ///
    /// A `children` file can miss a pid that forks while it is being read.
    /// That is self-correcting and already handled: an unseen pid is retired
    /// with its last reading intact, which is what happens when one genuinely
    /// exits, and the next tick picks it up again if it is still alive.
    fn scanDescendants(self: *Sampler, pgids: []const Pid) void {
        self.frontier.clearRetainingCapacity();
        self.frontier.append(self.gpa, os.linux.getpid()) catch return;

        var i: usize = 0;
        while (i < self.frontier.items.len and i < max_visited) : (i += 1) {
            const pid = self.frontier.items[i];
            self.pushChildren(pid);
            // devrun itself is slot zero. It is accounted like any other pid
            // rather than special-cased out: its pgid cannot match a Worker's
            // — a Worker's Group id is the pid of a process we forked, which
            // is never our own — so this walk and the `/proc` fallback reach
            // the same answer, and neither has a case the other lacks.
            self.account(pid, pgids);
        }
    }

    /// Appends `pid`'s children to the frontier. Every thread is asked, not
    /// just the main one: a `children` file lists what *that thread* forked,
    /// so a runtime that spawns from a worker thread would otherwise have its
    /// children go unseen.
    fn pushChildren(self: *Sampler, pid: Pid) void {
        var path: [64]u8 = undefined;
        const tasks_path = std.fmt.bufPrintZ(&path, "/proc/{d}/task", .{pid}) catch return;
        var tasks = os.DirIter.open(tasks_path) catch return;
        defer tasks.close();

        while (tasks.next()) |entry| {
            const tid = std.fmt.parseInt(Pid, entry, 10) catch continue;
            var child_path: [80]u8 = undefined;
            const p = std.fmt.bufPrintZ(
                &child_path,
                "/proc/{d}/task/{d}/children",
                .{ pid, tid },
            ) catch continue;

            var buf: [4096]u8 = undefined;
            const text = readSmallFile(p, &buf) orelse continue;
            var it = std.mem.tokenizeAny(u8, text, " \t\n");
            while (it.next()) |tok| {
                const child = std.fmt.parseInt(Pid, tok, 10) catch continue;
                if (self.frontier.items.len >= max_visited) return;
                self.frontier.append(self.gpa, child) catch return;
            }
        }
    }

    /// One pass over all of `/proc`. The fallback for a kernel built without
    /// `CONFIG_PROC_CHILDREN`, where the subtree is not discoverable and
    /// matching every process by pgid is the only way to find a Group.
    fn scanProc(self: *Sampler, pgids: []const Pid) void {
        var dir = os.DirIter.open("/proc") catch return;
        defer dir.close();

        while (dir.next()) |entry| {
            const pid = std.fmt.parseInt(Pid, entry, 10) catch continue;
            self.account(pid, pgids);
        }
    }

    /// Folds one process into its Group's numbers, if it is in one.
    fn account(self: *Sampler, pid: Pid, pgids: []const Pid) void {
        const stat: ProcStat = readStat(pid) orelse return;
        const group = indexOfPgid(pgids, stat.pgid) orelse return;

        const gop = self.live.getOrPut(self.gpa, pid) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .{
                .group = @intCast(group),
                .seen_tick = self.tick,
                .io = .{},
            };
        } else if (gop.value_ptr.seen_tick == self.tick) {
            // Already folded in on this tick. A walk should not offer the same
            // pid twice, but CPU is a sum over the live set rather than a
            // delta against a previous reading, so a duplicate would double a
            // Group's figure instead of contributing nothing to it.
            return;
        }
        const st = gop.value_ptr;

        const c = &self.current[group];
        c.processes += 1;
        c.cpu_ticks += stat.cpuTicks();

        // Memory is not folded in here: the Group's total is summed in
        // `foldMemory`, after the PSS rotation has had its turn, so that a pid
        // measured this tick contributes its PSS rather than last tick's.
        st.rss_bytes = stat.rss_pages * std.heap.pageSize();
        st.comm = stat.comm;
        st.comm_len = stat.comm_len;

        // Disk I/O gets the accumulator CPU no longer needs: there is no
        // `cutime` for bytes, so a pid's growth has to be banked as it is
        // observed and left behind in `totals` when the pid goes.
        //
        // A pid is only ever compared against itself, so the delta cannot be
        // polluted by a different process reusing the number: a reused pid
        // arrives as `!found_existing` with a zeroed baseline.
        const io = readIo(pid);
        self.totals[group].read_bytes += io.read -| st.io.read;
        self.totals[group].write_bytes += io.write -| st.io.write;

        st.io = io;
        st.seen_tick = self.tick;
        st.group = @intCast(group);
    }

    /// Drops pids that were not seen this tick. Their disk I/O already lives
    /// in `totals`, which is the entire point of banking it there; their CPU
    /// lives in whichever live process reaped them.
    ///
    /// Collected first, removed second: mutating a hash map through a live
    /// iterator is not allowed, and restarting the iterator after each removal
    /// — which is what this used to do — costs O(retired × live) on exactly
    /// the Worker that retires most, one that forks per request.
    fn retireDeadPids(self: *Sampler) void {
        self.doomed.clearRetainingCapacity();
        var it = self.live.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.seen_tick == self.tick) continue;
            self.doomed.append(self.gpa, e.key_ptr.*) catch break;
        }
        for (self.doomed.items) |key| _ = self.live.remove(key);
    }

    /// Re-reads a few pids' PSS, then sums each Group's memory from what every
    /// live pid was last measured at.
    ///
    /// Called after `retireDeadPids`, so every entry left in `live` was seen
    /// this tick and the sum needs no further filtering.
    ///
    /// A pid whose turn has not come contributes its RSS, which is what devrun
    /// reported for every pid before any of this existed. So a Group's figure
    /// starts exactly where it used to and settles downward onto the truth as
    /// the rotation reaches its processes — it never starts at zero, which is
    /// the one wrong answer a freshly spawned Worker must not show.
    fn foldMemory(self: *Sampler) void {
        // The `pss_per_tick` stalest pids, never-measured first: their
        // `pss_tick` is zero, and zero sorts ahead of any real tick.
        const Slot = struct { pid: Pid = 0, tick: u64 = std.math.maxInt(u64) };
        var queue: [pss_per_tick]Slot = @splat(.{});

        var it = self.live.iterator();
        while (it.next()) |e| {
            const staleness = e.value_ptr.pss_tick;
            var pos: usize = 0;
            while (pos < queue.len and queue[pos].tick <= staleness) : (pos += 1) {}
            if (pos == queue.len) continue;
            var i: usize = queue.len - 1;
            while (i > pos) : (i -= 1) queue[i] = queue[i - 1];
            queue[pos] = .{ .pid = e.key_ptr.*, .tick = staleness };
        }

        for (queue) |slot| {
            if (slot.pid == 0) continue;
            const st = self.live.getPtr(slot.pid) orelse continue;
            // An unreadable `smaps_rollup` — a process that exited between the
            // walk and now, or a kernel without it — leaves `pss_tick` at zero,
            // so the pid keeps reporting RSS and stays at the front of the
            // queue rather than being recorded as holding nothing.
            if (readPss(slot.pid)) |pss| {
                st.pss_bytes = pss;
                st.pss_tick = self.tick;
            }
        }

        var fold = self.live.iterator();
        while (fold.next()) |e| {
            std.debug.assert(e.value_ptr.group < self.current.len);
            self.current[e.value_ptr.group].memory_bytes += e.value_ptr.memory();
        }
    }

    /// Fills `out` with `group`'s processes, largest first, and returns how
    /// many it wrote. This is what turns "1.6 GB" from an alarming number into
    /// a legible one: the total belongs to a tree, and naming the two or three
    /// processes holding most of it is the difference between a reader
    /// believing the figure and doubting the tool.
    ///
    /// Insertion-sorted into the caller's slots rather than sorted in place —
    /// `out` is a handful of entries wide, so there is nothing to allocate and
    /// nothing to free.
    pub fn breakdown(self: *const Sampler, group: usize, out: []ProcInfo) usize {
        if (out.len == 0) return 0;
        var n: usize = 0;
        var it = self.live.iterator();
        while (it.next()) |e| {
            const st = e.value_ptr;
            if (st.group != group) continue;
            const info = ProcInfo{
                .pid = e.key_ptr.*,
                .memory_bytes = st.memory(),
                .comm = st.comm,
                .comm_len = st.comm_len,
            };

            var pos: usize = 0;
            while (pos < n and out[pos].memory_bytes >= info.memory_bytes) : (pos += 1) {}
            if (pos == out.len) continue;
            var i: usize = @min(n, out.len - 1);
            while (i > pos) : (i -= 1) out[i] = out[i - 1];
            out[pos] = info;
            if (n < out.len) n += 1;
        }
        return n;
    }
};

/// How many pids may have their PSS re-read on one tick.
///
/// Three, because the rotation's job is to be invisible. On the Session this
/// was measured against — fifteen processes, some of them large — three reads
/// cost a few milliseconds a second and get all the way round the tree in five
/// ticks. Raising it buys fresher memory figures at a linear price in the one
/// thing devrun is trying not to spend.
const pss_per_tick = 3;

/// Whether this kernel exposes the per-thread `children` list. Checked once,
/// because a kernel does not grow the file halfway through a Session.
fn childrenSupported() bool {
    const pid = os.linux.getpid();
    var path: [80]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{d}/task/{d}/children", .{ pid, pid }) catch
        return false;
    const fd = os.open(p, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return false;
    os.close(fd);
    return true;
}

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
    /// User and system time of children this process has already *reaped*.
    /// Recursive: reaping a child folds that child's own `cutime` in too, so
    /// a whole subtree that has come and gone is one number here.
    cutime: u64,
    cstime: u64,
    rss_pages: u64,
    /// Copied rather than pointed at: the text it is parsed from lives in a
    /// stack buffer that `readStat` drops on return.
    comm: [comm_max]u8 = @splat(0),
    comm_len: u8 = 0,

    /// Every tick this process is responsible for — its own, plus everything
    /// it has buried. See the module header for why the sum is taken over the
    /// live set rather than accumulated per pid.
    fn cpuTicks(self: ProcStat) u64 {
        return self.utime + self.stime + self.cutime + self.cstime;
    }
};

fn readStat(pid: Pid) ?ProcStat {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{d}/stat", .{pid}) catch return null;
    var buf: [1024]u8 = undefined;
    const text = readSmallFile(p, &buf) orelse return null;
    return parseStat(text);
}

/// Parses one line of `/proc/<pid>/stat`.
///
/// The command name is field 2 and may contain spaces *and* parentheses, so
/// the only safe place to start is the last `)` in the line. Splitting on
/// whitespace from the left is the classic way to get this wrong, and it
/// misreads exactly the processes a dev tool sees — `node (worker)`, say.
///
/// Split out from the read so the field arithmetic below can be tested against
/// a line with a hostile name in it, which is not something a real `/proc` can
/// be asked to produce on demand.
fn parseStat(text: []const u8) ?ProcStat {
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    if (close + 2 >= text.len) return null;

    var it = std.mem.tokenizeScalar(u8, text[close + 2 ..], ' ');
    var field: usize = 0;
    var out = ProcStat{ .pgid = 0, .utime = 0, .stime = 0, .cutime = 0, .cstime = 0, .rss_pages = 0 };

    // The name runs from the first `(` to that last `)`, so a name containing
    // either bracket is carried whole instead of cutting the line short.
    if (std.mem.indexOfScalar(u8, text, '(')) |open| {
        if (close > open + 1) {
            const name = text[open + 1 .. close];
            out.comm_len = @intCast(@min(name.len, comm_max));
            @memcpy(out.comm[0..out.comm_len], name[0..out.comm_len]);
        }
    }

    while (it.next()) |tok| : (field += 1) {
        switch (field) {
            // Token 0 is `state`, which procfs calls field 3 — so token N is
            // field N+3. pgrp is 5, utime 14, stime 15, cutime 16, cstime 17,
            // rss 24. The next field after rss is rsslim, which is usually
            // 2^64-1: reading one field late here does not look like a small
            // error, it overflows.
            2 => out.pgid = std.fmt.parseInt(Pid, tok, 10) catch return null,
            11 => out.utime = std.fmt.parseInt(u64, tok, 10) catch 0,
            12 => out.stime = std.fmt.parseInt(u64, tok, 10) catch 0,
            // Declared signed in procfs. A negative reading is not a number we
            // have a use for, so it lands as zero rather than wrapping.
            13 => out.cutime = std.fmt.parseInt(u64, tok, 10) catch 0,
            14 => out.cstime = std.fmt.parseInt(u64, tok, 10) catch 0,
            21 => {
                out.rss_pages = std.fmt.parseInt(u64, tok, 10) catch 0;
                return out;
            },
            else => {},
        }
    }
    return out;
}

/// Proportional set size: every resident page divided by the number of
/// processes mapping it, so the figures of several processes can be added up
/// without counting a shared page more than once.
///
/// The kernel has to walk the page tables to answer, and it shows. Measured
/// over a real fifteen-process Session: `/proc/<pid>/stat` took 51 µs for the
/// whole tree, `smaps_rollup` took 19.9 ms — 390 times dearer, and it scales
/// with a process's mappings rather than with how many there are. Reading it
/// for every pid every second would have been the single largest thing devrun
/// does, on a tool whose case for existing is that it costs nothing to run.
///
/// So it is read on a rotation instead: `pss_per_tick` pids per tick, stalest
/// first. Memory is a slow-moving figure and a few seconds of lag in it is not
/// a lie a reader can act wrongly on, whereas CPU — which does move fast —
/// stays on `stat` and is still read for every pid every tick.
fn readPss(pid: Pid) ?u64 {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{d}/smaps_rollup", .{pid}) catch return null;
    // The file is around 700 bytes and `Pss:` is its third line.
    var buf: [2048]u8 = undefined;
    const text = readSmallFile(p, &buf) orelse return null;

    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        // `Pss_Dirty:`, `Pss_Anon:` and friends share the prefix but not the
        // colon, so the total is the only line this matches.
        if (!std.mem.startsWith(u8, line, "Pss:")) continue;
        const kb = parseTrailingKb(line) orelse return null;
        return kb * 1024;
    }
    return null;
}

/// `Pss:  1234 kB` — the number, without the unit that follows it.
fn parseTrailingKb(line: []const u8) ?u64 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    var it = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
    const tok = it.next() orelse return null;
    return std.fmt.parseInt(u64, tok, 10) catch null;
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

/// A `/proc/<pid>/stat` line with the fields this reads placed where procfs
/// puts them. Everything between is filler, so the arithmetic is exercised
/// rather than a hand-counted subset of it.
fn statLine(comptime name: []const u8) []const u8 {
    return "4242 " ++ name ++ " S 1 " ++ // pid, comm, state, ppid
        "777 " ++ // 5 pgrp
        "1 2 3 4 5 6 7 8 " ++ // 6..13 filler
        "110 " ++ // 14 utime
        "20 " ++ // 15 stime
        "3000 " ++ // 16 cutime
        "400 " ++ // 17 cstime
        "1 2 3 4 5 6 " ++ // 18..23 filler
        "512 " ++ // 24 rss
        "18446744073709551615"; // 25 rsslim
}

test "parseStat reads the fields procfs puts them in, hostile name and all" {
    const stat = parseStat(statLine("(bash)")) orelse return error.NoStat;
    try testing.expectEqual(@as(Pid, 777), stat.pgid);
    try testing.expectEqual(@as(u64, 110), stat.utime);
    try testing.expectEqual(@as(u64, 20), stat.stime);
    try testing.expectEqual(@as(u64, 3000), stat.cutime);
    try testing.expectEqual(@as(u64, 400), stat.cstime);
    try testing.expectEqual(@as(u64, 512), stat.rss_pages);
    // rsslim sits one field past rss and is 2^64-1; reading late here would
    // not look like an off-by-one, it would look like a machine with eighteen
    // exabytes resident.
    try testing.expect(stat.rss_pages < 1 << 40);

    // The name is scanned from the *last* parenthesis, so spaces and nested
    // parentheses inside it cannot shift every field that follows.
    inline for ([_][]const u8{ "(node (worker))", "(a b c)", "((()))", "(x) (y)" }) |name| {
        const s = parseStat(statLine(name)) orelse return error.NoStat;
        try testing.expectEqual(@as(Pid, 777), s.pgid);
        try testing.expectEqual(@as(u64, 3000), s.cutime);
        try testing.expectEqual(@as(u64, 512), s.rss_pages);
    }
}

test "a process is charged for the children it has buried" {
    // This is the blind spot the sampler had: a Worker that forks a compiler
    // per file has almost every child born and reaped between two ticks, so
    // reading only `utime + stime` reported it as idle while it pinned a core.
    // `cutime` and `cstime` are where the kernel kept those ticks.
    const stat = parseStat(statLine("(make)")) orelse return error.NoStat;
    try testing.expectEqual(@as(u64, 110 + 20 + 3000 + 400), stat.cpuTicks());

    // Its own time is a rounding error next to what it has spawned, which is
    // exactly the shape that used to read as 0%.
    try testing.expect(stat.cpuTicks() > 25 * (stat.utime + stat.stime));
}

test "parseStat refuses a line it cannot trust rather than guessing" {
    try testing.expect(parseStat("") == null);
    try testing.expect(parseStat("4242 (bash") == null); // never closed
    try testing.expect(parseStat("4242 (bash)") == null); // nothing after
    // A pgid that will not parse is not defaulted to zero — zero is the value
    // `indexOfPgid` uses to mean "not running", and inventing it would file a
    // live process under a stopped Worker.
    try testing.expect(parseStat("1 (x) S 1 nonsense 1 1") == null);
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

test "parseStat carries the process name, brackets and all" {
    const plain = parseStat(statLine("(bash)")) orelse return error.NoStat;
    try testing.expectEqualStrings("bash", plain.comm[0..plain.comm_len]);

    // The name is what a reader is shown in the memory breakdown, so it has to
    // survive the same hostile spellings the field arithmetic does.
    const nested = parseStat(statLine("(node (worker))")) orelse return error.NoStat;
    try testing.expectEqualStrings("node (worker)", nested.comm[0..nested.comm_len]);

    // Longer than TASK_COMM_LEN cannot happen from the kernel, but a truncated
    // name is still better than a buffer overrun if it ever did.
    const long = parseStat(statLine("(abcdefghijklmnopqrstuvwxyz)")) orelse return error.NoStat;
    try testing.expectEqual(@as(u8, comm_max), long.comm_len);
}

test "parseTrailingKb reads a smaps_rollup line without its unit" {
    try testing.expectEqual(@as(u64, 3940), parseTrailingKb("Pss:                3940 kB").?);
    try testing.expectEqual(@as(u64, 0), parseTrailingKb("Pss:  0 kB").?);
    try testing.expect(parseTrailingKb("Pss") == null);
}

/// The `Rss:` line of the very file `readPss` reads.
///
/// Test-only, and it exists because the obvious comparison is wrong: the RSS
/// in `/proc/<pid>/stat` comes from per-CPU counters the kernel batches, while
/// `smaps_rollup` walks the page tables as it is asked. The two disagree by a
/// fraction of a percent — measured at +0.07% on a 220 MB process and +1.7% on
/// a small one — always in the same direction. For a process that shares
/// almost nothing, PSS sits just under the walked figure and just *over* the
/// batched one, so asserting `pss <= stat.rss` fails on exactly the processes
/// where the two numbers should be closest.
fn readRollupRss(pid: Pid) ?u64 {
    var path: [64]u8 = undefined;
    const p = std.fmt.bufPrintZ(&path, "/proc/{d}/smaps_rollup", .{pid}) catch return null;
    var buf: [2048]u8 = undefined;
    const text = readSmallFile(p, &buf) orelse return null;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "Rss:")) continue;
        return (parseTrailingKb(line) orelse return null) * 1024;
    }
    return null;
}

test "PSS is real, and never larger than the RSS it refines" {
    const me = os.linux.getpid();
    const pss = readPss(me) orelse {
        // A kernel without smaps_rollup is a supported configuration: the
        // rotation simply never records a reading and every pid keeps its RSS.
        return error.SkipZigTest;
    };
    try testing.expect(pss > 0);

    // This is the whole point of the change. PSS shares each page out among
    // the processes mapping it, so for any single process it is at most that
    // process's RSS — and summing it across a Group therefore cannot exceed
    // what the machine actually handed out.
    const rss = readRollupRss(me) orelse return error.NoRollupRss;
    try testing.expect(pss <= rss);

    // And it is a refinement of RSS, not an unrelated number: `stat`'s RSS is
    // the right order of magnitude even though it is not exact.
    const stat = readStat(me) orelse return error.NoStat;
    const stat_rss = stat.rss_pages * std.heap.pageSize();
    try testing.expect(stat_rss > 0);
    try testing.expect(rss * 2 > stat_rss and stat_rss * 2 > rss);
}

test "a Group's memory is never zero while it has processes" {
    // The rotation measures only a few pids a tick, so most pids spend their
    // first ticks unmeasured. Reporting zero for those would show a freshly
    // started Worker as holding no memory, which is the one answer that would
    // be read as a fact rather than as a figure still settling.
    const me = os.linux.getpid();
    const pgid = os.linux.getpgid(0);

    var s = try Sampler.init(testing.allocator, 1);
    defer s.deinit();

    var out: [1]Sample = undefined;
    const pgids = [_]Pid{@intCast(pgid)};

    s.sample(&pgids, &out);
    try testing.expect(out[0].processes >= 1);
    const first = out[0].memory_bytes;
    try testing.expect(first > 0);

    // Ticking on does not lose the figure, and cannot grow it without bound:
    // memory is assigned from the live set each time, never accumulated.
    var settled = first;
    for (0..6) |_| {
        s.sample(&pgids, &out);
        try testing.expect(out[0].memory_bytes > 0);
        settled = out[0].memory_bytes;
    }
    try testing.expect(settled < first * 4);

    // By now the rotation has reached this pid, and PSS is what it reports.
    if (readPss(me) != null) {
        const st = s.live.getPtr(me) orelse return error.NotTracked;
        try testing.expect(st.pss_tick > 0);
        try testing.expectEqual(st.pss_bytes, st.memory());
    }
}

test "the breakdown names the biggest processes first" {
    var s = try Sampler.init(testing.allocator, 1);
    defer s.deinit();

    const pgid: Pid = @intCast(os.linux.getpgid(0));
    var out: [1]Sample = undefined;
    s.sample(&[_]Pid{pgid}, &out);

    var procs: [4]ProcInfo = undefined;
    const n = s.breakdown(0, &procs);
    try testing.expect(n >= 1);
    try testing.expect(n <= procs.len);

    var previous: u64 = std.math.maxInt(u64);
    for (procs[0..n]) |p| {
        try testing.expect(p.memory_bytes <= previous);
        previous = p.memory_bytes;
        try testing.expect(p.pid > 0);
        try testing.expect(p.name().len > 0);
    }

    // The parts have to add up to the whole, or the line explaining the total
    // would contradict the total sitting beside it.
    var sum: u64 = 0;
    var all: [64]ProcInfo = undefined;
    for (all[0..s.breakdown(0, &all)]) |p| sum += p.memory_bytes;
    try testing.expectEqual(out[0].memory_bytes, sum);

    // A Group nobody is in has nothing to say about itself.
    try testing.expectEqual(@as(usize, 0), s.breakdown(0, procs[0..0]));
}

test "a Group's disk totals never go backwards when a pid exits" {
    var s = try Sampler.init(testing.allocator, 2);
    defer s.deinit();

    // A pid in Group 0 that has already read a page.
    s.tick = 1;
    try s.live.put(testing.allocator, 101, .{
        .group = 0,
        .seen_tick = 1,
        .io = .{ .read = 4096, .write = 0 },
    });
    s.totals[0] = .{ .read_bytes = 4096 };

    // Next tick, pid 101 is gone. Retiring it must leave the total alone —
    // those bytes were really read, and there is no `cutime` for I/O that
    // would carry them anywhere else.
    s.tick = 2;
    s.retireDeadPids();

    try testing.expectEqual(@as(usize, 0), s.live.count());
    try testing.expectEqual(@as(u64, 4096), s.totals[0].read_bytes);
    // And the untouched Group stays at zero.
    try testing.expectEqual(@as(u64, 0), s.totals[1].read_bytes);
}

test "CPU is summed from the live set, not accumulated across ticks" {
    // The counterpart to the fix: because a live pid carries its dead
    // children's ticks in `cutime`, the Group figure has to be *assigned*
    // from each walk. Accumulating deltas on top would charge a reaped child
    // once as itself and again as its parent's inheritance, and a Worker that
    // forks per file would climb to thousands of percent.
    var s = try Sampler.init(testing.allocator, 1);
    defer s.deinit();

    const me = os.linux.getpid();
    const stat = readStat(me) orelse return error.NoStat;
    const pgids = [_]Pid{stat.pgid};
    var out: [1]Sample = undefined;

    // Spend CPU until procfs credits this process a few ticks, so what
    // follows is a statement about a real figure rather than about zero. A
    // tick is 10 ms, and a whole test binary can run in less than one.
    var sink: u64 = 0;
    var rounds: usize = 0;
    while (rounds < 500) : (rounds += 1) {
        if ((readStat(me) orelse return error.NoStat).cpuTicks() >= 3) break;
        var i: usize = 1;
        while (i < 2_000_000) : (i += 1) sink +%= i *% 2654435761;
    }
    // Keeps the work above observable, and is a real claim: any round at all
    // must have moved the accumulator.
    try testing.expect(rounds == 0 or sink != 0);

    s.sample(&pgids, &out);
    try testing.expect(s.totals[0].cpu_ticks > 0);
    // The sharp one: the Group's figure is exactly what this walk found. A
    // `+=` here would pass on the first tick and diverge on every one after.
    try testing.expectEqual(s.current[0].cpu_ticks, s.totals[0].cpu_ticks);

    s.sample(&pgids, &out);
    try testing.expect(s.totals[0].cpu_ticks > 0);
    try testing.expectEqual(s.current[0].cpu_ticks, s.totals[0].cpu_ticks);
}

test "a pid offered twice in one walk is only charged once" {
    // CPU is a sum now, so a duplicate in the frontier would double a Group
    // rather than contribute a zero delta the way it used to.
    var s = try Sampler.init(testing.allocator, 1);
    defer s.deinit();

    const me = os.linux.getpid();
    const stat = readStat(me) orelse return error.NoStat;
    const pgids = [_]Pid{stat.pgid};

    s.tick = 1;
    s.account(me, &pgids);
    const once = s.current[0];
    try testing.expect(once.cpu_ticks > 0);
    try testing.expectEqual(@as(u32, 1), once.processes);

    s.account(me, &pgids);
    try testing.expectEqual(once.cpu_ticks, s.current[0].cpu_ticks);
    try testing.expectEqual(@as(u32, 1), s.current[0].processes);
    try testing.expectEqual(once.memory_bytes, s.current[0].memory_bytes);
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
