//! The Linux syscalls devrun needs, wrapped so a failure is a Zig error rather
//! than a negative number, and so the rest of the codebase never sees a raw
//! `usize` return.
//!
//! Two rules from `docs/adr/0004-portability-posture.md` shape this file:
//! signals arrive through a self-pipe rather than `signalfd`, and readiness is
//! discovered with `poll()` rather than `epoll`. Both are POSIX, so a macOS
//! port replaces `/proc` scraping and nothing here.
//!
//! `std.process.spawn` exists and even takes a `pgid`, but it routes through
//! the `std.Io` vtable, which owns reaping. A supervisor has to reap on its own
//! `SIGCHLD` — the exit status *is* the event it reacts to — so the fork/exec
//! is written out longhand here. The child path between `fork` and `execve`
//! touches nothing but async-signal-safe syscalls, which is why every string it
//! needs is built by the caller beforehand.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Re-exported so callers can name `sockaddr.in` and the `AF`/`SOCK` constants
/// without importing `std.os.linux` alongside this module and inviting the two
/// to be used interchangeably.
pub const linux = std.os.linux;

pub const Fd = linux.fd_t;
pub const Pid = linux.pid_t;
pub const SIG = linux.SIG;

/// Turns a raw syscall return into an error. Kept in one place so no call site
/// has to remember that the kernel returns errors as small negative numbers
/// bit-cast into an unsigned word.
fn check(rc: usize) !void {
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => |e| errnoToError(e),
    };
}

fn checkFd(rc: usize) !Fd {
    try check(rc);
    return @intCast(rc);
}

fn errnoToError(e: linux.E) anyerror {
    return switch (e) {
        .ACCES => error.AccessDenied,
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFileDescriptor,
        .EXIST => error.PathAlreadyExists,
        .INTR => error.Interrupted,
        .INVAL => error.InvalidArgument,
        .ISDIR => error.IsDir,
        .LOOP => error.SymlinkLoop,
        .MFILE, .NFILE => error.TooManyOpenFiles,
        .NAMETOOLONG => error.NameTooLong,
        .NOENT => error.FileNotFound,
        .NOMEM => error.OutOfMemory,
        .NOSPC => error.NoSpaceLeft,
        .NOTDIR => error.NotDir,
        .PERM => error.PermissionDenied,
        .PIPE => error.BrokenPipe,
        .SRCH => error.NoSuchProcess,
        .CHILD => error.NoChildProcess,
        else => error.Unexpected,
    };
}

// ------------------------------------------------------------- time

/// Milliseconds on `CLOCK_MONOTONIC`. Every deadline in devrun — probe periods,
/// the shutdown ladder, the Sample timer — is expressed against this, so that
/// suspending a laptop or stepping the wall clock cannot make a timeout fire
/// early or never.
pub fn nowMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

/// Milliseconds since the Unix epoch. Used for one thing only: stamping log
/// chunks in an Index, where the reader is a *different process* started at a
/// different time and needs an absolute answer to "when was this written".
///
/// Deliberately not `nowMs`. Monotonic time is the right clock for a deadline
/// and the wrong one for a label — two processes agree on it only within one
/// boot, and neither can turn it into something to print. A wall clock that
/// steps mislabels a few lines; a monotonic stamp cannot be read at all.
pub fn realtimeMs() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

// ------------------------------------------------------------- fds

pub fn close(fd: Fd) void {
    // Closing cannot usefully fail: EBADF is a bug we cannot fix here, and
    // EINTR does not mean the descriptor survived on Linux.
    _ = linux.close(fd);
}

pub fn read(fd: Fd, buf: []u8) !usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |e| return errnoToError(e),
        }
    }
}

