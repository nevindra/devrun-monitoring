//! The non-interactive view of a Session: every Worker's output, interleaved,
//! one prefixed line at a time.
//!
//! This is what `devrun up` does when stdout is not a terminal — piped into a
//! file, run under CI, or read by another program. It reads Archives exactly
//! the way the TUI does, through absolute offsets, so the two views cannot
//! drift apart.

const std = @import("std");
const os = @import("os.zig");
const supervisor = @import("supervisor.zig");

const Supervisor = supervisor.Supervisor;
const Archive = @import("archive.zig").Archive;
const Allocator = std.mem.Allocator;

/// Enough distinct colours to tell a handful of Workers apart at a glance,
/// reused beyond that. Deliberately skips red — red belongs to a Worker's own
/// error output, and a prefix that borrows it makes healthy output look broken.
const palette = [_][]const u8{
    "\x1b[36m", // cyan
    "\x1b[32m", // green
    "\x1b[35m", // magenta
    "\x1b[33m", // yellow
    "\x1b[34m", // blue
    "\x1b[96m", // bright cyan
};
const reset = "\x1b[0m";

pub const Printer = struct {
    /// How far into each Archive this view has already printed. The Archive is
    /// the record; this is just a bookmark into it.
    printed: []u64,
    /// The state each Worker was last reported in, so transitions are
    /// announced once rather than every pass.
    last_state: []supervisor.State,
    colour: bool,
    name_width: usize,

    pub fn init(gpa: Allocator, sup: *const Supervisor, colour: bool) !Printer {
        const n = sup.workers.len;
        const printed = try gpa.alloc(u64, n);
        @memset(printed, 0);
        const last = try gpa.alloc(supervisor.State, n);
        for (last) |*s| s.* = .pending;

        var width: usize = 0;
        for (sup.workers) |w| width = @max(width, w.name().len);

        return .{
            .printed = printed,
            .last_state = last,
            .colour = colour,
            .name_width = width,
        };
    }

    pub fn deinit(self: *Printer, gpa: Allocator) void {
        gpa.free(self.printed);
        gpa.free(self.last_state);
    }

    /// Emits everything that happened since the last call. Only whole lines
    /// are printed: a Worker that has written half a line keeps it until the
    /// newline arrives, so two Workers writing at once cannot interleave
    /// mid-line.
    pub fn flush(self: *Printer, sup: *Supervisor, out: *std.Io.Writer) !void {
        for (sup.workers, 0..) |*w, i| {
            if (self.last_state[i] != w.state) {
                self.last_state[i] = w.state;
                try self.status(w, out);
            }

            var at = self.printed[i];
            const end = w.archive.len();
            var line_buf: [4096]u8 = undefined;
            while (at < end) {
                const stop = w.archive.lineEnd(at);
                // An unterminated tail waits for the rest of its line.
                if (stop == at) break;
                if (stop == end and !endsWithNewline(&w.archive, end)) break;

                const line = w.archive.lineInto(at, &line_buf);
                try self.prefix(i, w.name(), out);
                try out.writeAll(line);
                try out.writeAll("\n");
                at = stop;
            }
            self.printed[i] = at;
        }
        try out.flush();
    }

    fn prefix(self: Printer, i: usize, name: []const u8, out: *std.Io.Writer) !void {
        if (self.colour) try out.writeAll(palette[i % palette.len]);
        try out.writeAll(name);
        try out.splatByteAll(' ', self.name_width - name.len);
        try out.writeAll(" | ");
        if (self.colour) try out.writeAll(reset);
    }

    fn status(self: Printer, w: *const supervisor.Runtime, out: *std.Io.Writer) !void {
        if (self.colour) try out.writeAll("\x1b[1m");
        try out.print("devrun: {s} ", .{w.name()});
        switch (w.state) {
            // A Worker with no `depends_on` that is pending is waiting out a
            // restart backoff, and saying "dependencies" there sends the
            // reader looking for a graph that does not exist.
            .pending => try out.writeAll(if (w.spec.depends_on.len > 0)
                "waiting on dependencies"
            else
                "waiting to start"),
            .running => try out.writeAll("started"),
            .ready => try out.writeAll("ready"),
            .stopping => try out.writeAll("stopping"),
            .exited => try out.writeAll("exited 0"),
            .stopped => try out.writeAll("stopped"),
            .failed => if (w.exit) |e| switch (e) {
                .exited => |c| try out.print("exited {d}", .{c}),
                .signaled => |s| try out.print("killed by {t}", .{s}),
            } else try out.writeAll("failed to start"),
            .skipped => try out.writeAll("skipped: a dependency will never be satisfied"),
        }
        if (self.colour) try out.writeAll(reset);
        try out.writeAll("\n");
    }

    /// Prints the one-line-per-Worker summary a Session ends with.
    pub fn summary(self: Printer, sup: *Supervisor, out: *std.Io.Writer) !void {
        try out.writeAll("\n");
        for (sup.workers) |*w| {
            try out.print("  {s}", .{w.name()});
            try out.splatByteAll(' ', self.name_width - w.name().len);
            switch (w.state) {
                .exited => try out.writeAll("  ok"),
                .stopped => try out.writeAll("  stopped"),
                .failed => if (w.exit) |e| switch (e) {
                    .exited => |c| try out.print("  exit {d}", .{c}),
                    .signaled => |s| try out.print("  {t}", .{s}),
                } else try out.writeAll("  did not start"),
                .skipped => try out.writeAll("  skipped"),
                else => try out.print("  {t}", .{w.state}),
            }
            if (w.archive.write_failed) try out.writeAll("  (Archive incomplete)");
            try out.writeAll("\n");
        }
        try out.flush();
    }
};

fn endsWithNewline(a: *const Archive, end: u64) bool {
    if (end == 0) return false;
    var b: [1]u8 = undefined;
    return a.readAt(end - 1, &b) == 1 and b[0] == '\n';
}
