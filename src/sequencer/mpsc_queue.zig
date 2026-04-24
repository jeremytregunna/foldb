/// Vyukov's intrusive MPSC (multi-producer, single-consumer) queue.
///
/// T must have a field: `next: std.atomic.Value(?*T)`
///
/// Properties:
///   - Producers (push): wait-free — one atomic swap + one store, no looping
///   - Consumer (pop):   lock-free — never blocks producers
///   - Consumer sleep:   Linux futex with timeout; woken immediately on push
///
/// Usage:
///   1. Embed `MpscQueue(T)` in a struct that will be heap-allocated (or otherwise
///      fixed in memory before use).
///   2. Call `init()` once the queue is at its final address.
///   3. Producers call `push()` from any thread.
///   4. A single consumer calls `currentSeq()` + `pop()` + `waitForWork()`.
const std = @import("std");

pub fn MpscQueue(comptime T: type) type {
    comptime {
        if (!@hasField(T, "next"))
            @compileError("MpscQueue requires T to have a field 'next: std.atomic.Value(?*T)'");
    }

    return struct {
        const Self = @This();

        /// Producers atomically swap this to append. Consumer reads via tail.
        head: std.atomic.Value(?*T),
        /// Consumer-only pointer. Not atomic — only the consumer thread touches it.
        tail: ?*T,
        /// Sentinel node. Embedded here so it has the same lifetime as the queue.
        /// Never returned from pop(). Only next field is used; all other fields are garbage.
        stub: T,
        /// Monotonically increasing counter. Incremented on every push.
        /// Consumer futex-waits on this value when the queue is empty.
        wake_seq: std.atomic.Value(u32),

        /// Initialize the queue. Must be called after the queue is at its final
        /// memory address — the stub's address is stored in head and tail.
        pub fn init(self: *Self) void {
            self.stub.next.store(null, .monotonic);
            self.head.store(&self.stub, .release);
            self.tail = &self.stub;
            self.wake_seq.store(0, .monotonic);
        }

        /// Push a node onto the queue. Wait-free; safe to call from any thread.
        pub fn push(self: *Self, node: *T) void {
            node.next.store(null, .monotonic);
            // Atomically install as new head, receiving the previous head.
            const prev = self.head.swap(node, .acq_rel).?;
            // Link prev → node. This store is what makes node visible to the consumer.
            // A producer that swapped between our swap and this store will see prev
            // as their old head and link correctly — the consumer handles a momentarily
            // incomplete chain by detecting tail != head and retrying next cycle.
            prev.next.store(node, .release);
            // Increment wake_seq and wake the consumer if it's sleeping.
            _ = self.wake_seq.fetchAdd(1, .release);
            _ = std.os.linux.futex_3arg(
                @ptrCast(&self.wake_seq.raw),
                .{ .cmd = .WAKE, .private = true },
                1,
            );
        }

        /// Pop a node. Lock-free; must be called from the single consumer thread only.
        /// Returns null when the queue is empty or when a push is momentarily mid-flight.
        pub fn pop(self: *Self) ?*T {
            var tail = self.tail.?;
            var next = tail.next.load(.acquire);

            if (tail == &self.stub) {
                // Skip the sentinel — it is never returned to the caller.
                const n = next orelse return null;
                self.tail = n;
                tail = n;
                next = tail.next.load(.acquire);
            }

            if (next) |n| {
                self.tail = n;
                return tail;
            }

            // tail is the last node in the list (next == null).
            // If head == tail, the queue has exactly one item — but a concurrent push
            // may have swapped head without completing its prev.next store yet.
            const head = self.head.load(.acquire);
            if (tail != head) return null; // push in progress, try again next cycle

            // Re-insert the stub so the pending producer store has somewhere to link.
            // This also resets the queue to the canonical empty state after we return tail.
            self.push(&self.stub);
            next = tail.next.load(.acquire);
            if (next) |n| {
                self.tail = n;
                return tail;
            }
            return null;
        }

        /// Read wake_seq before a pop attempt. Pass this value to waitForWork so the
        /// consumer never sleeps past a push that arrived between the pop and the wait.
        pub fn currentSeq(self: *const Self) u32 {
            return self.wake_seq.load(.acquire);
        }

        /// Sleep until a push occurs or timeout_ns nanoseconds elapse.
        /// seq must be the value returned by currentSeq() sampled before the failed pop.
        pub fn waitForWork(self: *Self, seq: u32, timeout_ns: u64) void {
            const ts = std.os.linux.timespec{
                .sec = @intCast(timeout_ns / 1_000_000_000),
                .nsec = @intCast(timeout_ns % 1_000_000_000),
            };
            _ = std.os.linux.futex_4arg(
                @ptrCast(&self.wake_seq.raw),
                .{ .cmd = .WAIT, .private = true },
                seq,
                &ts,
            );
        }

        /// Wake the consumer thread. Call this before setting a shutdown flag so the
        /// consumer exits its wait promptly.
        pub fn wakeConsumer(self: *Self) void {
            _ = self.wake_seq.fetchAdd(1, .release);
            _ = std.os.linux.futex_3arg(
                @ptrCast(&self.wake_seq.raw),
                .{ .cmd = .WAKE, .private = true },
                1,
            );
        }
    };
}
