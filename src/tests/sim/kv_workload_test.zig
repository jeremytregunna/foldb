const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");

test "sim workload: same seed produces identical KV operations" {
    const alloc = testing.allocator;
    var sched_a = sim.SimScheduler.init(0xF01D_BEEF);
    var sched_b = sim.SimScheduler.init(0xF01D_BEEF);

    var a = try sim.workload.generate(&sched_a, 128, alloc);
    defer a.deinit();
    var b = try sim.workload.generate(&sched_b, 128, alloc);
    defer b.deinit();

    try testing.expectEqual(a.ops.len, b.ops.len);
    for (a.ops, b.ops) |op_a, op_b| {
        try testing.expectEqual(op_a.kind, op_b.kind);
        try testing.expectEqual(op_a.id, op_b.id);
        try testing.expectEqual(op_a.value, op_b.value);
    }
}

test "sim workload: generated mutations are valid for a KV model" {
    const alloc = testing.allocator;
    var sched = sim.SimScheduler.init(42);
    var workload = try sim.workload.generate(&sched, 256, alloc);
    defer workload.deinit();

    var model = std.AutoHashMap(i64, i64).init(alloc);
    defer model.deinit();

    for (workload.ops) |op| {
        switch (op.kind) {
            .insert, .update => try model.put(op.id, op.value),
            .delete => _ = model.remove(op.id),
            .get => _ = model.get(op.id),
        }
    }
}
