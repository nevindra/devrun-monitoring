//! A TOML 1.0 reader, for `devrun.toml`.
//!
//! Everything in TOML 1.0 except dates and times, which devrun has no field
//! for. A date in the file is refused with a message rather than read as
//! something else. Inline tables are held to the 1.0 rule of one line: the
//! 1.1 relaxation would be easy to accept here, but an editor still on 1.0
//! would then paint a file red that devrun reads happily, and two tools
//! disagreeing about one file is the thing devrun refuses to cause.
//!
//! The tree is allocated from the arena the caller passes and is never freed
//! piecemeal. Tables keep their keys in file order, because the order
//! services appear in is the order devrun shows them in.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    /// A float, validated but kept as written. No devrun field takes one,
    /// and converting it would pull the float parser's tables into the
    /// binary for a value that is only ever reported as the wrong type.
    float: []const u8,
    boolean: bool,
    array: *Array,
    table: *Table,

    /// What a value is, in the words a person reading an error would use.
    pub fn kindName(self: Value) []const u8 {
        return switch (self) {
            .string => "a string",
            .integer => "an integer",
            .float => "a float",
            .boolean => "a boolean",
            .array => "an array",
            .table => "a table",
        };
    }
};

pub const Array = struct {
    items: std.ArrayList(Value) = .empty,
    /// Built by `[[header]]` lines. Only these can be appended to by a later
    /// header; a static `x = [...]` cannot.
    of_tables: bool = false,
};

pub const Table = struct {
    map: std.StringArrayHashMapUnmanaged(Value) = .empty,
    origin: Origin,

    /// How a table came to exist, which is what decides whether a later line
    /// may add to it. TOML's rules here are the subtle part of the format.
    pub const Origin = enum {
        /// Created only as the parent of a header, like `a` in `[a.b]`. A
        /// later `[a]` may still define it.
        implicit,
        /// Defined by its own `[header]` or `[[header]]`.
        header,
        /// Created by a dotted key, like `a` in `a.b = 1`.
        dotted,
        /// Written as `{ ... }`. Closed for good once the brace is.
        inline_,
    };

    pub fn get(self: *const Table, key: []const u8) ?Value {
        return self.map.get(key);
    }
};

pub const Diagnostic = struct {
    line: usize = 0,
    column: usize = 0,
    /// Allocated from the arena passed to `parse`.
    message: []const u8 = "",
};

pub const Error = error{ Invalid, OutOfMemory };

