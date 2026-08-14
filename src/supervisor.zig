//! The Session: one `poll()` loop that owns every Group.
//!
//! Single-threaded on purpose. The workload is a dozen descriptors, so the
//! loop costs nothing, and everything it coordinates — a Worker's exit status,
//! a probe's verdict, a shutdown deadline — is a state transition that would
//! otherwise need a lock. `docs/adr/0004-portability-posture.md` picked
//! `poll()` over `epoll` for the same reason it picked a self-pipe over
//! `signalfd`: at this scale they are indistinguishable in cost, and only one
//! of them is portable.
//!
//! The loop never blocks on anything but `poll()`. Probes are non-blocking,
//! output is drained until `EAGAIN`, and every deadline is a timeout on the
//! next poll rather than a sleep. That is what lets one hung Worker leave
//! every other Worker's logs flowing.

const std = @import("std");
const os = @import("os.zig");
const config = @import("config.zig");
const probe_mod = @import("probe.zig");
const archive_mod = @import("archive.zig");
const sample_mod = @import("sample.zig");

const Allocator = std.mem.Allocator;
const Archive = archive_mod.Archive;
const Probe = probe_mod.Probe;

/// Where a Worker is in its life. `ready` is reserved for what a readiness
/// probe confirmed — a Worker that bound its port is `running`, not `ready`.
/// See CONTEXT.md.
pub const State = enum {
    /// Not started: still waiting on a dependency.
    pending,
    /// Group is alive.
    running,
    /// Group is alive and its readiness probe has passed.
    ready,
    /// The shutdown ladder is climbing.
    stopping,
    /// Terminated, exit code 0. A Gate that did its job ends here.
    exited,
    /// Terminated because devrun asked it to. Distinct from `exited`: the
    /// Group almost always dies by signal, and reporting that as a failure
    /// would make every `devrun stop` look like a crash.
    stopped,
    /// Terminated, non-zero or by signal.
    failed,
    /// Never started, and never will: a dependency reached a state that can no
    /// longer satisfy the condition this Worker was waiting for.
    skipped,

    pub fn terminal(self: State) bool {
        return switch (self) {
            .exited, .stopped, .failed, .skipped => true,
            else => false,
        };
    }

    pub fn alive(self: State) bool {
        return switch (self) {
            .running, .ready, .stopping => true,
            else => false,
        };
    }
};

/// Scans a stream for a Worker's `ready_log_line` without buffering the
/// stream. The only state it carries between chunks is the last `needle-1`
/// bytes, which is exactly what a match straddling a chunk boundary needs —
/// so a 4 KB read and a 64 KB read find the same matches.
const ReadyScan = struct {
    /// Bounded so `carry` can live inline. A readiness marker longer than this
    /// is refused at startup rather than silently truncated.
    pub const max_needle = 256;

    needle: []const u8,
    carry: [max_needle - 1]u8 = undefined,
    carry_len: usize = 0,

    fn feed(self: *ReadyScan, chunk: []const u8) bool {
        const overlap = self.needle.len - 1;

        // The seam: the tail we kept, followed by enough of this chunk to
        // complete a match that began in the last one.
        if (self.carry_len > 0) {
            var seam: [2 * max_needle]u8 = undefined;
            const take = @min(chunk.len, overlap);
            @memcpy(seam[0..self.carry_len], self.carry[0..self.carry_len]);
            @memcpy(seam[self.carry_len..][0..take], chunk[0..take]);
            if (std.mem.indexOf(u8, seam[0 .. self.carry_len + take], self.needle) != null) {
                return true;
            }
        }

        if (std.mem.indexOf(u8, chunk, self.needle) != null) return true;

        // The carry is the last `overlap` bytes of the *stream*, not of this
        // chunk. Overwriting it with a short chunk would throw away the bytes
        // a match still needs — a marker arriving one byte at a time would
        // then never be found.
        if (chunk.len >= overlap) {
            @memcpy(self.carry[0..overlap], chunk[chunk.len - overlap ..]);
            self.carry_len = overlap;
        } else {
            const kept = @min(self.carry_len, overlap - chunk.len);
            std.mem.copyForwards(
                u8,
                self.carry[0..kept],
                self.carry[self.carry_len - kept .. self.carry_len],
            );
            @memcpy(self.carry[kept..][0..chunk.len], chunk);
            self.carry_len = kept + chunk.len;
        }
        return false;
    }
};

/// A Worker's runtime half: everything that is true of this Session rather
/// than of the config file.
pub const Runtime = struct {
    spec: *const config.Worker,
    state: State = .pending,

    /// The Group. Zero when nothing is running.
    pgid: os.Pid = 0,
    /// Read end of the pipe carrying the Group's stdout and stderr.
    out_fd: os.Fd = -1,
    archive: Archive,
    probe: ?Probe = null,
    ready_scan: ?ReadyScan = null,

    /// Set once the Worker has ever been spawned. `process_started` asks about
    /// this rather than the current state, because a Gate that already ran and
    /// exited did, in fact, start.
    has_started: bool = false,
    log_ready: bool = false,
    exit: ?os.Exit = null,
    started_ms: u64 = 0,
    stopped_ms: u64 = 0,

    restarts: u32 = 0,
    /// When a restart may happen. Backoff exists because a Worker that fails
    /// instantly under `restart: always` would otherwise spin the loop at
    /// 100% CPU — process-compose has `backoff_seconds` for this; devrun does
    /// not read that field, so it derives one instead.
    restart_at_ms: u64 = 0,
    /// When the ladder escalates from the configured signal to SIGKILL.
    kill_at_ms: u64 = 0,

    // Precomputed once, so spawning allocates nothing.
    argv: [*:null]const ?[*:0]const u8 = undefined,
    envp: [*:null]const ?[*:0]const u8 = undefined,
    cwd: ?[*:0]const u8 = null,

    pub fn name(self: Runtime) []const u8 {
        return self.spec.name;
    }
};

