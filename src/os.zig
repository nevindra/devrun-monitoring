//! The syscalls devrun needs, wrapped so a failure is a Zig error rather than a
//! negative number, and so the rest of the codebase never sees a raw `usize`
//! return.
//!
//! Two rules from `docs/adr/0004-portability-posture.md` shape this file:
//! signals arrive through a self-pipe rather than `signalfd`, and readiness is
//! discovered with `poll()` rather than `epoll`. Both are POSIX, which is what
//! let macOS in without a second event loop.
//!
//! On Linux the calls go straight to the kernel, so the binary links no libc
//! and is a static ELF. macOS has no stable syscall ABI — libSystem *is* the
//! interface — so there they go through `std.c`, behind `darwin_sys`, a shim
//! that hands results back in the kernel's own convention (a negated errno in
//! an unsigned word). Everything below is written once against that convention
//! and does not know which of the two it is talking to.
//!
//! `std.process.spawn` exists and even takes a `pgid`, but it routes through
//! the `std.Io` vtable, which owns reaping. A supervisor has to reap on its own
//! `SIGCHLD` — the exit status *is* the event it reacts to — so the fork/exec
//! is written out longhand here. The child path between `fork` and `execve`
//! touches nothing but async-signal-safe syscalls, which is why every string it
//! needs is built by the caller beforehand.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const is_darwin = builtin.os.tag.isDarwin();

const linux = std.os.linux;
const c = std.c;

/// The platform's own definitions: `std.os.linux` on Linux, `std.c` on macOS.
/// Re-exported piecemeal below so callers can name `sockaddr.in`, `AF` and
/// `SIG` without importing either alongside this module and inviting the two
/// to be mixed.
const native = if (is_darwin) c else linux;

/// What every call below goes through. See the module header.
const sys = if (is_darwin) darwin_sys else linux;

pub const Fd = native.fd_t;
pub const Pid = native.pid_t;
/// Signal numbers are not portable — SIGUSR1 is 10 on Linux and 30 on macOS,
/// SIGCHLD 17 and 20 — so a signal is always this enum and never a number
/// written into the source.
pub const SIG = native.SIG;
pub const E = native.E;
pub const AF = native.AF;
pub const SOCK = native.SOCK;
pub const sockaddr = native.sockaddr;
pub const termios = native.termios;
pub const V = native.V;

pub fn getpid() Pid {
    return if (is_darwin) c.getpid() else linux.getpid();
}

