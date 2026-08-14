//! `devrun update` — replace this binary with the latest release.
//!
//! The arch detection, the download, the checksum and the atomic swap all live
//! in `install.sh`, which is also what a first install runs. That is
//! deliberate: two implementations of "put the right binary in the right
//! place" drift apart, and the one that drifts is always the one nobody runs
//! by hand. So this command's whole job is to work out *where* the replacement
//! should land — the directory this binary is running from, read from
//! `/proc/self/exe` rather than guessed — and hand that to the script.
//!
//! It hands over with `execve` rather than forking and waiting. There is
//! nothing for devrun to do afterwards, and a supervisor that outlives the
//! thing replacing it is a supervisor holding an open handle to its own
//! previous version.

const std = @import("std");
const Allocator = std.mem.Allocator;
const os = @import("os.zig");
const build_options = @import("build_options");

/// Baked in at build time. `dev` locally, the tag in a released binary.
pub const version = build_options.version;

pub const repo = "nevindra/devrun-monitoring";

/// Read from the default branch rather than from the release being installed.
/// A released tarball contains a binary, not the script that places it, so
/// pinning this to a tag would mean a fix to the installer only ever reached
/// the people who had already updated past it.
pub const script_url =
    "https://raw.githubusercontent.com/" ++ repo ++ "/main/install.sh";

/// Printed whenever devrun cannot run the update itself. The command is the
/// same one the README gives for a first install, because it is the same
/// operation — there is no separate "upgrade" path to get wrong.
const by_hand = "          curl -fsSL " ++ script_url ++ " | sh\n";

pub fn run(
    gpa: Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    out: *std.Io.Writer,
) !u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Where this binary actually is, rather than wherever PATH happens to
    // resolve `devrun` today. Someone with a build in ~/src and a release in
    // ~/.local/bin should have the one they invoked replaced, not the other.
    var path_buf: [4096]u8 = undefined;
    const self_path = os.selfExe(&path_buf) orelse {
        try fail(io,
            "devrun: cannot read /proc/self/exe, so there is no way to tell\n" ++
            "        which binary to replace. Install over it by hand:\n\n" ++ by_hand,
            .{},
        );
        return 1;
    };
    const dir = std.fs.path.dirname(self_path) orelse ".";

    const path_env = environ.get("PATH");
    const sh = os.resolvePath(arena, "sh", path_env) catch {
        try fail(io, "devrun: no `sh` on PATH; devrun update needs a shell.\n", .{});
        return 1;
    };
    const fetch = fetcher(arena, path_env) orelse {
        try fail(io,
            "devrun: neither curl nor wget is on PATH, and devrun does not\n" ++
            "        carry an HTTPS client of its own — linking one would cost\n" ++
            "        more binary than the whole supervisor. Install either, or\n" ++
            "        download the release by hand:\n\n" ++
            "          https://github.com/" ++ repo ++ "/releases/latest\n",
            .{},
        );
        return 1;
    };

    // The install directory and the current version are passed as environment
    // rather than as arguments so the script reads the same whether it was
    // piped from a browser-copied curl line or invoked from here.
    const command = try std.fmt.allocPrintSentinel(
        arena,
        "{s} {s} | DEVRUN_INSTALL_DIR={s} DEVRUN_FROM={s} sh -s -- --managed",
        .{ fetch, script_url, try shellQuote(arena, dir), try shellQuote(arena, version) },
        0,
    );

    const argv = try arena.allocSentinel(?[*:0]const u8, 3, null);
    argv[0] = sh.ptr;
    argv[1] = "-c";
    argv[2] = command.ptr;

    try out.print("devrun {s} — checking for a newer release\n", .{version});
    // execve replaces this process image, taking anything still sitting in the
    // buffer with it.
    try out.flush();

    _ = os.linux.execve(sh.ptr, argv.ptr, try envp(arena, environ));

    // Only reachable when the exec itself failed.
    try fail(io, "devrun: could not run {s}. Install by hand:\n\n" ++ by_hand, .{sh});
    return 1;
}

