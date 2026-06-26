/// Read set declaration for KV operations.
///
/// In the KV model, reads are explicit in the operation itself:
/// - GET declares its key
/// - RANGE declares its bounds
/// - SET/DELETE declare no reads (write-only)
const std = @import("std");
const types = @import("types.zig");

/// Declare which keys a transaction will read.
/// For KV ops, the read set is extracted directly from the operations.
pub fn declare_reads(intent: types.TxnIntentDecoded) !void {
    // In the KV model, read declarations are trivial — the ops themselves
    // specify exactly what data is accessed. The storage layer tracks
    // reads implicitly via the ReadTracker.
    _ = intent;
}
