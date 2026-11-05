//! File watching: turns "something under these paths changed" into "this
//! Worker is due for a restart".
//!
//! The Watcher owns one inotify descriptor and nothing else that blocks. The
//! Session adds `pollFd()` to its poll set, calls `onReadable()` when it fires,
//! folds `wakeAt()` into its poll timeout, and drains `takeDue()` afterwards.
//! There is no thread and no timer: a debounce is just a deadline the loop
//! already knows how to wait for.
//!
//! inotify is not recursive, so a directory target becomes one watch per
//! directory in the tree. A new subdirectory is watched as soon as its
//! CREATE event is read. Two things keep that honest:
//!
//!   * Files may land in the new directory before the watch does, so the
//!     creation of a directory itself counts as a change. The restart then
//!     happens after the debounce, when the contents are all there.
//!   * A watch on a file would be lost when an editor saves by writing a
//!     temp file and renaming it over the original. File targets are therefore
//!     watched through their parent directory, filtered by basename.
//!
//! Known limit: paths that do not exist at `init` are reported in `problems`
//! and never picked up later. Watching a not-yet-created directory would mean
//! watching its ancestors, and the cost of that is out of proportion here.

const std = @import("std");
const os = @import("os.zig");
const Allocator = std.mem.Allocator;
const linux = os.linux;
const IN = linux.IN;

/// Upper bound on live watches across all targets. The kernel has its own
/// limit (often 8192 per user, shared with every editor and bundler), but
/// ours bounds devrun's memory regardless of how it is configured.
pub const max_watches = 16384;

/// What counts as a change. CLOSE_WRITE rather than MODIFY: a save is one
/// CLOSE_WRITE, while MODIFY fires on every write(2) of a large file.
const event_mask: u32 = IN.CLOSE_WRITE | IN.CREATE | IN.DELETE | IN.MOVED_FROM | IN.MOVED_TO;

pub const Target = struct {
    /// Index of the Worker this target restarts.
    worker: u32,
    /// Directory the paths are relative to (the Worker's resolved cwd). Absolute paths in `paths` ignore it.
    base: []const u8,
    paths: []const []const u8,
    /// Basename patterns; `*` matches any run of characters. Ignored names are neither watched nor reported.
    ignore: []const []const u8,
    debounce_ms: u32,
};

/// Why one watch is wanted. A directory can serve several targets, and a file
/// target and a directory target can even share one.
const Interest = struct {
    /// Index into `Watcher.infos`.
    target: u32,
    /// Only report this basename (a file target watched via its parent).
    file: ?[]const u8,
    /// Extend the watch to subdirectories as they appear.
    recursive: bool,

    fn eql(a: Interest, b: Interest) bool {
        if (a.target != b.target or a.recursive != b.recursive) return false;
        if (a.file == null or b.file == null) return a.file == null and b.file == null;
        return std.mem.eql(u8, a.file.?, b.file.?);
    }
};

/// One watched directory. Heap-allocated so pointers into the `wd` map stay
/// valid while the map grows.
const Dir = struct {
    path: []u8,
    interests: std.ArrayList(Interest) = .empty,
};

/// The parts of a Target that outlive `init`, copied into the arena so the
/// caller's slices need not stay alive.
const Info = struct {
    worker: u32,
    debounce_ms: u32,
    ignore: []const []const u8,
};

const Outcome = enum { ok, not_dir, missing, failed };