/// Writes all of `buf`, resuming after short writes and signals. Used for the
/// Archive, where a partial write would corrupt the record silently.
pub fn writeAll(fd: Fd, buf: []const u8) !void {
    var i: usize = 0;
    while (i < buf.len) {
        const rc = linux.write(fd, buf.ptr + i, buf.len - i);
        switch (linux.errno(rc)) {
            .SUCCESS => i += rc,
            .INTR => continue,
            else => |e| return errnoToError(e),
        }
    }
}

/// Positional read, used to page Archive bytes back in when the reader scrolls
/// past the Window. Does not disturb the file offset the writer is appending at.
pub fn pread(fd: Fd, buf: []u8, offset: u64) !usize {
    while (true) {
        const rc = linux.pread(fd, buf.ptr, buf.len, @intCast(offset));
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |e| return errnoToError(e),
        }
    }
}

pub fn unlink(path: [*:0]const u8) void {
    _ = linux.unlink(path);
}

/// Size of an open file. Null rather than an error: every caller is a reader
/// deciding how much of an Index there is to search, and "none of it" is the
/// same answer it would take from a failure.
pub fn fileSize(fd: Fd) ?u64 {
    // `statx` with `AT_EMPTY_PATH` rather than `lseek(SEEK_END)`: an Archive is
    // being appended to by the Session that owns it, and a helper that moved
    // the file offset as a side effect of asking a question would eventually
    // be called on that descriptor and corrupt the log.
    var st: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    if (!st.mask.SIZE) return null;
    return st.size;
}

/// The working directory, or null when it will not fit or cannot be read.
///
/// Null rather than an error: the one caller wants a name to put on screen,
/// and a Session with no name on it is a smaller problem than a Session that
/// refused to start over one.
pub fn getcwd(buf: []u8) ?[]const u8 {
    const rc = linux.getcwd(buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    // The kernel counts the NUL it wrote; a caller wants the name without it.
    const n = @as(usize, rc);
    if (n < 2) return null;
    return buf[0 .. n - 1];
}

/// The path of the running executable, or null when it cannot be read.
///
/// `readlink` does not NUL-terminate and reports a truncated read as a short
/// one rather than an error, so a result that exactly fills the buffer is
/// treated as a failure — a silently clipped path is worse than none, since
/// the one caller uses it to decide where to write a new binary.
///
/// A binary whose file has been unlinked reads back as "…/devrun (deleted)".
/// That is left alone rather than trimmed: the suffix is indistinguishable
/// from a real filename, and guessing wrong means writing to the wrong path.
pub fn selfExe(buf: []u8) ?[]const u8 {
    const rc = linux.readlink("/proc/self/exe", buf.ptr, buf.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    const n = @as(usize, rc);
    if (n == 0 or n == buf.len) return null;
    return buf[0..n];
}

/// `mkdir -p`. Creates each component in turn and treats "already there" as
/// success, which is the only outcome a caller distinguishes.
pub fn makePath(path: []const u8) !void {
    var buf: [4096]u8 = undefined;
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;

    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        const at_end = i == path.len;
        if (!at_end and buf[i] != '/') continue;
        if (i == 0) continue; // leading slash: the root already exists
        buf[i] = 0;
        switch (linux.errno(linux.mkdir(@ptrCast(&buf), 0o755))) {
            .SUCCESS, .EXIST => {},
            else => |e| return errnoToError(e),
        }
        if (!at_end) buf[i] = '/';
    }
}

pub const OpenFlags = linux.O;

pub fn open(path: [*:0]const u8, flags: OpenFlags, mode: linux.mode_t) !Fd {
    return checkFd(linux.openat(linux.AT.FDCWD, path, flags, mode));
}

/// A pipe. `flags` applies to *both* ends, which matters for `O_NONBLOCK`:
/// it lives on the open file description, so passing it here gives the writer
/// a non-blocking descriptor too, and any child that inherits one dies with
/// `EAGAIN` as soon as it out-runs its reader. Set it on the end you mean,
/// with `setNonblock`, after the fact.
pub fn pipe(flags: OpenFlags) ![2]Fd {
    var fds: [2]Fd = undefined;
    try check(linux.pipe2(&fds, flags));
    return fds;
}

pub fn setNonblock(fd: Fd, on: bool) void {
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return;
    var o: linux.O = @bitCast(@as(u32, @truncate(flags)));
    o.NONBLOCK = on;
    _ = linux.fcntl(fd, linux.F.SETFL, @as(u32, @bitCast(o)));
}

/// One write attempt, reporting how much went out. Distinct from `writeAll`:
/// a non-blocking socket that accepts half a request is a normal event the
/// caller resumes from, not a failure.
pub fn write(fd: Fd, buf: []const u8) !usize {
    while (true) {
        const rc = linux.write(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |e| return errnoToError(e),
        }
    }
}

// ------------------------------------------------------------- sockets

pub fn socket(domain: u32, kind: u32, protocol: u32) !Fd {
    return checkFd(linux.socket(domain, kind | linux.SOCK.CLOEXEC, protocol));
}

pub fn connect(fd: Fd, addr: *const linux.sockaddr.in) !void {
    const rc = linux.connect(fd, addr, @sizeOf(linux.sockaddr.in));
    return switch (linux.errno(rc)) {
        .SUCCESS => {},
        .INPROGRESS => error.InProgress,
        .AGAIN => error.WouldBlock,
        .INTR => error.InProgress,
        else => |e| errnoToError(e),
    };
}

pub fn bindUn(fd: Fd, addr: *const linux.sockaddr.un) !void {
    try check(linux.bind(fd, @ptrCast(addr), @sizeOf(linux.sockaddr.un)));
}

pub fn connectUn(fd: Fd, addr: *const linux.sockaddr.un) !void {
    try check(linux.connect(fd, addr, @sizeOf(linux.sockaddr.un)));
}

pub fn listen(fd: Fd, backlog: u32) !void {
    try check(linux.listen(fd, backlog));
}

pub fn accept(fd: Fd) !Fd {
    while (true) {
        const rc = linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |e| return errnoToError(e),
        }
    }
}

