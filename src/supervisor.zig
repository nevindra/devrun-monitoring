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
const watch_mod = @import("watch.zig");

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
    /// Not part of this run yet: left out by `up NAME`, a profile, or
    /// `autostart = false`. Not a failure and not waiting; `start` brings it in.
    off,

    pub fn terminal(self: State) bool {
        return switch (self) {
            .exited, .stopped, .failed, .skipped, .off => true,
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

/// The exit status devrun itself should have when it takes on a Worker's: its
/// own code, or 128 plus the signal as a shell reports it. A Worker with no
/// status (it never started) is 1.
pub fn exitStatus(exit: ?os.Exit) u8 {
    const e = exit orelse return 1;
    return switch (e) {
        .exited => |code| code,
        .signaled => |s| @intCast(128 +| @backingInt(s)),
    };
}

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

    /// Set once the Worker has ever been spawned. `started` asks about
    /// this rather than the current state, because a Gate that already ran and
    /// exited did, in fact, start.
    has_started: bool = false,
    log_ready: bool = false,
    exit: ?os.Exit = null,
    started_ms: u64 = 0,
    stopped_ms: u64 = 0,

    /// Restarts since the last manual start, automatic or watch-driven. This
    /// is what `status` shows; it only goes up, so a Worker that flaps stays
    /// visibly flapping even after a long healthy run.
    restarts: u32 = 0,
    /// Automatic restarts in a row, which is what `restart.max` is measured
    /// against. A run that lasted 30 s resets it. Kept apart from `restarts`
    /// so that forgiving a good run does not also erase the evidence.
    streak: u32 = 0,
    /// When a restart may happen. Backoff exists because a Worker that fails
    /// instantly under `restart: always` would otherwise spin the loop at
    /// 100% CPU. There is no field for it yet, so devrun derives one.
    restart_at_ms: u64 = 0,
    /// When the ladder escalates from the configured signal to SIGKILL.
    kill_at_ms: u64 = 0,

    // Precomputed once, so spawning allocates nothing.
    argv: [*:null]const ?[*:0]const u8 = undefined,
    envp: [*:null]const ?[*:0]const u8 = undefined,
    cwd: ?[*:0]const u8 = null,

    // `stop.command`, if the Worker has one.
    stop_argv: ?[*:null]const ?[*:0]const u8 = null,
    /// Group of the running stop command, zero when none is.
    stop_pgid: os.Pid = 0,
    /// When a stop command that is still running gets killed.
    stop_deadline_ms: u64 = 0,
    /// The stop command has been tried since the Worker last spawned. Tried,
    /// not succeeded: a command that fails to launch must not be retried on
    /// every pass of the shutdown ladder.
    stop_ran: bool = false,
    /// `stop.signal` is owed once the stop command has finished.
    signal_pending: bool = false,

    pub fn name(self: Runtime) []const u8 {
        return self.spec.name;
    }
};

pub const Options = struct {
    io: std.Io,
    environ: *const std.process.Environ.Map,
    /// Directory the config was read from; `env_file` paths and the default
    /// working directory resolve against it.
    base_dir: []const u8,
    /// Where this Session's Archives are written — its own directory under
    /// `log_root`, made by `store.openSession`.
    log_dir: []const u8,
    /// The directory those Session directories live in. Carried so a view can
    /// offer to tidy up every Session on the way out, not only this one.
    log_root: []const u8 = "",
    /// What to call this Session on screen. The directory the config was read
    /// from, which is what a reader has several of open at once.
    project: []const u8 = "",
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
    /// Where this Session's Archives are. Kept so a view can tell the reader
    /// which file it is looking at — the answer to "can I send you this log?"
    /// is a path, and it should not be something they have to already know.
    log_dir: []const u8,
    /// Where every Session's Archives live, this one's included.
    log_root: []const u8,
    /// What this Session is called on screen.
    project: []const u8,

    shutting_down: bool = false,
    /// The Worker whose `exit-on-end` policy ended this Session, so the
    /// process can exit with its status.
    ended_by: ?usize = null,
    watcher: watch_mod.Watcher,
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
            const index_path = try std.fmt.allocPrintSentinel(
                arena,
                "{s}/{s}.idx",
                .{ opts.log_dir, spec.name },
                0,
            );
            rt.* = .{
                .spec = spec,
                .state = if (spec.autostart) .pending else .off,
                .archive = Archive.create(gpa, path.ptr, index_path.ptr, window_bytes) catch {
                    return failWith(gpa, diag, "cannot write Archive {s}", .{path});
                },
            };
            made += 1;

            rt.argv = try buildArgv(arena, shell_path.ptr, cfg.shell.argument, spec.command);
            rt.envp = try buildEnv(arena, opts, spec, cfg.color, diag, gpa);
            rt.cwd = try resolveCwd(arena, opts.base_dir, spec.working_dir);
            if (spec.shutdown.command) |cmd| {
                rt.stop_argv = try buildArgv(arena, shell_path.ptr, cfg.shell.argument, cmd);
            }

            if (spec.ready_log_line) |line| {
                if (line.len == 0 or line.len > ReadyScan.max_needle) {
                    return failWith(
                        gpa,
                        diag,
                        "services.{s}.ready.log must be 1..{d} bytes",
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
                    return failWith(gpa, diag, "services.{s}.ready: {s}", .{
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

        // Paths are relative to the Worker's cwd. A Worker with none inherits
        // devrun's, but the config's directory is what its other relative
        // paths mean, so that is the base.
        var targets: std.ArrayList(watch_mod.Target) = .empty;
        for (cfg.workers, workers, 0..) |spec, rt, i| {
            const wt = spec.watch orelse continue;
            try targets.append(arena, .{
                .worker = @intCast(i),
                .base = if (rt.cwd) |c| std.mem.span(c) else opts.base_dir,
                .paths = wt.paths,
                .ignore = wt.ignore,
                .debounce_ms = wt.debounce_ms,
            });
        }
        var watcher = try watch_mod.Watcher.init(gpa, targets.items, n);
        errdefer watcher.deinit();

        var signals = try os.Signals.install(&.{ .CHLD, .INT, .TERM, .HUP, .WINCH });
        errdefer signals.deinit();

        // Orphaned grandchildren come back to us instead of escaping to PID 1,
        // so a Worker that daemonises is still part of its Group's accounting.
        os.becomeSubreaper();

        // Everything that allocates from the arena comes before the struct
        // copies it: a chunk the arena grows after the copy would belong to
        // a state nobody holds, and `deinit` would never free it.
        const log_dir = try arena.dupe(u8, opts.log_dir);
        const log_root = try arena.dupe(u8, opts.log_root);
        const project = try arena.dupe(u8, opts.project);
        // Worst case each Worker contributes an output pipe (a stop command's
        // reuses that slot) and a probe socket, plus the signal pipe, the
        // watcher, and room for the caller's own.
        const poll_buf = try arena.alloc(os.PollFd, 2 * n + 24);
        const poll_owner = try arena.alloc(u32, 2 * n + 24);
        const read_buf = try gpa.alloc(u8, 64 << 10);
        errdefer gpa.free(read_buf);
        const sampler = try sample_mod.Sampler.init(gpa, n);

        return .{
            .gpa = gpa,
            .arena = arena_state,
            .cfg = cfg,
            .workers = workers,
            .dependents = dependents,
            .dep_targets = dep_targets,
            .watcher = watcher,
            .signals = signals,
            .devnull = devnull,
            .shell = .{ .path = shell_path.ptr, .argument = cfg.shell.argument },
            .log_dir = log_dir,
            .log_root = log_root,
            .project = project,
            .poll_buf = poll_buf,
            .poll_owner = poll_owner,
            .read_buf = read_buf,
            .sampler = sampler,
            .samples = try gpa.alloc(sample_mod.Sample, n),
            .pgid_scratch = try gpa.alloc(os.Pid, n),
        };
    }

    pub fn deinit(self: *Supervisor) void {
        for (self.workers) |*w| {
            if (w.out_fd >= 0) os.close(w.out_fd);
            w.archive.deinit(self.gpa);
        }
        self.watcher.deinit();
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
        const watch_first = n;
        if (self.watcher.pollFd()) |pf| {
            fds[n] = pf;
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

        if (watch_first < extra_first and fds[watch_first].revents != 0) {
            self.watcher.onReadable(os.nowMs());
        }

        for (fds[probe_first..watch_first], probe_first..) |f, slot| {
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
            if (w.stop_pgid != 0) soonest = @min(soonest, w.stop_deadline_ms);
            if (w.restart_at_ms > 0 and w.state.terminal()) {
                soonest = @min(soonest, w.restart_at_ms);
            }
        }
        if (self.watcher.wakeAt()) |t| soonest = @min(soonest, t);
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
            // A stop command's Group first: it belongs to a Worker by name
            // but is not the Worker, and must never be taken for it.
            var claimed = false;
            for (self.workers, 0..) |*w, i| {
                if (w.stop_pgid == r.pid) {
                    self.onStopExit(i);
                    claimed = true;
                    break;
                }
            }
            if (claimed) continue;

            // A probe's Group, or the Worker's own?
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
        w.signal_pending = false;
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
            .exit_on_end => {
                self.ended_by = i;
                self.beginShutdown();
            },
        }
    }

    /// A stop command finished (or was killed). If the Worker is still up,
    /// the command was a courtesy and the configured signal is now due.
    fn onStopExit(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        w.stop_pgid = 0;
        // Its output is in the pipe already; take it before the pipe is
        // forgotten, or the last line of a cleanup never reaches the log.
        if (w.out_fd >= 0) self.drain(i);
        if (w.state == .stopping and w.signal_pending and w.pgid != 0) {
            os.killGroup(w.pgid, @fromBackingInt(@intCast(w.spec.shutdown.signal)));
        }
        w.signal_pending = false;
        self.generation += 1;
    }

    /// Exponential backoff from `restart.backoff`, capped at 30 s (or the
    /// backoff itself, if that is longer), so a Worker that keeps dying backs
    /// off instead of pinning a core. With `restart.max` set, the Worker is
    /// left as it died once that many restarts have happened in a row.
    fn scheduleRestart(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        // A long healthy run earns a clean slate.
        if (w.stopped_ms -| w.started_ms >= 30_000) w.streak = 0;
        if (w.spec.restart_max > 0 and w.streak >= w.spec.restart_max) return;

        const base: u64 = w.spec.restart_backoff_ms;
        const shift: u6 = @intCast(@min(w.streak, 16));
        const delay = @min(base << shift, @max(base, 30_000));
        w.streak += 1;
        w.restarts += 1;
        w.restart_at_ms = os.nowMs() + delay;
    }

    /// The state machine. Runs after every event, and is written to be
    /// idempotent: calling it twice with nothing changed does nothing twice.
    fn advance(self: *Supervisor) void {
        const now = os.nowMs();

        for (self.workers, 0..) |*w, i| {
            // A stop command is bounded by the same timeout as the stop it is
            // part of. Re-armed like the Worker's own kill, for the same reason.
            if (w.stop_pgid != 0 and now >= w.stop_deadline_ms) {
                os.killGroup(w.stop_pgid, .KILL);
                w.stop_deadline_ms = now + 1000;
            }
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
                .skipped, .off => {},
            }
        }

        // A debounce that elapsed. Drained even during shutdown, or its
        // deadline would stay in the past and keep the poll timeout at zero.
        while (self.watcher.takeDue(now)) |wi| {
            if (self.shutting_down) continue;
            const w = &self.workers[wi];
            switch (w.state) {
                .off, .pending => {},
                else => self.watchRestart(wi),
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
            // Left out of this run on purpose (`--no-deps`), so there is
            // nothing to wait for. Starting one by hand pulls its off
            // dependencies in first, which is why this is not a deadlock.
            if (d.state == .off) continue;
            const one: DepStatus = switch (dep.condition) {
                .started => if (d.has_started)
                    .satisfied
                else if (d.state == .skipped) .impossible else .waiting,

                .exited => switch (d.state) {
                    .exited, .failed, .stopped => .satisfied,
                    .skipped => .impossible,
                    else => .waiting,
                },

                .succeeded => switch (d.state) {
                    .exited => .satisfied,
                    // A Gate that failed will not succeed by being waited on
                    // longer. Restart policy may yet revive it, so only a
                    // terminal-and-not-restarting failure is impossible.
                    .failed, .stopped => if (d.restart_at_ms > 0) .waiting else .impossible,
                    .skipped => .impossible,
                    else => .waiting,
                },

                // A probe answers through the state, a log line through its
                // own flag. The config never gives one Worker both.
                .ready => if ((d.spec.readiness_probe != null and d.state == .ready) or
                    (d.spec.readiness_probe == null and d.log_ready))
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

        // A stop command's pipe may still be here; its writer is gone or about
        // to be, and the new Group needs the slot.
        if (w.out_fd >= 0) os.close(w.out_fd);
        w.out_fd = fds[0];
        w.pgid = child.pgid;
        w.stop_ran = false;
        w.signal_pending = false;
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
    /// Worker may be stopped once everything that depends on it is settled,
    /// which includes its own stop command having finished.
    ///
    /// This always finishes. Every ladder ends in SIGKILL, and a stop command
    /// is killed at the same deadline, so each dependent reaches a settled
    /// state in bounded time, which unblocks the Worker below it. The API goes
    /// down before the database it is talking to.
    fn advanceShutdown(self: *Supervisor) void {
        const now = os.nowMs();
        for (self.workers, 0..) |*w, i| {
            if (!self.dependentsFinished(i)) continue;
            switch (w.state) {
                .running, .ready => self.beginStop(i, now),
                // Gone already, but a stop command may still owe it a cleanup.
                .exited, .stopped, .failed, .skipped => _ = self.startStopCommand(i, now),
                .pending, .stopping, .off => {},
            }
        }
    }

    /// Settled: terminal, and no stop command running or still to run.
    fn dependentsFinished(self: *Supervisor, i: usize) bool {
        for (self.dependents[i]) |d| {
            const x = &self.workers[d];
            if (!x.state.terminal() or x.stop_pgid != 0 or stopOwed(x)) return false;
        }
        return true;
    }

    fn stopOwed(w: *const Runtime) bool {
        return w.spec.shutdown.command != null and w.has_started and !w.stop_ran;
    }

    /// Starts the Worker's `stop.command` unless it has run, or is running.
    /// Returns whether one is now in flight.
    ///
    /// Its output goes to the Worker's Archive when the Worker's own pipe has
    /// closed (a new pipe takes the slot, so `drain` picks it up like any other
    /// output) and to /dev/null otherwise, because a live pipe has a Group
    /// writing into it and interleaving a second writer there would garble both.
    fn startStopCommand(self: *Supervisor, i: usize, now: u64) bool {
        const w = &self.workers[i];
        if (w.stop_pgid != 0) return true;
        if (!stopOwed(w)) return false;
        w.stop_ran = true;
        const argv = w.stop_argv orelse return false;

        var out: os.Fd = self.devnull;
        var read_end: os.Fd = -1;
        if (w.out_fd < 0) {
            if (os.pipe(.{ .CLOEXEC = true })) |fds| {
                os.setNonblock(fds[0], true);
                read_end = fds[0];
                out = fds[1];
            } else |_| {}
        }

        const child = os.spawn(.{
            .path = self.shell.path,
            .argv = argv,
            .envp = w.envp,
            .cwd = w.cwd,
            .output = out,
            .input = self.devnull,
        }) catch {
            if (read_end >= 0) {
                os.close(read_end);
                os.close(out);
            }
            return false;
        };
        if (read_end >= 0) {
            os.close(out);
            w.out_fd = read_end;
        }
        w.stop_pgid = child.pgid;
        w.stop_deadline_ms = now + @as(u64, w.spec.shutdown.timeout_seconds) * 1000;
        self.generation += 1;
        return true;
    }

    /// Moves a live Worker onto the ladder: the stop command first if it has
    /// one (the signal follows when it finishes), else the signal at once.
    fn beginStop(self: *Supervisor, i: usize, now: u64) void {
        const w = &self.workers[i];
        w.state = .stopping;
        w.kill_at_ms = now + @as(u64, w.spec.shutdown.timeout_seconds) * 1000;
        w.signal_pending = self.startStopCommand(i, now);
        if (!w.signal_pending) {
            os.killGroup(w.pgid, @fromBackingInt(@intCast(w.spec.shutdown.signal)));
        }
        self.generation += 1;
    }

    /// True when there is nothing left to wait for.
    pub fn done(self: *Supervisor) bool {
        for (self.workers) |*w| {
            if (!w.state.terminal()) return false;
            if (w.stop_pgid != 0) return false;
            // A cleanup still owed is work; not yet started only matters once
            // the ladder is the thing that will start it.
            if (self.shutting_down and stopOwed(w)) return false;
            // A Worker with a restart pending is terminal only for the moment.
            if (w.restart_at_ms > 0 and !self.shutting_down) return false;
        }
        return true;
    }

    /// Asks a single Worker to stop, as the control socket's `stop` does.
    /// A Worker that already exited still gets its stop command, which is what
    /// lets `docker compose up -d` be undone.
    pub fn stopWorker(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        w.restart_at_ms = 0;
        if (w.state.terminal()) {
            _ = self.startStopCommand(i, os.nowMs());
            return;
        }
        if (!w.state.alive() or w.state == .stopping) return;
        self.beginStop(i, os.nowMs());
    }

    /// Puts a terminal Worker back in the queue. Its dependencies are checked
    /// again on the next pass, so starting one by hand cannot bypass the graph;
    /// a dependency that is `off` is brought in too, since nothing else would.
    pub fn startWorker(self: *Supervisor, i: usize) void {
        self.queue(i, true);
    }

    fn queue(self: *Supervisor, i: usize, fresh: bool) void {
        const w = &self.workers[i];
        if (!w.state.terminal()) return;
        w.state = .pending;
        w.restart_at_ms = 0;
        w.streak = 0;
        if (fresh) w.restarts = 0;
        self.generation += 1;
        // After the state change, so a cycle that slipped past the loader
        // ends here instead of recursing.
        for (self.dep_targets[i]) |t| {
            if (t != unresolved_dep and self.workers[t].state == .off) self.queue(t, true);
        }
    }

    pub fn restartWorker(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        if (w.state.terminal()) return self.startWorker(i);
        self.stopWorker(i);
        // Come back as soon as the old Group is reaped, not on a timer.
        w.restart_at_ms = 1;
        w.restarts = 0;
        w.streak = 0;
    }

    /// A watched path changed. Like `restartWorker`, but the count keeps
    /// going up: a change is a restart worth seeing in `status`.
    fn watchRestart(self: *Supervisor, i: usize) void {
        const w = &self.workers[i];
        const seen = w.restarts;
        if (w.state.terminal()) self.queue(i, false) else {
            self.stopWorker(i);
            w.restart_at_ms = 1;
            w.streak = 0;
        }
        w.restarts = seen + 1;
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
    argv[1] = (try arena.dupeSentinel(u8, shell_arg, 0)).ptr;
    argv[2] = (try arena.dupeSentinel(u8, command, 0)).ptr;
    return argv.ptr;
}

/// Layers the environment: the OS environment first, then each `env_file`,
/// then the explicit `env` entries. Later layers win, so a value written in
/// the config beats one inherited from the shell that launched devrun.
///
/// `color` adds `FORCE_COLOR=1` and `CLICOLOR_FORCE=1` underneath all of it:
/// a Worker writes into a pipe, so most tools would drop their colour. They
/// are only defaults, so a value from any layer beats them, and `NO_COLOR`
/// anywhere in the final environment means they are not added.
fn buildEnv(
    arena: Allocator,
    opts: Options,
    spec: *const config.Worker,
    color: bool,
    diag: ?*Diagnostic,
    gpa: Allocator,
) ![*:null]const ?[*:0]const u8 {
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

    var it = opts.environ.iterator();
    while (it.next()) |kv| {
        try map.put(arena, kv.key_ptr.*, kv.value_ptr.*);
    }

    for (spec.env_file) |file| {
        const path = try std.fs.path.join(arena, &.{ opts.base_dir, file });
        const text = std.Io.Dir.cwd().readFileAlloc(
            opts.io,
            path,
            arena,
            .limited(4 << 20),
        ) catch {
            // An explicitly named env file that is missing is a mistake worth
            // reporting: the config asked for it by name.
            return Supervisor.failWith(gpa, diag, "services.{s}.env_file: cannot read {s}", .{
                spec.name, path,
            });
        };
        try parseDotenv(arena, text, &map);
    }

    for (spec.env) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        try map.put(arena, entry[0..eq], entry[eq + 1 ..]);
    }

    if (color and !map.contains("NO_COLOR")) {
        for ([_][]const u8{ "FORCE_COLOR", "CLICOLOR_FORCE" }) |key| {
            if (!map.contains(key)) try map.put(arena, key, "1");
        }
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
    if (std.fs.path.isAbsolute(dir)) return (try arena.dupeSentinel(u8, dir, 0)).ptr;
    const joined = try std.fs.path.join(arena, &.{ base_dir, dir });
    return (try arena.dupeSentinel(u8, joined, 0)).ptr;
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
        .{ .name = "db", .group = "db", .command = "postgres" },
        .{ .name = "api", .group = "api", .command = "go run .", .depends_on = &.{
            .{ .name = "db", .condition = .started },
        } },
        .{ .name = "web", .group = "web", .command = "vite", .depends_on = &.{
            .{ .name = "db", .condition = .started },
            .{ .name = "api", .condition = .started },
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
        \\[services.gate]
        \\run = "echo gate-ran"
        \\[services.after]
        \\run = "echo after-ran"
        \\after = { gate = "succeeded" }
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
        \\[services.gate]
        \\run = "exit 3"
        \\[services.after]
        \\run = "echo SHOULD-NOT-RUN"
        \\after = { gate = "succeeded" }
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
        \\[services.noisy]
        \\run = "printf 'plain\nESC[31mred\n'"
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
        \\[services.firehose]
        \\run = "yes 0123456789abcdef0123456789abcdef | head -c 4000000"
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
        \\[services.parent]
        \\run = "sleep 120 & echo spawned; wait"
        \\stop.timeout = 1
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

/// Steps the loop until `pred` holds or the deadline passes.
fn stepUntil(sup: *Supervisor, timeout_ms: u64, comptime pred: fn (*Supervisor) bool) !bool {
    const deadline = os.nowMs() + timeout_ms;
    while (os.nowMs() < deadline) {
        if (pred(sup)) return true;
        try sup.step(&.{}, 25);
    }
    return pred(sup);
}

fn testSupervisor(
    gpa: Allocator,
    cfg: *config.Config,
    dir: []const u8,
    io: std.Io,
    environ: *const std.process.Environ.Map,
) !Supervisor {
    return Supervisor.init(gpa, cfg, .{
        .io = io,
        .environ = environ,
        .base_dir = dir,
        .log_dir = dir,
    }, null);
}

fn shutDown(sup: *Supervisor) !void {
    sup.beginShutdown();
    const deadline = os.nowMs() + 10_000;
    while (!sup.done() and os.nowMs() < deadline) try sup.step(&.{}, 25);
    try testing.expect(sup.done());
}

test "autostart = false stays off while its sibling runs, and start brings in what it needs" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "off");
    defer gpa.free(dir);

    var cfg = try loadCfg(gpa,
        \\[services.db]
        \\run = "echo db-ran"
        \\autostart = false
        \\[services.api]
        \\run = "echo api-ran"
        \\autostart = false
        \\after = ["db"]
        \\[services.sibling]
        \\run = "echo sibling-ran"
        \\
    );
    defer cfg.deinit();

    var sup = try runToCompletion(gpa, &cfg, dir, 10_000);
    defer sup.deinit();

    try testing.expect(sup.done());
    try testing.expectEqual(State.off, sup.workers[0].state);
    try testing.expectEqual(State.off, sup.workers[1].state);
    try testing.expectEqual(State.exited, sup.workers[2].state);
    try testing.expectEqual(@as(u64, 0), sup.workers[0].archive.len());

    // Starting api by hand starts db too: api waits on it, and nothing else
    // would ever bring it in.
    sup.startWorker(1);
    try testing.expectEqual(State.pending, sup.workers[0].state);
    const deadline = os.nowMs() + 10_000;
    while (!sup.done() and os.nowMs() < deadline) try sup.step(&.{}, 25);
    try testing.expectEqual(State.exited, sup.workers[0].state);
    try testing.expectEqual(State.exited, sup.workers[1].state);
}

test "a dependency that is off counts as satisfied" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "nodeps");
    defer gpa.free(dir);

    var cfg = try loadCfg(gpa,
        \\[services.db]
        \\run = "echo db"
        \\autostart = false
        \\[services.api]
        \\run = "echo api-ran"
        \\after = ["db"]
        \\
    );
    defer cfg.deinit();
    // The `--no-deps` case: db never starts, and api does not wait for it.
    var sup = try runToCompletion(gpa, &cfg, dir, 10_000);
    defer sup.deinit();
    try testing.expectEqual(State.off, sup.workers[0].state);
    try testing.expectEqual(State.exited, sup.workers[1].state);
}

test "restart max gives up after that many restarts and leaves the Worker failed" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "max");
    defer gpa.free(dir);

    var cfg = try loadCfg(gpa,
        \\[services.flaky]
        \\run = "exit 1"
        \\restart = { policy = "on-failure", max = 2, backoff = "50ms" }
        \\
    );
    defer cfg.deinit();

    var sup = try runToCompletion(gpa, &cfg, dir, 10_000);
    defer sup.deinit();

    try testing.expect(sup.done());
    try testing.expectEqual(State.failed, sup.workers[0].state);
    try testing.expectEqual(@as(u32, 2), sup.workers[0].restarts);
}

test "exit-on-end ends the Session with that Worker's status" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "eoe");
    defer gpa.free(dir);

    var cfg = try loadCfg(gpa,
        \\[services.server]
        \\run = "sleep 60"
        \\stop.timeout = 1
        \\[services.suite]
        \\run = "exit 3"
        \\restart = "exit-on-end"
        \\
    );
    defer cfg.deinit();

    var sup = try runToCompletion(gpa, &cfg, dir, 15_000);
    defer sup.deinit();

    try testing.expect(sup.done());
    try testing.expectEqual(@as(?usize, 1), sup.ended_by);
    try testing.expectEqual(@as(u8, 3), exitStatus(sup.workers[1].exit));
    try testing.expectEqual(State.stopped, sup.workers[0].state);
}

test "stop.command runs for a Worker that already exited, and its output lands in the Archive" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "stopcmd");
    defer gpa.free(dir);

    var cfg = try loadCfg(gpa,
        \\[services.daemon]
        \\run = "echo up"
        \\stop.command = "echo cleaned"
        \\
    );
    defer cfg.deinit();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    var sup = try testSupervisor(gpa, &cfg, dir, threaded.io(), &environ);
    defer sup.deinit();

    const exited = struct {
        fn f(s: *Supervisor) bool {
            return s.workers[0].state == .exited;
        }
    }.f;
    try testing.expect(try stepUntil(&sup, 10_000, exited));
    try shutDown(&sup);

    const a = &sup.workers[0].archive;
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("up", a.lineInto(0, &buf));
    var buf2: [64]u8 = undefined;
    try testing.expectEqualStrings("cleaned", a.lineInto(a.lastLineStart(), &buf2));
}

test "stop.command runs before the stop signal is sent" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "stoporder");
    defer gpa.free(dir);

    const src = try std.fmt.allocPrint(gpa,
        \\[services.svc]
        \\run = "trap 'echo got-term >> {s}/order; exit 0' TERM; echo ready; sleep 60 & wait"
        \\stop.command = "echo stop-command >> {s}/order; sleep 0.3"
        \\stop.timeout = 5
        \\
    , .{ dir, dir });
    defer gpa.free(src);
    var cfg = try loadCfg(gpa, src);
    defer cfg.deinit();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    var sup = try testSupervisor(gpa, &cfg, dir, threaded.io(), &environ);
    defer sup.deinit();

    const started = struct {
        fn f(s: *Supervisor) bool {
            return s.workers[0].archive.len() > 0;
        }
    }.f;
    try testing.expect(try stepUntil(&sup, 10_000, started));
    try shutDown(&sup);
    try testing.expectEqual(State.stopped, sup.workers[0].state);

    const path = try std.fmt.allocPrint(gpa, "{s}/order", .{dir});
    defer gpa.free(path);
    const text = try std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, gpa, .limited(4096));
    defer gpa.free(text);
    try testing.expectEqualStrings("stop-command\ngot-term\n", text);
}

