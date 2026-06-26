/// Centralized human-readable error message mapping.
/// Use humanize() wherever an error is shown to the user — never @errorName.
pub fn humanize(err: anyerror) []const u8 {
    return switch (err) {
        // Execution errors
        error.ConstraintViolation => "Constraint violation",
        error.ExecutionError => "Execution failed",
        error.NotLeader => "Node is not the current leader",

        // Storage / log errors
        error.SeqOutOfOrder => "Internal sequencing error",
        error.DiskFull => "Disk full",
        error.CrcMismatch => "Data corruption detected (CRC mismatch)",
        error.InvalidSegment => "Corrupt log segment",

        // Connectivity
        error.ConnectionClosed => "Connection closed",
        error.ConnectionReset => "Connection reset by peer",
        error.BrokenPipe => "Broken pipe",

        // Generic
        error.OutOfMemory => "Out of memory",
        error.Overflow => "Numeric overflow",

        else => @errorName(err),
    };
}
