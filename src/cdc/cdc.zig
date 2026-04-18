/// Change Data Capture: subscription API and event dispatch.
///
/// Every committed transaction produces a CdcEvent delivered to subscribers.
/// Delivery is at-least-once in-process; consumers must ack to advance their cursor.
const std = @import("std");
const storage_mod = @import("storage.zig");
const log_mod = @import("log.zig");

pub const TableId = storage_mod.TableId;
pub const Seq = storage_mod.Seq;
pub const ColumnValue = storage_mod.ColumnValue;
pub const MutationKind = storage_mod.MutationKind;
pub const Mutation = storage_mod.Mutation;
pub const Storage = storage_mod.Storage;
pub const EntryKind = log_mod.EntryKind;

pub const CdcOperation = enum { insert, update, delete };

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
pub const CdcSubscription = struct {
    id: u64,
    /// If set, only events touching this table are delivered.
    table_filter: ?TableId,
    /// Highest sequence number acked by the consumer.
    cursor: Seq,
    pending: std.ArrayListUnmanaged(CdcEvent),
    alloc: std.mem.Allocator,

    pub fn init(id: u64, table_filter: ?TableId, from_seq: Seq, alloc: std.mem.Allocator) CdcSubscription {
        return .{
            .id = id,
            .table_filter = table_filter,
            .cursor = from_seq,
            .pending = .empty,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *CdcSubscription) void {
        for (self.pending.items) |*e| e.deinit();
        self.pending.deinit(self.alloc);
    }

    /// Dequeue up to `out.len` events into `out`. Returns count written. Caller owns events.
    pub fn next(self: *CdcSubscription, out: []CdcEvent) !usize {
        const n = @min(out.len, self.pending.items.len);
        for (0..n) |i| out[i] = self.pending.items[i];
        const total = self.pending.items.len;
        for (n..total) |i| self.pending.items[i - n] = self.pending.items[i];
        self.pending.shrinkRetainingCapacity(total - n);
        return n;
    }

    /// Record that all events up to and including `seq` have been processed.
    pub fn ack(self: *CdcSubscription, seq: Seq) !void {
        if (seq > self.cursor) self.cursor = seq;
    }

    fn push(self: *CdcSubscription, event: CdcEvent) !void {
        try self.pending.append(self.alloc, event);
    }
};

/// Manages CDC subscriptions and orchestrates event dispatch from the executor.
pub const CdcManager = struct {
    subscriptions: std.ArrayListUnmanaged(*CdcSubscription),
    next_id: u64,
    alloc: std.mem.Allocator,

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
        const id = self.next_id;
        self.next_id += 1;
        const sub = try self.alloc.create(CdcSubscription);
        errdefer self.alloc.destroy(sub);
        sub.* = CdcSubscription.init(id, table_filter, from_seq, self.alloc);
        try self.subscriptions.append(self.alloc, sub);
        return sub;
    }

    /// Remove and destroy the subscription with the given id.
    pub fn unsubscribe(self: *CdcManager, id: u64) void {
        for (self.subscriptions.items, 0..) |sub, i| {
            if (sub.id == id) {
                sub.deinit();
                self.alloc.destroy(sub);
                _ = self.subscriptions.swapRemove(i);
                return;
            }
        }
    }

    /// Capture before-images for mutations. Call BEFORE storage.apply().
    /// Returns a BeforeImages parallel to `mutations`; caller must call deinit().
    pub fn captureBeforeImages(
        self: *CdcManager,
        mutations: []const Mutation,
        storage: *Storage,
        at_seq: Seq,
        alloc: std.mem.Allocator,
    ) !BeforeImages {
        _ = self;
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
            const row_opt = storage.get(m.table_id, m.key, at_seq) catch null;
            if (row_opt) |row| {
                var r = row;
                defer r.deinit(storage.alloc);
                images[committed] = try cloneColumnValues(r.values, alloc);
            } else {
                images[committed] = null;
            }
        }

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

            const ev = CdcEvent{
                .seq = seq,
                .epoch = epoch,
                .kind = kind,
                .effects = try effects.toOwnedSlice(alloc),
                .alloc = alloc,
            };
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
