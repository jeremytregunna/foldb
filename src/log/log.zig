/// Foldb Write-Ahead Log module.
const crc_mod = @import("crc.zig");
const entry = @import("entry.zig");
const segment = @import("segment.zig");
const manager = @import("manager.zig");

pub const crc = crc_mod;
pub const crc32c = crc_mod.crc32c;

pub const Seq = entry.Seq;
pub const Epoch = entry.Epoch;
pub const NodeId = entry.NodeId;
pub const PartitionId = entry.PartitionId;
pub const EntryKind = entry.EntryKind;
pub const TxnIntent = entry.TxnIntent;
pub const LogEntryHeader = entry.LogEntryHeader;
pub const LogEntry = entry.LogEntry;
pub const payload_len_max = entry.payload_len_max;

pub const Segment = segment.Segment;
pub const SegmentHeader = segment.SegmentHeader;
pub const SegmentFooter = segment.SegmentFooter;
pub const IndexEntry = segment.IndexEntry;
pub const header_size = segment.header_size;
pub const footer_size = segment.footer_size;
pub const magic = segment.magic;

pub const Log = manager.Log;
pub const LogError = manager.LogError;
pub const default_segment_max_entries = manager.default_segment_max_entries;

pub const LogMetrics = @import("observability.zig").LogMetrics;
pub const real_time_sec = segment.real_time_sec;

const config_change = @import("config_change.zig");
pub const ConfigChangeOp = config_change.ConfigChangeOp;
pub const ConfigChange = config_change.ConfigChange;

pub const entry_header_size = entry.LogEntryHeader.header_size;