/// Parses `src` into a root table. On `error.Invalid`, `diag` says where and
/// why, with a 1-based line and column.
pub fn parse(arena: Allocator, src: []const u8, diag: *Diagnostic) Error!*Table {
    var p = Parser{ .arena = arena, .src = src, .diag = diag };
    if (!std.unicode.utf8ValidateSlice(src)) {
        // Point at the first bad byte rather than at the top of the file.
        var i: usize = 0;
        while (i < src.len) {
            const n = std.unicode.utf8ByteSequenceLength(src[i]) catch break;
            if (i + n > src.len) break;
            _ = std.unicode.utf8Decode(src[i .. i + n]) catch break;
            i += n;
        }
        p.pos = i;
        return p.fail("the file is not valid UTF-8", .{});
    }
    return p.document();
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    diag: *Diagnostic,

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) Error {
        var line: usize = 1;
        var line_start: usize = 0;
        for (self.src[0..@min(self.pos, self.src.len)], 0..) |c, i| {
            if (c == '\n') {
                line += 1;
                line_start = i + 1;
            }
        }
        self.diag.line = line;
        self.diag.column = self.pos - line_start + 1;
        self.diag.message = std.fmt.allocPrint(self.arena, fmt, args) catch "out of memory";
        return error.Invalid;
    }

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn peekAt(self: *Parser, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.src.len) self.src[i] else null;
    }

    fn startsWith(self: *Parser, s: []const u8) bool {
        return std.mem.startsWith(u8, self.src[self.pos..], s);
    }

    fn skipSpaces(self: *Parser) void {
        while (self.peek()) |c| {
            if (c != ' ' and c != '\t') break;
            self.pos += 1;
        }
    }

    /// Consumes a newline if one is here. A bare `\r` is not one.
    fn newline(self: *Parser) Error!bool {
        const c = self.peek() orelse return false;
        if (c == '\n') {
            self.pos += 1;
            return true;
        }
        if (c == '\r') {
            if (self.peekAt(1) == '\n') {
                self.pos += 2;
                return true;
            }
            return self.fail("a carriage return must be followed by a newline", .{});
        }
        return false;
    }

    fn comment(self: *Parser) Error!void {
        if (self.peek() != '#') return;
        while (self.peek()) |c| {
            if (c == '\n' or (c == '\r' and self.peekAt(1) == '\n')) return;
            if (isControl(c) and c != '\t') {
                return self.fail("control character in a comment", .{});
            }
            self.pos += 1;
        }
    }

    /// Spaces, comments and newlines, as many as there are. Used between
    /// top-level lines and between array elements.
    fn skipBlank(self: *Parser) Error!void {
        while (true) {
            self.skipSpaces();
            try self.comment();
            if (!try self.newline()) return;
        }
    }

    /// What may follow a complete line: spaces, a comment, then a newline or
    /// the end of the file.
    fn endOfLine(self: *Parser) Error!void {
        self.skipSpaces();
        try self.comment();
        if (self.peek() == null) return;
        if (!try self.newline()) {
            return self.fail("expected the end of the line, found \"{c}\"", .{self.peek().?});
        }
    }

    fn document(self: *Parser) Error!*Table {
        const root = try self.newTable(.header);
        var current = root;
        while (true) {
            try self.skipBlank();
            const c = self.peek() orelse return root;
            if (c == '[') {
                if (self.peekAt(1) == '[') {
                    current = try self.arrayHeader(root);
                } else {
                    current = try self.tableHeader(root);
                }
            } else {
                try self.keyValue(current);
            }
            try self.endOfLine();
        }
    }

    fn newTable(self: *Parser, origin: Table.Origin) Error!*Table {
        const t = try self.arena.create(Table);
        t.* = .{ .origin = origin };
        return t;
    }

    // ---------------------------------------------------------- keys

    fn key(self: *Parser) Error![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        while (true) {
            self.skipSpaces();
            try parts.append(self.arena, try self.simpleKey());
            self.skipSpaces();
            if (self.peek() != '.') break;
            self.pos += 1;
        }
        return parts.items;
    }

    fn simpleKey(self: *Parser) Error![]const u8 {
        const c = self.peek() orelse return self.fail("expected a key, found the end of the file", .{});
        if (c == '"') {
            if (self.startsWith("\"\"\"")) return self.fail("a key cannot be a multi-line string", .{});
            return self.basicString();
        }
        if (c == '\'') {
            if (self.startsWith("'''")) return self.fail("a key cannot be a multi-line string", .{});
            return self.literalString();
        }
        const start = self.pos;
        while (self.peek()) |b| {
            if (!isBareKeyChar(b)) break;
            self.pos += 1;
        }
        if (self.pos == start) {
            return self.fail("expected a key, found \"{c}\"", .{c});
        }
        return self.src[start..self.pos];
    }

    fn keyValue(self: *Parser, table: *Table) Error!void {
        const key_start = self.pos;
        const parts = try self.key();
        if (self.peek() != '=') {
            if (self.peek() == null or self.peek() == '\n' or self.peek() == '\r') {
                return self.fail("expected \"=\" after the key \"{s}\"", .{parts[parts.len - 1]});
            }
            return self.fail("expected \"=\" after the key, found \"{c}\"", .{self.peek().?});
        }
        self.pos += 1;
        self.skipSpaces();
        const v = try self.value();
        const value_end = self.pos;

        // Errors about where the key goes point at the key, not past the value.
        self.pos = key_start;
        var t = table;
        for (parts[0 .. parts.len - 1]) |part| {
            if (t.map.get(part)) |existing| {
                switch (existing) {
                    .table => |sub| if (sub.origin == .dotted) {
                        t = sub;
                        continue;
                    },
                    else => {},
                }
                return self.fail("\"{s}\" is already defined, and cannot be extended with a dotted key", .{part});
            }
            const sub = try self.newTable(.dotted);
            try t.map.put(self.arena, part, .{ .table = sub });
            t = sub;
        }
        const last = parts[parts.len - 1];
        if (t.map.contains(last)) return self.fail("\"{s}\" is defined twice", .{last});
        try t.map.put(self.arena, last, v);
        self.pos = value_end;
    }

    // ---------------------------------------------------------- headers

    /// Follows `parts` down from the root the way a header does: through any
    /// table that is not inline, and into the last element of an array of
    /// tables.
    fn walkHeader(self: *Parser, root: *Table, parts: []const []const u8) Error!*Table {
        var t = root;
        for (parts) |part| {
            if (t.map.get(part)) |existing| {
                switch (existing) {
                    .table => |sub| {
                        if (sub.origin == .inline_) {
                            return self.fail("\"{s}\" is an inline table and cannot be extended", .{part});
                        }
                        t = sub;
                    },
                    .array => |arr| {
                        if (!arr.of_tables) {
                            return self.fail("\"{s}\" is an array, not a table", .{part});
                        }
                        t = arr.items.items[arr.items.items.len - 1].table;
                    },
                    else => return self.fail("\"{s}\" is {s}, not a table", .{ part, existing.kindName() }),
                }
            } else {
                const sub = try self.newTable(.implicit);
                try t.map.put(self.arena, part, .{ .table = sub });
                t = sub;
            }
        }
        return t;
    }

    fn headerKey(self: *Parser, closer: []const u8) Error![]const []const u8 {
        const parts = try self.key();
        if (!self.startsWith(closer)) {
            return self.fail("expected \"{s}\" to close the table header", .{closer});
        }
        self.pos += closer.len;
        return parts;
    }

    fn tableHeader(self: *Parser, root: *Table) Error!*Table {
        const start = self.pos;
        self.pos += 1;
        const parts = try self.headerKey("]");
        const end = self.pos;
        self.pos = start;

        const parent = try self.walkHeader(root, parts[0 .. parts.len - 1]);
        const last = parts[parts.len - 1];
        const t = if (parent.map.get(last)) |existing| blk: {
            switch (existing) {
                .table => |sub| if (sub.origin == .implicit) {
                    sub.origin = .header;
                    break :blk sub;
                },
                else => {},
            }
            return self.fail("table [{s}] is defined twice", .{joinKey(self.arena, parts)});
        } else blk: {
            const sub = try self.newTable(.header);
            try parent.map.put(self.arena, last, .{ .table = sub });
            break :blk sub;
        };
        self.pos = end;
        return t;
    }

    fn arrayHeader(self: *Parser, root: *Table) Error!*Table {
        const start = self.pos;
        self.pos += 2;
        const parts = try self.headerKey("]]");
        const end = self.pos;
        self.pos = start;

        const parent = try self.walkHeader(root, parts[0 .. parts.len - 1]);
        const last = parts[parts.len - 1];
        const elem = try self.newTable(.header);
        if (parent.map.get(last)) |existing| {
            switch (existing) {
                .array => |arr| if (arr.of_tables) {
                    try arr.items.append(self.arena, .{ .table = elem });
                    self.pos = end;
                    return elem;
                },
                else => {},
            }
            return self.fail("[[{s}]] names something that is not an array of tables", .{joinKey(self.arena, parts)});
        }
        const arr = try self.arena.create(Array);
        arr.* = .{ .of_tables = true };
        try arr.items.append(self.arena, .{ .table = elem });
        try parent.map.put(self.arena, last, .{ .array = arr });
        self.pos = end;
        return elem;
    }

    // ---------------------------------------------------------- values

    fn value(self: *Parser) Error!Value {
        const c = self.peek() orelse return self.fail("expected a value, found the end of the file", .{});
        switch (c) {
            '"' => {
                if (self.startsWith("\"\"\"")) return .{ .string = try self.multilineBasic() };
                return .{ .string = try self.basicString() };
            },
            '\'' => {
                if (self.startsWith("'''")) return .{ .string = try self.multilineLiteral() };
                return .{ .string = try self.literalString() };
            },
            '[' => return .{ .array = try self.array() },
            '{' => return .{ .table = try self.inlineTable() },
            '\n', '\r' => return self.fail("expected a value after \"=\"", .{}),
            else => {},
        }
        if (self.startsWith("true") and self.isDelimiterAt(4)) {
            self.pos += 4;
            return .{ .boolean = true };
        }
        if (self.startsWith("false") and self.isDelimiterAt(5)) {
            self.pos += 5;
            return .{ .boolean = false };
        }
        return self.number();
    }

    fn isDelimiterAt(self: *Parser, offset: usize) bool {
        const c = self.peekAt(offset) orelse return true;
        return isDelimiter(c);
    }

    fn array(self: *Parser) Error!*Array {
        self.pos += 1; // [
        const arr = try self.arena.create(Array);
        arr.* = .{};
        while (true) {
            try self.skipBlank();
            if (self.peek() == ']') {
                self.pos += 1;
                return arr;
            }
            try arr.items.append(self.arena, try self.value());
            try self.skipBlank();
            const c = self.peek() orelse return self.fail("unterminated array", .{});
            if (c == ',') {
                self.pos += 1;
                continue;
            }
            if (c == ']') {
                self.pos += 1;
                return arr;
            }
            return self.fail("expected \",\" or \"]\" in the array, found \"{c}\"", .{c});
        }
    }

    fn inlineTable(self: *Parser) Error!*Table {
        self.pos += 1; // {
        // Built as dotted so dotted keys inside it can extend each other, then
        // closed once the brace is.
        const t = try self.newTable(.dotted);
        self.skipSpaces();
        if (self.peek() == '}') {
            self.pos += 1;
            t.origin = .inline_;
            return t;
        }
        while (true) {
            self.skipSpaces();
            if (self.peek() == '\n' or self.peek() == '\r') return self.inlineNewline();
            try self.keyValue(t);
            self.skipSpaces();
            const c = self.peek() orelse return self.fail("unterminated inline table", .{});
            if (c == ',') {
                self.pos += 1;
                self.skipSpaces();
                if (self.peek() == '}') {
                    return self.fail("an inline table cannot end with a trailing comma", .{});
                }
                continue;
            }
            if (c == '}') {
                self.pos += 1;
                close(t);
                return t;
            }
            if (c == '\n' or c == '\r') return self.inlineNewline();
            return self.fail("expected \",\" or \"}}\" in the inline table, found \"{c}\"", .{c});
        }
    }

    fn inlineNewline(self: *Parser) Error {
        return self.fail(
            "an inline table must stay on one line. For a longer one, " ++
                "use a [table] header instead",
            .{},
        );
    }

    fn close(t: *Table) void {
        t.origin = .inline_;
        for (t.map.values()) |v| switch (v) {
            .table => |sub| close(sub),
            else => {},
        };
    }

    // ---------------------------------------------------------- strings

    fn basicString(self: *Parser) Error![]const u8 {
        self.pos += 1; // "
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated string", .{});
            switch (c) {
                '"' => {
                    self.pos += 1;
                    return out.items;
                },
                '\\' => try self.escape(&out),
                '\n', '\r' => return self.fail(
                    "unterminated string. A string that spans lines needs \"\"\" quotes",
                    .{},
                ),
                else => {
                    if (isControl(c) and c != '\t') return self.fail("control character in a string; escape it", .{});
                    try out.append(self.arena, c);
                    self.pos += 1;
                },
            }
        }
    }

    fn multilineBasic(self: *Parser) Error![]const u8 {
        self.pos += 3;
        _ = try self.newline(); // one right after the opening quotes is dropped
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated multi-line string", .{});
            if (c == '"' and self.startsWith("\"\"\"")) {
                if (try self.closeMultiline('"', &out)) return out.items;
                continue;
            }
            if (c == '\\') {
                // A backslash ending a line swallows every space and newline
                // up to the next character that is neither.
                var look = self.pos + 1;
                while (look < self.src.len and (self.src[look] == ' ' or self.src[look] == '\t')) look += 1;
                if (look < self.src.len and (self.src[look] == '\n' or self.src[look] == '\r')) {
                    self.pos = look;
                    while (true) {
                        self.skipSpaces();
                        if (!try self.newline()) break;
                    }
                    continue;
                }
                try self.escape(&out);
                continue;
            }
            if (c == '\r') {
                _ = try self.newline();
                try out.append(self.arena, '\n');
                continue;
            }
            if (isControl(c) and c != '\t' and c != '\n') {
                return self.fail("control character in a string; escape it", .{});
            }
            try out.append(self.arena, c);
            self.pos += 1;
        }
    }

    fn literalString(self: *Parser) Error![]const u8 {
        self.pos += 1; // '
        const start = self.pos;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated string", .{});
            if (c == '\'') {
                const s = self.src[start..self.pos];
                self.pos += 1;
                return s;
            }
            if (c == '\n' or c == '\r') {
                return self.fail("unterminated string. A string that spans lines needs ''' quotes", .{});
            }
            if (isControl(c) and c != '\t') return self.fail("control character in a string", .{});
            self.pos += 1;
        }
    }

    fn multilineLiteral(self: *Parser) Error![]const u8 {
        self.pos += 3;
        _ = try self.newline();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = self.peek() orelse return self.fail("unterminated multi-line string", .{});
            if (c == '\'' and self.startsWith("'''")) {
                if (try self.closeMultiline('\'', &out)) return out.items;
                continue;
            }
            if (c == '\r') {
                _ = try self.newline();
                try out.append(self.arena, '\n');
                continue;
            }
            if (isControl(c) and c != '\t' and c != '\n') {
                return self.fail("control character in a string", .{});
            }
            try out.append(self.arena, c);
            self.pos += 1;
        }
    }

    /// At a run of three or more quotes. Up to two of them may belong to the
    /// content, so `""""` is one quote and then the close.
    fn closeMultiline(self: *Parser, q: u8, out: *std.ArrayList(u8)) Error!bool {
        var n: usize = 0;
        while (self.peekAt(n) == q) n += 1;
        if (n > 5) return self.fail("too many quotes in a row", .{});
        try out.appendNTimes(self.arena, q, n - 3);
        self.pos += n;
        return true;
    }

    fn escape(self: *Parser, out: *std.ArrayList(u8)) Error!void {
        self.pos += 1; // backslash
        const c = self.peek() orelse return self.fail("unterminated escape", .{});
        self.pos += 1;
        const simple: ?u8 = switch (c) {
            'b' => 0x08,
            't' => '\t',
            'n' => '\n',
            'f' => 0x0c,
            'r' => '\r',
            '"' => '"',
            '\\' => '\\',
            else => null,
        };
        if (simple) |b| return out.append(self.arena, b);
        const digits: usize = switch (c) {
            'u' => 4,
            'U' => 8,
            else => {
                self.pos -= 2;
                return self.fail("unknown escape \"\\{c}\"", .{c});
            },
        };
        if (self.pos + digits > self.src.len) return self.fail("unterminated \\{c} escape", .{c});
        const hex = self.src[self.pos .. self.pos + digits];
        const cp = std.fmt.parseInt(u21, hex, 16) catch
            return self.fail("\"\\{c}{s}\" is not a valid Unicode escape", .{ c, hex });
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch
            return self.fail("\"\\{c}{s}\" is not a Unicode scalar value", .{ c, hex });
        self.pos += digits;
        try out.appendSlice(self.arena, buf[0..n]);
    }

    // ---------------------------------------------------------- numbers

    fn number(self: *Parser) Error!Value {
        const start = self.pos;
        while (self.peek()) |c| {
            if (isDelimiter(c)) break;
            self.pos += 1;
        }
        const tok = self.src[start..self.pos];
        self.pos = start;
        if (tok.len == 0) return self.fail("expected a value, found \"{c}\"", .{self.peek().?});

        // A date or a time. Recognised so it can be refused by name: a field
        // that expected a string would otherwise report a baffling error.
        if (tok.len >= 5 and std.ascii.isDigit(tok[0]) and
            (std.mem.indexOfScalar(u8, tok, ':') != null or
                (tok.len >= 10 and tok[4] == '-' and std.ascii.isDigit(tok[1]))))
        {
            return self.fail("dates and times are not supported; quote it to make it a string", .{});
        }

        const v = parseNumber(tok) orelse {
            if (std.ascii.isAlphabetic(tok[0])) {
                return self.fail(
                    "\"{s}\" is not a value. Strings need quotes: \"{s}\"",
                    .{ tok, tok },
                );
            }
            return self.fail("\"{s}\" is not a valid number", .{tok});
        };
        self.pos += tok.len;
        return v;
    }
};

