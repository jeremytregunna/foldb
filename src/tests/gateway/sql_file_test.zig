const std = @import("std");
const testing = std.testing;
const runner = @import("sql_runner.zig");

test "sql: constraints" {
    try runner.run(@embedFile("sql/constraints.sql"), testing.allocator);
}

test "sql: transactions" {
    try runner.run(@embedFile("sql/transactions.sql"), testing.allocator);
}