pub const Watcher = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    fd: os.Fd = -1,
    infos: []Info = &.{},
    /// Debounce deadline per Worker (monotonic ms), null when quiet.
    due: []?u64 = &.{},
    by_wd: std.AutoHashMapUnmanaged(i32, *Dir) = .empty,
    /// Set once the kernel or our own cap refuses more watches, so the
    /// warning is recorded exactly once and the walk stops trying.
    full: bool = false,

    /// Paths that could not be watched (missing, or the kernel watch limit
    /// hit), as "path: reason" lines for a warning. Each string is owned by
    /// the Watcher and freed by `deinit`; the list is only appended to during
    /// `init` and when a watch limit is hit later.
    problems: std.ArrayList([]const u8) = .empty,

    pub fn init(gpa: Allocator, targets: []const Target, worker_count: usize) !Watcher {
        var self: Watcher = .{ .gpa = gpa, .arena = .init(gpa) };
        errdefer self.deinit();
        if (targets.len == 0) return self;

        const a = self.arena.allocator();
        self.infos = try a.alloc(Info, targets.len);
        for (targets, self.infos) |t, *info| {
            if (t.worker >= worker_count) return error.WorkerOutOfRange;
            const ignore = try a.alloc([]const u8, t.ignore.len);
            for (t.ignore, ignore) |src, *dst| dst.* = try a.dupe(u8, src);
            info.* = .{ .worker = t.worker, .debounce_ms = t.debounce_ms, .ignore = ignore };
        }
        self.due = try gpa.alloc(?u64, worker_count);
        @memset(self.due, null);

        self.fd = try os.inotifyInit();
        for (targets, 0..) |t, i| {
            for (t.paths) |p| try self.addPath(@intCast(i), t.base, p);
        }
        // Nothing could be watched: hand the descriptor back rather than
        // leave the Session polling something that can never fire.
        if (self.by_wd.count() == 0) {
            os.close(self.fd);
            self.fd = -1;
        }
        return self;
    }

    pub fn deinit(self: *Watcher) void {
        if (self.fd >= 0) os.close(self.fd);
        var it = self.by_wd.valueIterator();
        while (it.next()) |d| self.freeDir(d.*);
        self.by_wd.deinit(self.gpa);
        for (self.problems.items) |p| self.gpa.free(p);
        self.problems.deinit(self.gpa);
        self.gpa.free(self.due);
        self.arena.deinit();
        self.* = undefined;
    }

    /// For the poll set; null when nothing is watched.
    pub fn pollFd(self: *const Watcher) ?os.PollFd {
        if (self.fd < 0) return null;
        return .{ .fd = self.fd, .events = os.POLL.IN, .revents = 0 };
    }

    /// Call when the descriptor is readable. Drains every pending event
    /// without blocking (bounded per call, so a flood cannot starve the rest
    /// of the loop; poll is level-triggered and calls us again).
    pub fn onReadable(self: *Watcher, now_ms: u64) void {
        if (self.fd < 0) return;
        // inotify_event is 4-byte aligned and the kernel packs records
        // back to back, so the buffer must honour that alignment.
        var buf: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
        var reads: usize = 0;
        while (reads < 64) : (reads += 1) {
            const n = os.read(self.fd, &buf) catch return;
            if (n == 0) return;
            var off: usize = 0;
            const header = @sizeOf(linux.inotify_event);
            while (off + header <= n) {
                const ev: *const linux.inotify_event = @ptrCast(@alignCast(&buf[off]));
                const end = off + header + ev.len;
                if (end > n) break;
                const name: ?[]const u8 = if (ev.len == 0)
                    null
                else
                    std.mem.sliceTo(buf[off + header .. end], 0);
                self.handle(ev.wd, ev.mask, name, now_ms);
                off = end;
            }
        }
    }

    /// Soonest debounce deadline, or null.
    pub fn wakeAt(self: *const Watcher) ?u64 {
        var soonest: ?u64 = null;
        for (self.due) |d| {
            const t = d orelse continue;
            if (soonest == null or t < soonest.?) soonest = t;
        }
        return soonest;
    }

    /// One Worker whose debounce has elapsed, clearing it; null when none.
    /// Callers loop.
    pub fn takeDue(self: *Watcher, now_ms: u64) ?u32 {
        for (self.due, 0..) |d, i| {
            const t = d orelse continue;
            if (t > now_ms) continue;
            self.due[i] = null;
            return @intCast(i);
        }
        return null;
    }

    // ------------------------------------------------------------ events

    fn handle(self: *Watcher, wd: i32, mask: u32, name: ?[]const u8, now_ms: u64) void {
        if (mask & IN.Q_OVERFLOW != 0) {
            // The kernel dropped events, so we cannot know what changed.
            // Restarting everything is wrong less often than missing a save.
            for (self.infos, 0..) |_, i| self.touch(@intCast(i), now_ms);
            return;
        }
        const d = self.by_wd.get(wd) orelse return;
        if (mask & IN.IGNORED != 0) {
            // The directory was deleted (or unmounted): the kernel has
            // already dropped the watch, so only our bookkeeping remains.
            _ = self.by_wd.remove(wd);
            self.freeDir(d);
            return;
        }
        const nm = name orelse return;
        for (d.interests.items) |in| {
            if (self.ignored(in.target, nm)) continue;
            if (in.file) |f| if (!std.mem.eql(u8, f, nm)) continue;
            self.touch(in.target, now_ms);
        }
        if (mask & IN.ISDIR != 0 and mask & (IN.CREATE | IN.MOVED_TO) != 0) {
            self.watchNewDir(d, nm) catch {
                // Out of memory: we cannot extend the watch, so make sure
                // the change itself is not lost.
                for (d.interests.items) |in| self.touch(in.target, now_ms);
            };
        }
    }

    fn watchNewDir(self: *Watcher, parent: *Dir, name: []const u8) Allocator.Error!void {
        var child: std.ArrayList(Interest) = .empty;
        defer child.deinit(self.gpa);
        try self.inherit(parent, name, &child);
        if (child.items.len == 0) return;
        const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ parent.path, name });
        defer self.gpa.free(path);
        _ = try self.watchDir(path, child.items, false);
    }

    fn touch(self: *Watcher, target: u32, now_ms: u64) void {
        const info = self.infos[target];
        self.due[info.worker] = now_ms +| info.debounce_ms;
    }

    fn ignored(self: *const Watcher, target: u32, name: []const u8) bool {
        for (self.infos[target].ignore) |pat| {
            if (globMatch(pat, name)) return true;
        }
        return false;
    }

    // ------------------------------------------------------------ setup

    fn addPath(self: *Watcher, target: u32, base: []const u8, path: []const u8) !void {
        const full = try joinPath(self.gpa, base, path);
        defer self.gpa.free(full);
        const as_dir = [_]Interest{.{ .target = target, .file = null, .recursive = true }};
        switch (try self.watchDir(full, &as_dir, true)) {
            .ok => {},
            .missing => try self.problem(path, "not found"),
            .failed => try self.problem(path, "cannot be watched"),
            .not_dir => {
                // A file: watch its parent and filter by name.
                var trimmed: []const u8 = full;
                while (trimmed.len > 1 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
                const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/');
                const parent = if (slash) |s| (if (s == 0) "/" else trimmed[0..s]) else ".";
                const file = if (slash) |s| trimmed[s + 1 ..] else trimmed;
                const as_file = [_]Interest{.{
                    .target = target,
                    .file = try self.arena.allocator().dupe(u8, file),
                    .recursive = false,
                }};
                switch (try self.watchDir(parent, &as_file, true)) {
                    .ok => {},
                    .missing => try self.problem(path, "not found"),
                    else => try self.problem(path, "cannot be watched"),
                }
            },
        }
    }

    /// Adds a watch on `path` and merges `interests` into it. When any
    /// interest is recursive, the existing subdirectories are walked too.
    fn watchDir(self: *Watcher, path: []const u8, interests: []const Interest, root: bool) Allocator.Error!Outcome {
        if (self.full) return .failed;
        if (self.by_wd.count() >= max_watches) {
            try self.exhausted("watch cap of 16384 reached, further paths are not watched");
            return .failed;
        }
        const pz = try self.gpa.dupeSentinel(u8, path, 0);
        defer self.gpa.free(pz);

        // Roots follow symlinks (the user named them); anything found while
        // walking does not, so a link back up the tree cannot loop.
        var m = event_mask | IN.ONLYDIR;
        if (!root) m |= IN.DONT_FOLLOW;
        const wd = os.inotifyAddWatch(self.fd, pz, m) catch |e| switch (e) {
            error.NoSpaceLeft => {
                try self.exhausted("kernel watch limit reached (fs.inotify.max_user_watches), further paths are not watched");
                return .failed;
            },
            error.NotDir => return .not_dir,
            error.FileNotFound => return .missing,
            else => return .failed,
        };

        const d = self.by_wd.get(wd) orelse blk: {
            const nd = try self.gpa.create(Dir);
            errdefer self.gpa.destroy(nd);
            nd.* = .{ .path = try self.gpa.dupe(u8, path) };
            errdefer self.gpa.free(nd.path);
            try self.by_wd.put(self.gpa, wd, nd);
            break :blk nd;
        };
        // The same inode reached by a new path (a moved directory): keep the
        // latest, since it is the one a later subdirectory must be joined to.
        if (!std.mem.eql(u8, d.path, path)) {
            const fresh = try self.gpa.dupe(u8, path);
            self.gpa.free(d.path);
            d.path = fresh;
        }
        var recursive = false;
        for (interests) |in| {
            recursive = recursive or in.recursive;
            for (d.interests.items) |have| {
                if (have.eql(in)) break;
            } else try d.interests.append(self.gpa, in);
        }
        if (recursive) try self.walk(d, pz);
        return .ok;
    }

    fn walk(self: *Watcher, d: *Dir, pz: [:0]const u8) Allocator.Error!void {
        // Collect first, recurse after: the iterator carries an 8 KiB buffer
        // and a deep tree would otherwise stack one per level.
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| self.gpa.free(n);
            names.deinit(self.gpa);
        }
        var it = os.DirIter.open(pz) catch return;
        while (it.nextEntry()) |e| {
            if (!e.is_dir) continue;
            if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
            const copy = try self.gpa.dupe(u8, e.name);
            names.append(self.gpa, copy) catch |err| {
                self.gpa.free(copy);
                it.close();
                return err;
            };
        }
        it.close();

        for (names.items) |name| {
            var child: std.ArrayList(Interest) = .empty;
            defer child.deinit(self.gpa);
            try self.inherit(d, name, &child);
            if (child.items.len == 0) continue;
            const path = try std.fmt.allocPrint(self.gpa, "{s}/{s}", .{ d.path, name });
            defer self.gpa.free(path);
            _ = try self.watchDir(path, child.items, false);
        }
    }

    /// The interests a subdirectory `name` inherits from `parent`: the
    /// recursive ones whose target does not ignore that name. Empty means the
    /// directory is not worth a watch at all.
    fn inherit(self: *Watcher, parent: *const Dir, name: []const u8, out: *std.ArrayList(Interest)) Allocator.Error!void {
        for (parent.interests.items) |in| {
            if (!in.recursive or self.ignored(in.target, name)) continue;
            try out.append(self.gpa, in);
        }
    }

    fn problem(self: *Watcher, path: []const u8, reason: []const u8) Allocator.Error!void {
        const line = try std.fmt.allocPrint(self.gpa, "{s}: {s}", .{ path, reason });
        errdefer self.gpa.free(line);
        try self.problems.append(self.gpa, line);
    }

    fn exhausted(self: *Watcher, reason: []const u8) Allocator.Error!void {
        if (self.full) return;
        self.full = true;
        try self.problem("(watch limit)", reason);
    }

    fn freeDir(self: *Watcher, d: *Dir) void {
        d.interests.deinit(self.gpa);
        self.gpa.free(d.path);
        self.gpa.destroy(d);
    }
};

