/// Foldb Write-Ahead Log module.
const crc = @import("crc.zig");
const entry = @import("entry.zig");
const segment = @import("segment.zig");
const manager = @import("manager.zig");

pub const crc32c = crc.crc32c;

pub const Seq = entry.Seq;
pub const Epoch = entry.Epoch;
pub const NodeId = entry.NodeId;
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

pub const Log = manager.Log;
pub const LogError = manager.LogError;
pub const default_segment_max_entries = manager.default_segment_max_entries;