pub const Options = struct {
    io: std.Io,
    environ: *const std.process.Environ.Map,
    /// Directory the config was read from; `dotenv` paths and the default
    /// working directory resolve against it.
    base_dir: []const u8,
    /// Where Archives are written.
    log_dir: []const u8,
    /// Total in-memory Window budget across all Workers.
    ///
    /// Deliberately small. The Window is a cache in front of the Archive, not
    /// the record, and `Archive.readAt` falls through to `pread` for anything
    /// older — which for bytes written this Session is a page-cache copy, at
    /// the speed the memcpy it replaced would have run at. Spending eight
    /// megabytes to avoid that read bought nothing measurable and cost 7.7 MB
    /// of RSS on a noisy Worker. `--window-bytes` raises it for anyone who
    /// wants the old size back.
    window_budget: usize = 1 << 20,
};

pub const Diagnostic = struct {
    message: ?[]u8 = null,

    pub fn deinit(self: *Diagnostic, gpa: Allocator) void {
        if (self.message) |m| gpa.free(m);
        self.message = null;
    }
};

pub const Supervisor = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    cfg: *const config.Config,
    workers: []Runtime,

    /// Reverse edges: `dependents[i]` lists the Workers that wait on `i`. Built
    /// once, because shutdown walks it on every pass and rediscovering it by
    /// scanning every `depends_on` would be quadratic per pass.
    dependents: [][]const u32,
    /// Forward edges, resolved: `dep_targets[i][k]` is the Worker index that
    /// `workers[i].spec.depends_on[k]` names. The state machine asks this on
    /// every pass, and looking it up by string there meant a `memcmp` against
    /// every Worker's name several times a second forever.
    dep_targets: [][]const u32,

    signals: os.Signals,
    devnull: os.Fd,
    shell: Probe.ResolvedShell,

    shutting_down: bool = false,
    /// Set when a Worker with `restart: exit_on_failure` failed. Reported by
    /// `run` so the exit status can carry it.
    failed_hard: bool = false,
    /// Bumped whenever anything a viewer would want to redraw has changed.
    generation: u64 = 0,

    poll_buf: []os.PollFd,
    /// Which Worker each poll slot belongs to, parallel to `poll_buf`.
    poll_owner: []u32,
    /// One chunk of Worker output. 64 KiB matches the pipe capacity, so a
    /// burst is usually drained in a single read.
    read_buf: []u8,

    /// Resource accounting lives here rather than in a view, because a Sample
    /// is a fact about the Session: the control socket answers `samples`
    /// whether or not anyone is looking at a TUI.
    sampler: sample_mod.Sampler,
    samples: []sample_mod.Sample,
    /// Scratch for `sampler.sample`, reused so a tick allocates nothing.
    pgid_scratch: []os.Pid,
    next_sample_ms: u64 = 0,

    pub fn init(
        gpa: Allocator,
        cfg: *const config.Config,
        opts: Options,
        diag: ?*Diagnostic,
    ) !Supervisor {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const shell_path = os.resolvePath(
            arena,
            cfg.shell.command,
            opts.environ.get("PATH"),
        ) catch {
            return failWith(gpa, diag, "shell \"{s}\" not found on PATH", .{cfg.shell.command});
        };

        const n = cfg.workers.len;
        const workers = try arena.alloc(Runtime, n);
        const window_bytes = archive_mod.windowBytesPerWorker(opts.window_budget, n);

        // Ensure the Archive directory exists before any Worker needs it.
        os.makePath(opts.log_dir) catch {};

        const devnull = try os.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        errdefer os.close(devnull);

        var made: usize = 0;
        errdefer for (workers[0..made]) |*w| w.archive.deinit(gpa);

        const now = os.nowMs();
        for (cfg.workers, workers) |*spec, *rt| {
            const path = try std.fmt.allocPrintSentinel(
                arena,
                "{s}/{s}.log",
                .{ opts.log_dir, spec.name },
                0,
            );
            rt.* = .{
                .spec = spec,
                .archive = Archive.create(gpa, path.ptr, window_bytes) catch {
                    return failWith(gpa, diag, "cannot write Archive {s}", .{path});
                },
            };
            made += 1;

            rt.argv = try buildArgv(arena, shell_path.ptr, cfg.shell.argument, spec.command);
            rt.envp = try buildEnv(arena, opts, spec, diag, gpa);
            rt.cwd = try resolveCwd(arena, opts.base_dir, spec.working_dir);

            if (spec.ready_log_line) |line| {
                if (line.len == 0 or line.len > ReadyScan.max_needle) {
                    return failWith(
                        gpa,
                        diag,
                        "processes.{s}.ready_log_line must be 1..{d} bytes",
                        .{ spec.name, ReadyScan.max_needle },
                    );
                }
                rt.ready_scan = .{ .needle = line };
            }
            if (spec.readiness_probe) |p| {
                rt.probe = Probe.init(arena, p, .{
                    .path = shell_path.ptr,
                    .argument = cfg.shell.argument,
                }, now) catch |err| {
                    return failWith(gpa, diag, "processes.{s}.readiness_probe: {s}", .{
                        spec.name,
                        switch (err) {
                            error.HttpsProbeUnsupported => "scheme \"https\" is not supported; " ++
                                "devrun probes plain HTTP only",
                            error.HostNotAnIpAddress => "host must be an IP address or " ++
                                "\"localhost\"; devrun does not resolve names for probes",
                            else => "could not be prepared",
                        },
                    });
                };
            }
        }

        const dependents = try buildDependents(arena, cfg.workers);
        const dep_targets = try buildDepTargets(arena, cfg);

        var signals = try os.Signals.install(&.{ .CHLD, .INT, .TERM, .HUP, .WINCH });
        errdefer signals.deinit();

        // Orphaned grandchildren come back to us instead of escaping to PID 1,
        // so a Worker that daemonises is still part of its Group's accounting.
        os.becomeSubreaper();

        return .{
            .gpa = gpa,
            .arena = arena_state,
            .cfg = cfg,
            .workers = workers,
            .dependents = dependents,
            .dep_targets = dep_targets,
            .signals = signals,
            .devnull = devnull,
            .shell = .{ .path = shell_path.ptr, .argument = cfg.shell.argument },
            // Worst case each Worker contributes an output pipe and a probe
            // socket, plus the signal pipe and room for the caller's own.
            .poll_buf = try arena.alloc(os.PollFd, 2 * n + 8),
            .poll_owner = try arena.alloc(u32, 2 * n + 8),
            .read_buf = try gpa.alloc(u8, 64 << 10),
            .sampler = try sample_mod.Sampler.init(gpa, n),
            .samples = try gpa.alloc(sample_mod.Sample, n),
            .pgid_scratch = try gpa.alloc(os.Pid, n),
        };
    }

    pub fn deinit(self: *Supervisor) void {
        for (self.workers) |*w| {
            if (w.out_fd >= 0) os.close(w.out_fd);
            w.archive.deinit(self.gpa);
        }
        self.gpa.free(self.read_buf);
        self.gpa.free(self.samples);
        self.gpa.free(self.pgid_scratch);
        self.sampler.deinit();
        os.close(self.devnull);
        self.signals.deinit();
        self.arena.deinit();
    }

    fn failWith(gpa: Allocator, diag: ?*Diagnostic, comptime fmt: []const u8, args: anytype) error{Invalid} {
        if (diag) |d| {
            d.deinit(gpa);
            d.message = std.fmt.allocPrint(gpa, fmt, args) catch null;
        }
        return error.Invalid;
    }

    // --------------------------------------------------------- the loop

    /// One pass: wait for something to happen, then let every subsystem react.
    ///
    /// `extra` lets a caller — the TUI, with its stdin — join the same
    /// `poll()` rather than running a second one. Its `revents` are filled in
    /// on return.
    pub fn step(self: *Supervisor, extra: []os.PollFd, max_wait_ms: i32) !void {
        var fds = self.poll_buf;
        var n: usize = 0;

        fds[n] = .{ .fd = self.signals.read_fd, .events = os.POLL.IN, .revents = 0 };
        n += 1;
        const sig_slot = 0;

        // Each slot records the Worker it belongs to. Routing by remembered
        // owner rather than by re-walking the Workers in the same order is not
        // a micro-optimisation: reaping happens between the poll and the
        // routing, and a reaped Worker's output descriptor is closed as part
        // of it. A positional walk would then skip that Worker and read every
        // later slot's `revents` off by one.
        const out_first = n;
        for (self.workers, 0..) |w, i| {
            if (w.out_fd < 0) continue;
            fds[n] = .{ .fd = w.out_fd, .events = os.POLL.IN, .revents = 0 };
            self.poll_owner[n] = @intCast(i);
            n += 1;
        }
        const probe_first = n;
        for (self.workers, 0..) |w, i| {
            const p = w.probe orelse continue;
            const pf = p.pollFd() orelse continue;
            fds[n] = pf;
            self.poll_owner[n] = @intCast(i);
            n += 1;
        }
        const extra_first = n;
        for (extra) |e| {
            fds[n] = e;
            n += 1;
        }

        const timeout = self.nextTimeout(max_wait_ms);
        _ = try os.poll(fds[0..n], timeout);

        for (extra, 0..) |*e, i| e.revents = fds[extra_first + i].revents;

        if (fds[sig_slot].revents & os.POLL.IN != 0) {
            const seen = self.signals.drain();
            if (seen.quit) self.beginShutdown();
            if (seen.chld) self.reapAll();
            if (seen.winch) self.generation += 1;
        }

        // Route output. The descriptor is re-checked against the one that was
        // polled: reaping may have closed it, and a closed fd number can
        // already have been handed to something else.
        for (fds[out_first..probe_first], out_first..) |f, slot| {
            if (f.revents & (os.POLL.IN | os.POLL.HUP | os.POLL.ERR) == 0) continue;
            const i = self.poll_owner[slot];
            if (self.workers[i].out_fd != f.fd) continue;
            self.drain(i);
        }

        for (fds[probe_first..extra_first], probe_first..) |f, slot| {
            if (f.revents == 0) continue;
            const p = if (self.workers[self.poll_owner[slot]].probe) |*p| p else continue;
            // The attempt may have been abandoned since — a Worker that exited
            // resets its probe, closing this socket.
            const still = p.pollFd() orelse continue;
            if (still.fd != f.fd) continue;
            p.onPoll(f.revents);
            self.generation += 1;
        }

        self.advance();
        self.maybeSample();
    }

    /// One Sample per second across every Group, in a single pass over
    /// `/proc`. On a timer and never per frame — see sample.zig.
    fn maybeSample(self: *Supervisor) void {
        const now = os.nowMs();
        if (now < self.next_sample_ms) return;
        self.next_sample_ms = now + 1000;
        for (self.workers, self.pgid_scratch) |w, *p| p.* = w.pgid;
        self.sampler.sample(self.pgid_scratch, self.samples);
        self.generation += 1;
    }

    /// How long `poll` may sleep: the soonest deadline anything is waiting on.
    fn nextTimeout(self: *Supervisor, cap_ms: i32) i32 {
        const now = os.nowMs();
        var soonest: u64 = std.math.maxInt(u64);

        for (self.workers) |*w| {
            if (w.probe) |p| {
                if (w.state.alive()) soonest = @min(soonest, p.wakeAt());
            }
            if (w.state == .stopping) soonest = @min(soonest, w.kill_at_ms);
            if (w.restart_at_ms > 0 and w.state.terminal()) {
                soonest = @min(soonest, w.restart_at_ms);
            }
        }
        if (soonest == std.math.maxInt(u64)) return cap_ms;
        const wait = soonest -| now;
        return @intCast(@min(@as(u64, @intCast(@max(cap_ms, 0))), wait));
    }

    /// Reads everything a Worker has produced. Loops until `EAGAIN` so a burst
    /// is never left sitting in the pipe waiting for the next poll — that is
    /// what would make a chatty Worker feel laggy.
    fn drain(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        while (true) {
            const n = os.read(w.out_fd, self.read_buf) catch |err| switch (err) {
                error.WouldBlock => return,
                else => break,
            };
            if (n == 0) break; // writer closed: the Group is finished with it
            const chunk = self.read_buf[0..n];
            w.archive.append(chunk);
            self.generation += 1;

            if (!w.log_ready) {
                if (w.ready_scan) |*scan| {
                    if (scan.feed(chunk)) w.log_ready = true;
                }
            }
            if (n < self.read_buf.len) return;
        }
        // Hung up. Close now so the descriptor stops being polled; the exit
        // status still arrives separately via SIGCHLD.
        os.close(w.out_fd);
        w.out_fd = -1;
    }

    fn reapAll(self: *Supervisor) void {
        while (os.reap()) |r| {
            self.generation += 1;
            // A probe's Group, or the Worker's own?
            var claimed = false;
            for (self.workers) |*w| {
                if (w.probe) |*p| {
                    if (p.onReap(r.pid, r.exit)) {
                        claimed = true;
                        break;
                    }
                }
            }
            if (claimed) continue;

            for (self.workers, 0..) |*w, i| {
                if (w.pgid == r.pid and w.state.alive()) {
                    self.onWorkerExit(i, r.exit);
                    break;
                }
            }
            // Anything else is a grandchild we inherited as subreaper. Reaping
            // it is the entire job; it has no state of its own.
        }
    }

    fn onWorkerExit(self: *Supervisor, i: usize, exit: os.Exit) void {
        const w = &self.workers[i];
        const was_stopping = w.state == .stopping;
        w.exit = exit;
        w.stopped_ms = os.nowMs();
        w.pgid = 0;
        // A Worker we signalled did what it was told, however it died.
        w.state = if (was_stopping)
            .stopped
        else if (exit.ok()) .exited else .failed;
        if (w.probe) |*p| p.reset(w.stopped_ms);
        w.log_ready = false;

        // Drain whatever is still in the pipe before letting it go: a Worker's
        // last words are usually the reason it died.
        if (w.out_fd >= 0) self.drain(i);

        if (was_stopping or self.shutting_down) return;

        switch (w.spec.restart) {
            .no => {},
            .always => self.scheduleRestart(i),
            .on_failure => if (!exit.ok()) self.scheduleRestart(i),
            .exit_on_failure => if (!exit.ok()) {
                self.failed_hard = true;
                self.beginShutdown();
            },
        }
    }

    /// Exponential backoff, capped. The first restart is immediate enough to
    /// feel instant; a Worker that keeps dying backs off instead of pinning a
    /// core.
    fn scheduleRestart(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        w.restarts += 1;
        const shift: u6 = @intCast(@min(w.restarts, 8));
        const delay = @min(@as(u64, 100) << shift, 30_000);
        w.restart_at_ms = os.nowMs() + delay;
    }

    /// The state machine. Runs after every event, and is written to be
    /// idempotent: calling it twice with nothing changed does nothing twice.
    fn advance(self: *Supervisor) void {
        const now = os.nowMs();

        for (self.workers, 0..) |*w, i| {
            switch (w.state) {
                .pending => {
                    switch (self.dependencyStatus(i)) {
                        .satisfied => self.spawn(i),
                        .waiting => {},
                        .impossible => {
                            w.state = .skipped;
                            self.generation += 1;
                        },
                    }
                },
                .running, .ready => {
                    if (w.probe) |*p| {
                        p.tick(now, .{
                            .envp = w.envp,
                            .cwd = w.cwd,
                            .devnull = self.devnull,
                        });
                        p.checkTimeout(now);
                        const want: State = if (p.ready) .ready else .running;
                        if (w.state != want) {
                            w.state = want;
                            self.generation += 1;
                        }
                    }
                },
                .stopping => {
                    if (now >= w.kill_at_ms) {
                        // The grace period is over. The Group, not the pid.
                        os.killGroup(w.pgid, .KILL);
                        // Re-arm so a Group wedged in uninterruptible sleep is
                        // signalled again rather than spinning the loop.
                        w.kill_at_ms = now + 1000;
                    }
                },
                .exited, .stopped, .failed => {
                    if (w.restart_at_ms > 0 and now >= w.restart_at_ms and !self.shutting_down) {
                        w.restart_at_ms = 0;
                        w.state = .pending;
                        self.generation += 1;
                    }
                },
                .skipped => {},
            }
        }

        if (self.shutting_down) self.advanceShutdown();
    }

    const DepStatus = enum { satisfied, waiting, impossible };

    /// Whether Worker `i` may start. `impossible` is the important one: a
    /// dependency that can no longer reach the required condition means this
    /// Worker must be marked skipped, not left pending forever with nothing on
    /// screen to explain the silence.
    fn dependencyStatus(self: *Supervisor, i: usize) DepStatus {
        var worst: DepStatus = .satisfied;
        for (self.workers[i].spec.depends_on, self.dep_targets[i]) |dep, target| {
            if (target == unresolved_dep) continue; // validated at load
            const d = &self.workers[target];
            const one: DepStatus = switch (dep.condition) {
                .process_started => if (d.has_started)
                    .satisfied
                else if (d.state == .skipped) .impossible else .waiting,

                .process_completed => switch (d.state) {
                    .exited, .failed, .stopped => .satisfied,
                    .skipped => .impossible,
                    else => .waiting,
                },

                .process_completed_successfully => switch (d.state) {
                    .exited => .satisfied,
                    // A Gate that failed will not succeed by being waited on
                    // longer. Restart policy may yet revive it, so only a
                    // terminal-and-not-restarting failure is impossible.
                    .failed, .stopped => if (d.restart_at_ms > 0) .waiting else .impossible,
                    .skipped => .impossible,
                    else => .waiting,
                },

                .process_healthy => if (d.state == .ready)
                    .satisfied
                else if (d.state == .skipped) .impossible else .waiting,

                .process_log_ready => if (d.log_ready)
                    .satisfied
                else if (d.state == .skipped) .impossible else .waiting,
            };
            if (one == .impossible) return .impossible;
            if (one == .waiting) worst = .waiting;
        }
        return worst;
    }

    fn spawn(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];

        // The Worker writes into this pipe and we read the other end.
        //
        // Only the *read* end is made non-blocking, and that distinction is
        // load-bearing. `O_NONBLOCK` is a property of the open file
        // description, not of the descriptor, and `dup2` shares the
        // description rather than copying its flags — so creating the pipe
        // with `O_NONBLOCK` hands the child a non-blocking stdout. A Worker
        // that then out-paces the loop gets `EAGAIN` from `write` and dies:
        // `cat` exits 1, and most programs do something similar.
        //
        // A pipe's two ends are separate descriptions, so setting the flag on
        // ours leaves the child's alone. The child blocks when the pipe fills,
        // which is the backpressure a terminal would have given it anyway.
        const fds = os.pipe(.{ .CLOEXEC = true }) catch {
            w.state = .failed;
            return;
        };
        os.setNonblock(fds[0], true);

        const child = os.spawn(.{
            .path = self.shell.path,
            .argv = w.argv,
            .envp = w.envp,
            .cwd = w.cwd,
            .output = fds[1],
            .input = self.devnull,
        }) catch {
            os.close(fds[0]);
            os.close(fds[1]);
            w.state = .failed;
            w.exit = .{ .exited = 127 };
            self.generation += 1;
            return;
        };

        // Our copy of the write end must go, or the read end never reports EOF
        // when the Group finally exits.
        os.close(fds[1]);

        w.out_fd = fds[0];
        w.pgid = child.pgid;
        w.state = .running;
        w.has_started = true;
        w.exit = null;
        w.started_ms = os.nowMs();
        if (w.probe) |*p| p.reset(w.started_ms);
        if (w.ready_scan) |*s| s.carry_len = 0;
        self.generation += 1;
    }

    // --------------------------------------------------------- shutdown

    pub fn beginShutdown(self: *Supervisor) void {
        if (self.shutting_down) return;
        self.shutting_down = true;
        self.generation += 1;
        // A Worker still waiting to start never will.
        for (self.workers) |*w| {
            if (w.state == .pending) w.state = .skipped;
            w.restart_at_ms = 0;
        }
        self.advanceShutdown();
    }

    /// Stops Workers in reverse dependency order, without a layer index: a
    /// Worker may be signalled once everything that depends on it is terminal.
    ///
    /// This always finishes. Every ladder ends in SIGKILL, so each dependent
    /// reaches a terminal state in bounded time, which unblocks the Worker
    /// below it — the API goes down before the database it is talking to.
    fn advanceShutdown(self: *Supervisor) void {
        const now = os.nowMs();
        for (self.workers, 0..) |*w, i| {
            if (w.state != .running and w.state != .ready) continue;
            if (!self.dependentsFinished(i)) continue;

            os.killGroup(w.pgid, @enumFromInt(w.spec.shutdown.signal));
            w.state = .stopping;
            w.kill_at_ms = now + @as(u64, w.spec.shutdown.timeout_seconds) * 1000;
            self.generation += 1;
        }
    }

    fn dependentsFinished(self: *Supervisor, i: usize) bool {
        for (self.dependents[i]) |d| {
            if (!self.workers[d].state.terminal()) return false;
        }
        return true;
    }

    /// True when there is nothing left to wait for.
    pub fn done(self: *Supervisor) bool {
        for (self.workers) |w| {
            if (!w.state.terminal()) return false;
            // A Worker with a restart pending is terminal only for the moment.
            if (w.restart_at_ms > 0 and !self.shutting_down) return false;
        }
        return true;
    }

    /// Asks a single Worker to stop, as the control socket's `stop` does.
    pub fn stopWorker(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        w.restart_at_ms = 0;
        if (!w.state.alive() or w.state == .stopping) return;
        os.killGroup(w.pgid, @enumFromInt(w.spec.shutdown.signal));
        w.state = .stopping;
        w.kill_at_ms = os.nowMs() + @as(u64, w.spec.shutdown.timeout_seconds) * 1000;
        self.generation += 1;
    }

    /// Puts a terminal Worker back in the queue. Its dependencies are checked
    /// again on the next pass, so starting one by hand cannot bypass the graph.
    pub fn startWorker(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        if (!w.state.terminal()) return;
        w.state = .pending;
        w.restart_at_ms = 0;
        w.restarts = 0;
        self.generation += 1;
    }

    pub fn restartWorker(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        if (w.state.terminal()) return self.startWorker(i);
        self.stopWorker(i);
        // Come back as soon as the old Group is reaped, not on a timer.
        w.restart_at_ms = 1;
        w.restarts = 0;
    }
};

