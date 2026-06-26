/// Change Data Capture: subscription API and event dispatch.
///
/// Every committed transaction produces a CdcEvent delivered to subscribers.
/// Delivery is at-least-once in-process; consumers must ack to advance their cursor.
const std = @import("std");
const assert = std.debug.assert;
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");
const obs = @import("observability.zig");

pub const TableId = storage_mod.TableId;
pub const Seq = storage_mod.Seq;
pub const MutationKind = storage_mod.MutationKind;
pub const Mutation = storage_mod.Mutation;
pub const Storage = storage_mod.Storage;
pub const EntryKind = log_mod.EntryKind;

/// Capacity of each subscription's event ring buffer.
/// Events beyond this count are refused with error.InboxFull.
pub const events_capacity_max: u32 = 1024;

/// Maximum number of concurrent subscriptions per CdcManager.
pub const subscriptions_max: u32 = 256;

pub const CdcOperation = enum { insert, update, delete };

/// A simple test-and-set spinlock. Suitable for short, rarely-contended critical sections.
/// Zig 0.16 has no std.Thread.Mutex; std.Io.Mutex requires an Io instance.
const SpinMutex = struct {
    locked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn lock(self: *SpinMutex) void {
        while (self.locked.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            std.atomic.spinLoopHint();
        }
    }

    fn unlock(self: *SpinMutex) void {
        self.locked.store(false, .release);
    }
};

/// A single row change within a committed transaction.
pub const CdcEffect = struct {
    table_id: TableId,
    key: []const u8,
    op: CdcOperation,
    /// State before the change. Null for inserts or if row did not previously exist.
    before: ?[]const u8,
    /// State after the change. Null for deletes.
    after: ?[]const u8,

    pub fn deinit(self: *CdcEffect, alloc: std.mem.Allocator) void {
        assert(self.key.len > 0);
        alloc.free(self.key);
        if (self.before) |before_values| {
            alloc.free(before_values);
        }
        if (self.after) |after_values| {
            alloc.free(after_values);
        }
    }
};

/// A transaction's change event, delivered to CDC subscribers.
pub const CdcEvent = struct {
    seq: Seq,
    epoch: u64,
    kind: EntryKind,
    effects: []CdcEffect,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *CdcEvent) void {
        assert(self.effects.len > 0);
        for (self.effects) |*effect| effect.deinit(self.alloc);
        self.alloc.free(self.effects);
    }
};

/// Before-images captured prior to a storage.apply() call. Parallel to the mutations slice.
pub const BeforeImages = struct {
    /// images[i] is the before-state for mutations[i]. Null for inserts or missing rows.
    images: []?[]const u8,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *BeforeImages) void {
        for (self.images) |image_opt| {
            if (image_opt) |image| {
                self.alloc.free(image);
            }
        }
        self.alloc.free(self.images);
    }
};

