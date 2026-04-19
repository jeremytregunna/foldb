const std = @import("std");
const errors = @import("errors.zig");

test "known errors return human-readable strings" {
    try std.testing.expectEqualStrings("Table not found", errors.humanize(error.TableNotFound));
    try std.testing.expectEqualStrings("Table already exists", errors.humanize(error.TableAlreadyExists));
    try std.testing.expectEqualStrings("Column not found", errors.humanize(error.ColumnNotFound));
    try std.testing.expectEqualStrings("Column already exists", errors.humanize(error.ColumnAlreadyExists));
    try std.testing.expectEqualStrings("Index not found", errors.humanize(error.IndexNotFound));
    try std.testing.expectEqualStrings("Index already exists", errors.humanize(error.IndexAlreadyExists));
    try std.testing.expectEqualStrings("Table requires a primary key", errors.humanize(error.NoPrimaryKey));
    try std.testing.expectEqualStrings("Primary key references an unknown column", errors.humanize(error.PrimaryKeyColumnNotFound));
    try std.testing.expectEqualStrings("Duplicate column in primary key", errors.humanize(error.DuplicatePrimaryKeyColumn));
}

test "parser errors return human-readable strings" {
    try std.testing.expectEqualStrings("Unexpected token in SQL", errors.humanize(error.UnexpectedToken));
    try std.testing.expectEqualStrings("Column is missing a NULL or NOT NULL constraint", errors.humanize(error.MissingNullability));
    try std.testing.expectEqualStrings("SELECT * is not allowed in registered queries", errors.humanize(error.SelectStarInRegisteredQuery));
    try std.testing.expectEqualStrings("Unterminated string literal", errors.humanize(error.UnterminatedString));
    try std.testing.expectEqualStrings("Invalid escape sequence", errors.humanize(error.InvalidEscape));
    try std.testing.expectEqualStrings("Unterminated block comment", errors.humanize(error.UnterminatedBlockComment));
}

test "execution errors return human-readable strings" {
    try std.testing.expectEqualStrings("Type error in query", errors.humanize(error.TypeCheckError));
    try std.testing.expectEqualStrings("Query is incompatible with the current schema", errors.humanize(error.SchemaBreakingChange));
    try std.testing.expectEqualStrings("Query not registered — send RegisterQuery first", errors.humanize(error.QueryNotFound));
    try std.testing.expectEqualStrings("Constraint violation", errors.humanize(error.ConstraintViolation));
    try std.testing.expectEqualStrings("Execution failed", errors.humanize(error.ExecutionError));
    try std.testing.expectEqualStrings("Node is not the current leader", errors.humanize(error.NotLeader));
    try std.testing.expectEqualStrings("Operation not supported", errors.humanize(error.UnsupportedOperation));
}

test "storage and connectivity errors return human-readable strings" {
    try std.testing.expectEqualStrings("Internal sequencing error", errors.humanize(error.SeqOutOfOrder));
    try std.testing.expectEqualStrings("Disk full", errors.humanize(error.DiskFull));
    try std.testing.expectEqualStrings("Data corruption detected (CRC mismatch)", errors.humanize(error.CrcMismatch));
    try std.testing.expectEqualStrings("Corrupt log segment", errors.humanize(error.InvalidSegment));
    try std.testing.expectEqualStrings("Connection closed", errors.humanize(error.ConnectionClosed));
    try std.testing.expectEqualStrings("Connection reset by peer", errors.humanize(error.ConnectionReset));
    try std.testing.expectEqualStrings("Broken pipe", errors.humanize(error.BrokenPipe));
    try std.testing.expectEqualStrings("Out of memory", errors.humanize(error.OutOfMemory));
    try std.testing.expectEqualStrings("Numeric overflow", errors.humanize(error.Overflow));
}

test "unknown errors fall back to error name" {
    try std.testing.expectEqualStrings("SomeUnknownError", errors.humanize(error.SomeUnknownError));
}
