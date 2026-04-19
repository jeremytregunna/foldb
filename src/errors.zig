/// Centralized human-readable error message mapping.
/// Use humanize() wherever an error is shown to the user — never @errorName.
pub fn humanize(err: anyerror) []const u8 {
    return switch (err) {
        // Schema errors
        error.TableNotFound => "Table not found",
        error.TableAlreadyExists => "Table already exists",
        error.ColumnNotFound => "Column not found",
        error.ColumnAlreadyExists => "Column already exists",
        error.IndexNotFound => "Index not found",
        error.IndexAlreadyExists => "Index already exists",
        error.NoPrimaryKey => "Table requires a primary key",
        error.PrimaryKeyColumnNotFound => "Primary key references an unknown column",
        error.DuplicatePrimaryKeyColumn => "Duplicate column in primary key",

        // Plan errors
        error.UnsupportedOperation => "Operation not supported",

        // Parser errors
        error.UnexpectedToken => "Unexpected token in SQL",
        error.MissingNullability => "Column is missing a NULL or NOT NULL constraint",
        error.SelectStarInRegisteredQuery => "SELECT * is not allowed in registered queries",
        error.UnterminatedString => "Unterminated string literal",
        error.InvalidEscape => "Invalid escape sequence",
        error.UnterminatedBlockComment => "Unterminated block comment",

        // Type-check errors
        error.TypeCheckError => "Type error in query",
        error.SchemaBreakingChange => "Query is incompatible with the current schema",

        // Registry errors
        error.QueryNotFound => "Query not registered — send RegisterQuery first",

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