fn parseNumber(tok: []const u8) ?Value {
    const unsigned = if (tok[0] == '+' or tok[0] == '-') tok[1..] else tok;
    if (std.mem.eql(u8, unsigned, "inf")) {
        return .{ .float = tok };
    }
    if (std.mem.eql(u8, unsigned, "nan")) return .{ .float = tok };
    if (unsigned.len == 0) return null;

    // Prefixed integers take no sign.
    if (tok.len > 2 and tok[0] == '0' and (tok[1] == 'x' or tok[1] == 'o' or tok[1] == 'b')) {
        const base: u8 = switch (tok[1]) {
            'x' => 16,
            'o' => 8,
            else => 2,
        };
        const digits = tok[2..];
        if (!underscoresOk(digits)) return null;
        var buf: [128]u8 = undefined;
        const clean = stripUnderscores(digits, &buf) orelse return null;
        return .{ .integer = std.fmt.parseInt(i64, clean, base) catch return null };
    }

    const is_float = std.mem.indexOfAny(u8, unsigned, ".eE") != null;
    if (!is_float) {
        for (unsigned) |c| if (!std.ascii.isDigit(c) and c != '_') return null;
        if (!underscoresOk(unsigned)) return null;
        if (unsigned.len > 1 and unsigned[0] == '0') return null; // no leading zeros
        var buf: [128]u8 = undefined;
        const clean = stripUnderscores(tok, &buf) orelse return null;
        return .{ .integer = std.fmt.parseInt(i64, clean, 10) catch return null };
    }

    // Float: an integer part, then a fraction, an exponent, or both. Every
    // part needs digits on both sides of its dot or underscore.
    const exp_at = std.mem.indexOfAny(u8, unsigned, "eE");
    const mantissa = unsigned[0 .. exp_at orelse unsigned.len];
    const dot = std.mem.indexOfScalar(u8, mantissa, '.');
    const int_part = mantissa[0 .. dot orelse mantissa.len];
    if (!digitsOk(int_part)) return null;
    if (int_part.len > 1 and int_part[0] == '0') return null;
    if (dot) |d| if (!digitsOk(mantissa[d + 1 ..])) return null;
    if (exp_at) |e| {
        var exp = unsigned[e + 1 ..];
        if (exp.len > 0 and (exp[0] == '+' or exp[0] == '-')) exp = exp[1..];
        if (!digitsOk(exp)) return null;
    }
    return .{ .float = tok };
}