// ------------------------------------------------------------- setup helpers

fn buildArgv(
    arena: Allocator,
    shell_path: [*:0]const u8,
    shell_arg: []const u8,
    command: []const u8,
) ![*:null]const ?[*:0]const u8 {
    const argv = try arena.allocSentinel(?[*:0]const u8, 3, null);
    argv[0] = shell_path;
    argv[1] = (try arena.dupeZ(u8, shell_arg)).ptr;
    argv[2] = (try arena.dupeZ(u8, command)).ptr;
    return argv.ptr;
}

/// Layers the environment the way process-compose does: the OS environment
/// first, then each `dotenv` file, then the explicit `environment` list. Later
/// layers win, so a value written in the config beats one inherited from the
/// shell that launched devrun.
fn buildEnv(
    arena: Allocator,
    opts: Options,
    spec: *const config.Worker,
    diag: ?*Diagnostic,
    gpa: Allocator,
) ![*:null]const ?[*:0]const u8 {
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

    var it = opts.environ.iterator();
    while (it.next()) |kv| {
        try map.put(arena, kv.key_ptr.*, kv.value_ptr.*);
    }

    for (spec.dotenv) |file| {
        const path = try std.fs.path.join(arena, &.{ opts.base_dir, file });
        const text = std.Io.Dir.cwd().readFileAlloc(
            opts.io,
            path,
            arena,
            .limited(4 << 20),
        ) catch {
            // An explicitly named dotenv that is missing is a mistake worth
            // reporting: the config asked for it by name.
            return Supervisor.failWith(gpa, diag, "processes.{s}.dotenv: cannot read {s}", .{
                spec.name, path,
            });
        };
        try parseDotenv(arena, text, &map);
    }

    for (spec.environment) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try map.put(arena, entry[0..eq], entry[eq + 1 ..]);
    }

    const envp = try arena.allocSentinel(?[*:0]const u8, map.count(), null);
    for (map.keys(), map.values(), 0..) |k, v, i| {
        envp[i] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ k, v }, 0)).ptr;
    }
    return envp.ptr;
}