/// `SO_ERROR`, which is the only thing that distinguishes a connected socket
/// from a refused one after `poll` reports it writable. Zero means connected.
pub fn socketError(fd: Fd) i32 {
    var err: i32 = 0;
    var len: linux.socklen_t = @sizeOf(i32);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &len);
    if (linux.errno(rc) != .SUCCESS) return -1;
    return err;
}

// ------------------------------------------------------------- directories

/// A directory read straight through `getdents64`.
///
/// Exists because sampling walks `/proc` on a timer: a few hundred entries,
/// once a second, forever. `getdents64` fills a 8 KiB buffer in one syscall
/// and the names are read in place, so a whole scan allocates nothing.
pub const DirIter = struct {
    fd: Fd,
    buf: [8192]u8 align(8) = undefined,
    len: usize = 0,
    pos: usize = 0,

    const Dirent64 = extern struct {
        ino: u64,
        off: i64,
        reclen: u16,
        type: u8,
        // Name follows, NUL-terminated.

        /// Where `d_name` actually begins: 8 + 8 + 2 + 1.
        ///
        /// Deliberately not `@sizeOf(Dirent64)`, which is 24 — Zig pads the
        /// struct up to its 8-byte alignment, but the kernel does not pad the
        /// record. Using `@sizeOf` reads the name five bytes late, which
        /// yields garbage for every entry.
        const name_offset = 19;
    };

    pub fn open(path: [*:0]const u8) !DirIter {
        const fd = try checkFd(linux.openat(linux.AT.FDCWD, path, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0));
        return .{ .fd = fd };
    }

    pub fn close(self: *DirIter) void {
        // Not the module-level `close`: inside this struct that name resolves
        // to this method.
        if (self.fd >= 0) _ = linux.close(self.fd);
        self.fd = -1;
    }

    /// The next entry's name, valid until the following call.
    pub fn next(self: *DirIter) ?[]const u8 {
        while (true) {
            if (self.pos >= self.len) {
                const rc = linux.getdents64(self.fd, &self.buf, self.buf.len);
                switch (linux.errno(rc)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return null,
                }
                if (rc == 0) return null;
                self.len = rc;
                self.pos = 0;
            }
            const d: *align(1) const Dirent64 = @ptrCast(&self.buf[self.pos]);
            const name_start = self.pos + Dirent64.name_offset;
            const rec_end = self.pos + d.reclen;
            // A zero-length record would spin forever; a record running past
            // the buffer means the kernel gave us something we cannot parse.
            if (d.reclen == 0 or rec_end > self.len or name_start >= rec_end) return null;
            self.pos = rec_end;
            return std.mem.sliceTo(self.buf[name_start..rec_end], 0);
        }
    }
};

