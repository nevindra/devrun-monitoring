//! The agent skill: a SKILL.md that rides inside the binary and can be put
//! where coding agents look for skills.
//!
//! `devrun init` writes a block into AGENTS.md, which an agent pays for on
//! every turn, so that block stays tiny. A skill is the other half: the full
//! guide, loaded only when the task is about running or debugging local
//! services. It is embedded rather than fetched so the text always matches
//! the binary that will be asked about, and so installing it needs no network.

const std = @import("std");

pub const text = @embedFile("skill/SKILL.md");

/// The directory name has to equal `name:` in the frontmatter, or agents that
/// check it ignore the skill.
const dir_name = "devrun";
const file_name = "SKILL.md";

pub const Options = struct {
    /// Replaces the default roots with this one.
    to: ?[]const u8 = null,
    /// Only rewrite a skill that is already there. `devrun update` uses it so
    /// someone who removed the skill does not get it back.
    refresh: bool = false,
};

/// Where skills go. `~/.agents/skills` is read by Codex and OpenCode and is
/// the cross-agent location, so it is always a target. `~/.claude/skills` is
/// Claude Code's own, and only worth creating for someone who has Claude Code.
const Roots = struct {
    buf: [2][]const u8 = undefined,
    len: usize = 0,

    fn slice(self: *const Roots) []const []const u8 {
        return self.buf[0..self.len];
    }
};

fn pickRoots(
    arena: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
    opts: Options,
    /// `uninstall` wants both defaults even when `.claude` is gone, so a
    /// removal cannot miss a copy because the directory above it moved.
    both: bool,
    err_w: *std.Io.Writer,
) !?Roots {
    var roots: Roots = .{};
    if (opts.to) |dir| {
        roots.buf[0] = dir;
        roots.len = 1;
        return roots;
    }
    const h = home orelse {
        try err_w.writeAll("devrun: HOME is not set, so there is nowhere to put the skill. Use --to DIR.\n");
        return null;
    };
    roots.buf[0] = try std.fs.path.join(arena, &.{ h, ".agents", "skills" });
    roots.len = 1;
    const claude = try std.fs.path.join(arena, &.{ h, ".claude" });
    const have_claude = both or blk: {
        std.Io.Dir.cwd().access(io, claude, .{}) catch break :blk false;
        break :blk true;
    };
    if (have_claude) {
        roots.buf[1] = try std.fs.path.join(arena, &.{ h, ".claude", "skills" });
        roots.len = 2;
    }
    return roots;
}

/// Returns the exit status: non-zero only if a target that was attempted
/// failed. A root skipped on purpose is not a failure.
pub fn install(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
    opts: Options,
    out: *std.Io.Writer,
    err_w: *std.Io.Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const roots = (try pickRoots(arena, io, home, opts, false, err_w)) orelse return 1;

    var failed = false;
    var touched = false;
    for (roots.slice()) |root| {
        const dir = try std.fs.path.join(arena, &.{ root, dir_name });
        const file = try std.fs.path.join(arena, &.{ dir, file_name });

        const existing: ?[]u8 = std.Io.Dir.cwd().readFileAlloc(io, file, arena, .limited(1 << 20)) catch null;

        if (existing) |old| {
            if (std.mem.eql(u8, old, text)) {
                touched = true;
                try out.print("devrun: the agent skill is already current at {s}\n", .{file});
                continue;
            }
        } else if (opts.refresh) {
            try out.print("devrun: skipped {s} (no devrun skill installed there)\n", .{root});
            continue;
        }
        touched = true;

        writeAtomic(io, arena, dir, file) catch |e| {
            try err_w.print("devrun: cannot install the agent skill at {s}: {t}\n", .{ file, e });
            failed = true;
            continue;
        };
        try out.print("devrun: {s} the agent skill at {s}\n", .{
            if (existing != null) "updated" else "installed",
            file,
        });
    }
    if (opts.refresh and !touched) try out.writeAll("devrun: no installed agent skill to refresh.\n");
    return if (failed) 1 else 0;
}

/// The temp file lives in the same directory so the rename never crosses a
/// filesystem, and an agent scanning the skills folder never sees a half
/// written SKILL.md.
fn writeAtomic(io: std.Io, arena: std.mem.Allocator, dir: []const u8, file: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, dir);
    const tmp = try std.fmt.allocPrint(arena, "{s}/.{s}.tmp", .{ dir, file_name });
    try cwd.writeFile(io, .{ .sub_path = tmp, .data = text });
    cwd.rename(tmp, cwd, file, io) catch |e| {
        cwd.deleteFile(io, tmp) catch {};
        return e;
    };
}

/// Removes only `<root>/devrun/SKILL.md` and then the `devrun` directory if
/// that left it empty. Anything else in there is somebody's, and stays.
pub fn uninstall(
    gpa: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
    opts: Options,
    out: *std.Io.Writer,
    err_w: *std.Io.Writer,
) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const roots = (try pickRoots(arena, io, home, opts, true, err_w)) orelse return 1;
    const cwd = std.Io.Dir.cwd();

    var failed = false;
    for (roots.slice()) |root| {
        const dir = try std.fs.path.join(arena, &.{ root, dir_name });
        const file = try std.fs.path.join(arena, &.{ dir, file_name });
        cwd.deleteFile(io, file) catch |e| switch (e) {
            error.FileNotFound => {
                try out.print("devrun: skipped {s} (no devrun skill installed there)\n", .{root});
                continue;
            },
            else => {
                try err_w.print("devrun: cannot remove {s}: {t}\n", .{ file, e });
                failed = true;
                continue;
            },
        };
        // Fails when the directory still holds something else; that is the
        // point, so the error is the answer rather than a problem.
        cwd.deleteDir(io, dir) catch {};
        try out.print("devrun: removed the agent skill at {s}\n", .{file});
    }
    return if (failed) 1 else 0;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

