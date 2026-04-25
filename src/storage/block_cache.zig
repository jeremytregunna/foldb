/// 2-clock LRU block cache keyed by (sstable_id, block_index).
const std = @import("std");

const assert = std.debug.assert;

const CacheKey = struct {
    sstable_id: u64,
    block_index: u32,
};

const CacheEntry = struct {
    key: CacheKey,
    data: []u8,
    size: u32,
    referenced: bool, // 2-clock second-chance bit
};

pub const BlockCache = struct {
    entries: std.ArrayList(CacheEntry),
    map: std.AutoHashMap(u64, u32), // hash(key) → entries index
    capacity_bytes: u64,
    used_bytes: u64,
    clock_hand: u32,
    alloc: std.mem.Allocator,

    pub fn init(capacity_bytes: u64, alloc: std.mem.Allocator) !BlockCache {
        assert(capacity_bytes > 0);
        return .{
            .entries = .empty,
            .map = std.AutoHashMap(u64, u32).init(alloc),
            .capacity_bytes = capacity_bytes,
            .used_bytes = 0,
            .clock_hand = 0,
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *BlockCache) void {
        for (self.entries.items) |*e| self.alloc.free(e.data);
        self.entries.deinit(self.alloc);
        self.map.deinit();
    }

    pub fn get(self: *BlockCache, sstable_id: u64, block_index: u32) ?[]const u8 {
        const h = hashKey(.{ .sstable_id = sstable_id, .block_index = block_index });
        const idx = self.map.get(h) orelse return null;
        if (idx >= self.entries.items.len) return null;
        const entry = &self.entries.items[idx];
        if (entry.key.sstable_id != sstable_id or entry.key.block_index != block_index) return null;
        entry.referenced = true;
        return entry.data;
    }

    pub fn put(self: *BlockCache, sstable_id: u64, block_index: u32, data: []const u8) !void {
        assert(data.len <= std.math.maxInt(u32));
        // Evict until there's space.
        while (self.used_bytes + data.len > self.capacity_bytes and self.entries.items.len > 0) {
            self.evict();
        }
        if (data.len > self.capacity_bytes) return; // single block larger than cache; skip

        const data_copy = try self.alloc.dupe(u8, data);
        errdefer self.alloc.free(data_copy);

        const key = CacheKey{ .sstable_id = sstable_id, .block_index = block_index };
        const h = hashKey(key);
        assert(self.entries.items.len <= std.math.maxInt(u32));
        const idx: u32 = @intCast(self.entries.items.len);
        try self.entries.append(self.alloc, .{
            .key = key,
            .data = data_copy,
            .size = @intCast(data.len),
            .referenced = false,
        });
        try self.map.put(h, idx);
        self.used_bytes += data.len;
    }

    fn evict(self: *BlockCache) void {
        const len = self.entries.items.len;
        assert(len > 0);
        // 2-clock: advance hand until we find an unreferenced entry.
        const max_attempts: u32 = @intCast(len * 2);
        var attempts: u32 = 0;
        while (attempts < max_attempts) : (attempts += 1) {
            const idx: u32 = self.clock_hand % @as(u32, @intCast(len));
            const entry = &self.entries.items[idx];
            if (entry.referenced) {
                entry.referenced = false;
                self.clock_hand = (self.clock_hand + 1) % @as(u32, @intCast(len));
            } else {
                self.evictAt(idx, len);
                return;
            }
        }
        // All entries referenced; evict the one at clock_hand anyway.
        const idx: u32 = self.clock_hand % @as(u32, @intCast(self.entries.items.len));
        self.evictAt(idx, self.entries.items.len);
        self.clock_hand = 0;
    }

    /// Remove the entry at `idx`, update map for any swapped entry.
    fn evictAt(self: *BlockCache, idx: u32, len_before: usize) void {
        const entry = &self.entries.items[idx];
        const h = hashKey(entry.key);
        _ = self.map.remove(h);
        self.used_bytes -= entry.size;
        self.alloc.free(entry.data);
        _ = self.entries.swapRemove(idx);
        // swapRemove moves the last entry to `idx`; update its map entry.
        // On OOM, remove the orphaned entry to keep map and array consistent.
        if (idx < self.entries.items.len) {
            const swapped_h = hashKey(self.entries.items[idx].key);
            self.map.put(swapped_h, idx) catch {
                self.used_bytes -= self.entries.items[idx].size;
                self.alloc.free(self.entries.items[idx].data);
                _ = self.entries.swapRemove(idx);
            };
        }
        if (len_before > 1) {
            self.clock_hand = idx % @as(u32, @intCast(@max(1, self.entries.items.len)));
        } else {
            self.clock_hand = 0;
        }
    }
};

fn hashKey(key: CacheKey) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const id_bytes = std.mem.asBytes(&key.sstable_id);
    for (id_bytes) |b| h = (h ^ b) *% 0x100000001b3;
    const idx_bytes = std.mem.asBytes(&key.block_index);
    for (idx_bytes) |b| h = (h ^ b) *% 0x100000001b3;
    return h;
}
