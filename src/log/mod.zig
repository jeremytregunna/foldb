/// Foldb Write-Ahead Log module.
///
/// Provides core types and utilities for the log implementation.
const crc = @import("crc.zig");
const entry = @import("entry.zig");
const segment = @import("segment.zig");
const manager = @import("manager.zig");

// Re-export CRC utilities
pub const crc32c = crc.crc32c;

// Re-export entry types
pub const Seq = entry.Seq;
pub const Epoch = entry.Epoch;
pub const NodeId = entry.NodeId;
pub const EntryKind = entry.EntryKind;
pub const TxnIntent = entry.TxnIntent;
pub const LogEntryHeader = entry.LogEntryHeader;
pub const LogEntry = entry.LogEntry;

// Re-export segment types
pub const Segment = segment.Segment;
pub const SegmentHeader = segment.SegmentHeader;
pub const SegmentFooter = segment.SegmentFooter;
pub const IndexEntry = segment.IndexEntry;
pub const HEADER_SIZE = segment.HEADER_SIZE;
pub const FOOTER_SIZE = segment.FOOTER_SIZE;

// Re-export log manager
pub const Log = manager.Log;
pub const LogError = manager.LogError;
pub const DEFAULT_SEGMENT_MAX_ENTRIES = manager.DEFAULT_SEGMENT_MAX_ENTRIES;
