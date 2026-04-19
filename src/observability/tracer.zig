/// Per-TxnIntent distributed tracing.
///
/// Every TxnIntent flowing through the system gets a TraceId. Each subsystem
/// records a Span covering its slice of the work. Spans are stored in a ring
/// buffer per-Tracer; old spans are overwritten when the buffer is full.
///
/// Design notes:
/// - TraceId is a monotonically increasing u64 assigned by the gateway.
/// - Span timestamps are in virtual-clock ticks (not wall-clock ns) so the
///   DST harness can reproduce exact timings.
/// - The ring buffer size is a compile-time constant; choose based on expected
///   query concurrency × span depth.
const std = @import("std");

pub const TraceId = u64;

pub const SpanKind = enum(u8) {
    gateway = 0,
    sequencer = 1,
    log = 2,
    executor = 3,
};

pub const Span = struct {
    trace_id: TraceId,
    kind: SpanKind,
    /// Logical ticks at span start (VirtualClock.now() or seq-based).
    start_tick: i64,
    /// Logical ticks at span end.
    end_tick: i64,
    /// The global seq this trace is associated with (0 if not yet assigned).
    seq: u64,
    /// Subsystem-specific status code: 0 = ok, non-zero = error/abort.
    status: u8,
};

/// Ring buffer tracer — fixed capacity, no allocation.
pub fn Tracer(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        spans: [capacity]Span = undefined,
        head: usize = 0,
        total: u64 = 0,
        next_trace_id: TraceId = 1,

        /// Allocate and return a new TraceId.
        pub fn newTrace(self: *Self) TraceId {
            const id = self.next_trace_id;
            self.next_trace_id +|= 1;
            return id;
        }

        /// Record a completed span.
        pub fn record(self: *Self, span: Span) void {
            self.spans[self.head % capacity] = span;
            self.head = (self.head + 1) % capacity;
            self.total +|= 1;
        }

        /// Return all spans currently in the buffer (up to capacity), newest first.
        /// Caller supplies a buffer of size ≥ capacity.
        pub fn snapshot(self: *const Self, out: []Span) usize {
            const n = @min(self.total, capacity);
            for (0..n) |i| {
                // Walk backwards from head-1
                const idx = (capacity + self.head - 1 - i) % capacity;
                out[i] = self.spans[idx];
            }
            return n;
        }

        /// Find spans matching a specific trace_id. Returns count written to out.
        pub fn findByTrace(self: *const Self, trace_id: TraceId, out: []Span) usize {
            const n = @min(self.total, capacity);
            var written: usize = 0;
            for (0..n) |i| {
                const idx = (capacity + self.head - 1 - i) % capacity;
                if (self.spans[idx].trace_id == trace_id and written < out.len) {
                    out[written] = self.spans[idx];
                    written += 1;
                }
            }
            return written;
        }
    };
}

/// Default tracer capacity: 4096 spans (covers ~1000 concurrent 4-span traces).
pub const DefaultTracer = Tracer(4096);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Tracer: new trace ids are unique and monotonic" {
    var t: DefaultTracer = .{};
    const id1 = t.newTrace();
    const id2 = t.newTrace();
    try std.testing.expect(id2 > id1);
}

test "Tracer: record and snapshot" {
    var t: Tracer(8) = .{};
    t.record(.{ .trace_id = 1, .kind = .gateway, .start_tick = 0, .end_tick = 10, .seq = 1, .status = 0 });
    t.record(.{ .trace_id = 1, .kind = .executor, .start_tick = 5, .end_tick = 15, .seq = 1, .status = 0 });

    var out: [8]Span = undefined;
    const n = t.snapshot(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    // Newest first: executor span
    try std.testing.expectEqual(SpanKind.executor, out[0].kind);
    try std.testing.expectEqual(SpanKind.gateway, out[1].kind);
}

test "Tracer: ring buffer wraps" {
    var t: Tracer(4) = .{};
    for (0..6) |i| {
        t.record(.{ .trace_id = @intCast(i), .kind = .log, .start_tick = @intCast(i), .end_tick = @intCast(i + 1), .seq = @intCast(i), .status = 0 });
    }
    // Only 4 most recent spans should be in buffer
    var out: [4]Span = undefined;
    const n = t.snapshot(&out);
    try std.testing.expectEqual(@as(usize, 4), n);
    // Newest span has trace_id = 5
    try std.testing.expectEqual(@as(TraceId, 5), out[0].trace_id);
}

test "Tracer: findByTrace" {
    var t: Tracer(16) = .{};
    t.record(.{ .trace_id = 42, .kind = .gateway, .start_tick = 0, .end_tick = 1, .seq = 10, .status = 0 });
    t.record(.{ .trace_id = 99, .kind = .gateway, .start_tick = 0, .end_tick = 1, .seq = 11, .status = 0 });
    t.record(.{ .trace_id = 42, .kind = .executor, .start_tick = 1, .end_tick = 2, .seq = 10, .status = 0 });

    var out: [4]Span = undefined;
    const n = t.findByTrace(42, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    for (out[0..n]) |s| {
        try std.testing.expectEqual(@as(TraceId, 42), s.trace_id);
    }
}