fn digitsOk(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| if (!std.ascii.isDigit(c) and c != '_') return false;
    return underscoresOk(s);
}

/// An underscore must sit between two digits.
fn underscoresOk(s: []const u8) bool {
    if (s.len == 0) return false;
    if (s[0] == '_' or s[s.len - 1] == '_') return false;
    return std.mem.indexOf(u8, s, "__") == null;
}

fn stripUnderscores(s: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    for (s) |c| {
        if (c == '_') continue;
        if (n == buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

fn isBareKeyChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

fn isDelimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ',', ']', '}', '#' => true,
        else => false,
    };
}

fn isControl(c: u8) bool {
    return c < 0x20 or c == 0x7f;
}

fn joinKey(arena: Allocator, parts: []const []const u8) []const u8 {
    return std.mem.join(arena, ".", parts) catch "?";
}

// ------------------------------------------------------------- tests

const testing = std.testing;

fn parseOk(arena: Allocator, src: []const u8) !*Table {
    var diag: Diagnostic = .{};
    return parse(arena, src, &diag) catch |e| {
        std.debug.print("unexpected error {d}:{d}: {s}\n", .{ diag.line, diag.column, diag.message });
        return e;
    };
}

fn parseErr(arena: Allocator, src: []const u8) !Diagnostic {
    var diag: Diagnostic = .{};
    if (parse(arena, src, &diag)) |_| {
        std.debug.print("expected an error for:\n{s}\n", .{src});
        return error.TestUnexpectedResult;
    } else |e| try testing.expectEqual(error.Invalid, e);
    return diag;
}

fn tableAt(t: *const Table, k: []const u8) *Table {
    return t.get(k).?.table;
}

test "scalars, comments and both kinds of string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = try parseOk(a,
        \\# leading comment
        \\name = "api"   # trailing comment
        \\path = 'C:\Users\x'
        \\port = 3_000
        \\neg = -17
        \\hex = 0xff
        \\ratio = 1.5e3
        \\on = true
        \\off = false
        \\esc = "tab\there \u00e9 \"q\""
        \\
    );
    try testing.expectEqualStrings("api", t.get("name").?.string);
    try testing.expectEqualStrings("C:\\Users\\x", t.get("path").?.string);
    try testing.expectEqual(@as(i64, 3000), t.get("port").?.integer);
    try testing.expectEqual(@as(i64, -17), t.get("neg").?.integer);
    try testing.expectEqual(@as(i64, 255), t.get("hex").?.integer);
    try testing.expectEqualStrings("1.5e3", t.get("ratio").?.float);
    try testing.expect(t.get("on").?.boolean);
    try testing.expect(!t.get("off").?.boolean);
    try testing.expectEqualStrings("tab\there \u{e9} \"q\"", t.get("esc").?.string);
}

