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

const assert = std.debug.assert;

pub const TraceId = u64;

pub const SpanKind = enum(u8) {
    gateway = 0,
    sequencer = 1,
    log = 2,
    executor = 3,
};

/// Span execution status. Non-exhaustive to accommodate subsystem-specific codes.
pub const SpanStatus = enum(u8) {
    ok = 0,
    aborted = 1,
    @"error" = 2,
    _, // non-exhaustive: subsystem-specific non-zero codes are valid
};

pub const Span = struct {
    trace_id: TraceId,
    kind: SpanKind,
    /// Logical ticks at span start (VirtualClock.now() or seq-based).
    /// Non-negative by definition; u64 matches TraceId and seq types.
    start_tick: u64,
    /// Logical ticks at span end. Invariant: end_tick >= start_tick.
    end_tick: u64,
    /// The global seq this trace is associated with (0 if not yet assigned).
    seq: u64,
    /// Execution status: ok = 0, aborted/error = non-zero subsystem code.
    status: SpanStatus,
};

/// Ring buffer tracer — fixed capacity, no allocation.
pub fn Tracer(comptime capacity: usize) type {
    return struct {
        // Fields first, then types, then methods.
        spans: [capacity]Span,
        head: usize = 0,
        total: u64 = 0,
        next_trace_id: TraceId = 1,

        const Self = @This();

        comptime {
            assert(capacity > 0);
            // head is usize; capacity must fit so ring arithmetic is always safe.
            assert(capacity <= std.math.maxInt(u32));
        }

        pub fn init() Self {
            return .{
                .spans = undefined,
                .head = 0,
                .total = 0,
                .next_trace_id = 1,
            };
        }

        /// Allocate and return a new TraceId. IDs are monotonically increasing
        /// starting at 1; 0 is never returned and is an invalid sentinel.
        pub fn newTrace(self: *Self) TraceId {
            const id = self.next_trace_id;
            assert(id > 0); // next_trace_id starts at 1 and saturates before reaching 0
            self.next_trace_id +|= 1;
            return id;
        }

        /// Record a completed span.
        pub fn record(self: *Self, span: Span) void {
            assert(span.trace_id != 0); // 0 is not a valid trace id
            assert(span.start_tick <= span.end_tick);
            self.spans[self.head % capacity] = span;
            self.head = (self.head + 1) % capacity;
            self.total +|= 1;
        }

        /// Return all spans currently in the buffer (up to capacity), newest first.
        /// Caller must supply a buffer of length >= capacity.
        pub fn snapshot(self: *const Self, out: []Span) usize {
            assert(out.len >= capacity);
            const n: usize = @intCast(@min(self.total, capacity));
            for (0..n) |i| {
                // Walk backwards from the most recently written slot.
                const idx = (capacity + self.head - 1 - i) % capacity;
                out[i] = self.spans[idx];
            }
            return n;
        }

        /// Find spans matching a specific trace_id. Returns count written to out.
        /// out.len caps the number of results; the function never writes beyond it.
        pub fn findByTrace(self: *const Self, trace_id: TraceId, out: []Span) usize {
            assert(trace_id != 0); // 0 is not a valid trace id
            const n: usize = @intCast(@min(self.total, capacity));
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
    var t = DefaultTracer.init();
    const id1 = t.newTrace();
    const id2 = t.newTrace();
    try std.testing.expect(id2 > id1);
}

test "Tracer: record and snapshot" {
    var t = Tracer(8).init();
    t.record(.{ .trace_id = 1, .kind = .gateway, .start_tick = 0, .end_tick = 10, .seq = 1, .status = .ok });
    t.record(.{ .trace_id = 1, .kind = .executor, .start_tick = 5, .end_tick = 15, .seq = 1, .status = .ok });

    var out: [8]Span = undefined;
    const n = t.snapshot(&out);
    try std.testing.expectEqual(@as(usize, 2), n);
    // Newest first: executor span
    try std.testing.expectEqual(SpanKind.executor, out[0].kind);
    try std.testing.expectEqual(SpanKind.gateway, out[1].kind);
}

test "Tracer: ring buffer wraps" {
    var t = Tracer(4).init();
    for (0..6) |i| {
        t.record(.{
            .trace_id = @as(u64, @intCast(i)) + 1, // trace_id must be non-zero
            .kind = .log,
            .start_tick = @intCast(i),
            .end_tick = @intCast(i + 1),
            .seq = @intCast(i),
            .status = .ok,
        });
    }
    // Only 4 most recent spans should be in buffer.
    var out: [4]Span = undefined;
    const n = t.snapshot(&out);
    try std.testing.expectEqual(@as(usize, 4), n);
    // Newest span has trace_id = 6 (i=5, +1).
    try std.testing.expectEqual(@as(TraceId, 6), out[0].trace_id);
}

test "Tracer: findByTrace" {
    var t = Tracer(16).init();
    t.record(.{ .trace_id = 42, .kind = .gateway, .start_tick = 0, .end_tick = 1, .seq = 10, .status = .ok });
    t.record(.{ .trace_id = 99, .kind = .gateway, .start_tick = 0, .end_tick = 1, .seq = 11, .status = .ok });
    t.record(.{ .trace_id = 42, .kind = .executor, .start_tick = 1, .end_tick = 2, .seq = 10, .status = .ok });

    var out: [4]Span = undefined;
    const n = t.findByTrace(42, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    for (out[0..n]) |s| {
        try std.testing.expectEqual(@as(TraceId, 42), s.trace_id);
    }
}
