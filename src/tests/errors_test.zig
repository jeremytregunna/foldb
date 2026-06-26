const std = @import("std");
const errors = @import("errors.zig");

test "execution errors return human-readable strings" {
    try std.testing.expectEqualStrings("Constraint violation", errors.humanize(error.ConstraintViolation));
    try std.testing.expectEqualStrings("Execution failed", errors.humanize(error.ExecutionError));
    try std.testing.expectEqualStrings("Node is not the current leader", errors.humanize(error.NotLeader));
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