test "multi-line strings trim the first newline and honour line-ending backslashes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = try parseOk(a,
        \\script = """
        \\set -e
        \\pnpm db:seed
        \\"""
        \\joined = """one \
        \\    two"""
        \\raw = '''
        \\echo '$HOME' \n stays'''
        \\quote = """a "quoted" word"""""
        \\
    );
    try testing.expectEqualStrings("set -e\npnpm db:seed\n", t.get("script").?.string);
    try testing.expectEqualStrings("one two", t.get("joined").?.string);
    try testing.expectEqualStrings("echo '$HOME' \\n stays", t.get("raw").?.string);
    try testing.expectEqualStrings("a \"quoted\" word\"\"", t.get("quote").?.string);
}

test "tables, dotted keys, inline tables and arrays keep file order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = try parseOk(a,
        \\[services.web]
        \\run = "pnpm dev"
        \\
        \\[services.api]
        \\run = ["go", "run", "."]
        \\env = { PORT = "3000", "WEIRD KEY" = 'x' }
        \\after.db = "ready"
        \\
        \\[services.api.ready]
        \\http = "http://localhost:3000/health"
        \\
        \\[services.db]
        \\run = """
        \\postgres
        \\"""
        \\args = [
        \\  "a",  # a comment inside an array
        \\  "b",
        \\]
        \\
    );
    const services = tableAt(t, "services");
    try testing.expectEqualStrings("web", services.map.keys()[0]);
    try testing.expectEqualStrings("api", services.map.keys()[1]);
    try testing.expectEqualStrings("db", services.map.keys()[2]);

    const api = tableAt(services, "api");
    const run = api.get("run").?.array.items.items;
    try testing.expectEqual(@as(usize, 3), run.len);
    try testing.expectEqualStrings("go", run[0].string);
    try testing.expectEqualStrings("x", tableAt(api, "env").get("WEIRD KEY").?.string);
    try testing.expectEqualStrings("ready", tableAt(api, "after").get("db").?.string);
    try testing.expectEqualStrings(
        "http://localhost:3000/health",
        tableAt(api, "ready").get("http").?.string,
    );
    try testing.expectEqual(@as(usize, 2), tableAt(services, "db").get("args").?.array.items.items.len);
}

