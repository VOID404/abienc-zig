const std = @import("std");
const bigint = @import("bigint.zig").bigint;
const assert = std.debug.assert;

const EncodingError = error{
    EmptyData,
    BadType,
    BadSize,
};

pub const SolUint = struct {
    const Inner = bigint(u64, 256);
    const Self = @This();

    data: Inner,

    pub fn new(val: Inner) Self {
        return Self{
            .data = val,
        };
    }

    pub fn encode(self: Self, buf: []u8) usize {
        const hex = self.data.hex();
        @memcpy(buf.ptr, &hex);
        return hex.len;
    }
};

pub const SolTuple = struct {
    const Self = @This();

    data: []SolVal,

    fn new(data: []SolVal) Self {
        return Self{
            .data = data,
        };
    }

    fn dynamic(self: Self) bool {
        for (self.data) |elem| {
            if (elem.dynamic()) return true;
        }
        return false;
    }

    fn headLen(self: Self) usize {
        if (self.dynamic())
            return 64;

        return self.childHead();
    }

    fn childHead(self: Self) usize {
        var len: usize = 0;
        for (self.data) |elem| {
            len += elem.headLen();
        }
        return len;
    }

    fn encode(self: Self, buf: []u8) EncodingError!usize {
        const headSize = self.childHead();
        var tailSizeSoFar: usize = 0;
        var headSizeSoFar: usize = 0;

        for (self.data) |elem| {
            if (elem.dynamic()) {
                const ptr = SolVal.pack_uint((headSize + tailSizeSoFar) / 2);
                headSizeSoFar += try ptr.encode(buf[headSizeSoFar..]);
                tailSizeSoFar += try elem.encode(buf[headSize + tailSizeSoFar ..]);
            } else {
                headSizeSoFar += try elem.encode(buf[headSizeSoFar..]);
            }
        }

        assert(headSize == headSizeSoFar);

        return headSize + tailSizeSoFar;
    }
};

pub const SolArrayDyn = struct {
    const Self = @This();

    data: SolTuple,

    fn new(data: []SolVal) Self {
        return Self{
            .data = SolTuple.new(data),
        };
    }

    fn encode(self: Self, buf: []u8) EncodingError!usize {
        const len = SolVal.pack_uint(self.data.data.len);
        var size = try len.encode(buf);
        size += try self.data.encode(buf[size..]);

        return size;
    }
};

pub const SolType = enum {
    uint,
    tuple,
    array,
    arrayDyn,
};

pub const SolVal = union(SolType) {
    const Self = @This();

    uint: SolUint,
    tuple: SolTuple,
    array: SolTuple,
    arrayDyn: SolArrayDyn,

    pub fn pack_uint(val: u64) Self {
        const big = SolUint.Inner.new(val);
        return Self{
            .uint = SolUint.new(big),
        };
    }

    pub fn pack_tuple(val: []SolVal) Self {
        return Self{
            .tuple = SolTuple.new(val),
        };
    }

    pub fn pack_array(val: []SolVal) Self {
        return Self{
            .array = SolTuple.new(val),
        };
    }

    pub fn pack_array_dyn(val: []SolVal) Self {
        return Self{
            .arrayDyn = SolArrayDyn.new(val),
        };
    }

    pub fn encode(self: Self, buf: []u8) EncodingError!usize {
        return switch (self) {
            SolType.uint => |val| val.encode(buf),
            SolType.tuple => |val| val.encode(buf),
            SolType.array => |val| val.encode(buf),
            SolType.arrayDyn => |val| val.encode(buf),
        };
    }

    fn dynamic(self: Self) bool {
        return switch (self) {
            SolType.uint => false,
            SolType.tuple => |val| val.dynamic(),
            SolType.array => |val| val.dynamic(),
            SolType.arrayDyn => true,
        };
    }

    fn headLen(self: Self) usize {
        return switch (self) {
            SolType.uint => 64,
            SolType.tuple => |val| val.headLen(),
            SolType.array => |val| val.headLen(),
            SolType.arrayDyn => 64,
        };
    }

    fn typep(self: Self, t: SolType) bool {
        return @as(SolType, self) == t;
    }
};

const testing = std.testing;

test "uint" {
    const num = SolVal.pack_uint(0xdead0beef);
    const expected = @embedFile("testing/uint.txt");
    var buf = [_]u8{0} ** 128;

    const len = try num.encode(&buf);
    try testing.expectEqual(@as(usize, 64), len);
    const str = std.mem.span(@as([*:0]u8, @ptrCast(&buf)));
    try testing.expectEqualStrings(expected, str);
}

test "(uint,uint,uint)" {
    const nums = [_]u64{ 1, 2, 3 };
    const expected = @embedFile("testing/tuple01.txt");

    var pckd = [_]SolVal{SolVal.pack_uint(0)} ** 3;

    for (nums, 0..) |num, i| {
        pckd[i] = SolVal.pack_uint(num);
    }

    const tpl = SolVal.pack_tuple(&pckd);

    var buf = [_]u8{0} ** 256;
    const len = try tpl.encode(&buf);

    try testing.expectEqual(@as(usize, 3 * 64), len);
    const str = std.mem.span(@as([*:0]u8, @ptrCast(&buf)));
    try testing.expectEqualStrings(expected, str);
}

test "(uint,uint[][3],uint)" {
    // (0, [[1,2],[],[3,4,5]], 6)
    var nums: [7]SolVal = undefined;
    for (&nums, 0..) |*num, i| {
        num.* = SolVal.pack_uint(i);
    }

    const expected = @embedFile("testing/tuple02.txt");

    const dyn1 = SolVal.pack_array_dyn(nums[1..3]);
    const dyn2 = SolVal.pack_array_dyn(nums[3..3]);
    const dyn3 = SolVal.pack_array_dyn(nums[3..6]);

    var arrData = [_]SolVal{ dyn1, dyn2, dyn3 };
    const arr = SolVal.pack_array(&arrData);

    var tplData = [_]SolVal{ nums[0], arr, nums[6] };
    const tpl = SolVal.pack_tuple(&tplData);

    var buf = [_]u8{0} ** 1024;
    const len = try tpl.encode(&buf);
    try testing.expectEqual(@as(usize, 896), len);

    const str = std.mem.span(@as([*:0]u8, @ptrCast(&buf)));
    try testing.expectEqualStrings(expected, str);
}