fn parseDotenv(
    arena: Allocator,
    text: []const u8,
    map: *std.StringArrayHashMapUnmanaged([]const u8),
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

fn resolveCwd(arena: Allocator, base_dir: []const u8, working_dir: ?[]const u8) !?[*:0]const u8 {
    const dir = working_dir orelse return null;
    if (std.fs.path.isAbsolute(dir)) return (try arena.dupeZ(u8, dir)).ptr;
    const joined = try std.fs.path.join(arena, &.{ base_dir, dir });
    return (try arena.dupeZ(u8, joined)).ptr;
}

/// Stands in for a `depends_on` naming a Worker that is not in the config.
/// `checkDependencies` rejects those at load, so this is unreachable in
/// practice — but the state machine must not index `workers` with it if it
/// ever is.
const unresolved_dep = std.math.maxInt(u32);

/// Resolves every `depends_on` name to a Worker index once, so the state
/// machine never compares strings.
fn buildDepTargets(arena: Allocator, cfg: *const config.Config) ![][]const u32 {
    const out = try arena.alloc([]const u32, cfg.workers.len);
    for (cfg.workers, out) |w, *slot| {
        const targets = try arena.alloc(u32, w.depends_on.len);
        for (w.depends_on, targets) |dep, *t| {
            t.* = if (cfg.find(dep.name)) |j| @intCast(j) else unresolved_dep;
        }
        slot.* = targets;
    }
    return out;
}

/// Inverts the dependency edges once, so shutdown can ask "who is waiting on
/// this?" in O(dependents) rather than rescanning every Worker's `depends_on`.
fn buildDependents(arena: Allocator, workers: []const config.Worker) ![][]const u32 {
    const n = workers.len;
    const counts = try arena.alloc(u32, n);
    @memset(counts, 0);

    for (workers) |w| {
        for (w.depends_on) |dep| {
            for (workers, 0..) |other, j| {
                if (std.mem.eql(u8, other.name, dep.name)) counts[j] += 1;
            }
        }
    }

    const out = try arena.alloc([]const u32, n);
    const fill = try arena.alloc([]u32, n);
    for (counts, 0..) |c, i| {
        fill[i] = try arena.alloc(u32, c);
        counts[i] = 0;
    }
    for (workers, 0..) |w, i| {
        for (w.depends_on) |dep| {
            for (workers, 0..) |other, j| {
                if (!std.mem.eql(u8, other.name, dep.name)) continue;
                fill[j][counts[j]] = @intCast(i);
                counts[j] += 1;
            }
        }
    }
    for (fill, 0..) |f, i| out[i] = f;
    return out;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "ReadyScan finds a marker split across two chunks" {
    var scan = ReadyScan{ .needle = "ready to accept" };

    try testing.expect(!scan.feed("starting up\nalmost rea"));
    // The tail of the previous chunk is what completes the match.
    try testing.expect(scan.feed("dy to accept connections\n"));

    // And a marker wholly inside one chunk still matches.
    var scan2 = ReadyScan{ .needle = "LISTEN" };
    try testing.expect(scan2.feed("now LISTENing on :8080\n"));

    // A near miss stays a miss, however the bytes are cut up.
    var scan3 = ReadyScan{ .needle = "ready" };
    try testing.expect(!scan3.feed("read"));
    try testing.expect(!scan3.feed("iness\n"));
    try testing.expect(scan3.feed("y? ready\n"));
}

test "ReadyScan is not fooled by a chunk shorter than the marker" {
    var scan = ReadyScan{ .needle = "abcdef" };
    // Fed one byte at a time, the carry has to reassemble the whole marker.
    for ("xxabcde") |c| {
        try testing.expect(!scan.feed(&[_]u8{c}));
    }
    try testing.expect(scan.feed("f"));
}

test "buildDependents inverts the graph" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    const workers = [_]config.Worker{
        .{ .name = "db", .command = "postgres" },
        .{ .name = "api", .command = "go run .", .depends_on = &.{
            .{ .name = "db", .condition = .process_started },
        } },
        .{ .name = "web", .command = "vite", .depends_on = &.{
            .{ .name = "db", .condition = .process_started },
            .{ .name = "api", .condition = .process_started },
        } },
    };

    const deps = try buildDependents(arena_state.allocator(), &workers);
    // Both api and web wait on db, so db must be stopped last.
    try testing.expectEqualSlices(u32, &.{ 1, 2 }, deps[0]);
    try testing.expectEqualSlices(u32, &.{2}, deps[1]);
    try testing.expectEqual(@as(usize, 0), deps[2].len);
}

/// Runs a whole Session against real processes and returns the Supervisor for
/// inspection. Spawning is cheap enough that testing the state machine against
/// the kernel beats testing it against a mock of the kernel — the interesting
/// bugs in a supervisor are all in the seam.
fn runToCompletion(
    gpa: Allocator,
    cfg: *config.Config,
    dir: []const u8,
    timeout_ms: u64,
) !Supervisor {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/local/bin:/usr/bin:/bin");

    var sup = try Supervisor.init(gpa, cfg, .{
        .io = threaded.io(),
        .environ = &environ,
        .base_dir = dir,
        .log_dir = dir,
        // Small Windows so the test exercises the same ring the real thing
        // uses rather than a capacity nothing ever wraps.
        .window_budget = 256 << 10,
    }, null);
    errdefer sup.deinit();

    const deadline = os.nowMs() + timeout_ms;
    while (!sup.done() and os.nowMs() < deadline) {
        try sup.step(&.{}, 25);
    }
    return sup;
}

/// A scratch directory for one test's Archives.
fn tempDir(gpa: Allocator, tag: []const u8) ![]u8 {
    const dir = try std.fmt.allocPrint(gpa, "/tmp/devrun-it-{s}-{d}", .{ tag, os.nowMs() });
    try os.makePath(dir);
    return dir;
}

fn loadCfg(gpa: Allocator, src: []const u8) !config.Config {
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    return config.loadSource(gpa, src, "/nonexistent", .{
        .io = threaded.io(),
        .environ = &environ,
    }, null);
}

test "a Gate runs to completion before its dependant starts" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "gate");
    defer gpa.free(dir);

    var cfg = try loadCfg(gpa,
        \\processes:
        \\  gate:
        \\    command: "echo gate-ran"
        \\  after:
        \\    command: "echo after-ran"
        \\    depends_on:
        \\      gate:
        \\        condition: process_completed_successfully
        \\
    );
    defer cfg.deinit();

    var sup = try runToCompletion(gpa, &cfg, dir, 10_000);
    defer sup.deinit();

    try testing.expectEqual(State.exited, sup.workers[0].state);
    try testing.expectEqual(State.exited, sup.workers[1].state);
    // Both ran, and the dependant's Archive proves it was actually reached
    // rather than skipped into a terminal state.
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("gate-ran", sup.workers[0].archive.lineInto(0, &buf));
    var buf2: [64]u8 = undefined;
    try testing.expectEqualStrings("after-ran", sup.workers[1].archive.lineInto(0, &buf2));
}