fn joinPath(gpa: Allocator, base: []const u8, path: []const u8) ![]u8 {
    if (path.len > 0 and path[0] == '/') return gpa.dupe(u8, path);
    if (base.len == 0) return gpa.dupe(u8, path);
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, path });
}

/// Shell-style match where `*` is any run of characters (including none) and
/// everything else is literal. Iterative with a single backtrack point, so it
/// cannot go exponential on a pattern like `*a*a*a*b`.
fn globMatch(pat: []const u8, name: []const u8) bool {
    var p: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (n < name.len) {
        if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            mark = n;
        } else if (p < pat.len and pat[p] == name[n]) {
            p += 1;
            n += 1;
        } else if (star) |s| {
            p = s + 1;
            mark += 1;
            n = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

/// A scratch directory under /tmp, unique per test and per run.
const Scratch = struct {
    path: []u8,

    fn init(label: []const u8) !Scratch {
        const path = try std.fmt.allocPrint(testing.allocator, "/tmp/devrun-watch-{s}-{d}", .{ label, os.nowMs() });
        errdefer testing.allocator.free(path);
        try os.makePath(path);
        return .{ .path = path };
    }

    fn deinit(self: *Scratch) void {
        removeTree(testing.allocator, self.path);
        testing.allocator.free(self.path);
    }

    fn sub(self: Scratch, rel: []const u8) ![]u8 {
        return std.fmt.allocPrint(testing.allocator, "{s}/{s}", .{ self.path, rel });
    }

    fn mkdir(self: Scratch, rel: []const u8) !void {
        const p = try self.sub(rel);
        defer testing.allocator.free(p);
        try os.makePath(p);
    }

    fn write(self: Scratch, rel: []const u8, data: []const u8) !void {
        const p = try self.sub(rel);
        defer testing.allocator.free(p);
        const z = try testing.allocator.dupeSentinel(u8, p, 0);
        defer testing.allocator.free(z);
        const fd = try os.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        defer os.close(fd);
        try os.writeAll(fd, data);
    }
};

fn removeTree(gpa: Allocator, path: []const u8) void {
    const z = gpa.dupeSentinel(u8, path, 0) catch return;
    defer gpa.free(z);
    var it = os.DirIter.open(z) catch return;
    var names: std.ArrayList(os.DirIter.Entry) = .empty;
    defer {
        for (names.items) |e| gpa.free(e.name);
        names.deinit(gpa);
    }
    while (it.nextEntry()) |e| {
        if (std.mem.eql(u8, e.name, ".") or std.mem.eql(u8, e.name, "..")) continue;
        const copy = gpa.dupe(u8, e.name) catch break;
        names.append(gpa, .{ .name = copy, .is_dir = e.is_dir }) catch {
            gpa.free(copy);
            break;
        };
    }
    it.close();
    for (names.items) |e| {
        const child = std.fmt.allocPrint(gpa, "{s}/{s}", .{ path, e.name }) catch continue;
        defer gpa.free(child);
        if (e.is_dir) {
            removeTree(gpa, child);
        } else {
            const cz = gpa.dupeSentinel(u8, child, 0) catch continue;
            defer gpa.free(cz);
            os.unlink(cz);
        }
    }
    os.rmdir(z);
}

/// Waits up to `timeout_ms` for the descriptor, then reads events as if the
/// clock said 1000. Events are queued synchronously by the syscall that caused
/// them, so a short timeout is enough to prove "nothing arrived".
fn pump(w: *Watcher, timeout_ms: i32) !void {
    var fds = [_]os.PollFd{w.pollFd().?};
    if (try os.poll(&fds, timeout_ms) > 0) w.onReadable(1000);
}

test "a write makes the worker due only after the debounce" {
    var s = try Scratch.init("debounce");
    defer s.deinit();
    const targets = [_]Target{.{ .worker = 0, .base = s.path, .paths = &.{"."}, .ignore = &.{}, .debounce_ms = 50 }};
    var w = try Watcher.init(testing.allocator, &targets, 1);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 0), w.problems.items.len);
    try testing.expectEqual(@as(?u64, null), w.wakeAt());

    try s.write("a.txt", "hi");
    try pump(&w, 500);
    try testing.expectEqual(@as(?u64, 1050), w.wakeAt());
    try testing.expectEqual(@as(?u32, null), w.takeDue(1049));
    try testing.expectEqual(@as(?u32, 0), w.takeDue(1050));
    try testing.expectEqual(@as(?u32, null), w.takeDue(2000));
    try testing.expectEqual(@as(?u64, null), w.wakeAt());
}

