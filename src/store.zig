//! Where Archives live between Sessions.
//!
//! One directory per Session under `.devrun/logs`, named for the moment it
//! started, plus a `latest` symlink pointing at the newest. See
//! `docs/adr/0006-an-archive-per-session.md` — the short version is that a
//! Session that truncated the previous one's Archives destroyed the log you
//! wanted at exactly the moment you restarted to reproduce the thing that
//! wrote it.
//!
//! Nothing here holds a directory open. Every operation is a fresh walk, so a
//! Session that is running and a `devrun clean` in another terminal cannot get
//! a stale view of each other.
//!
//! ## What counts as a Session
//!
//! Only a directory whose name is exactly a stamp — `2026-08-14T10-32-05Z`.
//! Every deletion in this file is filtered through `isStamp`, so a `notes.txt`
//! or a `keepme/` that somebody parked in the logs directory is not something
//! `clean` can reach. The rule is deliberately narrow: this code deletes
//! things, and the cost of it being too shy is a stale directory nobody
//! notices, while the cost of it being too eager is somebody's file.

const std = @import("std");
const os = @import("os.zig");

const Allocator = std.mem.Allocator;

/// `2026-08-14T10-32-05Z`. UTC, because reading `/etc/localtime` to render a
/// name is a TZif parser this project does not otherwise need, and a stamp
/// that lies about the zone is worse than one that says which zone it is in.
///
/// Sorts lexically into chronological order, which is what lets `list` order
/// Sessions without parsing any of them back into a time.
pub const stamp_len = "2026-08-14T10-32-05Z".len;

pub fn stamp(buf: *[stamp_len]u8, wall_seconds: i64) []const u8 {
    const secs: u64 = if (wall_seconds < 0) 0 else @intCast(wall_seconds);
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}Z", .{
        day.year,
        md.month.numeric(),
        md.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Whether a directory name is one of ours. Shape only — a name that looks
/// like a stamp is treated as a Session even if the date in it is nonsense,
/// because the alternative is deciding that somebody's clock skew makes their
/// logs undeletable.
pub fn isStamp(name: []const u8) bool {
    if (name.len != stamp_len) return false;
    for (name, 0..) |c, i| {
        const want_digit = switch (i) {
            4, 7, 10, 13, 16 => false,
            19 => false,
            else => true,
        };
        if (want_digit) {
            if (!std.ascii.isDigit(c)) return false;
        } else {
            const ok = switch (i) {
                4, 7 => c == '-',
                10 => c == 'T',
                13, 16 => c == '-',
                19 => c == 'Z',
                else => unreachable,
            };
            if (!ok) return false;
        }
    }
    return true;
}

/// The name every reader can rely on: `.devrun/logs/latest/api.log` is a path
/// worth putting in a README, and a path with a timestamp in it is not.
pub const latest_link = "latest";

pub const Session = struct {
    name: [stamp_len]u8,
    bytes: u64,

    pub fn text(self: *const Session) []const u8 {
        return &self.name;
    }
};

/// Every Session under `root`, oldest first, each with what it costs on disk.
///
/// A directory that cannot be read comes back as an empty list rather than an
/// error: the callers are "how much is here" and "what can be tidied", and
/// neither has anything useful to do with a failure.
pub fn list(gpa: Allocator, root: []const u8) ![]Session {
    var found: std.ArrayList(Session) = .empty;
    errdefer found.deinit(gpa);

    var root_z: [4096]u8 = undefined;
    const root_path = std.fmt.bufPrintZ(&root_z, "{s}", .{root}) catch return found.toOwnedSlice(gpa);

    var dir = os.DirIter.open(root_path.ptr) catch return found.toOwnedSlice(gpa);
    defer dir.close();

    while (dir.next()) |name| {
        if (!isStamp(name)) continue;
        var s: Session = .{ .name = undefined, .bytes = 0 };
        @memcpy(&s.name, name);
        s.bytes = sessionBytes(root, name);
        try found.append(gpa, s);
    }

    const items = try found.toOwnedSlice(gpa);
    std.mem.sort(Session, items, {}, lessByName);
    return items;
}

fn lessByName(_: void, a: Session, b: Session) bool {
    return std.mem.order(u8, &a.name, &b.name) == .lt;
}

