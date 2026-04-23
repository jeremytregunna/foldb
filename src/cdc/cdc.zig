/// Change Data Capture: subscription API and event dispatch.
///
/// Every committed transaction produces a CdcEvent delivered to subscribers.
/// Delivery is at-least-once in-process; consumers must ack to advance their cursor.
const std = @import("std");
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");
const obs = @import("observability.zig");

pub const TableId = storage_mod.TableId;
pub const Seq = storage_mod.Seq;
pub const ColumnValue = storage_mod.ColumnValue;
pub const MutationKind = storage_mod.MutationKind;
pub const Mutation = storage_mod.Mutation;
pub const Storage = storage_mod.Storage;
pub const EntryKind = log_mod.EntryKind;

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
    before: ?[]ColumnValue,
    /// State after the change. Null for deletes.
    after: ?[]ColumnValue,

    pub fn deinit(self: *CdcEffect, alloc: std.mem.Allocator) void {
        alloc.free(self.key);
        if (self.before) |b| {
            for (b) |v| v.freeIfOwned(alloc);
            alloc.free(b);
        }
        if (self.after) |a| {
            for (a) |v| v.freeIfOwned(alloc);
            alloc.free(a);
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
        for (self.effects) |*e| e.deinit(self.alloc);
        self.alloc.free(self.effects);
    }
};

/// Before-images captured prior to a storage.apply() call. Parallel to the mutations slice.
pub const BeforeImages = struct {
    /// images[i] is the before-state for mutations[i]. Null for inserts or missing rows.
    images: []?[]ColumnValue,
    alloc: std.mem.Allocator,

    pub fn deinit(self: *BeforeImages) void {
        for (self.images) |img_opt| {
            if (img_opt) |img| {
                for (img) |v| v.freeIfOwned(self.alloc);
                self.alloc.free(img);
            }
        }
        self.alloc.free(self.images);
    }
};

