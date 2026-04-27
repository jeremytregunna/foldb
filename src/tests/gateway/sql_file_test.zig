const std = @import("std");
const testing = std.testing;
const runner = @import("sql_runner.zig");

test "sql: constraints" {
    try runner.run(@embedFile("sql/constraints.sql"), testing.allocator);
}

test "sql: transactions" {
    try runner.run(@embedFile("sql/transactions.sql"), testing.allocator);
}

test "sql: dml" {
    try runner.run(@embedFile("sql/dml.sql"), testing.allocator);
}

test "sql: select" {
    try runner.run(@embedFile("sql/select.sql"), testing.allocator);
}

test "sql: aggregates" {
    try runner.run(@embedFile("sql/aggregates.sql"), testing.allocator);
}

test "sql: joins" {
    try runner.run(@embedFile("sql/joins.sql"), testing.allocator);
}

test "sql: subqueries" {
    try runner.run(@embedFile("sql/subqueries.sql"), testing.allocator);
}

test "sql: on_conflict" {
    try runner.run(@embedFile("sql/on_conflict.sql"), testing.allocator);
}

test "sql: returning" {
    try runner.run(@embedFile("sql/returning.sql"), testing.allocator);
}

test "sql: distinct" {
    try runner.run(@embedFile("sql/distinct.sql"), testing.allocator);
}

test "sql: update_from" {
    try runner.run(@embedFile("sql/update_from.sql"), testing.allocator);
}

test "sql: delete_using" {
    try runner.run(@embedFile("sql/delete_using.sql"), testing.allocator);
}

test "sql: window" {
    try runner.run(@embedFile("sql/window.sql"), testing.allocator);
}

test "sql: bitwise" {
    try runner.run(@embedFile("sql/bitwise.sql"), testing.allocator);
}

test "sql: ddl" {
    try runner.run(@embedFile("sql/ddl.sql"), testing.allocator);
}

test "sql: expressions" {
    try runner.run(@embedFile("sql/expressions.sql"), testing.allocator);
}

test "sql: combinations" {
    try runner.run(@embedFile("sql/combinations.sql"), testing.allocator);
}

test "sql: null" {
    try runner.run(@embedFile("sql/null.sql"), testing.allocator);
}