/// What one Session's Archives add up to. Counts every file in the directory,
/// not only `*.log`: whatever is in there is what deleting it would reclaim,
/// and a figure that undercounts is a figure that makes the offer look
/// pointless.
fn sessionBytes(root: []const u8, name: []const u8) u64 {
    var path_buf: [4096]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ root, name }) catch return 0;
    var dir = os.DirIter.open(dir_path.ptr) catch return 0;
    defer dir.close();

    var total: u64 = 0;
    var file_buf: [4096]u8 = undefined;
    while (dir.next()) |entry| {
        if (std.mem.eql(u8, entry, ".") or std.mem.eql(u8, entry, "..")) continue;
        const file = std.fmt.bufPrintZ(&file_buf, "{s}/{s}/{s}", .{ root, name, entry }) catch continue;
        total += os.fileBytes(file.ptr);
    }
    return total;
}

pub const Usage = struct {
    sessions: usize = 0,
    bytes: u64 = 0,
};

pub fn usage(gpa: Allocator, root: []const u8) Usage {
    const sessions = list(gpa, root) catch return .{};
    defer gpa.free(sessions);
    var u: Usage = .{ .sessions = sessions.len };
    for (sessions) |s| u.bytes += s.bytes;
    return u;
}

/// Creates this Session's directory and aims `latest` at it. Returns the
/// directory, owned by the caller.
///
/// The stamp has one-second resolution, and two Sessions in the same second in
/// the same directory is not a case worth suffixing for. `control.sock`
/// already refuses a second Session while one is running, so the only way in
/// is to stop a Session and start another inside the same second — which lands
/// back on the old behaviour of truncating the run before it, for one second
/// out of every day's worth of them. A suffix scheme would have to be
/// recognised by `isStamp` and therefore by every delete in this file, which
/// is a lot of new surface to buy that second back.
pub fn openSession(gpa: Allocator, root: []const u8, wall_seconds: i64) ![]const u8 {
    var name_buf: [stamp_len]u8 = undefined;
    const name = stamp(&name_buf, wall_seconds);

    const dir = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, name });
    errdefer gpa.free(dir);
    try os.makePath(dir);

    // The link is relative, so moving or copying a `.devrun` directory keeps
    // it pointing at something. An absolute link would name a path that only
    // exists on the machine it was made on.
    var link_buf: [4096]u8 = undefined;
    const link = std.fmt.bufPrintZ(&link_buf, "{s}/{s}", .{ root, latest_link }) catch return dir;
    var target_buf: [stamp_len + 1]u8 = undefined;
    const target = std.fmt.bufPrintZ(&target_buf, "{s}", .{name}) catch return dir;
    // A Session that runs without its symlink is a Session that runs. Failing
    // here would refuse to start a repo's services over a convenience.
    os.relink(target.ptr, link.ptr) catch {};

    return dir;
}

pub const Removed = struct {
    sessions: usize = 0,
    bytes: u64 = 0,
};

/// Deletes a Session's directory and everything in it. One level deep on
/// purpose: an Archive directory holds files, and a recursive delete is a
/// bigger weapon than this needs.
fn removeSession(root: []const u8, name: []const u8) void {
    var path_buf: [4096]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ root, name }) catch return;

    var dir = os.DirIter.open(dir_path.ptr) catch return;
    var file_buf: [4096]u8 = undefined;
    while (dir.next()) |entry| {
        if (std.mem.eql(u8, entry, ".") or std.mem.eql(u8, entry, "..")) continue;
        const file = std.fmt.bufPrintZ(&file_buf, "{s}/{s}/{s}", .{ root, name, entry }) catch continue;
        os.unlink(file.ptr);
    }
    dir.close();
    os.rmdir(dir_path.ptr);
}

/// What `clean` and the offer on the way out are both made of.
pub const Scope = enum {
    /// Every Session except the newest.
    older,
    /// Everything, including the Session that is running right now.
    all,
};

pub fn clean(gpa: Allocator, root: []const u8, scope: Scope) Removed {
    const sessions = list(gpa, root) catch return .{};
    defer gpa.free(sessions);
    if (sessions.len == 0) return .{};

    const upto = switch (scope) {
        .older => sessions.len - 1,
        .all => sessions.len,
    };

    var removed: Removed = .{};
    for (sessions[0..upto]) |s| {
        removeSession(root, s.text());
        removed.sessions += 1;
        removed.bytes += s.bytes;
    }
    // A link with nothing on the end of it is a worse answer than no link:
    // `tail -f .devrun/logs/latest/api.log` fails either way, but a dangling
    // link fails as though something is broken.
    if (scope == .all) dropLatest(root);
    return removed;
}