// ------------------------------------------------------------- poll

pub const PollFd = linux.pollfd;
pub const POLL = linux.POLL;

/// `timeout_ms` of -1 blocks. Returns the number of ready descriptors; an
/// interrupted poll reports zero rather than an error, because the caller's
/// next move — re-check deadlines, re-poll — is the same either way.
pub fn poll(fds: []PollFd, timeout_ms: i32) !usize {
    const rc = linux.poll(fds.ptr, fds.len, timeout_ms);
    return switch (linux.errno(rc)) {
        .SUCCESS => rc,
        .INTR => 0,
        else => |e| errnoToError(e),
    };
}

// ------------------------------------------------------------- signals

/// The self-pipe. A handler cannot allocate, take a lock, or touch the event
/// loop's data, but it can `write(2)` one byte — so it does, and the loop
/// learns about the signal by polling a descriptor like any other source.
///
/// There is exactly one of these per process; the handler needs a global to
/// find the write end, and signals are process-wide regardless.
pub const Signals = struct {
    var write_fd: std.atomic.Value(Fd) = .init(-1);

    read_fd: Fd,

    pub fn install(signals: []const SIG) !Signals {
        const fds = try pipe(.{ .CLOEXEC = true, .NONBLOCK = true });
        write_fd.store(fds[1], .release);

        for (signals) |sig| {
            var act: linux.Sigaction = .{
                .handler = .{ .handler = handler },
                .mask = linux.sigemptyset(),
                // Restart interrupted syscalls where the kernel can; the loop
                // still tolerates EINTR, but not making it happen is cheaper.
                .flags = linux.SA.RESTART,
            };
            _ = linux.sigaction(sig, &act, null);
        }
        return .{ .read_fd = fds[0] };
    }

    fn handler(sig: SIG) callconv(.c) void {
        const fd = write_fd.load(.acquire);
        if (fd < 0) return;
        const byte: [1]u8 = .{@truncate(@intFromEnum(sig))};
        // A full pipe means the loop is behind and already has a wake-up
        // queued, so dropping this byte loses nothing: the loop reaps with
        // WNOHANG in a loop and re-checks every deadline on each pass.
        _ = linux.write(fd, &byte, 1);
    }

    /// Drains every byte the handler queued and returns which signals were
    /// seen. Deliberately a set rather than a count — two SIGCHLDs and one
    /// SIGCHLD lead to the same work.
    pub fn drain(self: Signals) Set {
        var seen: Set = .{};
        var buf: [64]u8 = undefined;
        while (true) {
            const n = read(self.read_fd, &buf) catch return seen;
            if (n == 0) return seen;
            for (buf[0..n]) |b| switch (@as(SIG, @enumFromInt(b))) {
                .CHLD => seen.chld = true,
                .INT, .TERM, .QUIT, .HUP => seen.quit = true,
                .WINCH => seen.winch = true,
                else => {},
            };
            if (n < buf.len) return seen;
        }
    }

    pub const Set = struct {
        chld: bool = false,
        quit: bool = false,
        winch: bool = false,
    };

    pub fn deinit(self: *Signals) void {
        close(self.read_fd);
        const w = write_fd.swap(-1, .acq_rel);
        if (w >= 0) close(w);
        self.read_fd = -1;
    }
};

