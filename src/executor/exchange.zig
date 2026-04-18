/// Inter-partition row exchange types for cross-partition transaction execution.
///
/// When a TxnIntent touches multiple partitions, each executor declares which rows
/// it needs from other partitions (ForeignReadRequest), and receives those rows
/// (ForeignRow) before executing its local slice of the transaction.
const std = @import("std");
const types = @import("types.zig");
const storage_mod = @import("storage.zig");

pub const PartitionId = types.PartitionId;
pub const TableId = storage_mod.TableId;
pub const Row = storage_mod.Row;

/// A request for a row from a specific partition's storage at seq-1.
pub const ForeignReadRequest = struct {
    from_partition: PartitionId,
    table_id: TableId,
    key: []const u8,
};

/// A row fetched from a foreign partition's storage at seq-1.
/// row == null means the row did not exist at seq-1.
pub const ForeignRow = struct {
    from_partition: PartitionId,
    table_id: TableId,
    key: []const u8,
    row: ?Row,
};