fn dropLatest(root: []const u8) void {
    var link_buf: [4096]u8 = undefined;
    const link = std.fmt.bufPrintZ(&link_buf, "{s}/{s}", .{ root, latest_link }) catch return;
    os.unlink(link.ptr);
}

/// Keeps the newest `keep` Sessions and removes the rest. `keep == 0` means
/// keep everything — a retention flag whose zero deletes everything is a foot
/// gun, and "unlimited" is the only reading of zero anyone would type on
/// purpose.
///
/// Called at startup, after this Session's own directory exists, so the
/// Session about to run is always among the newest and is never a candidate.
pub fn prune(gpa: Allocator, root: []const u8, keep: usize) Removed {
    if (keep == 0) return .{};
    const sessions = list(gpa, root) catch return .{};
    defer gpa.free(sessions);
    if (sessions.len <= keep) return .{};

    var removed: Removed = .{};
    for (sessions[0 .. sessions.len - keep]) |s| {
        removeSession(root, s.text());
        removed.sessions += 1;
        removed.bytes += s.bytes;
    }
    return removed;
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "a stamp reads as a time and sorts as one" {
    var buf: [stamp_len]u8 = undefined;
    // 2026-08-14T10:32:05Z.
    try testing.expectEqualStrings("2026-08-14T10-32-05Z", stamp(&buf, 1786703525));

    var earlier: [stamp_len]u8 = undefined;
    var later: [stamp_len]u8 = undefined;
    _ = stamp(&earlier, 1786703525);
    _ = stamp(&later, 1786703526);
    // Chronological order is lexical order, which is what `list` relies on
    // instead of parsing a name back into a time.
    try testing.expect(std.mem.order(u8, &earlier, &later) == .lt);
}

test "only a stamp-shaped name is something clean may delete" {
    try testing.expect(isStamp("2026-08-14T10-32-05Z"));

    // Everything a person might reasonably leave in the logs directory.
    try testing.expect(!isStamp("latest"));
    try testing.expect(!isStamp("api.log"));
    try testing.expect(!isStamp("keepme"));
    try testing.expect(!isStamp("2026-08-14T10-32-05"));
    try testing.expect(!isStamp("2026-08-14T10-32-05Z.bak"));
    try testing.expect(!isStamp("2026-08-14 10-32-05Z"));
    try testing.expect(!isStamp("xxxx-08-14T10-32-05Z"));
}

/// A logs root under /tmp with `names` as Sessions in it, each holding one
/// Archive of `bytes` bytes.
fn testRoot(gpa: Allocator, names: []const []const u8, bytes: usize) ![]const u8 {
    const root = try std.fmt.allocPrint(gpa, "/tmp/devrun-store-test-{d}", .{os.nowMs()});
    errdefer gpa.free(root);
    for (names) |n| {
        var path_buf: [4096]u8 = undefined;
        const dir = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, n });
        try os.makePath(dir);
        var file_buf: [4096]u8 = undefined;
        const file = try std.fmt.bufPrintZ(&file_buf, "{s}/{s}/api.log", .{ root, n });
        const fd = try os.open(file.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        defer os.close(fd);
        const filler = try gpa.alloc(u8, bytes);
        defer gpa.free(filler);
        @memset(filler, 'x');
        try os.writeAll(fd, filler);
    }
    return root;
}

fn tearDown(gpa: Allocator, root: []const u8) void {
    _ = clean(gpa, root, .all);
    var buf: [4096]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{root}) catch return;
    os.rmdir(z.ptr);
    gpa.free(root);
}

test "Sessions come back oldest first, with what they cost" {
    const gpa = testing.allocator;
    const root = try testRoot(gpa, &.{
        "2026-08-14T10-32-05Z",
        "2026-08-12T09-00-00Z",
        "2026-08-13T22-15-30Z",
    }, 100);
    defer tearDown(gpa, root);

    const sessions = try list(gpa, root);
    defer gpa.free(sessions);

    try testing.expectEqual(@as(usize, 3), sessions.len);
    try testing.expectEqualStrings("2026-08-12T09-00-00Z", sessions[0].text());
    try testing.expectEqualStrings("2026-08-13T22-15-30Z", sessions[1].text());
    try testing.expectEqualStrings("2026-08-14T10-32-05Z", sessions[2].text());
    try testing.expectEqual(@as(u64, 100), sessions[0].bytes);

    const u = usage(gpa, root);
    try testing.expectEqual(@as(usize, 3), u.sessions);
    try testing.expectEqual(@as(u64, 300), u.bytes);
}