test "a watched path restarts the Worker after the debounce" {
    const gpa = testing.allocator;
    const dir = try tempDir(gpa, "watch");
    defer gpa.free(dir);
    const watched = try std.fmt.allocPrint(gpa, "{s}/src", .{dir});
    defer gpa.free(watched);
    try os.makePath(watched);

    const src = try std.fmt.allocPrint(gpa,
        \\[services.app]
        \\run = "echo started; sleep 60"
        \\stop.timeout = 1
        \\watch = {{ paths = ["{s}"], debounce = "50ms" }}
        \\
    , .{watched});
    defer gpa.free(src);
    var cfg = try loadCfg(gpa, src);
    defer cfg.deinit();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/usr/local/bin:/usr/bin:/bin");
    var sup = try testSupervisor(gpa, &cfg, dir, threaded.io(), &environ);
    defer sup.deinit();
    try testing.expectEqual(@as(usize, 0), sup.watcher.problems.items.len);

    const up = struct {
        fn f(s: *Supervisor) bool {
            return s.workers[0].state == .running and s.workers[0].archive.len() > 0;
        }
    }.f;
    try testing.expect(try stepUntil(&sup, 10_000, up));
    try testing.expectEqual(@as(u32, 0), sup.workers[0].restarts);

    const file = try std.fmt.allocPrintSentinel(gpa, "{s}/changed.txt", .{watched}, 0);
    defer gpa.free(file);
    const fd = try os.open(file.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    try os.writeAll(fd, "x");
    os.close(fd);

    const restarted = struct {
        fn f(s: *Supervisor) bool {
            return s.workers[0].restarts >= 1 and s.workers[0].state == .running and
                s.workers[0].archive.len() > "started\n".len;
        }
    }.f;
    try testing.expect(try stepUntil(&sup, 10_000, restarted));
    try shutDown(&sup);
}

test "colour defaults are the lowest layer and NO_COLOR removes them" {
    const gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("PATH", "/bin");

    const plain_spec: config.Worker = .{ .name = "a", .group = "a", .command = "true" };
    const explicit: config.Worker = .{
        .name = "b",
        .group = "b",
        .command = "true",
        .env = &.{"FORCE_COLOR=0"},
    };
    const opts: Options = .{
        .io = threaded.io(),
        .environ = &environ,
        .base_dir = "/",
        .log_dir = "/",
    };

    const has = struct {
        fn f(envp: [*:null]const ?[*:0]const u8, entry: []const u8) bool {
            var i: usize = 0;
            while (envp[i]) |e| : (i += 1) {
                if (std.mem.eql(u8, std.mem.span(e), entry)) return true;
            }
            return false;
        }
        fn hasKey(envp: [*:null]const ?[*:0]const u8, key: []const u8) bool {
            var i: usize = 0;
            while (envp[i]) |e| : (i += 1) {
                if (std.mem.startsWith(u8, std.mem.span(e), key) and
                    std.mem.span(e).len > key.len and std.mem.span(e)[key.len] == '=') return true;
            }
            return false;
        }
    };

    const on = try buildEnv(arena, opts, &plain_spec, true, null, gpa);
    try testing.expect(has.f(on, "FORCE_COLOR=1"));
    try testing.expect(has.f(on, "CLICOLOR_FORCE=1"));

    const off = try buildEnv(arena, opts, &plain_spec, false, null, gpa);
    try testing.expect(!has.hasKey(off, "FORCE_COLOR"));

    // An explicit value in the config beats the default.
    const kept = try buildEnv(arena, opts, &explicit, true, null, gpa);
    try testing.expect(has.f(kept, "FORCE_COLOR=0"));
    try testing.expect(!has.f(kept, "FORCE_COLOR=1"));

    try environ.put("NO_COLOR", "1");
    const muted = try buildEnv(arena, opts, &plain_spec, true, null, gpa);
    try testing.expect(!has.hasKey(muted, "FORCE_COLOR"));
    try testing.expect(!has.hasKey(muted, "CLICOLOR_FORCE"));
    // ...but a value written in the config is still honoured.
    const mixed = try buildEnv(arena, opts, &explicit, true, null, gpa);
    try testing.expect(has.f(mixed, "FORCE_COLOR=0"));
    try testing.expect(!has.hasKey(mixed, "CLICOLOR_FORCE"));
}

test "State classifies terminal and alive without overlap" {
    for ([_]State{ .exited, .failed, .skipped, .off }) |s| {
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