test "arrays of tables, and headers that reach into their last element" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = try parseOk(a,
        \\[[hook]]
        \\run = "one"
        \\[hook.opts]
        \\x = 1
        \\[[hook]]
        \\run = "two"
        \\
    );
    const hooks = t.get("hook").?.array.items.items;
    try testing.expectEqual(@as(usize, 2), hooks.len);
    try testing.expectEqual(@as(i64, 1), tableAt(hooks[0].table, "opts").get("x").?.integer);
    try testing.expect(hooks[1].table.get("opts") == null);
}

test "an implicit table may be defined later, a defined one may not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    _ = try parseOk(a,
        \\[a.b]
        \\x = 1
        \\[a]
        \\y = 2
        \\
    );
    _ = try parseErr(a,
        \\[a]
        \\x = 1
        \\[a]
        \\y = 2
        \\
    );
}

test "the mistakes TOML exists to refuse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const cases = [_][]const u8{
        "x = 1\nx = 2\n", // duplicate key
        "x = { a = 1 }\n[x]\nb = 2\n", // reopening an inline table
        "x = { a = 1 }\nx.b = 2\n", // extending one with a dotted key
        "x = 1\nx.y = 2\n", // a scalar used as a table
        "[x]\ny = 1\n[x.y]\n", // a key used as a table header
        "x = \"unterminated\n", // newline in a basic string
        "x = { a = 1, }\n", // trailing comma in an inline table
        "x = 01\n", // leading zero
        "x = 1__0\n", // doubled underscore
        "x = 1.\n", // nothing after the dot
        "x = \"\\q\"\n", // unknown escape
        "x = 1 y = 2\n", // two pairs on one line
        "x\n", // no equals
        "x = \n", // no value
        "x = bare\n", // an unquoted string
        "[x\n", // unclosed header
    };
    for (cases) |src| _ = try parseErr(a, src);
}

test "an inline table split over lines says what to do instead" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const d = try parseErr(a,
        \\ready = {
        \\  http = "http://localhost:3000"
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), d.line);
    try testing.expect(std.mem.indexOf(u8, d.message, "[table] header") != null);
}

test "a date is refused by name rather than misread" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const d = try parseErr(a, "since = 1979-05-27\n");
    try testing.expect(std.mem.indexOf(u8, d.message, "dates and times") != null);
    const d2 = try parseErr(a, "at = 07:32:00\n");
    try testing.expect(std.mem.indexOf(u8, d2.message, "dates and times") != null);
}

test "errors carry the line and column they happened on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const d = try parseErr(a,
        \\[services.api]
        \\run = "x"
        \\run = "y"
        \\
    );
    try testing.expectEqual(@as(usize, 3), d.line);
    try testing.expectEqual(@as(usize, 1), d.column);
    try testing.expect(std.mem.indexOf(u8, d.message, "defined twice") != null);
}

test "CRLF line endings read the same as LF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const t = try parseOk(a, "[a]\r\nx = \"\"\"\r\none\r\ntwo\"\"\"\r\n");
    try testing.expectEqualStrings("one\ntwo", tableAt(t, "a").get("x").?.string);
}
