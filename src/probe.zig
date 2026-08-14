//! Readiness probes: the thing that decides a Worker is Ready rather than
//! merely started.
//!
//! Both kinds are non-blocking, and that is the whole design constraint. A
//! probe with a one-second timeout is allowed to take a second; the event loop
//! is not allowed to stop for it. So an exec probe is a Group whose death
//! arrives as `SIGCHLD` like any other, and an HTTP probe is a socket that
//! joins the same `poll()` set as everything else. Neither ever blocks the
//! loop, which is why a hung probe on one Worker cannot stall another Worker's
//! logs.
//!
//! Attempt bookkeeping follows process-compose: `success_threshold` consecutive
//! passes make a Worker Ready, `failure_threshold` consecutive failures make it
//! unhealthy, and either counter resets when the other side scores.

const std = @import("std");
const os = @import("os.zig");
const config = @import("config.zig");

const Allocator = std.mem.Allocator;

pub const Error = error{
    /// `scheme: https` is in the config. Terminating TLS to probe a local dev
    /// service is not something devrun does, and quietly probing it over plain
    /// HTTP instead would be the silent divergence this project refuses.
    HttpsProbeUnsupported,
    /// The host is neither an IPv4 literal nor `localhost`. devrun does not
    /// resolve names for probes — a resolver in the event loop is a blocking
    /// call wearing a disguise.
    HostNotAnIpAddress,
} || Allocator.Error;

/// What one attempt concluded.
const Verdict = enum { pass, fail };

/// An attempt in flight. `none` between attempts, which is most of the time —
/// a probe with the default 10s period is idle for essentially all of it.
const Attempt = union(enum) {
    none,
    /// The Group running the exec command. Reaped through the supervisor's
    /// normal `SIGCHLD` path, then handed here.
    exec: os.Pid,
    http: Http,
};

const Http = struct {
    fd: os.Fd,
    phase: enum { connecting, sending, receiving },
    sent: usize = 0,
    /// Only the status line matters, and it is the first thing on the wire.
    /// Anything past this is discarded, so a Worker that answers a probe with
    /// a megabyte of JSON costs us 64 bytes.
    got: [64]u8 = undefined,
    got_len: usize = 0,
};