test "a burst of saves pushes the deadline out" {
    var s = try Scratch.init("burst");
    defer s.deinit();
    const targets = [_]Target{.{ .worker = 0, .base = s.path, .paths = &.{"."}, .ignore = &.{}, .debounce_ms = 50 }};
    var w = try Watcher.init(testing.allocator, &targets, 1);
    defer w.deinit();

    try s.write("a.txt", "1");
    try pump(&w, 500);
    try testing.expectEqual(@as(?u64, 1050), w.wakeAt());
    try s.write("a.txt", "2");
    var fds = [_]os.PollFd{w.pollFd().?};
    try testing.expect(try os.poll(&fds, 500) > 0);
    w.onReadable(1030);
    try testing.expectEqual(@as(?u64, 1080), w.wakeAt());
}

test "ignored names never trigger" {
    var s = try Scratch.init("ignore");
    defer s.deinit();
    try s.mkdir("node_modules");
    const targets = [_]Target{.{
        .worker = 0,
        .base = s.path,
        .paths = &.{"."},
        .ignore = &.{ "*.swp", "node_modules" },
        .debounce_ms = 10,
    }};
    var w = try Watcher.init(testing.allocator, &targets, 1);
    defer w.deinit();

    try s.write("x.swp", "tmp");
    try s.write("node_modules/dep.js", "x");
    try s.mkdir("node_modules/nested");
    try s.write("node_modules/nested/y.js", "x");
    try pump(&w, 50);
    try testing.expectEqual(@as(?u64, null), w.wakeAt());

    // node_modules got no watch of its own, only the root did.
    try testing.expectEqual(@as(u32, 1), w.by_wd.count());

    try s.write("real.js", "x");
    try pump(&w, 500);
    try testing.expect(w.wakeAt() != null);
}