/// The process group `pid` belongs to, or null when there is no such process.
pub fn getpgid(pid: Pid) ?Pid {
    if (is_darwin) {
        const rc = darwin_sys.getpgid(pid);
        return if (rc < 0) null else rc;
    }
    const rc = linux.getpgid(pid);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// Decodes the convention every `sys` call returns in: a value, or a negated
/// errno in the top 4095 values of the word.
fn errno(rc: usize) E {
    if (!is_darwin) return linux.errno(rc);
    const signed: isize = @bitCast(rc);
    if (signed > -4096 and signed < 0) return @fromBackingInt(@intCast(-signed));
    return .SUCCESS;
}

/// Turns a raw syscall return into an error. Kept in one place so no call site
/// has to remember that the kernel returns errors as small negative numbers
/// bit-cast into an unsigned word.
fn check(rc: usize) !void {
    return switch (errno(rc)) {
        .SUCCESS => {},
        else => |e| errnoToError(e),
    };
}

fn checkFd(rc: usize) !Fd {
    try check(rc);
    return @intCast(rc);
}

fn errnoToError(e: E) anyerror {
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
    var ts: native.timespec = undefined;
    _ = sys.clock_gettime(.MONOTONIC, &ts);
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
    var ts: native.timespec = undefined;
    _ = sys.clock_gettime(.REALTIME, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

/// Seconds since the epoch, on `CLOCK_REALTIME`. The other thing that wants the
/// wall clock rather than `nowMs` is naming a Session's directory, where the
/// whole point is that a person can read it and know when it ran.
pub fn wallSeconds() i64 {
    var ts: native.timespec = undefined;
    _ = sys.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

// ------------------------------------------------------------- fds

pub fn close(fd: Fd) void {
    // Closing cannot usefully fail: EBADF is a bug we cannot fix here, and
    // EINTR does not mean the descriptor survived on Linux.
    _ = sys.close(fd);
}

pub fn read(fd: Fd, buf: []u8) !usize {
    while (true) {
        const rc = sys.read(fd, buf.ptr, buf.len);
        switch (errno(rc)) {
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
        const rc = sys.write(fd, buf.ptr + i, buf.len - i);
        switch (errno(rc)) {
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
        const rc = sys.pread(fd, buf.ptr, buf.len, @intCast(offset));
        switch (errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            else => |e| return errnoToError(e),
        }
    }
}

pub fn unlink(path: [*:0]const u8) void {
    _ = sys.unlink(path);
}

/// Removes an empty directory. Failure is not reported for the same reason
/// `unlink`'s is not: every caller is tidying up, and a directory that would
/// not go is not worth interrupting anyone over.
pub fn rmdir(path: [*:0]const u8) void {
    _ = sys.rmdir(path);
}

/// Points `path` at `target`, replacing whatever `path` was. Two steps because
/// `symlink` refuses an existing name: the unlink is what makes "latest" a
/// name that can be re-aimed at each Session rather than one that sticks to
/// the first.
pub fn relink(target: [*:0]const u8, path: [*:0]const u8) !void {
    _ = sys.unlink(path);
    return check(sys.symlink(target, path));
}

/// Size of an already-open file. Null rather than an error: every caller is a
/// reader deciding how much of an Index there is to search, and "none of it" is
/// the same answer it would take from a failure.
pub fn fileSize(fd: Fd) ?u64 {
    // A stat rather than `lseek(SEEK_END)`: an Archive is being appended to by
    // the Session that owns it, and a helper that moved the file offset as a
    // side effect of asking a question would eventually be called on that
    // descriptor and corrupt the log.
    if (is_darwin) {
        var st: c.Stat = undefined;
        if (c.fstat(fd, &st) != 0) return null;
        return @intCast(st.size);
    }
    var st: linux.Statx = undefined;
    const rc = linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st);
    if (errno(rc) != .SUCCESS) return null;
    if (!st.mask.SIZE) return null;
    return st.size;
}

/// How big a file is by path, or zero when it cannot be read. The one caller —
/// adding up what a directory of Archives costs — is already paying for an
/// open per file.
pub fn fileBytes(path: [*:0]const u8) u64 {
    const fd = open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return 0;
    defer close(fd);
    return fileSize(fd) orelse 0;
}

/// The working directory, or null when it will not fit or cannot be read.
///
/// Null rather than an error: the one caller wants a name to put on screen,
/// and a Session with no name on it is a smaller problem than a Session that
/// refused to start over one.
pub fn getcwd(buf: []u8) ?[]const u8 {
    if (is_darwin) {
        // libc hands back the buffer, NUL-terminated, rather than a length.
        const p = c.getcwd(buf.ptr, buf.len) orelse return null;
        const name = std.mem.sliceTo(@as([*:0]u8, @ptrCast(p)), 0);
        return if (name.len == 0) null else name;
    }
    const rc = linux.getcwd(buf.ptr, buf.len);
    if (errno(rc) != .SUCCESS) return null;
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
///
/// macOS has no `/proc`. `_NSGetExecutablePath` gives the path the binary was
/// launched by, which may run through a symlink — a Homebrew-style link in
/// `/usr/local/bin`, say — so it is resolved with `realpath` to land where
/// `/proc/self/exe` would have: on the file itself.
pub fn selfExe(buf: []u8) ?[]const u8 {
    if (is_darwin) {
        var launched: [4096]u8 = undefined;
        var len: u32 = launched.len;
        if (c._NSGetExecutablePath(&launched, &len) != 0) return null;
        // realpath writes up to PATH_MAX (1024) bytes and has no way to be told
        // the buffer is smaller.
        if (buf.len < 1024) return null;
        const resolved = c.realpath(@ptrCast(&launched), buf.ptr) orelse return null;
        const path = std.mem.sliceTo(resolved, 0);
        return if (path.len == 0) null else path;
    }
    const rc = linux.readlink("/proc/self/exe", buf.ptr, buf.len);
    if (errno(rc) != .SUCCESS) return null;
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
        switch (errno(sys.mkdir(@ptrCast(&buf), 0o755))) {
            .SUCCESS, .EXIST => {},
            else => |e| return errnoToError(e),
        }
        if (!at_end) buf[i] = '/';
    }
}

pub const OpenFlags = native.O;

pub fn open(path: [*:0]const u8, flags: OpenFlags, mode: native.mode_t) !Fd {
    return checkFd(sys.openat(native.AT.FDCWD, path, flags, mode));
}

/// A pipe. `flags` applies to *both* ends, which matters for `O_NONBLOCK`:
/// it lives on the open file description, so passing it here gives the writer
/// a non-blocking descriptor too, and any child that inherits one dies with
/// `EAGAIN` as soon as it out-runs its reader. Set it on the end you mean,
/// with `setNonblock`, after the fact.
pub fn pipe(flags: OpenFlags) ![2]Fd {
    var fds: [2]Fd = undefined;
    if (is_darwin) {
        // No `pipe2` on macOS, so the flags go on after the fact. The window in
        // which a pipe exists without CLOEXEC only matters to a fork from
        // another thread, and devrun forks from the one.
        try check(darwin_sys.ret(c.pipe(&fds)));
        for (fds) |fd| {
            if (flags.CLOEXEC) setCloexec(fd);
            if (flags.NONBLOCK) setNonblock(fd, true);
        }
        return fds;
    }
    try check(linux.pipe2(&fds, flags));
    return fds;
}

fn setCloexec(fd: Fd) void {
    _ = sys.fcntl(fd, native.F.SETFD, native.FD_CLOEXEC);
}

pub fn setNonblock(fd: Fd, on: bool) void {
    const flags = sys.fcntl(fd, native.F.GETFL, 0);
    if (errno(flags) != .SUCCESS) return;
    var o: native.O = @bitCast(@as(u32, @truncate(flags)));
    o.NONBLOCK = on;
    _ = sys.fcntl(fd, native.F.SETFL, @as(u32, @bitCast(o)));
}

/// One write attempt, reporting how much went out. Distinct from `writeAll`:
/// a non-blocking socket that accepts half a request is a normal event the
/// caller resumes from, not a failure.
pub fn write(fd: Fd, buf: []const u8) !usize {
    while (true) {
        const rc = sys.write(fd, buf.ptr, buf.len);
        switch (errno(rc)) {
            .SUCCESS => return rc,
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            else => |e| return errnoToError(e),
        }
    }
}

// ------------------------------------------------------------- sockets

pub fn socket(domain: u32, kind: u32, protocol: u32) !Fd {
    if (is_darwin) {
        // No SOCK_CLOEXEC either; see `pipe`.
        const fd = try checkFd(sys.socket(domain, kind, protocol));
        setCloexec(fd);
        return fd;
    }
    return checkFd(linux.socket(domain, kind | linux.SOCK.CLOEXEC, protocol));
}

pub fn connect(fd: Fd, addr: *const native.sockaddr.in) !void {
    const rc = sys.connect(fd, addr, @sizeOf(native.sockaddr.in));
    return switch (errno(rc)) {
        .SUCCESS => {},
        .INPROGRESS => error.InProgress,
        .AGAIN => error.WouldBlock,
        .INTR => error.InProgress,
        else => |e| errnoToError(e),
    };
}

pub fn bindUn(fd: Fd, addr: *const native.sockaddr.un) !void {
    try check(sys.bind(fd, @ptrCast(addr), @sizeOf(native.sockaddr.un)));
}

pub fn connectUn(fd: Fd, addr: *const native.sockaddr.un) !void {
    try check(sys.connect(fd, addr, @sizeOf(native.sockaddr.un)));
}

pub fn listen(fd: Fd, backlog: u32) !void {
    try check(sys.listen(fd, backlog));
}

pub fn accept(fd: Fd) !Fd {
    while (true) {
        const rc = if (is_darwin)
            darwin_sys.ret(c.accept(fd, null, null))
        else
            linux.accept4(fd, null, null, linux.SOCK.CLOEXEC);
        switch (errno(rc)) {
            .SUCCESS => {
                const client: Fd = @intCast(rc);
                if (is_darwin) setCloexec(client);
                return client;
            },
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
    var len: native.socklen_t = @sizeOf(i32);
    const rc = sys.getsockopt(fd, native.SOL.SOCKET, native.SO.ERROR, @ptrCast(&err), &len);
    if (errno(rc) != .SUCCESS) return -1;
    return err;
}

// ------------------------------------------------------------- directories

/// A directory read straight through `getdents64` (`getdirentries` on macOS).
///
/// Exists because sampling walks `/proc` on a timer: a few hundred entries,
/// once a second, forever. `getdents64` fills a 8 KiB buffer in one syscall
/// and the names are read in place, so a whole scan allocates nothing.
pub const DirIter = struct {
    fd: Fd,
    buf: [8192]u8 align(8) = undefined,
    len: usize = 0,
    pos: usize = 0,
    /// macOS's `getdirentries` wants somewhere to write the offset it reached.
    /// Nothing reads it back; the descriptor's own offset is what advances.
    base: i64 = 0,

    /// Where each field of a record sits. Offsets rather than an `extern
    /// struct`, because the name begins where the kernel says and not where
    /// Zig would pad a struct out to — reading at `@sizeOf` lands five bytes
    /// late on Linux and yields garbage for every entry.
    const Dirent = if (is_darwin) struct {
        // ino u64, seekoff u64, reclen u16, namlen u16, type u8, name…
        const reclen = 16;
        const kind = 20;
        const name = 21;
    } else struct {
        // ino u64, off i64, reclen u16, type u8, name…
        const reclen = 16;
        const kind = 18;
        const name = 19;
    };

    pub fn open(path: [*:0]const u8) !DirIter {
        return openIn(native.AT.FDCWD, path);
    }

    /// `path` relative to an open directory — `"."` reads that directory
    /// itself, wherever it has since been moved to.
    pub fn openIn(dir: Fd, path: [*:0]const u8) !DirIter {
        const fd = try checkFd(sys.openat(dir, path, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0));
        return .{ .fd = fd };
    }

    pub fn close(self: *DirIter) void {
        // Not the module-level `close`: inside this struct that name resolves
        // to this method.
        if (self.fd >= 0) _ = sys.close(self.fd);
        self.fd = -1;
    }

    /// The next entry's name, valid until the following call.
    pub fn next(self: *DirIter) ?[]const u8 {
        const rec = self.nextRecord() orelse return null;
        return rec.name;
    }

    pub const Entry = struct {
        name: []const u8,
        is_dir: bool,
        /// The inode number, which tells a file replaced by a rename apart
        /// from the one that held its name before.
        ino: u64 = 0,
    };

    /// Like `next`, but also says whether the entry is a directory. A symlink
    /// to a directory is not one: callers walking a tree must not follow it,
    /// or a link back up the tree would recurse forever.
    ///
    /// Most filesystems fill in the dirent `type` field. Those that do not
    /// report DT_UNKNOWN, and for them we ask the kernel with a no-follow
    /// `openat(O_DIRECTORY)`, which succeeds only for a real directory.
    pub fn nextEntry(self: *DirIter) ?Entry {
        const rec = self.nextRecord() orelse return null;
        const is_dir = switch (rec.kind) {
            DT_DIR => true,
            DT_UNKNOWN => self.probeDir(rec.name),
            else => false,
        };
        return .{ .name = rec.name, .is_dir = is_dir, .ino = rec.ino };
    }

    const DT_UNKNOWN = 0;
    const DT_DIR = 4;

    fn probeDir(self: *DirIter, name: []const u8) bool {
        // `name` points into `buf` and the record carries its NUL terminator,
        // so it can be handed to the kernel as is.
        const z: [*:0]const u8 = @ptrCast(name.ptr);
        const fd = checkFd(sys.openat(self.fd, z, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .NOFOLLOW = true,
            .CLOEXEC = true,
        }, 0)) catch return false;
        _ = sys.close(fd);
        return true;
    }

    const Record = struct { name: []const u8, kind: u8, ino: u64 };

    fn nextRecord(self: *DirIter) ?Record {
        while (true) {
            if (self.pos >= self.len) {
                const rc = if (is_darwin)
                    darwin_sys.ret(c.getdirentries(self.fd, &self.buf, self.buf.len, &self.base))
                else
                    linux.getdents64(self.fd, &self.buf, self.buf.len);
                switch (errno(rc)) {
                    .SUCCESS => {},
                    .INTR => continue,
                    else => return null,
                }
                if (rc == 0) return null;
                self.len = rc;
                self.pos = 0;
            }
            const rec = self.buf[self.pos..self.len];
            if (rec.len <= Dirent.name) return null;
            const reclen = std.mem.readInt(u16, rec[Dirent.reclen..][0..2], builtin.cpu.arch.endian());
            const name_start = self.pos + Dirent.name;
            const rec_end = self.pos + reclen;
            // A zero-length record would spin forever; a record running past
            // the buffer means the kernel gave us something we cannot parse.
            if (reclen == 0 or rec_end > self.len or name_start >= rec_end) return null;
            self.pos = rec_end;
            return .{
                .name = std.mem.sliceTo(self.buf[name_start..rec_end], 0),
                .kind = rec[Dirent.kind],
                .ino = std.mem.readInt(u64, rec[0..8], builtin.cpu.arch.endian()),
            };
        }
    }
};

// ------------------------------------------------------------- inotify

/// A non-blocking, close-on-exec inotify descriptor, for the file watcher.
/// Linux only; the macOS watcher is built on `kqueue` below.
pub fn inotifyInit() !Fd {
    return checkFd(linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK));
}

/// Adds (or extends) a watch and returns its descriptor. Watching the same
/// inode twice returns the same `wd`, which callers rely on to merge
/// interest. `error.NoSpaceLeft` here means the per-user watch limit
/// (`fs.inotify.max_user_watches`), not a full disk.
pub fn inotifyAddWatch(fd: Fd, path: [*:0]const u8, mask: u32) !i32 {
    return checkFd(linux.inotify_add_watch(fd, path, mask));
}

// ------------------------------------------------------------- poll

pub const PollFd = native.pollfd;
pub const POLL = native.POLL;

/// `timeout_ms` of -1 blocks. Returns the number of ready descriptors; an
/// interrupted poll reports zero rather than an error, because the caller's
/// next move — re-check deadlines, re-poll — is the same either way.
pub fn poll(fds: []PollFd, timeout_ms: i32) !usize {
    const rc = sys.poll(fds.ptr, fds.len, timeout_ms);
    return switch (errno(rc)) {
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

        // Restart interrupted syscalls where the kernel can; the loop still
        // tolerates EINTR, but not making it happen is cheaper.
        for (signals) |sig| setHandler(sig, handler, native.SA.RESTART);
        return .{ .read_fd = fds[0] };
    }

    fn handler(sig: SIG) callconv(.c) void {
        const fd = write_fd.load(.acquire);
        if (fd < 0) return;
        const byte: [1]u8 = .{@truncate(@backingInt(sig))};
        // A full pipe means the loop is behind and already has a wake-up
        // queued, so dropping this byte loses nothing: the loop reaps with
        // WNOHANG in a loop and re-checks every deadline on each pass.
        _ = sys.write(fd, &byte, 1);
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
            for (buf[0..n]) |b| switch (@as(SIG, @fromBackingInt(@intCast(b)))) {
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

/// `sigaction` with an empty mask. The one place the two platforms' structs
/// differ in shape — Linux's mask is a value `sigemptyset` returns, macOS's is
/// filled in through a pointer — so it is the one place that has to know.
fn setHandler(sig: SIG, h: ?native.Sigaction.handler_fn, flags: u32) void {
    if (is_darwin) {
        var act: c.Sigaction = .{ .handler = .{ .handler = h }, .mask = 0, .flags = flags };
        _ = c.sigemptyset(&act.mask);
        _ = c.sigaction(sig, &act, null);
        return;
    }
    var act: linux.Sigaction = .{
        .handler = .{ .handler = h },
        .mask = linux.sigemptyset(),
        .flags = flags,
    };
    _ = linux.sigaction(sig, &act, null);
}

/// Makes this process inherit orphaned grandchildren instead of losing them to
/// PID 1. A Worker that daemonises — or whose shell exits leaving children —
/// still has its Group reaped by us rather than escaping the Session.
///
/// macOS has no equivalent: an orphan there is reparented to launchd, which
/// reaps it. What it keeps is its process group, and the group is what devrun
/// signals and what the macOS sampler enumerates — so an orphan is still
/// measured and still killed. Only one that leaves its group (`setsid`, a real
/// daemon) escapes, and it would have escaped the Group on Linux too.
pub fn becomeSubreaper() void {
    if (is_darwin) return;
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
    const rc = sys.fork();
    try check(rc);
    const pid: Pid = @intCast(rc);
    return if (pid == 0) .child else .{ .parent = pid };
}

/// Leaves the terminal behind: new session, no controlling tty. Without this a
/// detached Session dies with the shell that started it, which is the one
/// thing detaching was supposed to prevent.
pub fn setsid() void {
    _ = sys.setsid();
}

/// Points stdin, stdout and stderr at `fd`. Used by a detached Session so that
/// a panic or a diagnostic has somewhere to land instead of a closed pipe.
pub fn redirectStdio(fd: Fd) void {
    _ = sys.dup2(fd, 0);
    _ = sys.dup2(fd, 1);
    _ = sys.dup2(fd, 2);
}

/// Sleeps. Only for the one-shot CLI paths (`wait`, and the parent half of
/// `up --detach`), which have nothing to do but ask again in a moment. The
/// Session's own loop never calls this — it blocks in `poll` with a deadline,
/// which is how it stays responsive to a signal.
pub fn sleepMs(ms: u64) void {
    var ts: native.timespec = .{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: native.timespec = undefined;
    while (errno(sys.nanosleep(&ts, &rem)) == .INTR) ts = rem;
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
        var raw_status: i32 = 0;
        const rc = sys.wait4(-1, &raw_status, native.W.NOHANG, null);
        switch (errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            // ECHILD: nothing left to reap, which is the normal exit condition.
            else => return null,
        }
        const pid: Pid = @intCast(rc);
        if (pid == 0) return null;
        // `wait4` writes an i32 in 0.17 while the `W` macros still read a u32.
        const status: u32 = @bitCast(raw_status);
        if (native.W.IFEXITED(status)) {
            return .{ .pid = pid, .exit = .{ .exited = @intCast(native.W.EXITSTATUS(status)) } };
        }
        if (native.W.IFSIGNALED(status)) {
            return .{ .pid = pid, .exit = .{ .signaled = native.W.TERMSIG(status) } };
        }
        // Stopped or continued: not a death, so keep looking.
    }
}

/// Signals an entire Group. The negative pid is the whole point — a Worker is
/// its process group, and signalling only the pid we spawned would leave the
/// shell's children running. See CONTEXT.md.
pub fn killGroup(pgid: Pid, sig: SIG) void {
    _ = sys.kill(-pgid, sig);
}

/// True while any process in the Group is still alive. `kill(pgid, 0)` performs
/// the permission and existence check without delivering anything.
pub fn groupAlive(pgid: Pid) bool {
    // Signal 0 is not a member of macOS's signal enum, so it is passed as the
    // number it is rather than conjured into one.
    if (is_darwin) return darwin_sys.ret(darwin_sys.killNumber(-pgid, 0)) == 0;
    return errno(linux.kill(-pgid, @fromBackingInt(@intCast(0)))) == .SUCCESS;
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

    const rc = sys.fork();
    switch (errno(rc)) {
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
    _ = sys.setpgid(pid, pid);

    var err_buf: [@sizeOf(u32)]u8 = undefined;
    const n = read(sync[0], &err_buf) catch 0;
    if (n == err_buf.len) {
        // The child could not exec and is already gone; reap it now so it does
        // not surface later as an unknown pid.
        var status: i32 = 0;
        _ = sys.wait4(pid, &status, 0, null);
        return error.ExecFailed;
    }

    return .{ .pid = pid, .pgid = pid };
}

/// The child half of `spawn`. Never returns. Async-signal-safe throughout:
/// every allocation this needed was done by the caller before the fork.
fn childExec(args: SpawnArgs, sync_fd: Fd) noreturn {
    // Its own Group, so a later kill reaches the shell's children too.
    _ = sys.setpgid(0, 0);

    // Handlers inherited across fork would run this child's copy of devrun's
    // logic on Ctrl-C. Reset to default and unblock everything.
    var i: u32 = 1;
    while (i < 32) : (i += 1) {
        const sig: SIG = @fromBackingInt(@intCast(i));
        // SIGKILL and SIGSTOP cannot be caught, so they were never inherited
        // as anything but default — and asking to reset them is an error.
        if (sig == .KILL or sig == .STOP) continue;
        setHandler(sig, SIG.DFL, 0);
    }
    if (is_darwin) {
        var empty: c.sigset_t = 0;
        _ = c.sigemptyset(&empty);
        _ = c.sigprocmask(c.SIG.SETMASK, &empty, null);
    } else {
        var empty = linux.sigemptyset();
        _ = linux.sigprocmask(linux.SIG.SETMASK, &empty, null);
    }

    // The descriptor limit devrun raised for its own watcher is not the
    // Worker's to inherit: it should run under the limit it would have had
    // without devrun in the middle.
    restoreFdLimit();

    if (args.cwd) |dir| {
        if (errno(sys.chdir(dir)) != .SUCCESS) fail(sync_fd);
    }

    // dup2 clears O_CLOEXEC and O_NONBLOCK on the copy, which is exactly what
    // the child should see: plain blocking descriptors.
    if (errno(sys.dup2(args.input, 0)) != .SUCCESS) fail(sync_fd);
    if (errno(sys.dup2(args.output, 1)) != .SUCCESS) fail(sync_fd);
    if (errno(sys.dup2(args.output, 2)) != .SUCCESS) fail(sync_fd);

    _ = sys.execve(args.path, args.argv, args.envp);
    fail(sync_fd);
}

fn fail(sync_fd: Fd) noreturn {
    const code: u32 = 1;
    _ = sys.write(sync_fd, @ptrCast(&code), @sizeOf(u32));
    if (is_darwin) c._exit(127);
    linux.exit(127);
}

/// Finds `name` on PATH, or returns it unchanged when it already looks like a
/// path. Runs in the parent, where allocating is allowed.
pub fn resolvePath(arena: Allocator, name: []const u8, path_env: ?[]const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return arena.dupeSentinel(u8, name, 0);
    }
    const path = path_env orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, name }, 0);
        if (errno(sys.faccessat(native.AT.FDCWD, full.ptr, native.X_OK, 0)) == .SUCCESS) {
            return full;
        }
    }
    return error.FileNotFound;
}

/// Replaces this process with `path`, or returns when it could not be run.
pub fn execve(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) void {
    _ = sys.execve(path, argv, envp);
}

pub fn rename(from: [*:0]const u8, to: [*:0]const u8) !void {
    if (is_darwin) return check(darwin_sys.ret(c.rename(from, to)));
    return check(linux.rename(from, to));
}

// ------------------------------------------------------------- descriptor limit

/// The soft `RLIMIT_NOFILE` devrun started with, when it has raised it.
var original_fd_limit: ?native.rlimit = null;

/// Lifts the soft descriptor limit as far toward `want` as the hard limit
/// allows, and returns what it ended up at.
///
/// For the macOS watcher, which needs a descriptor per watched file where
/// inotify needed none, against a soft default of 256. The old limit is kept
/// so `spawn` can hand each Worker the limit it would have had anyway.
pub fn raiseFdLimit(want: u64) u64 {
    var lim: native.rlimit = undefined;
    if (getrlimit(&lim) != 0) return 0;
    if (lim.cur >= want) return lim.cur;
    const target = @min(want, lim.max);
    if (target <= lim.cur) return lim.cur;
    const before = lim;
    lim.cur = target;
    if (setrlimit(&lim) != 0) return before.cur;
    if (original_fd_limit == null) original_fd_limit = before;
    return target;
}

/// Async-signal-safe: one syscall on a value read before the fork.
fn restoreFdLimit() void {
    const lim = original_fd_limit orelse return;
    _ = setrlimit(&lim);
}

fn getrlimit(lim: *native.rlimit) usize {
    if (is_darwin) return darwin_sys.ret(c.getrlimit(.NOFILE, lim));
    return linux.getrlimit(.NOFILE, lim);
}

fn setrlimit(lim: *const native.rlimit) usize {
    if (is_darwin) return darwin_sys.ret(c.setrlimit(.NOFILE, lim));
    return linux.setrlimit(.NOFILE, lim);
}

// ------------------------------------------------------------- kqueue

/// macOS's file-change notification, for the watcher. A kqueue descriptor is
/// readable while it holds events, so it joins the Session's `poll` set like
/// the inotify descriptor it replaces.
pub const kq = struct {
    pub const Kevent = c.Kevent;
    pub const NOTE = c.NOTE;

    pub fn init() !Fd {
        const fd = try checkFd(darwin_sys.ret(c.kqueue()));
        setCloexec(fd);
        return fd;
    }

    /// Watches the vnode behind `fd` for `fflags`, tagged with `id`. Closing
    /// `fd` removes the watch; there is no separate call to forget it.
    pub fn watch(kqfd: Fd, fd: Fd, fflags: u32, id: usize) !void {
        const change = [1]c.Kevent{.{
            .ident = @intCast(fd),
            .filter = c.EVFILT.VNODE,
            .flags = c.EV.ADD | c.EV.CLEAR,
            .fflags = fflags,
            .data = 0,
            .udata = id,
        }};
        var none: [0]c.Kevent = .{};
        const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
        try check(darwin_sys.ret(c.kevent(kqfd, &change, 1, &none, 0, &zero)));
    }

    /// Whatever is pending, without blocking.
    pub fn drain(kqfd: Fd, out: []c.Kevent) usize {
        const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
        const none: [0]c.Kevent = .{};
        const rc = c.kevent(kqfd, &none, 0, out.ptr, @intCast(out.len), &zero);
        return if (rc < 0) 0 else @intCast(rc);
    }

    /// A descriptor that exists only to be watched: `O_EVTONLY` does not stop
    /// the volume it is on from being unmounted, which an ordinary read
    /// descriptor would.
    pub fn openEventOnly(path: [*:0]const u8, dir: bool, follow: bool) !Fd {
        return open(path, .{
            .ACCMODE = .RDONLY,
            .EVTONLY = true,
            .DIRECTORY = dir,
            .NOFOLLOW = !follow,
            .CLOEXEC = true,
        }, 0);
    }

    pub const Identity = struct { dev: i64, ino: u64 };

    /// Where the file behind `fd` is now (`F_GETPATH`), which follows a
    /// rename the path it was opened by does not.
    pub fn pathOf(fd: Fd, buf: *[1024]u8) ?[]const u8 {
        const F_GETPATH = 50;
        if (c.fcntl(fd, F_GETPATH, buf) == -1) return null;
        const path = std.mem.sliceTo(buf, 0);
        return if (path.len == 0) null else path;
    }

    /// Which file a descriptor is on, so two paths to one directory share a
    /// watch the way inotify would have them share a `wd`.
    pub fn identity(fd: Fd) ?Identity {
        var st: c.Stat = undefined;
        if (c.fstat(fd, &st) != 0) return null;
        return .{ .dev = st.dev, .ino = st.ino };
    }
};

// ------------------------------------------------------------- macOS shim

/// libSystem, made to answer the way the Linux kernel does: a value, or a
/// negated errno in an unsigned word. That is the whole trick that lets the
/// rest of this file be written once — `errno` decodes either.
const darwin_sys = struct {
    fn ret(rc: anytype) usize {
        if (rc == -1) return @bitCast(-@as(isize, c._errno().*));
        return @intCast(rc);
    }

    extern "c" fn getpgid(pid: c.pid_t) c.pid_t;

    /// `kill` with a raw number, for signal 0.
    fn killNumber(pid: c.pid_t, sig: c_int) c_int {
        const raw: *const fn (c.pid_t, c_int) callconv(.c) c_int = @ptrCast(&c.kill);
        return raw(pid, sig);
    }

    fn clock_gettime(clock: c.clockid_t, ts: *c.timespec) usize {
        return ret(c.clock_gettime(clock, ts));
    }
    fn close(fd: Fd) usize {
        return ret(c.close(fd));
    }
    fn read(fd: Fd, ptr: [*]u8, len: usize) usize {
        return ret(c.read(fd, ptr, len));
    }
    fn write(fd: Fd, ptr: [*]const u8, len: usize) usize {
        return ret(c.write(fd, ptr, len));
    }
    fn pread(fd: Fd, ptr: [*]u8, len: usize, offset: i64) usize {
        return ret(c.pread(fd, ptr, len, offset));
    }
    fn unlink(path: [*:0]const u8) usize {
        return ret(c.unlink(path));
    }
    fn rmdir(path: [*:0]const u8) usize {
        return ret(c.rmdir(path));
    }
    fn symlink(target: [*:0]const u8, path: [*:0]const u8) usize {
        return ret(c.symlink(target, path));
    }
    fn mkdir(path: [*:0]const u8, mode: c.mode_t) usize {
        return ret(c.mkdir(path, mode));
    }
    fn openat(dir: Fd, path: [*:0]const u8, flags: c.O, mode: c.mode_t) usize {
        return ret(c.openat(dir, path, flags, @as(c_uint, mode)));
    }
    fn fcntl(fd: Fd, cmd: c_int, arg: anytype) usize {
        return ret(c.fcntl(fd, cmd, @as(c_int, @intCast(arg))));
    }
    fn socket(domain: u32, kind: u32, protocol: u32) usize {
        return ret(c.socket(domain, kind, protocol));
    }
    fn connect(fd: Fd, addr: *const anyopaque, len: c.socklen_t) usize {
        return ret(c.connect(fd, @ptrCast(@alignCast(addr)), len));
    }
    fn bind(fd: Fd, addr: *const c.sockaddr, len: c.socklen_t) usize {
        return ret(c.bind(fd, addr, len));
    }
    fn listen(fd: Fd, backlog: u32) usize {
        return ret(c.listen(fd, backlog));
    }
    fn getsockopt(fd: Fd, level: i32, name: u32, val: ?*anyopaque, len: *c.socklen_t) usize {
        return ret(c.getsockopt(fd, level, name, val, len));
    }
    fn poll(fds: [*]c.pollfd, n: usize, timeout: i32) usize {
        return ret(c.poll(fds, @intCast(n), timeout));
    }
    fn fork() usize {
        return ret(c.fork());
    }
    fn setsid() usize {
        return ret(c.setsid());
    }
    fn dup2(old: Fd, new: Fd) usize {
        return ret(c.dup2(old, new));
    }
    fn nanosleep(req: *const c.timespec, rem: ?*c.timespec) usize {
        return ret(c.nanosleep(req, rem));
    }
    fn wait4(pid: c.pid_t, status: ?*i32, options: u32, ru: ?*c.rusage) usize {
        return ret(c.wait4(pid, status, @intCast(options), ru));
    }
    fn kill(pid: c.pid_t, sig: SIG) usize {
        return ret(c.kill(pid, sig));
    }
    fn setpgid(pid: c.pid_t, pgid: c.pid_t) usize {
        return ret(c.setpgid(pid, pgid));
    }
    fn chdir(path: [*:0]const u8) usize {
        return ret(c.chdir(path));
    }
    fn execve(
        path: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) usize {
        return ret(c.execve(path, argv, envp));
    }
    fn faccessat(dir: Fd, path: [*:0]const u8, mode: c_uint, flags: c_uint) usize {
        return ret(c.faccessat(dir, path, mode, flags));
    }
};

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