/// Makes this process inherit orphaned grandchildren instead of losing them to
/// PID 1. A Worker that daemonises — or whose shell exits leaving children —
/// still has its Group reaped by us rather than escaping the Session.
pub fn becomeSubreaper() void {
    const PR_SET_CHILD_SUBREAPER = 36;
    _ = linux.prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0);
}

// ------------------------------------------------------------- detaching

pub const Fork = union(enum) {
    /// In the original process; carries the child's pid.
    parent: Pid,
    /// In the new one.
    child,
};

/// A plain fork, for `devrun up --detach`. Unlike `spawn` below there is no
/// exec: the child *is* devrun, and goes on to be the Session.
pub fn fork() !Fork {
    const rc = linux.fork();
    try check(rc);
    const pid: Pid = @intCast(rc);
    return if (pid == 0) .child else .{ .parent = pid };
}

/// Leaves the terminal behind: new session, no controlling tty. Without this a
/// detached Session dies with the shell that started it, which is the one
/// thing detaching was supposed to prevent.
pub fn setsid() void {
    _ = linux.setsid();
}

/// Points stdin, stdout and stderr at `fd`. Used by a detached Session so that
/// a panic or a diagnostic has somewhere to land instead of a closed pipe.
pub fn redirectStdio(fd: Fd) void {
    _ = linux.dup2(fd, 0);
    _ = linux.dup2(fd, 1);
    _ = linux.dup2(fd, 2);
}

/// Sleeps. Only for the one-shot CLI paths (`wait`, and the parent half of
/// `up --detach`), which have nothing to do but ask again in a moment. The
/// Session's own loop never calls this — it blocks in `poll` with a deadline,
/// which is how it stays responsive to a signal.
pub fn sleepMs(ms: u64) void {
    var ts: linux.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: linux.timespec = undefined;
    while (linux.errno(linux.nanosleep(&ts, &rem)) == .INTR) ts = rem;
}

// ------------------------------------------------------------- processes

pub const Exit = union(enum) {
    exited: u8,
    signaled: SIG,

    pub fn ok(self: Exit) bool {
        return self == .exited and self.exited == 0;
    }
};

pub const Reaped = struct {
    pid: Pid,
    exit: Exit,
};

/// Reaps one already-dead child, or returns null when none is waiting. Callers
/// loop until null: one `SIGCHLD` can stand for any number of deaths, because
/// signals coalesce.
pub fn reap() ?Reaped {
    while (true) {
        var status: u32 = 0;
        const rc = linux.wait4(-1, &status, linux.W.NOHANG, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            // ECHILD: nothing left to reap, which is the normal exit condition.
            else => return null,
        }
        const pid: Pid = @intCast(rc);
        if (pid == 0) return null;
        if (linux.W.IFEXITED(status)) {
            return .{ .pid = pid, .exit = .{ .exited = @intCast(linux.W.EXITSTATUS(status)) } };
        }
        if (linux.W.IFSIGNALED(status)) {
            return .{ .pid = pid, .exit = .{ .signaled = linux.W.TERMSIG(status) } };
        }
        // Stopped or continued: not a death, so keep looking.
    }
}

/// Signals an entire Group. The negative pid is the whole point — a Worker is
/// its process group, and signalling only the pid we spawned would leave the
/// shell's children running. See CONTEXT.md.
pub fn killGroup(pgid: Pid, sig: SIG) void {
    _ = linux.kill(-pgid, sig);
}

/// True while any process in the Group is still alive. `kill(pgid, 0)` performs
/// the permission and existence check without delivering anything.
pub fn groupAlive(pgid: Pid) bool {
    return linux.errno(linux.kill(-pgid, @enumFromInt(0))) == .SUCCESS;
}