/// At-least-once ordered CDC event delivery for a single consumer.
///
/// Concurrency model:
///   - push() is called from dispatch(), which holds the manager mutex.
///     Pushes are therefore serialised; release/acquire ordering on events_tail
///     ensures the consumer sees each write.
///   - next() and ack() are called from a single consumer thread only.
///     They store events_head with .release so the producer can observe freed slots.
///   - cursor is written by the consumer (ack) with .release and read by push
///     (under the manager mutex) with .acquire.
///
/// The events slice is a bounded SPSC ring buffer.  Both head and tail are
/// std.atomic.Value(u32); wrapping u32 arithmetic gives correct counts as long
/// as the outstanding depth never exceeds 2^31 (far above events_capacity_max).
pub const CdcSubscription = struct {
    id: u64,
    /// If set, only events touching this table are delivered.
    table_filter: ?TableId,
    /// Highest sequence number acked by the consumer. Written by ack(), read by push().
    cursor: std.atomic.Value(Seq),
    /// Bounded event ring buffer. Allocated by CdcManager.init(), stable for lifetime.
    events: []CdcEvent,
    /// Consumer read index. Stored with .release so producer can observe freed slots.
    events_head: std.atomic.Value(u32),
    /// Producer write index. Stored with .release by push(); loaded with .acquire by consumer.
    events_tail: std.atomic.Value(u32),
    alloc: std.mem.Allocator,

    /// Initialise a free pool slot. Does not allocate; events slice must already be set.
    fn init_slot(
        self: *CdcSubscription,
        id: u64,
        table_filter: ?TableId,
        from_seq: Seq,
    ) void {
        assert(id > 0);
        assert(self.events.len == events_capacity_max);
        self.id = id;
        self.table_filter = table_filter;
        self.cursor = std.atomic.Value(Seq).init(from_seq);
        self.events_head = std.atomic.Value(u32).init(0);
        self.events_tail = std.atomic.Value(u32).init(0);
    }

    /// Free all pending CdcEvent heap data. Does not free the events slice itself.
    fn drain_events(self: *CdcSubscription) void {
        const tail = self.events_tail.load(.acquire);
        var head = self.events_head.load(.monotonic);
        while (head != tail) : (head += 1) {
            self.events[head % events_capacity_max].deinit();
        }
        self.events_head.store(tail, .release);
    }

    /// Dequeue up to out.len events. Returns count written. Caller owns the events.
    /// Must be called from the single consumer thread only.
    pub fn next(self: *CdcSubscription, out: []CdcEvent) usize {
        assert(out.len > 0);
        const tail = self.events_tail.load(.acquire);
        const head = self.events_head.load(.monotonic);
        const available = tail -% head;
        assert(available <= events_capacity_max);
        const take_count = @min(@as(u32, @intCast(out.len)), available);
        for (0..take_count) |i| {
            out[i] = self.events[(head + @as(u32, @intCast(i))) % events_capacity_max];
        }
        self.events_head.store(head + take_count, .release);
        return take_count;
    }

    /// Record that all events up to and including seq have been processed.
    /// Discards any pending ring-buffer events covered by seq.
    /// Must be called from the single consumer thread only.
    pub fn ack(self: *CdcSubscription, seq: Seq) void {
        const cur = self.cursor.load(.monotonic);
        if (seq > cur) self.cursor.store(seq, .release);
        const new_cur = if (seq > cur) seq else cur;

        // Discard pending ring-buffer events at or below new_cur.
        const tail = self.events_tail.load(.acquire);
        var head = self.events_head.load(.monotonic);
        while (head != tail) {
            const event = &self.events[head % events_capacity_max];
            if (event.seq > new_cur) break;
            event.deinit();
            head += 1;
        }
        self.events_head.store(head, .release);
    }

    /// Push an event. Called from dispatch() with the manager mutex held.
    fn push(self: *CdcSubscription, event: CdcEvent) error{InboxFull}!void {
        assert(event.effects.len > 0);
        // Skip events already covered by the consumer's cursor.
        if (event.seq <= self.cursor.load(.acquire)) {
            var e = event;
            e.deinit();
            return;
        }
        const head = self.events_head.load(.acquire);
        const tail = self.events_tail.load(.monotonic);
        const count = tail -% head;
        assert(count <= events_capacity_max);
        if (count == events_capacity_max) return error.InboxFull;
        self.events[tail % events_capacity_max] = event;
        self.events_tail.store(tail + 1, .release);
    }
};

