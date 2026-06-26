/// Core types for the KV fold executor.
const std = @import("std");
const entry_mod = @import("log.zig").entry;

pub const Seq = entry_mod.Seq;
pub const PartitionId = entry_mod.PartitionId;
pub const KvOp = entry_mod.KvOp;
pub const TxnIntent = entry_mod.TxnIntent;

pub const AbortCode = enum(u8) {
    constraint_violation = 1,
    bad_payload = 2,
    retry = 3,
};

pub const ExecResult = union(enum) {
    ok: struct { rows_affected: u64 },
    abort: struct { code: AbortCode, detail: []const u8 },

    pub fn deinit(self: ExecResult, alloc: std.mem.Allocator) void {
        if (self.abort) |a| alloc.free(a.detail);
    }
};

pub const TxnIntentDecoded = struct {
    ops: []const KvOp,
    read_set_hint: []const PartitionId,
    write_set_hint: []const PartitionId,
    client_id: u64,
    client_seq: u64,
    recon_seq: Seq,

    pub fn deinit(self: *TxnIntentDecoded, alloc: std.mem.Allocator) void {
        for (self.ops) |op| op.deinit(alloc);
        alloc.free(self.ops);
        alloc.free(self.read_set_hint);
        alloc.free(self.write_set_hint);
    }
};

pub const ValidatedTxnEntry = struct {
    seq: Seq,
    partition: PartitionId,
    decoded: TxnIntentDecoded,

    pub fn deinit(self: *ValidatedTxnEntry, alloc: std.mem.Allocator) void {
        self.decoded.deinit(alloc);
    }
};

pub fn deserialize_txn_intent(payload: []const u8, alloc: std.mem.Allocator) !TxnIntentDecoded {
    const intent = try entry_mod.TxnIntent.deserialize_from(payload, alloc);
    return .{
        .ops = intent.ops,
        .read_set_hint = intent.read_set_hint,
        .write_set_hint = intent.write_set_hint,
        .client_id = intent.client_id,
        .client_seq = intent.client_seq,
        .recon_seq = intent.recon_seq,
    };
}

pub fn serialize_txn_intent(intent: TxnIntent, alloc: std.mem.Allocator) ![]u8 {
    return intent.serialize_to(alloc);
}
