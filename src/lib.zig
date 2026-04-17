const std = @import("std");
const testing = std.testing;

pub const VERSION = "0.1.0";

/// Example function demonstrating foldb functionality
pub fn exampleFunction(allocator: std.mem.Allocator) !void {
    // Placeholder for foldb core functionality
    _ = allocator;
}

test "example function works" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try exampleFunction(arena.allocator());
}
