const std = @import("std");
const foldb = @import("lib.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    std.debug.print("Foldb v{s}\n", .{foldb.VERSION});

    // Example usage of foldb
    _ = try foldb.exampleFunction(allocator);
}