pub const SpawnArgs = struct {
    /// Absolute path to the executable. Resolved by the caller, because PATH
    /// search allocates and the child cannot.
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    /// Directory to `chdir` into, or null to inherit.
    cwd: ?[*:0]const u8,
    /// Both stdout and stderr are wired here: a Worker has one Archive, and
    /// interleaving is what the reader expects to see.
    output: Fd,
    /// stdin. A dev process that reads stdin should see EOF, not the terminal
    /// devrun is drawing on.
    input: Fd,
};

pub const Spawned = struct {
    pid: Pid,
    /// Equal to `pid`: the child calls `setpgid(0, 0)`, making it the leader of
    /// a new Group. Named separately because everything downstream signals the
    /// Group, and a bare `pid` at a `kill` call site reads like a bug.
    pgid: Pid,
};

pub const SpawnError = error{
    ForkFailed,
    /// The shell itself could not be executed — a missing `shell_command`,
    /// almost always. Distinct from the shell running and exiting 127.
    ExecFailed,
} || anyerror;

/// Forks, puts the child in its own Group, and execs. Nothing between `fork`
/// and `execve` allocates or takes a lock.
///
/// The `sync` pipe is how a failed `execve` is reported: it is close-on-exec,
/// so a successful exec closes it and the parent reads EOF. A child that
/// cannot exec writes its errno instead, which is the difference between
/// "your shell is missing" and a process that started and died immediately.
pub fn spawn(args: SpawnArgs) SpawnError!Spawned {
    const sync = try pipe(.{ .CLOEXEC = true });

    const rc = linux.fork();
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        else => {
            close(sync[0]);
            close(sync[1]);
            return error.ForkFailed;
        },
    }

    if (rc == 0) {
        childExec(args, sync[1]);
        unreachable;
    }

    close(sync[1]);
    // Closed on exactly one path below rather than by `errdefer`, which would
    // fire *in addition to* the explicit close on the ExecFailed path and shut
    // a descriptor number that something else may already have been handed.
    defer close(sync[0]);
    const pid: Pid = @intCast(rc);

    // Race-free grouping: both sides call setpgid, so the Group exists no
    // matter which process is scheduled first. EACCES here means the child
    // already exec'd, which means it already won the race.
    _ = linux.setpgid(pid, pid);

    var err_buf: [@sizeOf(u32)]u8 = undefined;
    const n = read(sync[0], &err_buf) catch 0;
    if (n == err_buf.len) {
        // The child could not exec and is already gone; reap it now so it does
        // not surface later as an unknown pid.
        var status: u32 = 0;
        _ = linux.wait4(pid, &status, 0, null);
        return error.ExecFailed;
    }

    return .{ .pid = pid, .pgid = pid };
}

/// The child half of `spawn`. Never returns. Async-signal-safe throughout:
/// every allocation this needed was done by the caller before the fork.
fn childExec(args: SpawnArgs, sync_fd: Fd) noreturn {
    // Its own Group, so a later kill reaches the shell's children too.
    _ = linux.setpgid(0, 0);

    // Handlers inherited across fork would run this child's copy of devrun's
    // logic on Ctrl-C. Reset to default and unblock everything.
    var i: u32 = 1;
    while (i < 32) : (i += 1) {
        const sig: SIG = @enumFromInt(i);
        // SIGKILL and SIGSTOP cannot be caught, so they were never inherited
        // as anything but default — and asking to reset them is an error.
        if (sig == .KILL or sig == .STOP) continue;
        var act: linux.Sigaction = .{
            .handler = .{ .handler = SIG.DFL },
            .mask = linux.sigemptyset(),
            .flags = 0,
        };
        _ = linux.sigaction(sig, &act, null);
    }
    var empty = linux.sigemptyset();
    _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);

    if (args.cwd) |dir| {
        if (linux.errno(linux.chdir(dir)) != .SUCCESS) fail(sync_fd);
    }

    // dup2 clears O_CLOEXEC and O_NONBLOCK on the copy, which is exactly what
    // the child should see: plain blocking descriptors.
    if (linux.errno(linux.dup2(args.input, 0)) != .SUCCESS) fail(sync_fd);
    if (linux.errno(linux.dup2(args.output, 1)) != .SUCCESS) fail(sync_fd);
    if (linux.errno(linux.dup2(args.output, 2)) != .SUCCESS) fail(sync_fd);

    _ = linux.execve(args.path, args.argv, args.envp);
    fail(sync_fd);
}

