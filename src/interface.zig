const std = @import("std");
const sol = @import("sol.zig");

comptime {
    _ = SessionOpaque.init;
    _ = SessionOpaque.deinit;
    _ = SessionOpaque.destroy;
    _ = SessionOpaque.pack_uint;
    _ = SessionOpaque.pack_array;
    _ = SessionOpaque.pack_array_dyn;
    _ = SessionOpaque.pack_tuple;
}

pub const SolValOpaque = opaque {
    fn unpack(this: *SolValOpaque) *sol.SolVal {
        const self = @as(*sol.SolVal, @ptrCast(@alignCast(this)));
        return self;
    }

    fn pack(this: *sol.SolVal) *SolValOpaque {
        return @as(*SolValOpaque, @ptrCast(this));
    }
};

pub const SessionOpaque = opaque {
    const Gpa = std.heap.GeneralPurposeAllocator(.{});

    const Sol = struct {
        gpa: Gpa,
    };

    pub export fn init() ?*SessionOpaque {
        var gpa = Gpa{};
        const self = gpa.allocator().create(Sol) catch return null;
        self.gpa = gpa;
        return @as(*SessionOpaque, @ptrCast(self));
    }

    pub export fn deinit(this: *SessionOpaque) void {
        const self = @as(*Sol, @ptrCast(@alignCast(this)));

        var gpa = self.gpa;
        const allocator = gpa.allocator();
        allocator.destroy(self);
        _ = gpa.deinit();
    }

    pub export fn destroy(this: *SessionOpaque, val: *SolValOpaque) void {
        const self = @as(*Sol, @ptrCast(@alignCast(this)));
        const allocator = self.gpa.allocator();
        const v = SolValOpaque.unpack(val);
        allocator.destroy(v);
    }

    pub export fn pack_uint(this: *SessionOpaque, num: u64) ?*SolValOpaque {
        const self = @as(*Sol, @ptrCast(@alignCast(this)));
        var val = self.gpa.allocator().create(sol.SolVal) catch return null;
        val.* = sol.SolVal.pack_uint(num);
        return SolValOpaque.pack(val);
    }

    pub export fn pack_tuple(this: *SessionOpaque, len: usize, vals: [*]*SolValOpaque) ?*SolValOpaque {
        const ptrs = vals[0..len];

        const self = @as(*Sol, @ptrCast(@alignCast(this)));
        const alloc = self.gpa.allocator();
        var val = alloc.create(sol.SolVal) catch return null;

        var data = alloc.alloc(sol.SolVal, len) catch return null;
        for (ptrs, 0..) |ptr, i| {
            const v = SolValOpaque.unpack(ptr);
            data[i] = v.*;
        }
        val.* = sol.SolVal.pack_tuple(data);
        return SolValOpaque.pack(val);
    }

    pub export fn pack_array(this: *SessionOpaque, len: usize, vals: [*]*SolValOpaque) ?*SolValOpaque {
        const ptrs = vals[0..len];

        const self = @as(*Sol, @ptrCast(@alignCast(this)));

        const alloc = self.gpa.allocator();
        var val = alloc.create(sol.SolVal) catch return null;

        var data = alloc.alloc(sol.SolVal, len) catch return null;
        for (ptrs, 0..) |ptr, i| {
            const v = SolValOpaque.unpack(ptr);
            data[i] = v.*;
        }

        val.* = sol.SolVal.pack_array(data);
        alloc.free(data);
        return SolValOpaque.pack(val);
    }

    pub export fn pack_array_dyn(this: *SessionOpaque, len: usize, vals: [*]*SolValOpaque) ?*SolValOpaque {
        const ptrs = vals[0..len];

        const self = @as(*Sol, @ptrCast(@alignCast(this)));

        const alloc = self.gpa.allocator();
        var val = alloc.create(sol.SolVal) catch return null;

        var data = alloc.alloc(sol.SolVal, len) catch return null;
        for (ptrs, 0..) |ptr, i| {
            const v = SolValOpaque.unpack(ptr);
            data[i] = v.*;
        }

        val.* = sol.SolVal.pack_array_dyn(data);
        alloc.free(data);
        return SolValOpaque.pack(val);
    }

    pub export fn encode(_: *SessionOpaque, valp: *SolValOpaque, len: usize, buf: [*]u8) i32 {
        var val = SolValOpaque.unpack(valp);
        return @intCast(val.*.encode(buf[0..len]) catch return -1);
    }
};

const testing = std.testing;

test "init / deinit" {
    const Sol = SessionOpaque;

    const s = Sol.init().?;
    s.deinit();
}

test "init / deinit with alloc" {
    const Sol = SessionOpaque;

    const s = Sol.init().?;

    const num = s.pack_uint(10).?;
    s.destroy(num);

    s.deinit();
}

test "encode uint" {
    const Sol = SessionOpaque;

    const s = Sol.init().?;
    const num: ?*SolValOpaque = Sol.pack_uint(s, 0xdead0beef);
    try testing.expect(num != null);

    var buf = [_]u8{0} ** 512;
    _ = SessionOpaque.encode(s, num.?, 512, buf[0..]);

    const expected = "0000000000000000000000000000000000000000000000000000000dead0beef";

    const str = std.mem.span(@as([*:0]u8, @ptrCast(&buf)));
    try testing.expectEqualStrings(expected, str);

    s.destroy(num.?);
    s.deinit();
}

test "encode tuple" {
    const s = SessionOpaque.init().?;
    var nums: [3]*SolValOpaque = undefined;
    for (nums, 0..) |_, i| {
        const v = SessionOpaque.pack_uint(s, i);
        try std.testing.expect(v != null);
        nums[i] = v.?;
    }

    var buf = [_]u8{0} ** 512;
    const tpl = SessionOpaque.pack_tuple(s, 3, nums[0..]);
    try std.testing.expect(tpl != null);
    std.log.warn("Here", .{});
    _ = SessionOpaque.encode(s, tpl.?, 512, buf[0..]);

    const expected = "000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003";
    _ = expected;

    for (nums, 0..) |_, i| {
        s.destroy(nums[i]);
    }
    s.destroy(tpl.?);
    // s.deinit();
}