pub const Probe = struct {
    spec: config.Probe,

    /// Built once at startup so an attempt never formats or allocates.
    exec_argv: ?[*:null]const ?[*:0]const u8 = null,
    exec_path: ?[*:0]const u8 = null,
    http_addr: os.linux.sockaddr.in = undefined,
    http_request: []const u8 = &.{},

    attempt: Attempt = .none,
    /// When the current attempt gives up.
    deadline_ms: u64 = 0,
    /// When the next attempt may begin.
    next_ms: u64,

    successes: u32 = 0,
    failures: u32 = 0,

    /// True once `success_threshold` consecutive attempts passed. This is what
    /// `process_healthy` waits on.
    ready: bool = false,
    /// True once `failure_threshold` consecutive attempts failed. Reported,
    /// not acted on: a Worker that fails its probe is still running, and
    /// killing it is a policy decision devrun does not make for you.
    unhealthy: bool = false,

    /// `shell` is the Session's already-resolved shell. Resolving it here
    /// instead would re-walk PATH once per probe to reach the same answer.
    pub const ResolvedShell = struct {
        path: [*:0]const u8,
        argument: []const u8,
    };

    pub fn init(
        arena: Allocator,
        spec: config.Probe,
        shell: ResolvedShell,
        started_ms: u64,
    ) Error!Probe {
        var p = Probe{
            .spec = spec,
            .next_ms = started_ms + @as(u64, spec.initial_delay_seconds) * 1000,
        };

        switch (spec.target) {
            .exec => |command| {
                // The probe runs under the same shell as the Worker, so a
                // probe that works when pasted into a terminal works here.
                const argv = try arena.allocSentinel(?[*:0]const u8, 3, null);
                argv[0] = shell.path;
                argv[1] = (try arena.dupeZ(u8, shell.argument)).ptr;
                argv[2] = (try arena.dupeZ(u8, command)).ptr;
                p.exec_path = shell.path;
                p.exec_argv = argv.ptr;
            },
            .http_get => |h| {
                if (!std.mem.eql(u8, h.scheme, "http")) return error.HttpsProbeUnsupported;
                const ip = try parseIp4(h.host);
                p.http_addr = .{
                    .port = std.mem.nativeToBig(u16, h.port),
                    .addr = ip,
                };
                p.http_request = try std.fmt.allocPrint(
                    arena,
                    "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: devrun\r\n" ++
                        "Accept: */*\r\nConnection: close\r\n\r\n",
                    .{ h.path, h.host, h.port },
                );
            },
        }
        return p;
    }

    pub fn inFlight(self: Probe) bool {
        return self.attempt != .none;
    }

    /// When the loop next needs to wake for this probe: the attempt's timeout
    /// while one is running, otherwise the start of the next period.
    pub fn wakeAt(self: Probe) u64 {
        return if (self.inFlight()) self.deadline_ms else self.next_ms;
    }

    /// Starts an attempt if one is due. Failing to start *is* a failed
    /// attempt — a probe socket we cannot open says as much about readiness as
    /// one that connects and is refused.
    pub fn tick(self: *Probe, now: u64, spawn_env: SpawnEnv) void {
        if (self.inFlight() or now < self.next_ms) return;
        self.next_ms = now + @as(u64, self.spec.period_seconds) * 1000;
        self.deadline_ms = now + @as(u64, self.spec.timeout_seconds) * 1000;
        switch (self.spec.target) {
            .exec => self.beginExec(spawn_env),
            .http_get => self.beginHttp(),
        }
    }

    /// What the supervisor passes down so an exec probe can be spawned without
    /// this module knowing how the Session is wired.
    pub const SpawnEnv = struct {
        envp: [*:null]const ?[*:0]const u8,
        cwd: ?[*:0]const u8,
        devnull: os.Fd,
    };

    fn beginExec(self: *Probe, env: SpawnEnv) void {
        const child = os.spawn(.{
            .path = self.exec_path.?,
            .argv = self.exec_argv.?,
            .envp = env.envp,
            .cwd = env.cwd,
            // A probe's chatter is not the Worker's output and must not land
            // in its Archive.
            .output = env.devnull,
            .input = env.devnull,
        }) catch {
            self.settle(.fail);
            return;
        };
        self.attempt = .{ .exec = child.pgid };
    }

    fn beginHttp(self: *Probe) void {
        const fd = os.socket(os.linux.AF.INET, os.linux.SOCK.STREAM, 0) catch {
            self.settle(.fail);
            return;
        };
        os.setNonblock(fd, true);
        // A non-blocking connect returns EINPROGRESS and completes later; on
        // loopback it usually completes immediately, and both are fine.
        os.connect(fd, &self.http_addr) catch |err| switch (err) {
            error.WouldBlock, error.InProgress => {},
            else => {
                os.close(fd);
                self.settle(.fail);
                return;
            },
        };
        self.attempt = .{ .http = .{ .fd = fd, .phase = .connecting } };
    }

    /// The descriptor this probe wants in the loop's `poll()` set, if any.
    pub fn pollFd(self: Probe) ?os.PollFd {
        const h = switch (self.attempt) {
            .http => |h| h,
            else => return null,
        };
        return .{
            .fd = h.fd,
            .events = switch (h.phase) {
                .connecting, .sending => os.POLL.OUT,
                .receiving => os.POLL.IN,
            },
            .revents = 0,
        };
    }

    pub fn onPoll(self: *Probe, revents: i16) void {
        const h = switch (self.attempt) {
            .http => |*h| h,
            else => return,
        };
        if (revents & (os.POLL.ERR | os.POLL.NVAL) != 0) return self.finishHttp(.fail);

        switch (h.phase) {
            .connecting => {
                // POLLOUT alone does not mean success: a refused connection is
                // also writable, and only SO_ERROR tells them apart.
                if (os.socketError(h.fd) != 0) return self.finishHttp(.fail);
                h.phase = .sending;
                self.onPoll(os.POLL.OUT);
            },
            .sending => {
                const n = os.write(h.fd, self.http_request[h.sent..]) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return self.finishHttp(.fail),
                };
                h.sent += n;
                if (h.sent == self.http_request.len) h.phase = .receiving;
            },
            .receiving => {
                const n = os.read(h.fd, h.got[h.got_len..]) catch |err| switch (err) {
                    error.WouldBlock => return,
                    else => return self.finishHttp(.fail),
                };
                if (n == 0) return self.finishHttp(.fail); // closed before answering
                h.got_len += n;
                if (statusLineVerdict(h.got[0..h.got_len])) |v| return self.finishHttp(v);
                // The buffer only ever holds a status line; if it filled
                // without one appearing, this is not an HTTP server.
                if (h.got_len == h.got.len) return self.finishHttp(.fail);
            },
        }
    }

    /// Hands a reaped pid to the probe. Returns true when it was this probe's,
    /// so the supervisor knows not to treat it as a Worker exiting.
    pub fn onReap(self: *Probe, pgid: os.Pid, exit: os.Exit) bool {
        const mine = switch (self.attempt) {
            .exec => |p| p == pgid,
            else => false,
        };
        if (!mine) return false;
        self.attempt = .none;
        self.settle(if (exit.ok()) .pass else .fail);
        return true;
    }

    /// Gives up on an attempt that outlived `timeout_seconds`.
    pub fn checkTimeout(self: *Probe, now: u64) void {
        if (!self.inFlight() or now < self.deadline_ms) return;
        switch (self.attempt) {
            .exec => |pgid| {
                // The Group, not the pid: a probe like `curl | grep` leaves
                // children, and a timed-out probe must not leak them.
                os.killGroup(pgid, .KILL);
                // Left in flight, and deliberately *not* settled here: the
                // kill arrives as a SIGCHLD within milliseconds and `onReap`
                // records the failure then. Settling in both places would
                // count one timed-out attempt against `failure_threshold`
                // twice. Re-armed so an unkillable Group is signalled again
                // rather than spinning the loop.
                self.deadline_ms = now + 1000;
            },
            .http => self.finishHttp(.fail),
            .none => unreachable,
        }
    }

    fn finishHttp(self: *Probe, v: Verdict) void {
        switch (self.attempt) {
            .http => |h| os.close(h.fd),
            else => {},
        }
        self.attempt = .none;
        self.settle(v);
    }

    /// Applies one verdict to the thresholds. Consecutive is the operative
    /// word: a pass clears the failure run and vice versa, so a probe that
    /// flaps never accumulates its way over either line.
    fn settle(self: *Probe, v: Verdict) void {
        switch (v) {
            .pass => {
                self.failures = 0;
                self.successes += 1;
                if (self.successes >= self.spec.success_threshold) {
                    self.ready = true;
                    self.unhealthy = false;
                }
            },
            .fail => {
                self.successes = 0;
                self.failures += 1;
                if (self.failures >= self.spec.failure_threshold) {
                    self.unhealthy = true;
                    self.ready = false;
                }
            },
        }
    }

    /// Forgets everything learned about a Worker that is being restarted. The
    /// new Group has to earn Ready again.
    pub fn reset(self: *Probe, now: u64) void {
        switch (self.attempt) {
            .http => |h| os.close(h.fd),
            .exec => |pgid| os.killGroup(pgid, .KILL),
            .none => {},
        }
        self.attempt = .none;
        self.successes = 0;
        self.failures = 0;
        self.ready = false;
        self.unhealthy = false;
        self.next_ms = now + @as(u64, self.spec.initial_delay_seconds) * 1000;
    }
};