fn fail(sync_fd: Fd) noreturn {
    const code: u32 = 1;
    _ = linux.write(sync_fd, @ptrCast(&code), @sizeOf(u32));
    linux.exit(127);
}

/// Finds `name` on PATH, or returns it unchanged when it already looks like a
/// path. Runs in the parent, where allocating is allowed.
pub fn resolvePath(arena: Allocator, name: []const u8, path_env: ?[]const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return arena.dupeZ(u8, name);
    }
    const path = path_env orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, name }, 0);
        if (linux.errno(linux.faccessat(linux.AT.FDCWD, full.ptr, linux.X_OK, 0)) == .SUCCESS) {
            return full;
        }
    }
    return error.FileNotFound;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "spawn puts the child in its own Group and reaps a clean exit" {
    const arena_gpa = testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(arena_gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sh = try resolvePath(arena, "sh", "/bin:/usr/bin");
    const argv = [_:null]?[*:0]const u8{ sh.ptr, "-c", "exit 7" };
    const envp = [_:null]?[*:0]const u8{};

    const devnull = try open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer close(devnull);

    const child = try spawn(.{
        .path = sh.ptr,
        .argv = &argv,
        .envp = &envp,
        .cwd = null,
        .output = devnull,
        .input = devnull,
    });

    // A new Group whose id is the child's own pid is what makes `kill(-pgid)`
    // reach the shell's children later.
    try testing.expectEqual(child.pid, child.pgid);

    // No SIGCHLD handler is installed in this test, so poll the reaper.
    const deadline = nowMs() + 5000;
    while (nowMs() < deadline) {
        if (reap()) |r| {
            try testing.expectEqual(child.pid, r.pid);
            try testing.expectEqual(@as(u8, 7), r.exit.exited);
            try testing.expect(!r.exit.ok());
            return;
        }
    }
    return error.ChildNeverExited;
}

test "killGroup reaches a grandchild the shell left behind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sh = try resolvePath(arena, "sh", "/bin:/usr/bin");
    // The shell spawns a sleeper and waits: signalling only the shell's pid
    // would orphan the sleeper, which is the bug Group exists to prevent.
    const argv = [_:null]?[*:0]const u8{ sh.ptr, "-c", "sleep 300 & wait" };
    const envp = [_:null]?[*:0]const u8{};

    const devnull = try open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
    defer close(devnull);

    const child = try spawn(.{
        .path = sh.ptr,
        .argv = &argv,
        .envp = &envp,
        .cwd = null,
        .output = devnull,
        .input = devnull,
    });

    killGroup(child.pgid, .KILL);

    const deadline = nowMs() + 5000;
    while (nowMs() < deadline) {
        if (reap()) |r| {
            if (r.pid == child.pid) {
                try testing.expectEqual(SIG.KILL, r.exit.signaled);
                return;
            }
        }
    }
    return error.GroupSurvivedKill;
}

test "resolvePath finds a program on PATH and leaves a path alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sh = try resolvePath(arena, "sh", "/bin:/usr/bin");
    try testing.expect(std.mem.endsWith(u8, sh, "/sh"));

    const literal = try resolvePath(arena, "./scripts/x.sh", "/bin");
    try testing.expectEqualStrings("./scripts/x.sh", literal);

    try testing.expectError(
        error.FileNotFound,
        resolvePath(arena, "devrun-no-such-program", "/bin:/usr/bin"),
    );
}