test "a subdirectory created after init is picked up" {
    var s = try Scratch.init("newdir");
    defer s.deinit();
    const targets = [_]Target{.{ .worker = 0, .base = s.path, .paths = &.{"."}, .ignore = &.{}, .debounce_ms = 10 }};
    var w = try Watcher.init(testing.allocator, &targets, 1);
    defer w.deinit();

    try s.mkdir("pkg/deep");
    try pump(&w, 500);
    try testing.expectEqual(@as(?u32, 0), w.takeDue(2000));

    try s.write("pkg/deep/file.txt", "x");
    try pump(&w, 500);
    try testing.expectEqual(@as(?u32, 0), w.takeDue(2000));
}

test "a file target ignores its siblings and survives a rename-over" {
    var s = try Scratch.init("file");
    defer s.deinit();
    try s.write("app.conf", "v1");
    const targets = [_]Target{.{ .worker = 0, .base = s.path, .paths = &.{"app.conf"}, .ignore = &.{}, .debounce_ms = 10 }};
    var w = try Watcher.init(testing.allocator, &targets, 1);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 0), w.problems.items.len);

    try s.write("other.txt", "x");
    try pump(&w, 50);
    try testing.expectEqual(@as(?u64, null), w.wakeAt());

    // Editors save by writing a temp file and renaming it over the target.
    try s.write("app.conf.tmp", "v2");
    const from = try s.sub("app.conf.tmp");
    defer testing.allocator.free(from);
    const to = try s.sub("app.conf");
    defer testing.allocator.free(to);
    const fz = try testing.allocator.dupeSentinel(u8, from, 0);
    defer testing.allocator.free(fz);
    const tz = try testing.allocator.dupeSentinel(u8, to, 0);
    defer testing.allocator.free(tz);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.rename(fz, tz)));
    try pump(&w, 500);
    try testing.expectEqual(@as(?u32, 0), w.takeDue(2000));
}