/// A 2xx or 3xx is ready; anything else is not. Returns null while the status
/// line is still incomplete.
fn statusLineVerdict(buf: []const u8) ?Verdict {
    const eol = std.mem.indexOfScalar(u8, buf, '\n') orelse return null;
    const line = buf[0..eol];
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return .fail;
    if (!std.mem.startsWith(u8, line, "HTTP/")) return .fail;
    const rest = std.mem.trimStart(u8, line[sp..], " ");
    if (rest.len < 3) return .fail;
    const code = std.fmt.parseInt(u16, rest[0..3], 10) catch return .fail;
    return if (code >= 200 and code < 400) .pass else .fail;
}

/// IPv4 in network byte order, ready for `sockaddr.in.addr`. Hand-written
/// rather than pulled from a resolver: probes must never block the loop, and
/// every name lookup eventually does.
///
/// The result is a `@bitCast` of the four octets in memory order, *not*
/// `readInt(..., .big)` — that returns a native integer whose bytes come out
/// reversed on a little-endian machine, which turns 127.0.0.1 into 1.0.0.127
/// and makes every probe fail to connect.
fn parseIp4(host: []const u8) Error!u32 {
    if (std.mem.eql(u8, host, "localhost")) return parseIp4("127.0.0.1");
    var octets: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    for (&octets) |*o| {
        const part = it.next() orelse return error.HostNotAnIpAddress;
        if (part.len == 0 or part.len > 3) return error.HostNotAnIpAddress;
        o.* = std.fmt.parseInt(u8, part, 10) catch return error.HostNotAnIpAddress;
    }
    if (it.next() != null) return error.HostNotAnIpAddress;
    return @bitCast(octets);
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "an HTTP status line decides readiness, and a partial one decides nothing" {
    try testing.expectEqual(Verdict.pass, statusLineVerdict("HTTP/1.1 200 OK\r\n").?);
    try testing.expectEqual(Verdict.pass, statusLineVerdict("HTTP/1.1 204 No Content\r\n").?);
    // A redirect means something is listening and answering, which is what a
    // readiness probe is asking.
    try testing.expectEqual(Verdict.pass, statusLineVerdict("HTTP/1.1 301 Moved\r\n").?);
    try testing.expectEqual(Verdict.fail, statusLineVerdict("HTTP/1.1 404 Not Found\r\n").?);
    try testing.expectEqual(Verdict.fail, statusLineVerdict("HTTP/1.1 503 Unavailable\r\n").?);
    // Something is listening, but it does not speak HTTP.
    try testing.expectEqual(Verdict.fail, statusLineVerdict("SSH-2.0-OpenSSH_9.6\n").?);
    // Still arriving: no verdict yet, rather than a wrong one.
    try testing.expect(statusLineVerdict("HTTP/1.1 20") == null);
}

test "parseIp4 accepts literals and localhost, and refuses names" {
    // Compared against the octets laid out in memory order, which is what the
    // wire wants. Writing the expectation as a hex integer instead would pass
    // on a big-endian machine and silently reverse the address on this one.
    const loopback: u32 = @bitCast([4]u8{ 127, 0, 0, 1 });
    try testing.expectEqual(loopback, try parseIp4("127.0.0.1"));
    try testing.expectEqual(loopback, try parseIp4("localhost"));
    try testing.expectEqual(@as(u32, @bitCast([4]u8{ 0, 0, 0, 0 })), try parseIp4("0.0.0.0"));
    try testing.expectEqual(
        @as(u32, @bitCast([4]u8{ 192, 168, 1, 1 })),
        try parseIp4("192.168.1.1"),
    );

    try testing.expectError(error.HostNotAnIpAddress, parseIp4("db.internal"));
    try testing.expectError(error.HostNotAnIpAddress, parseIp4("127.0.0"));
    try testing.expectError(error.HostNotAnIpAddress, parseIp4("127.0.0.1.5"));
    try testing.expectError(error.HostNotAnIpAddress, parseIp4("999.0.0.1"));
}

test "thresholds need consecutive results, not cumulative ones" {
    var p = Probe{
        .spec = .{ .target = .{ .exec = "true" }, .success_threshold = 2, .failure_threshold = 3 },
        .next_ms = 0,
    };

    p.settle(.pass);
    try testing.expect(!p.ready); // one pass is not two
    p.settle(.fail); // resets the success run
    p.settle(.pass);
    try testing.expect(!p.ready);
    p.settle(.pass);
    try testing.expect(p.ready);

    // Two failures do not unset Ready when the threshold is three...
    p.settle(.fail);
    p.settle(.fail);
    try testing.expect(p.ready);
    try testing.expect(!p.unhealthy);
    // ...and the third does.
    p.settle(.fail);
    try testing.expect(!p.ready);
    try testing.expect(p.unhealthy);

    // Recovery is symmetric: the failure run clears as soon as it passes.
    p.settle(.pass);
    p.settle(.pass);
    try testing.expect(p.ready);
    try testing.expect(!p.unhealthy);
}

test "https is refused rather than silently probed over http" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    try testing.expectError(error.HttpsProbeUnsupported, Probe.init(
        arena_state.allocator(),
        .{ .target = .{ .http_get = .{ .scheme = "https", .port = 8443 } } },
        .{ .path = "/bin/sh", .argument = "-c" },
        0,
    ));
}

test "initial_delay_seconds pushes the first attempt out, not every attempt" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const p = try Probe.init(
        arena_state.allocator(),
        .{
            .target = .{ .http_get = .{ .port = 8080 } },
            .initial_delay_seconds = 3,
            .period_seconds = 10,
        },
        .{ .path = "/bin/sh", .argument = "-c" },
        1_000,
    );
    // Started at t=1000 with a 3s delay: the first attempt is due at 4000.
    try testing.expectEqual(@as(u64, 4_000), p.next_ms);
    try testing.expectEqual(@as(u64, 4_000), p.wakeAt());
    try testing.expect(!p.inFlight());
}
