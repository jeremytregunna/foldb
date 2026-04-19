/// Observability module — re-exports.
pub const metrics = @import("metrics.zig");
pub const subsystems = @import("subsystems.zig");
pub const tracer = @import("tracer.zig");
pub const debug = @import("debug.zig");

pub const Counter = metrics.Counter;
pub const Gauge = metrics.Gauge;
pub const Histogram = metrics.Histogram;
pub const BUCKET_UPPER_NS = metrics.BUCKET_UPPER_NS;

pub const LogMetrics = subsystems.LogMetrics;
pub const StorageMetrics = subsystems.StorageMetrics;
pub const ExecutorMetrics = subsystems.ExecutorMetrics;
pub const SequencerMetrics = subsystems.SequencerMetrics;
pub const GatewayMetrics = subsystems.GatewayMetrics;
pub const RaftMetrics = subsystems.RaftMetrics;
pub const CdcMetrics = subsystems.CdcMetrics;

pub const TraceId = tracer.TraceId;
pub const SpanKind = tracer.SpanKind;
pub const Span = tracer.Span;
pub const DefaultTracer = tracer.DefaultTracer;

pub const SeqDescription = debug.SeqDescription;
pub const EntryKindTag = debug.EntryKindTag;
pub const TxnSummary = debug.TxnSummary;
pub const describeSeq = debug.describeSeq;
pub const LogReader = debug.LogReader;
pub const LogEntryOpaque = debug.LogEntryOpaque;