/// Manages CDC subscriptions and orchestrates event dispatch from the executor.
///
/// Concurrency: the subscription pool is protected by a mutex. subscribe(),
/// unsubscribe(), dispatch(), min_cursor(), and find_by_id() all acquire it.
/// push() on individual subscriptions is serialised by that same mutex.
pub const CdcManager = struct {
    /// Pre-allocated fixed pool of subscription slots. Addresses are stable for manager lifetime.
    pool: []CdcSubscription,
    /// Number of currently active (id != 0) subscriptions.
    subscription_count: u32,
    next_id: u64,
    alloc: std.mem.Allocator,
    mutex: SpinMutex = .{},
    metrics: obs.CdcMetrics = .{},

    pub fn init(alloc: std.mem.Allocator) !CdcManager {
        const pool = try alloc.alloc(CdcSubscription, subscriptions_max);
        errdefer alloc.free(pool);
        var committed: u32 = 0;
        errdefer {
            for (pool[0..committed]) |sub| alloc.free(sub.events);
        }
        while (committed < subscriptions_max) : (committed += 1) {
            pool[committed].events = try alloc.alloc(CdcEvent, events_capacity_max);
            pool[committed].id = 0;
        }
        assert(committed == subscriptions_max);
        return .{
            .pool = pool,
            .subscription_count = 0,
            .next_id = 1,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *CdcManager) void {
        for (self.pool) |*sub| {
            if (sub.id != 0) sub.drain_events();
            self.alloc.free(sub.events);
        }
        self.alloc.free(self.pool);
    }

    /// Create a new subscription from the pre-allocated pool.
    /// Pass null for table_filter to receive events for all tables.
    /// from_seq sets the initial cursor (events at or below this seq are skipped).
    pub fn subscribe(
        self: *CdcManager,
        table_filter: ?TableId,
        from_seq: Seq,
    ) error{TooManySubscriptions}!*CdcSubscription {
        self.mutex.lock();
        defer self.mutex.unlock();
        assert(self.subscription_count <= subscriptions_max);
        if (self.subscription_count == subscriptions_max) return error.TooManySubscriptions;
        for (self.pool) |*sub| {
            if (sub.id != 0) continue;
            const id = self.next_id;
            self.next_id += 1;
            sub.init_slot(id, table_filter, from_seq);
            self.subscription_count += 1;
            self.metrics.subscriptions_active.set(self.subscription_count);
            return sub;
        }
        // Unreachable: subscription_count < subscriptions_max guarantees a free slot exists.
        unreachable;
    }

    /// Remove and retire the subscription with the given id.
    pub fn unsubscribe(self: *CdcManager, id: u64) void {
        assert(id > 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.pool) |*sub| {
            if (sub.id != id) continue;
            sub.drain_events();
            sub.id = 0;
            assert(self.subscription_count > 0);
            self.subscription_count -= 1;
            self.metrics.subscriptions_active.set(self.subscription_count);
            return;
        }
    }

    /// Minimum cursor across all active subscriptions, or 0 if none.
    /// Used by log truncation to determine the safe truncation point.
    pub fn min_cursor(self: *CdcManager) Seq {
        self.mutex.lock();
        defer self.mutex.unlock();
        var min: Seq = std.math.maxInt(Seq);
        for (self.pool) |*sub| {
            if (sub.id == 0) continue;
            const cursor = sub.cursor.load(.acquire);
            if (cursor < min) min = cursor;
        }
        return if (min == std.math.maxInt(Seq)) 0 else min;
    }

    /// Find a subscription by ID. Returns null if not found or already unsubscribed.
    pub fn find_by_id(self: *CdcManager, id: u64) ?*CdcSubscription {
        assert(id > 0);
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.pool) |*sub| {
            if (sub.id == id) return sub;
        }
        return null;
    }

    /// Capture before-images for mutations. Call BEFORE storage.apply().
    /// Returns a BeforeImages parallel to mutations; caller must call deinit().
    pub fn capture_before_images(
        self: *CdcManager,
        mutations: []const Mutation,
        storage: anytype,
        at_seq: Seq,
        alloc: std.mem.Allocator,
    ) !BeforeImages {
        const images = try alloc.alloc(?[]const u8, mutations.len);
        var committed: usize = 0;
        errdefer {
            for (images[0..committed]) |image_opt| {
                if (image_opt) |image| {
                    alloc.free(image);
                }
            }
            alloc.free(images);
        }

        while (committed < mutations.len) : (committed += 1) {
            const mutation = mutations[committed];
            if (mutation.kind == .insert) {
                images[committed] = null;
                continue;
            }
            const row_opt = try storage.get(mutation.table_id, mutation.key, at_seq);
            if (row_opt) |row| {
                var r = row;
                defer r.deinit(storage.alloc);
                images[committed] = try alloc.dupe(u8, r.value);
            } else {
                images[committed] = null;
            }
        }
        assert(committed == mutations.len);

        self.metrics.before_images_captured.add(@intCast(mutations.len));
        return .{ .images = images, .alloc = alloc };
    }

    /// Build and fan-out CdcEvents to all matching subscriptions. Call AFTER storage.apply().
    /// Does not take ownership of before; caller must deinit() it.
    pub fn dispatch(
        self: *CdcManager,
        seq: Seq,
        epoch: u64,
        kind: EntryKind,
        mutations: []const Mutation,
        before: BeforeImages,
        alloc: std.mem.Allocator,
    ) !void {
        assert(seq > 0);
        assert(before.images.len == mutations.len);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.subscription_count == 0) return;
        if (mutations.len == 0) return;

        for (self.pool) |*sub| {
            if (sub.id == 0) continue;
            var effects: std.ArrayListUnmanaged(CdcEffect) = .empty;
            errdefer {
                for (effects.items) |*effect| effect.deinit(alloc);
                effects.deinit(alloc);
            }

            for (mutations, 0..) |mutation, mutation_index| {
                if (sub.table_filter) |filter| {
                    if (mutation.table_id != filter) continue;
                }
                const effect = try build_effect(alloc, mutation, before.images[mutation_index]);
                effects.append(alloc, effect) catch |err| {
                    var e = effect;
                    e.deinit(alloc);
                    return err;
                };
            }

            if (effects.items.len == 0) {
                effects.deinit(alloc);
                continue;
            }

            const effects_slice = try effects.toOwnedSlice(alloc);
            const event = CdcEvent{
                .seq = seq,
                .epoch = epoch,
                .kind = kind,
                .effects = effects_slice,
                .alloc = alloc,
            };
            assert(event.effects.len > 0);
            self.metrics.events_emitted.inc();
            self.metrics.effects_total.add(@intCast(effects_slice.len));
            sub.push(event) catch |err| {
                var e = event;
                e.deinit();
                return err;
            };
        }
    }
};

fn mutation_kind_to_op(kind: MutationKind) CdcOperation {
    return switch (kind) {
        .insert => .insert,
        .update => .update,
        .delete => .delete,
    };
}

fn build_effect(alloc: std.mem.Allocator, mutation: Mutation, before_img: ?[]const u8) !CdcEffect {
    assert(mutation.key.len > 0);
    const op = mutation_kind_to_op(mutation.kind);

    const key = try alloc.dupe(u8, mutation.key);
    errdefer alloc.free(key);
    assert(key.len == mutation.key.len);

    const before: ?[]const u8 = if (before_img) |img|
        try alloc.dupe(u8, img)
    else
        null;
    errdefer if (before) |b| alloc.free(b);

    const after: ?[]const u8 = if (op != .delete) blk: {
        const src = mutation.value orelse break :blk null;
        break :blk try alloc.dupe(u8, src);
    } else null;

    return .{ .table_id = mutation.table_id, .key = key, .op = op, .before = before, .after = after };
}