/// Prints the version and nothing else, so `devrun version` is usable from a
/// script without trimming a prefix off it.
pub fn printVersion(out: *std.Io.Writer) !u8 {
    try out.print("{s}\n", .{version});
    return 0;
}

/// The command that writes a URL's contents to stdout, or null when the
/// machine has neither. curl is tried first because it is what the README's
/// install line uses, which makes it the one a machine that installed devrun
/// this way is known to have.
fn fetcher(arena: Allocator, path_env: ?[]const u8) ?[]const u8 {
    if (os.resolvePath(arena, "curl", path_env)) |_| {
        return "curl -fsSL";
    } else |_| {}
    if (os.resolvePath(arena, "wget", path_env)) |_| {
        return "wget -qO-";
    } else |_| {}
    return null;
}

/// Wraps `text` in single quotes for `sh`, so a path with a space or a `$` in
/// it survives the trip. Inside single quotes every byte is literal except the
/// quote itself, which is closed, escaped and reopened — the standard
/// `'\''` dance, and the only escaping POSIX sh needs here.
fn shellQuote(arena: Allocator, text: []const u8) ![]const u8 {
    var extra: usize = 0;
    for (text) |c| {
        if (c == '\'') extra += 3;
    }
    const buf = try arena.alloc(u8, text.len + extra + 2);
    var n: usize = 0;
    buf[n] = '\'';
    n += 1;
    for (text) |c| {
        if (c == '\'') {
            @memcpy(buf[n..][0..4], "'\\''");
            n += 4;
        } else {
            buf[n] = c;
            n += 1;
        }
    }
    buf[n] = '\'';
    n += 1;
    return buf[0..n];
}

/// The current environment, copied into the shape `execve` wants. Passed
/// through unchanged: the script may want PATH, HOME, HTTPS_PROXY and
/// GITHUB_TOKEN, and deciding here which of those matter is how a proxy stops
/// working for reasons nobody can see.
fn envp(arena: Allocator, environ: *const std.process.Environ.Map) ![*:null]const ?[*:0]const u8 {
    var n: usize = 0;
    var counting = environ.iterator();
    while (counting.next()) |_| n += 1;

    const list = try arena.allocSentinel(?[*:0]const u8, n, null);
    var i: usize = 0;
    var it = environ.iterator();
    while (it.next()) |kv| : (i += 1) {
        list[i] = (try std.fmt.allocPrintSentinel(
            arena,
            "{s}={s}",
            .{ kv.key_ptr.*, kv.value_ptr.* },
            0,
        )).ptr;
    }
    return list.ptr;
}

fn fail(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buf);
    const w = &stderr.interface;
    defer w.flush() catch {};
    try w.print(fmt, args);
}

const testing = std.testing;

test "shellQuote survives spaces, dollars, and quotes" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("'/usr/local/bin'", try shellQuote(arena, "/usr/local/bin"));
    try testing.expectEqualStrings("'/home/a b/bin'", try shellQuote(arena, "/home/a b/bin"));

    // The whole point: none of these may reach sh as anything but literal text.
    try testing.expectEqualStrings("'$HOME/bin'", try shellQuote(arena, "$HOME/bin"));
    try testing.expectEqualStrings("'a;rm -rf /'", try shellQuote(arena, "a;rm -rf /"));
    try testing.expectEqualStrings("'`whoami`'", try shellQuote(arena, "`whoami`"));

    // A quote closes the string, contributes an escaped one, and reopens it.
    try testing.expectEqualStrings("'it'\\''s'", try shellQuote(arena, "it's"));
    try testing.expectEqualStrings("''\\'''", try shellQuote(arena, "'"));
    try testing.expectEqualStrings("''", try shellQuote(arena, ""));
}
