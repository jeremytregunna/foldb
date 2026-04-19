/// ConfigChange payload for membership reconfiguration log entries.
///
/// Wire format (9 bytes):
///   u8  op        (ConfigChangeOp tag)
///   u64 node_id   (little-endian)
const std = @import("std");
const entry = @import("entry.zig");

pub const NodeId = entry.NodeId;

pub const ConfigChangeOp = enum(u8) {
    add_voter = 1,
    remove_voter = 2,
};

pub const ConfigChange = struct {
    op: ConfigChangeOp,
    node_id: NodeId,

    pub fn serialize(self: ConfigChange) [9]u8 {
        var buf: [9]u8 = undefined;
        buf[0] = @intFromEnum(self.op);
        std.mem.writeInt(u64, buf[1..9], self.node_id, .little);
        return buf;
    }

    pub fn deserialize(buf: []const u8) !ConfigChange {
        if (buf.len < 9) return error.BufferTooShort;
        const op: ConfigChangeOp = switch (buf[0]) {
            1 => .add_voter,
            2 => .remove_voter,
            else => return error.InvalidOp,
        };
        const node_id = std.mem.readInt(u64, buf[1..9][0..8], .little);
        return .{ .op = op, .node_id = node_id };
    }
};