/// At-least-once ordered CDC event delivery for a single consumer.
///
/// Concurrency model:
///   - push() may be called from multiple producer threads (executor threads).
///     It uses a lock-free Treiber stack: each push is a CAS-prepend, no locks.
///   - next() and ack() are called from a single consumer thread only.
///     They operate on a consumer-private local buffer; no synchronisation needed
///     once the inbox has been drained into it.
///   - cursor is written only by the consumer (ack) and read by producers (push).
///     It is an atomic value with release/acquire ordering.
///
/// The inbox is an atomic singly-linked list (Treiber stack). Producers prepend;
/// the consumer atomically swaps the head to null, reverses the chain to restore
/// insertion order, and appends into the local buffer.
pub const CdcSubscription = struct {
    id: u64,
    /// If set, only events touching this table are delivered.
    table_filter: ?TableId,
    /// Highest sequence number acked by the consumer. Written by ack(), read by push().
    cursor: std.atomic.Value(Seq),
    /// Lock-free inbox: producers CAS-prepend InboxNodes here.
    inbox: std.atomic.Value(?*InboxNode),
    /// Consumer-private buffer. Only next() and ack() access this — no locking needed.
    local: std.ArrayListUnmanaged(CdcEvent),
    alloc: std.mem.Allocator,

    const InboxNode = struct {
        event: CdcEvent,
        next: ?*InboxNode,
    };

    pub fn init(id: u64, table_filter: ?TableId, from_seq: Seq, alloc: std.mem.Allocator) CdcSubscription {
        return .{
            .id = id,
            .table_filter = table_filter,
            .cursor = std.atomic.Value(Seq).init(from_seq),
            .inbox = std.atomic.Value(?*InboxNode).init(null),
            .local = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *CdcSubscription) void {
        // Drain the inbox.
        var node = self.inbox.swap(null, .acquire);
        while (node) |n| {
            var e = n.event;
            e.deinit();
            const nx = n.next;
            self.alloc.destroy(n);
            node = nx;
        }
        // Drain the local consumer buffer.
        for (self.local.items) |*e| e.deinit();
        self.local.deinit(self.alloc);
    }

    /// Dequeue up to `out.len` events into `out`. Returns count written. Caller owns events.
    /// Must be called from the single consumer thread only.
    pub fn next(self: *CdcSubscription, out: []CdcEvent) !usize {
        // Drain the inbox into local (inbox nodes are in reverse order — reverse them back).
        var node = self.inbox.swap(null, .acquire);
        if (node != null) {
            // Collect into a temporary slice for reversal.
            var tmp: std.ArrayListUnmanaged(*InboxNode) = .empty;
            defer tmp.deinit(self.alloc);
            while (node) |n| {
                try tmp.append(self.alloc, n);
                node = n.next;
            }
            var i = tmp.items.len;
            while (i > 0) {
                i -= 1;
                const n = tmp.items[i];
                try self.local.append(self.alloc, n.event);
                self.alloc.destroy(n);
            }
        }
        // Serve from the local buffer.
        const n = @min(out.len, self.local.items.len);
        for (0..n) |i| out[i] = self.local.items[i];
        const total = self.local.items.len;
        for (n..total) |i| self.local.items[i - n] = self.local.items[i];
        self.local.shrinkRetainingCapacity(total - n);
        return n;
    }

    /// Record that all events up to and including `seq` have been processed.
    /// Drains any pending inbox items into the local buffer first, then prunes
    /// both buffers — so ack() before next() correctly discards covered events.
    /// Must be called from the single consumer thread only.
    pub fn ack(self: *CdcSubscription, seq: Seq) !void {
        const cur = self.cursor.load(.monotonic);
        if (seq > cur) self.cursor.store(seq, .release);
        const new_cur = if (seq > cur) seq else cur;

        // Drain inbox into local (same logic as next(), reused here).
        var node = self.inbox.swap(null, .acquire);
        if (node != null) {
            var tmp: std.ArrayListUnmanaged(*InboxNode) = .empty;
            defer tmp.deinit(self.alloc);
            while (node) |n| {
                try tmp.append(self.alloc, n);
                node = n.next;
            }
            var i = tmp.items.len;
            while (i > 0) {
                i -= 1;
                const n = tmp.items[i];
                try self.local.append(self.alloc, n.event);
                self.alloc.destroy(n);
            }
        }

        // Prune local buffer up to new_cur.
        var i: usize = 0;
        while (i < self.local.items.len and self.local.items[i].seq <= new_cur) : (i += 1) {
            self.local.items[i].deinit();
        }
        if (i > 0) {
            const new_len = self.local.items.len - i;
            std.mem.copyForwards(CdcEvent, self.local.items[0..new_len], self.local.items[i..]);
            self.local.shrinkRetainingCapacity(new_len);
        }
    }

    /// Push an event from a producer thread. Lock-free: CAS-prepend onto the inbox stack.
    fn push(self: *CdcSubscription, event: CdcEvent) !void {
        // Skip events already covered by the consumer's cursor.
        if (event.seq <= self.cursor.load(.acquire)) {
            var e = event;
            e.deinit();
            return;
        }
        const node = try self.alloc.create(InboxNode);
        node.* = .{ .event = event, .next = null };
        var head = self.inbox.load(.monotonic);
        while (true) {
            node.next = head;
            if (self.inbox.cmpxchgWeak(head, node, .release, .monotonic)) |actual| {
                head = actual;
            } else break;
        }
    }
};

/// Manages CDC subscriptions and orchestrates event dispatch from the executor.
///
/// Concurrency: the subscriptions list is protected by a mutex. subscribe(),
/// unsubscribe(), dispatch(), minCursor(), and findById() all acquire it.
/// push() on individual subscriptions is lock-free (see CdcSubscription).
pub const CdcManager = struct {
    subscriptions: std.ArrayListUnmanaged(*CdcSubscription),
    next_id: u64,
    alloc: std.mem.Allocator,
    mutex: SpinMutex = .{},
    metrics: obs.CdcMetrics = .{},

    pub fn init(alloc: std.mem.Allocator) CdcManager {
        return .{ .subscriptions = .empty, .next_id = 1, .alloc = alloc };
    }

    pub fn deinit(self: *CdcManager) void {
        for (self.subscriptions.items) |sub| {
            sub.deinit();
            self.alloc.destroy(sub);
        }
        self.subscriptions.deinit(self.alloc);
    }

    /// Create a new subscription owned by this manager.
    /// Pass null for `table_filter` to receive events for all tables.
    /// `from_seq` sets the initial cursor (events at or before this seq are skipped).
    pub fn subscribe(self: *CdcManager, table_filter: ?TableId, from_seq: Seq) !*CdcSubscription {
        const sub = try self.alloc.create(CdcSubscription);
        errdefer self.alloc.destroy(sub);
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_id;
        self.next_id += 1;
        sub.* = CdcSubscription.init(id, table_filter, from_seq, self.alloc);
        try self.subscriptions.append(self.alloc, sub);
        self.metrics.subscriptions_active.set(@intCast(self.subscriptions.items.len));
        return sub;
    }

    /// Remove and destroy the subscription with the given id.
    pub fn unsubscribe(self: *CdcManager, id: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscriptions.items, 0..) |sub, i| {
            if (sub.id == id) {
                sub.deinit();
                self.alloc.destroy(sub);
                _ = self.subscriptions.swapRemove(i);
                self.metrics.subscriptions_active.set(@intCast(self.subscriptions.items.len));
                return;
            }
        }
    }

    /// Minimum cursor across all active subscriptions, or 0 if none.
    /// Used by log truncation to determine the safe truncation point.
    pub fn minCursor(self: *CdcManager) Seq {
        self.mutex.lock();
        defer self.mutex.unlock();
        var min: Seq = std.math.maxInt(Seq);
        for (self.subscriptions.items) |sub| {
            const c = sub.cursor.load(.acquire);
            if (c < min) min = c;
        }
        return if (min == std.math.maxInt(Seq)) 0 else min;
    }

    /// Find a subscription by ID. Returns null if not found or already unsubscribed.
    pub fn findById(self: *CdcManager, id: u64) ?*CdcSubscription {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.subscriptions.items) |sub| {
            if (sub.id == id) return sub;
        }
        return null;
    }

    /// Capture before-images for mutations. Call BEFORE storage.apply().
    /// Returns a BeforeImages parallel to `mutations`; caller must call deinit().
    pub fn captureBeforeImages(
        self: *CdcManager,
        mutations: []const Mutation,
        storage: anytype,
        at_seq: Seq,
        alloc: std.mem.Allocator,
    ) !BeforeImages {
        const images = try alloc.alloc(?[]ColumnValue, mutations.len);
        var committed: usize = 0;
        errdefer {
            for (images[0..committed]) |img_opt| {
                if (img_opt) |img| {
                    for (img) |v| v.freeIfOwned(alloc);
                    alloc.free(img);
                }
            }
            alloc.free(images);
        }

        while (committed < mutations.len) : (committed += 1) {
            const m = mutations[committed];
            if (m.kind == .insert) {
                images[committed] = null;
                continue;
            }
            const row_opt = try storage.get(m.table_id, m.key, at_seq);
            if (row_opt) |row| {
                var r = row;
                defer r.deinit(storage.alloc);
                images[committed] = try cloneColumnValues(r.values, alloc);
            } else {
                images[committed] = null;
            }
        }

        self.metrics.before_images_captured.add(@intCast(mutations.len));
        return .{ .images = images, .alloc = alloc };
    }

    /// Build and fan-out CdcEvents to all matching subscriptions. Call AFTER storage.apply().
    /// Does not take ownership of `before`; caller must deinit() it.
    pub fn dispatch(
        self: *CdcManager,
        seq: Seq,
        epoch: u64,
        kind: EntryKind,
        mutations: []const Mutation,
        before: BeforeImages,
        alloc: std.mem.Allocator,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.subscriptions.items.len == 0 or mutations.len == 0) return;

        for (self.subscriptions.items) |sub| {
            var effects: std.ArrayListUnmanaged(CdcEffect) = .empty;
            errdefer {
                for (effects.items) |*e| e.deinit(alloc);
                effects.deinit(alloc);
            }

            for (mutations, 0..) |m, mi| {
                if (sub.table_filter) |tf| if (m.table_id != tf) continue;
                const effect = try buildEffect(alloc, m, before.images[mi]);
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
            const ev = CdcEvent{
                .seq = seq,
                .epoch = epoch,
                .kind = kind,
                .effects = effects_slice,
                .alloc = alloc,
            };
            self.metrics.events_emitted.inc();
            self.metrics.effects_total.add(@intCast(effects_slice.len));
            sub.push(ev) catch |err| {
                var e = ev;
                e.deinit();
                return err;
            };
        }
    }
};

