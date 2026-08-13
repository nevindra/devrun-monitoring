const std = @import("std");
const config = @import("config.zig");

/// The vendored YAML parser logs every token it sees at `.debug`, which in a
/// Debug build buries anything we print. Its warnings are still worth having.
/// These are all three scopes it uses; re-check after re-syncing the vendor.
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .yaml, .level = .warn },
        .{ .scope = .parser, .level = .warn },
        .{ .scope = .tokenizer, .level = .warn },
    },
};

const usage =
    \\devrun — process runner for local development
    \\
    \\Usage:
    \\  devrun config [path]   Parse a process-compose.yaml and print what devrun understood
    \\
    \\Default path: process-compose.yaml
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var out_buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll(usage);
        return 1;
    }

    if (std.mem.eql(u8, args[1], "config")) {
        const path = if (args.len > 2) args[2] else "process-compose.yaml";
        return dumpConfig(gpa, io, init.environ_map, path, out);
    }

    try out.print("unknown command \"{s}\"\n\n{s}", .{ args[1], usage });
    return 1;
}

fn dumpConfig(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ: *const std.process.Environ.Map,
    path: []const u8,
    out: *std.Io.Writer,
) !u8 {
    var diag: config.Diagnostic = .{};
    defer diag.deinit(gpa);

    var cfg = config.load(gpa, path, .{ .io = io, .environ = environ }, &diag) catch |err| {
        var err_buf: [4096]u8 = undefined;
        var stderr = std.Io.File.stderr().writer(io, &err_buf);
        const e = &stderr.interface;
        defer e.flush() catch {};
        if (diag.message) |m| {
            try e.print("devrun: {s}\n", .{m});
        } else {
            try e.print("devrun: {s}: {t}\n", .{ path, err });
        }
        return 1;
    };
    defer cfg.deinit();

    try out.print("shell: {s} {s}\n\n", .{ cfg.shell.command, cfg.shell.argument });
    for (cfg.workers) |w| {
        try out.print("{s}\n", .{w.name});
        if (w.description) |d| try out.print("  description   {s}\n", .{d});
        try out.print("  command       {s}\n", .{w.command});
        if (w.working_dir) |d| try out.print("  working_dir   {s}\n", .{d});
        try out.print("  restart       {t}\n", .{w.restart});
        for (w.dotenv) |f| try out.print("  dotenv        {s}\n", .{f});
        for (w.environment) |e| try out.print("  env           {s}\n", .{e});
        for (w.depends_on) |d| {
            try out.print("  depends_on    {s} ({t})\n", .{ d.name, d.condition });
        }
        if (w.readiness_probe) |p| {
            switch (p.target) {
                .exec => |c| try out.print("  probe exec    {s}\n", .{c}),
                .http_get => |h| try out.print(
                    "  probe http    {s}://{s}:{d}{s}\n",
                    .{ h.scheme, h.host, h.port, h.path },
                ),
            }
            try out.print(
                "                delay={d}s period={d}s timeout={d}s failures={d}\n",
                .{ p.initial_delay_seconds, p.period_seconds, p.timeout_seconds, p.failure_threshold },
            );
        }
        try out.writeAll("\n");
    }
    return 0;
}

test {
    _ = config;
}