const test_root = "/tmp/devrun-skill-test";

fn freshHome() !void {
    const cwd = std.Io.Dir.cwd();
    cwd.deleteTree(testing.io, test_root) catch {};
    try cwd.createDirPath(testing.io, test_root);
}

fn run(
    comptime f: anytype,
    opts: Options,
    out: *std.Io.Writer.Allocating,
    err_w: *std.Io.Writer.Allocating,
) !u8 {
    return f(testing.allocator, testing.io, test_root, opts, &out.writer, &err_w.writer);
}

test "the embedded skill names itself devrun" {
    try testing.expect(std.mem.startsWith(u8, text, "---\nname: devrun\n"));
}

test "install writes the embedded bytes, and a second one finds it current" {
    try freshHome();
    defer std.Io.Dir.cwd().deleteTree(testing.io, test_root) catch {};

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var er: std.Io.Writer.Allocating = .init(testing.allocator);
    defer er.deinit();

    try testing.expectEqual(@as(u8, 0), try run(install, .{}, &out, &er));
    try testing.expect(std.mem.indexOf(u8, out.written(), "installed the agent skill at " ++ test_root ++ "/.agents/skills/devrun/SKILL.md") != null);
    // No ~/.claude, so no Claude Code skills directory is invented.
    try testing.expect(std.mem.indexOf(u8, out.written(), ".claude") == null);

    const got = try std.Io.Dir.cwd().readFileAlloc(testing.io, test_root ++ "/.agents/skills/devrun/SKILL.md", testing.allocator, .limited(1 << 20));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(text, got);

    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try run(install, .{}, &out, &er));
    try testing.expect(std.mem.indexOf(u8, out.written(), "already current") != null);
}

test "install also targets ~/.claude/skills when ~/.claude exists" {
    try freshHome();
    defer std.Io.Dir.cwd().deleteTree(testing.io, test_root) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, test_root ++ "/.claude");

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var er: std.Io.Writer.Allocating = .init(testing.allocator);
    defer er.deinit();

    try testing.expectEqual(@as(u8, 0), try run(install, .{}, &out, &er));
    try std.Io.Dir.cwd().access(testing.io, test_root ++ "/.claude/skills/devrun/SKILL.md", .{});
}

test "refresh leaves a root without a skill alone, and updates a stale one" {
    try freshHome();
    defer std.Io.Dir.cwd().deleteTree(testing.io, test_root) catch {};

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var er: std.Io.Writer.Allocating = .init(testing.allocator);
    defer er.deinit();

    try testing.expectEqual(@as(u8, 0), try run(install, .{ .refresh = true }, &out, &er));
    try testing.expect(std.mem.indexOf(u8, out.written(), "skipped") != null);
    try testing.expect(std.mem.indexOf(u8, out.written(), "no installed agent skill to refresh") != null);
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, test_root ++ "/.agents", .{}));

    // A stale copy is rewritten.
    try std.Io.Dir.cwd().createDirPath(testing.io, test_root ++ "/.agents/skills/devrun");
    try std.Io.Dir.cwd().writeFile(testing.io, .{
        .sub_path = test_root ++ "/.agents/skills/devrun/SKILL.md",
        .data = "old",
    });
    out.clearRetainingCapacity();
    try testing.expectEqual(@as(u8, 0), try run(install, .{ .refresh = true }, &out, &er));
    try testing.expect(std.mem.indexOf(u8, out.written(), "updated the agent skill") != null);
}

test "uninstall removes the skill and leaves sibling skills alone" {
    try freshHome();
    defer std.Io.Dir.cwd().deleteTree(testing.io, test_root) catch {};
    const cwd = std.Io.Dir.cwd();

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var er: std.Io.Writer.Allocating = .init(testing.allocator);
    defer er.deinit();

    try cwd.createDirPath(testing.io, test_root ++ "/.agents/skills/other");
    try cwd.writeFile(testing.io, .{
        .sub_path = test_root ++ "/.agents/skills/other/SKILL.md",
        .data = "mine",
    });
    _ = try run(install, .{}, &out, &er);
    out.clearRetainingCapacity();

    try testing.expectEqual(@as(u8, 0), try run(uninstall, .{}, &out, &er));
    try testing.expect(std.mem.indexOf(u8, out.written(), "removed the agent skill") != null);
    try testing.expectError(error.FileNotFound, cwd.access(testing.io, test_root ++ "/.agents/skills/devrun", .{}));
    try cwd.access(testing.io, test_root ++ "/.agents/skills/other/SKILL.md", .{});
}

test "--to replaces the default roots" {
    try freshHome();
    defer std.Io.Dir.cwd().deleteTree(testing.io, test_root) catch {};

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var er: std.Io.Writer.Allocating = .init(testing.allocator);
    defer er.deinit();

    try testing.expectEqual(@as(u8, 0), try run(install, .{ .to = test_root ++ "/elsewhere" }, &out, &er));
    try std.Io.Dir.cwd().access(testing.io, test_root ++ "/elsewhere/devrun/SKILL.md", .{});
    try testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(testing.io, test_root ++ "/.agents", .{}));
}