fn mutationKindToOp(kind: MutationKind) CdcOperation {
    return switch (kind) {
        .insert => .insert,
        .update => .update,
        .delete => .delete,
    };
}

fn cloneColumnValues(src: []const ColumnValue, alloc: std.mem.Allocator) ![]ColumnValue {
    const dst = try alloc.alloc(ColumnValue, src.len);
    var i: usize = 0;
    errdefer {
        for (dst[0..i]) |v| v.freeIfOwned(alloc);
        alloc.free(dst);
    }
    while (i < src.len) : (i += 1) dst[i] = try src[i].dupe(alloc);
    return dst;
}

fn buildEffect(alloc: std.mem.Allocator, m: Mutation, before_img: ?[]ColumnValue) !CdcEffect {
    const op = mutationKindToOp(m.kind);

    const key = try alloc.dupe(u8, m.key);
    errdefer alloc.free(key);

    const before: ?[]ColumnValue = if (before_img) |img|
        try cloneColumnValues(img, alloc)
    else
        null;
    errdefer if (before) |b| {
        for (b) |v| v.freeIfOwned(alloc);
        alloc.free(b);
    };

    const after: ?[]ColumnValue = if (op != .delete) blk: {
        const src = m.values orelse break :blk null;
        break :blk try cloneColumnValues(src, alloc);
    } else null;

    return .{ .table_id = m.table_id, .key = key, .op = op, .before = before, .after = after };
}
