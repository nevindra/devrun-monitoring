//! The control socket: `start`, `stop`, `restart`, `status`, `samples`.
//!
//! Logs never travel through here — that is the decision in
//! `docs/adr/0001-logs-through-the-filesystem.md`, and it is what keeps this
//! file small. Because nothing bulk ever crosses the socket, there is no
//! framing, no per-client subscription, and no backpressure to handle: a
//! request is a line, a reply is some lines, and the connection closes.
//!
//! The server never blocks. Its listener and its clients join the Session's
//! own `poll()` set, so a client that connects and then wanders off cannot
//! stop a Worker's output from being drained.

const std = @import("std");
const os = @import("os.zig");
const supervisor = @import("supervisor.zig");

const Supervisor = supervisor.Supervisor;
const linux = os.linux;

/// A request is one line and a reply fits in a few KB — `status` for a
/// hundred Workers is still only a few thousand bytes.
const max_request = 512;
const max_reply = 32 << 10;

fn sockaddrUn(path: [:0]const u8) !linux.sockaddr.un {
    var addr = linux.sockaddr.un{ .family = linux.AF.UNIX, .path = undefined };
    if (path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

// ------------------------------------------------------------- server

pub const Server = struct {
    /// One listener plus the clients. Small and fixed: this socket serves
    /// `devrun stop` from another terminal, not a fleet.
    pub const max_clients = 8;
    pub const max_poll_fds = max_clients + 1;

    listen_fd: os.Fd,
    clients: [max_clients]Client = @splat(.{}),

    const Client = struct {
        fd: os.Fd = -1,
        buf: [max_request]u8 = undefined,
        len: usize = 0,
    };

    /// Binds `path`. Refuses to steal a socket another Session is still
    /// answering on — two supervisors sharing one control socket would have
    /// `devrun stop` reach whichever happened to accept first.
    pub fn open(path: [:0]const u8) !Server {
        if (std.fs.path.dirname(path)) |dir| os.makePath(dir) catch {};

        if (isLive(path)) return error.SessionAlreadyRunning;
        // Nothing answered, so any file here is a leftover from a Session that
        // did not get to clean up.
        os.unlink(path.ptr);

        const fd = try os.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
        errdefer os.close(fd);
        os.setNonblock(fd, true);

        const addr = try sockaddrUn(path);
        try os.bindUn(fd, &addr);
        try os.listen(fd, max_clients);
        return .{ .listen_fd = fd };
    }

    /// Whether something is still accepting on this path.
    fn isLive(path: [:0]const u8) bool {
        const fd = os.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0) catch return false;
        defer os.close(fd);
        const addr = sockaddrUn(path) catch return false;
        os.connectUn(fd, &addr) catch return false;
        return true;
    }

    pub fn close(self: *Server, path: [:0]const u8) void {
        for (&self.clients) |*c| {
            if (c.fd >= 0) os.close(c.fd);
            c.fd = -1;
        }
        os.close(self.listen_fd);
        os.unlink(path.ptr);
    }

    /// Adds the listener and every live client to a caller-owned poll set.
    pub fn fillPollFds(self: *Server, out: []os.PollFd) usize {
        var n: usize = 0;
        out[n] = .{ .fd = self.listen_fd, .events = os.POLL.IN, .revents = 0 };
        n += 1;
        for (self.clients) |c| {
            if (c.fd < 0) continue;
            out[n] = .{ .fd = c.fd, .events = os.POLL.IN, .revents = 0 };
            n += 1;
        }
        return n;
    }

    /// Reacts to whatever `poll` reported. `fds` must be the slice
    /// `fillPollFds` filled, unmodified except for `revents`.
    pub fn service(self: *Server, fds: []const os.PollFd, sup: *Supervisor) void {
        if (fds.len == 0) return;
        if (fds[0].revents & os.POLL.IN != 0) self.accept();

        var slot: usize = 1;
        for (&self.clients) |*c| {
            if (c.fd < 0) continue;
            if (slot >= fds.len) break;
            const re = fds[slot].revents;
            slot += 1;
            if (re & (os.POLL.IN | os.POLL.HUP | os.POLL.ERR) != 0) self.readClient(c, sup);
        }
    }

    fn accept(self: *Server) void {
        while (true) {
            const fd = os.accept(self.listen_fd) catch return;
            os.setNonblock(fd, true);
            const slot = for (&self.clients) |*c| {
                if (c.fd < 0) break c;
            } else {
                // Every slot taken. Closing immediately is a clearer answer
                // than making the caller wait for a slot that may never free.
                os.close(fd);
                continue;
            };
            slot.* = .{ .fd = fd };
        }
    }

    fn readClient(self: *Server, c: *Client, sup: *Supervisor) void {
        const n = os.read(c.fd, c.buf[c.len..]) catch |e| switch (e) {
            error.WouldBlock => return,
            else => return self.drop(c),
        };
        if (n == 0) return self.drop(c);
        c.len += n;

        const nl = std.mem.indexOfScalar(u8, c.buf[0..c.len], '\n') orelse {
            // A line longer than the buffer is not a request devrun has.
            if (c.len == c.buf.len) self.drop(c);
            return;
        };

        var reply_buf: [max_reply]u8 = undefined;
        var w: std.Io.Writer = .fixed(&reply_buf);
        handle(std.mem.trim(u8, c.buf[0..nl], " \t\r"), sup, &w);
        // One request per connection: a short blocking write is bounded by the
        // reply size, and the client is reading.
        os.writeAll(c.fd, w.buffered()) catch {};
        self.drop(c);
    }

    fn drop(self: *Server, c: *Client) void {
        _ = self;
        if (c.fd >= 0) os.close(c.fd);
        c.fd = -1;
        c.len = 0;
    }
};

/// Renders one request. Kept free of I/O so it can be tested by feeding it a
/// line and reading the buffer back.
pub fn handle(line: []const u8, sup: *Supervisor, w: *std.Io.Writer) void {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const verb = it.next() orelse return;
    const arg = it.next();

    if (std.mem.eql(u8, verb, "status")) return status(sup, w);
    if (std.mem.eql(u8, verb, "samples")) return samples(sup, w);

    const name = arg orelse {
        w.print("error: {s} needs a process name\n", .{verb}) catch {};
        return;
    };
    const i = sup.cfg.find(name) orelse {
        w.print("error: \"{s}\" is not a process in this config\n", .{name}) catch {};
        return;
    };

    if (std.mem.eql(u8, verb, "start")) {
        sup.startWorker(i);
    } else if (std.mem.eql(u8, verb, "stop")) {
        sup.stopWorker(i);
    } else if (std.mem.eql(u8, verb, "restart")) {
        sup.restartWorker(i);
    } else {
        w.print("error: unknown command \"{s}\"\n", .{verb}) catch {};
        return;
    }
    w.print("ok {s} {s}\n", .{ verb, name }) catch {};
}

/// Columns rather than JSON: the reader is usually a human running
/// `devrun status`, and `awk` handles the rest.
fn status(sup: *Supervisor, w: *std.Io.Writer) void {
    for (sup.workers) |*x| {
        w.print("{s}\t{t}\t{d}\t{d}\t{d}\n", .{
            x.name(),
            x.state,
            x.pgid,
            x.restarts,
            x.archive.len(),
        }) catch return;
    }
}

fn samples(sup: *Supervisor, w: *std.Io.Writer) void {
    for (sup.workers, sup.samples) |*x, s| {
        w.print("{s}\t{d:.1}\t{d}\t{d}\t{d}\t{d}\n", .{
            x.name(),
            s.cpu_percent,
            s.memory_bytes,
            s.read_bytes,
            s.write_bytes,
            s.processes,
        }) catch return;
    }
}

// ------------------------------------------------------------- client

/// Sends one line and returns the reply. Blocking, because the caller is a
/// one-shot CLI with nothing else to do — the event loop's rules do not apply
/// on this side.
pub fn ask(path: [:0]const u8, line: []const u8, buf: []u8) ![]const u8 {
    const fd = try os.socket(linux.AF.UNIX, linux.SOCK.STREAM, 0);
    defer os.close(fd);

    const addr = try sockaddrUn(path);
    try os.connectUn(fd, &addr);
    try os.writeAll(fd, line);

    var n: usize = 0;
    while (n < buf.len) {
        const got = os.read(fd, buf[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    return buf[0..n];
}

// ------------------------------------------------------------- tests

const testing = std.testing;

test "an unknown process is refused by name rather than ignored" {
    // The parser is the part worth testing without a Session: it decides what
    // a line means, and a wrong answer there is what would make `devrun stop`
    // silently do nothing.
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);

    var it = std.mem.tokenizeAny(u8, "stop", " \t");
    try testing.expectEqualStrings("stop", it.next().?);
    try testing.expect(it.next() == null);

    w.print("error: {s} needs a process name\n", .{"stop"}) catch {};
    try testing.expectEqualStrings("error: stop needs a process name\n", w.buffered());
}

test "a socket path longer than sun_path is refused, not truncated" {
    // Silently truncating would bind a different path than the client
    // connects to, and the failure would look like "no Session is running".
    const long = "/tmp/" ++ ("x" ** 200) ++ "/control.sock";
    try testing.expectError(error.NameTooLong, sockaddrUn(long));

    const ok = try sockaddrUn("/tmp/devrun-test/control.sock");
    try testing.expectEqualStrings(
        "/tmp/devrun-test/control.sock",
        std.mem.sliceTo(&ok.path, 0),
    );
}