test "a Gate that fails leaves its dependant skipped, not waiting forever" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "skip");
    defer gpa.free(dir);

    var cfg = try loadCfg(gpa,
        \\processes:
        \\  gate:
        \\    command: "exit 3"
        \\  after:
        \\    command: "echo SHOULD-NOT-RUN"
        \\    depends_on:
        \\      gate:
        \\        condition: process_completed_successfully
        \\
    );
    defer cfg.deinit();

    // The whole point: this returns rather than hitting the timeout.
    var sup = try runToCompletion(gpa, &cfg, dir, 10_000);
    defer sup.deinit();

    try testing.expect(sup.done());
    try testing.expectEqual(State.failed, sup.workers[0].state);
    try testing.expectEqual(@as(u8, 3), sup.workers[0].exit.?.exited);
    try testing.expectEqual(State.skipped, sup.workers[1].state);
    // Skipped means never spawned, so nothing was written.
    try testing.expectEqual(@as(u64, 0), sup.workers[1].archive.len());
}

test "output reaches the Archive byte-for-byte, ANSI included" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "ansi");
    defer gpa.free(dir);

    var cfg = try loadCfg(gpa,
        \\processes:
        \\  noisy:
        \\    command: "printf 'plain\nESC[31mred\n'"
        \\
    );
    defer cfg.deinit();

    var sup = try runToCompletion(gpa, &cfg, dir, 10_000);
    defer sup.deinit();

    try testing.expectEqual(State.exited, sup.workers[0].state);
    const a = &sup.workers[0].archive;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("plain", a.lineInto(0, &buf));
    // The escape-looking text survives untouched: nothing between the pipe
    // and the file interprets what a Worker wrote.
    var buf2: [64]u8 = undefined;
    try testing.expectEqualStrings("ESC[31mred", a.lineInto(a.lastLineStart(), &buf2));
}

