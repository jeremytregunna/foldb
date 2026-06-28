const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const LSM = storage.LSM;

test "tiered: many writes" {
    const alloc = testing.allocator;
    const path = "/tmp/foldb_tiered_1";
    var lsm = try LSM.init(path, alloc);
    defer lsm.deinit();

    var i: u64 = 0;
    while (i < 300) : (i += 1) {
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "k_{d:03}", .{i}) catch unreachable;
        try lsm.apply(&[_]storage.Mutation{ .{ .kind = .insert, .namespace_id = 1, .key = key, .value = "v" } }, i + 1);
    }
    {
        const r1 = try lsm.get("k_000", 300);
        try testing.expect(r1 != null);
        if (r1) |r| r.deinit(alloc);
    }
    {
        const r2 = try lsm.get("k_150", 300);
        try testing.expect(r2 != null);
        if (r2) |r| r.deinit(alloc);
    }
    {
        const r3 = try lsm.get("k_299", 300);
        try testing.expect(r3 != null);
        if (r3) |r| r.deinit(alloc);
    }
}