test "starting a Session leaves the one before it alone" {
    const gpa = testing.allocator;
    const root = try testRoot(gpa, &.{"2026-08-12T09-00-00Z"}, 64);
    defer tearDown(gpa, root);

    const dir = try openSession(gpa, root, 1786703525);
    defer gpa.free(dir);

    const sessions = try list(gpa, root);
    defer gpa.free(sessions);
    try testing.expectEqual(@as(usize, 2), sessions.len);
    // The Archive that was already there still has its bytes: this is the
    // whole point of the change, so it is the thing worth asserting.
    try testing.expectEqual(@as(u64, 64), sessions[0].bytes);
}

test "latest points at the Session that just started" {
    const gpa = testing.allocator;
    const root = try testRoot(gpa, &.{}, 0);
    defer tearDown(gpa, root);

    const dir = try openSession(gpa, root, 1786703525);
    defer gpa.free(dir);

    var link_buf: [4096]u8 = undefined;
    const link = try std.fmt.bufPrintZ(&link_buf, "{s}/latest/api.log", .{root});
    const fd = try os.open(link.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true }, 0o644);
    os.close(fd);

    // Written through `latest`, read back through the stamped directory: the
    // link is the same place, not a copy of it.
    var real_buf: [4096]u8 = undefined;
    const real = try std.fmt.bufPrintZ(&real_buf, "{s}/2026-08-14T10-32-05Z/api.log", .{root});
    const check = try os.open(real.ptr, .{ .ACCMODE = .RDONLY }, 0);
    os.close(check);

    // A second Session re-aims it rather than failing on a name that exists.
    const dir2 = try openSession(gpa, root, 1786703526);
    defer gpa.free(dir2);
    const moved = try std.fmt.bufPrintZ(&link_buf, "{s}/latest/api.log", .{root});
    try testing.expectError(error.FileNotFound, os.open(moved.ptr, .{ .ACCMODE = .RDONLY }, 0));
}

test "clean older keeps the newest Session and clean all keeps nothing" {
    const gpa = testing.allocator;
    const root = try testRoot(gpa, &.{
        "2026-08-12T09-00-00Z",
        "2026-08-13T22-15-30Z",
        "2026-08-14T10-32-05Z",
    }, 10);
    defer tearDown(gpa, root);

    const older = clean(gpa, root, .older);
    try testing.expectEqual(@as(usize, 2), older.sessions);
    try testing.expectEqual(@as(u64, 20), older.bytes);

    const left = try list(gpa, root);
    defer gpa.free(left);
    try testing.expectEqual(@as(usize, 1), left.len);
    try testing.expectEqualStrings("2026-08-14T10-32-05Z", left[0].text());

    const rest = clean(gpa, root, .all);
    try testing.expectEqual(@as(usize, 1), rest.sessions);
    try testing.expectEqual(@as(usize, 0), usage(gpa, root).sessions);
}

test "clean will not touch a file that is not a Session" {
    const gpa = testing.allocator;
    const root = try testRoot(gpa, &.{"2026-08-12T09-00-00Z"}, 10);
    defer tearDown(gpa, root);

    var keep_buf: [4096]u8 = undefined;
    const keep_dir = try std.fmt.bufPrint(&keep_buf, "{s}/keepme", .{root});
    try os.makePath(keep_dir);

    _ = clean(gpa, root, .all);

    var z_buf: [4096]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&z_buf, "{s}/keepme", .{root});
    var still_there = try os.DirIter.open(z.ptr);
    still_there.close();
    os.rmdir(z.ptr);
}

test "prune keeps the newest and zero means keep everything" {
    const gpa = testing.allocator;
    const root = try testRoot(gpa, &.{
        "2026-08-10T09-00-00Z",
        "2026-08-11T09-00-00Z",
        "2026-08-12T09-00-00Z",
        "2026-08-13T09-00-00Z",
    }, 5);
    defer tearDown(gpa, root);

    try testing.expectEqual(@as(usize, 0), prune(gpa, root, 0).sessions);
    try testing.expectEqual(@as(usize, 4), usage(gpa, root).sessions);

    const removed = prune(gpa, root, 2);
    try testing.expectEqual(@as(usize, 2), removed.sessions);

    const left = try list(gpa, root);
    defer gpa.free(left);
    try testing.expectEqual(@as(usize, 2), left.len);
    try testing.expectEqualStrings("2026-08-12T09-00-00Z", left[0].text());
    try testing.expectEqualStrings("2026-08-13T09-00-00Z", left[1].text());
}