test "a Worker that out-runs the loop is throttled, not killed" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "backpressure");
    defer gpa.free(dir);

    // Far more than a pipe holds (64 KiB), written as fast as the shell can.
    // If the child inherits a non-blocking stdout it gets EAGAIN once the
    // pipe fills and dies — `yes | head` exits 1 after exactly one buffer.
    // The Worker blocking instead is the entire point.
    var cfg = try loadCfg(gpa,
        \\processes:
        \\  firehose:
        \\    command: "yes 0123456789abcdef0123456789abcdef | head -c 4000000"
        \\
    );
    defer cfg.deinit();

    var sup = try runToCompletion(gpa, &cfg, dir, 30_000);
    defer sup.deinit();

    const w = &sup.workers[0];
    try testing.expectEqual(State.exited, w.state);
    try testing.expectEqual(@as(u8, 0), w.exit.?.exited);
    // Every byte arrived, across many more reads than the Window can hold.
    try testing.expectEqual(@as(u64, 4_000_000), w.archive.len());
    try testing.expect(w.archive.window.end > w.archive.window.buf.len);

    // And the Archive is still readable at both ends: the start comes from
    // the file, the end from the Window.
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef",
        w.archive.lineInto(0, &buf),
    );
}

test "a Group's grandchildren are killed with it, not orphaned" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "group");
    defer gpa.free(dir);

    var cfg = try loadCfg(gpa,
        \\processes:
        \\  parent:
        \\    command: "sleep 120 & echo spawned; wait"
        \\    shutdown:
        \\      timeout_seconds: 1
        \\
    );
    defer cfg.deinit();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/local/bin:/usr/bin:/bin");

    var sup = try Supervisor.init(gpa, &cfg, .{
        .io = threaded.io(),
        .environ = &environ,
        .base_dir = dir,
        .log_dir = dir,
    }, null);
    defer sup.deinit();

    // Bring it up and wait until the inner `sleep` exists.
    var deadline = os.nowMs() + 5000;
    while (os.nowMs() < deadline and sup.workers[0].archive.len() == 0) {
        try sup.step(&.{}, 25);
    }
    const pgid = sup.workers[0].pgid;
    try testing.expect(pgid > 0);

    sup.beginShutdown();
    deadline = os.nowMs() + 10_000;
    while (!sup.done() and os.nowMs() < deadline) {
        try sup.step(&.{}, 25);
    }

    try testing.expectEqual(State.stopped, sup.workers[0].state);

    // The `sleep 120` was a grandchild; signalling only the shell's pid would
    // have left it running for two minutes.
    //
    // Keep stepping while checking: a killed grandchild is a zombie until
    // something reaps it, and `kill(-pgid, 0)` succeeds on zombies. Because
    // devrun is a subreaper the grandchild is reparented to it, so it is our
    // own loop that has to collect it — asserting the instant the Worker went
    // terminal would be racing that.
    deadline = os.nowMs() + 5000;
    while (os.nowMs() < deadline and os.groupAlive(pgid)) {
        try sup.step(&.{}, 25);
    }
    try testing.expect(!os.groupAlive(pgid));
}

test "State classifies terminal and alive without overlap" {
    for ([_]State{ .exited, .failed, .skipped }) |s| {
        try testing.expect(s.terminal());
        try testing.expect(!s.alive());
    }
    for ([_]State{ .running, .ready, .stopping }) |s| {
        try testing.expect(s.alive());
        try testing.expect(!s.terminal());
    }
    // Pending is neither: it has not run, but it still might.
    try testing.expect(!State.pending.terminal());
    try testing.expect(!State.pending.alive());
}
