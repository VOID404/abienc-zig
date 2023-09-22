const std = @import("std");

fn num_fmt(comptime num: type) []const u8 {
    return std.fmt.comptimePrint("{{x:0>{d}}}", .{@typeInfo(num).Int.bits / 4});
}

pub fn bigint(comptime inner: type, comptime size: comptime_int) type {
    const bits = @typeInfo(inner).Int.bits;
    comptime std.debug.assert(size % bits == 0);
    return struct {
        const Self = @This();
        const inner_bits = bits;
        const len = size / inner_bits;
        const hex_len = size / 4;

        data: [len]inner,

        pub fn new(v: inner) Self {
            var out = Self{ .data = [_]inner{0} ** len };
            out.data[len - 1] = v;
            return out;
        }

        pub fn newBig(v: [len]inner) Self {
            var out = Self{ .data = v };
            return out;
        }

        pub fn hex(self: Self) [hex_len]u8 {
            var out = [_]u8{'0'} ** (hex_len);

            for (self.data, 0..) |value, i| {
                const start = i * inner_bits / 4;
                const end = start + (inner_bits / 4);

                _ = std.fmt.bufPrint(out[start..end], num_fmt(inner), .{value}) catch unreachable;
            }

            return out;
        }
    };
}
