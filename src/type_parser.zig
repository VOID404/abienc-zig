const std = @import("std");
const sol = @import("sol.zig");

const ArrType = struct {
    len: usize,
    type: Type,
};

const Type = union(sol.SolType) {
    const Self = @This();
    uint,
    tuple: []const Type,
    array: *ArrType,
    arrayDyn: *Type,

    const uint = Self{ .uint = {} };
    fn tuple(inner: []Self) Self {
        return Self{
            .tuple = inner,
        };
    }
    fn array(alloc: std.mem.Allocator, inner: Self, len: usize) !Self {
        var i = try alloc.create(ArrType);
        i.type = inner;
        i.len = len;
        return Self{
            .array = i,
        };
    }
    fn arrayDyn(alloc: std.mem.Allocator, inner: Self) !Self {
        var i = try alloc.create(Type);
        i.* = inner;
        return Self{
            .arrayDyn = i,
        };
    }
    fn destroy(self: Self, alloc: std.mem.Allocator) void {
        switch (self) {
            .tuple => |v| {
                for (v) |inner| {
                    inner.destroy(alloc);
                }
                alloc.free(v);
            },
            .arrayDyn => |v| {
                v.destroy(alloc); // destroy inner type
                alloc.destroy(v); // destroy the pointer
            },
            .array => |v| {
                v.type.destroy(alloc);
                alloc.destroy(v);
            },
            else => {},
        }
    }
};

const ParseError = std.mem.Allocator.Error || error{
    UnexpectedSymbol,
    EOF,
};

const Parser = struct {
    const Self = @This();

    column: usize,
    alloc: std.mem.Allocator,

    fn new(alloc: std.mem.Allocator) Self {
        return Self{
            .column = 0,
            .alloc = alloc,
        };
    }

    pub fn parse(self: *Self, buf: []const u8) ParseError!Type {
        self.column = 0;

        var t = try self.switchBoard(buf);
        if (self.noEOF(buf)) |_| {
            const size = try self.parseArr(buf);
            if (size) |len| {
                return Type.array(self.alloc, t, len);
            } else {
                return Type.arrayDyn(self.alloc, t);
            }
        } else |_| {
            return t;
        }
    }

    fn parseArr(self: *Self, buf: []const u8) ParseError!?usize {
        var len: ?usize = null;
        try self.noEOF(buf);
        try self.parseChars(buf, "[");
        if (self.parseNum(buf)) |n| {
            len = n;
        } else |_| {}
        try self.parseChars(buf, "]");
        return len;
    }

    fn switchBoard(self: *Self, buf: []const u8) ParseError!Type {
        switch (buf[self.column]) {
            'u' => return self.parseUInt(buf), // ufixed isn't supported
            '(' => return self.parseTuple(buf),
            else => return ParseError.UnexpectedSymbol,
        }
    }

    fn parseTuple(self: *Self, buf: []const u8) ParseError!Type {
        try self.parseChars(buf, "(");

        var list = std.ArrayList(Type).init(self.alloc);
        errdefer list.deinit();

        while (true) {
            const elem = try self.switchBoard(buf);
            try list.append(elem);
            try self.noEOF(buf);
            switch (buf[self.column]) {
                ',' => self.column += 1,
                ')' => break,
                else => return ParseError.UnexpectedSymbol,
            }
        }

        self.column += 1;
        return Type{ .tuple = try list.toOwnedSlice() };
    }

    fn parseUInt(self: *Self, buf: []const u8) ParseError!Type {
        try self.parseChars(buf, "uint");
        _ = self.parseNum(buf) catch 0;
        return Type{ .uint = {} };
    }

    fn parseNum(self: *Self, buf: []const u8) ParseError!u64 {
        var out: ?u64 = null;
        var pos: usize = 0;
        try self.noEOF(buf);
        while (self.column < buf.len) {
            switch (buf[self.column]) {
                '0'...'9' => |n| {
                    const digit = std.fmt.charToDigit(n, 10) catch unreachable;
                    out = digit + (out orelse 0) * std.math.pow(u64, 10, pos);
                    pos += 1;
                    self.column += 1;
                },
                else => break,
            }
        }
        if (out) |o| {
            return o;
        } else {
            return ParseError.UnexpectedSymbol;
        }
    }

    fn parseChars(self: *Self, buf: []const u8, expected: []const u8) ParseError!void {
        for (expected) |c| {
            try self.noEOF(buf);
            if (buf[self.column] == c) {
                self.column += 1;
            } else {
                return ParseError.UnexpectedSymbol;
            }
        }
    }

    fn noEOF(self: *Self, buf: []const u8) ParseError!void {
        if (self.column >= buf.len)
            return ParseError.EOF;
    }
};

const testing = std.testing;
test "parse uint" {
    var p = Parser.new(testing.allocator);
    const actual = try p.parse("uint");

    try testing.expectEqual(sol.SolType.uint, actual);
}

test "parse tuple" {
    var p = Parser.new(testing.allocator);
    const actual = try p.parse("(uint,uint234)");
    defer actual.destroy(testing.allocator);

    try testing.expectEqual(sol.SolType.tuple, actual);

    var inner = [_]Type{ Type.uint, Type.uint };
    try testing.expectEqualSlices(Type, &inner, actual.tuple);
}

test "parse nested tuple" {
    var p = Parser.new(testing.allocator);
    const actual = try p.parse("(uint,(uint,uint))");
    defer actual.destroy(testing.allocator);

    try testing.expectEqual(sol.SolType.tuple, actual);

    const first = actual.tuple[0];
    const second = actual.tuple[1];

    try testing.expectEqual(Type.uint, first);
    try testing.expectEqualSlices(Type, &[_]Type{ Type.uint, Type.uint }, second.tuple);
}

test "parse array" {
    var p = Parser.new(testing.allocator);
    const actual = try p.parse("(uint,uint)[13]");
    defer actual.destroy(testing.allocator);

    try testing.expectEqual(sol.SolType.array, actual);

    const inner = actual.array.type;
    try testing.expectEqual(@as(usize, 13), actual.array.len);
    try testing.expectEqual(sol.SolType.tuple, inner);
    try testing.expectEqual(@as(usize, 2), inner.tuple.len);
    try testing.expectEqual(sol.SolType.uint, inner.tuple[0]);
    try testing.expectEqual(sol.SolType.uint, inner.tuple[1]);
}

test "parse dynamic array" {
    var p = Parser.new(testing.allocator);
    const actual = try p.parse("(uint,uint)[]");
    defer actual.destroy(testing.allocator);

    try testing.expectEqual(sol.SolType.arrayDyn, actual);

    const inner = actual.arrayDyn.*;
    try testing.expectEqual(sol.SolType.tuple, inner);
    try testing.expectEqual(@as(usize, 2), inner.tuple.len);
    try testing.expectEqual(sol.SolType.uint, inner.tuple[0]);
    try testing.expectEqual(sol.SolType.uint, inner.tuple[1]);
}