test "two targets on one directory both fire" {
    var s = try Scratch.init("shared");
    defer s.deinit();
    const targets = [_]Target{
        .{ .worker = 0, .base = s.path, .paths = &.{"."}, .ignore = &.{}, .debounce_ms = 10 },
        .{ .worker = 1, .base = s.path, .paths = &.{"."}, .ignore = &.{"*.log"}, .debounce_ms = 20 },
    };
    var w = try Watcher.init(testing.allocator, &targets, 2);
    defer w.deinit();
    try testing.expectEqual(@as(u32, 1), w.by_wd.count());

    try s.write("a.txt", "x");
    try pump(&w, 500);
    try testing.expectEqual(@as(?u64, 1010), w.wakeAt());
    try testing.expectEqual(@as(?u32, 0), w.takeDue(1010));
    try testing.expectEqual(@as(?u32, null), w.takeDue(1019));
    try testing.expectEqual(@as(?u32, 1), w.takeDue(1020));

    // Only the first target is interested in a .log file.
    try s.write("run.log", "x");
    try pump(&w, 500);
    try testing.expectEqual(@as(?u32, 0), w.takeDue(2000));
    try testing.expectEqual(@as(?u32, null), w.takeDue(2000));
}

test "a missing path lands in problems" {
    var s = try Scratch.init("missing");
    defer s.deinit();
    const targets = [_]Target{.{ .worker = 0, .base = s.path, .paths = &.{"nope/here"}, .ignore = &.{}, .debounce_ms = 10 }};
    var w = try Watcher.init(testing.allocator, &targets, 1);
    defer w.deinit();
    try testing.expectEqual(@as(usize, 1), w.problems.items.len);
    try testing.expect(std.mem.startsWith(u8, w.problems.items[0], "nope/here: "));
    try testing.expectEqual(@as(?os.PollFd, null), w.pollFd());
}

test "globMatch" {
    try testing.expect(globMatch("*.swp", "x.swp"));
    try testing.expect(!globMatch("*.swp", "x.swpx"));
    try testing.expect(globMatch("node_modules", "node_modules"));
    try testing.expect(!globMatch("node_modules", "node_modules2"));
    try testing.expect(globMatch("*", ""));
    try testing.expect(globMatch(".#*", ".#lock"));
    try testing.expect(globMatch("a*b*c", "aXbYbZc"));
    try testing.expect(!globMatch("a*b*c", "aXbYbZ"));
}
