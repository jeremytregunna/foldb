/// 2-clock LRU block cache keyed by (sstable_id, block_index).
const std = @import("std");

const CacheKey = struct {
    sstable_id: u64,
    block_index: u32,
};

const CacheEntry = struct {
    key: CacheKey,
    data: []u8,
    size: usize,
    referenced: bool, // 2-clock second-chance bit
};

pub const BlockCache = struct {
    entries: std.ArrayList(CacheEntry),
    map: std.AutoHashMap(u64, usize), // hash(key) → entries index
    capacity_bytes: usize,
    used_bytes: usize,
    clock_hand: usize,
    alloc: std.mem.Allocator,

    pub fn init(capacity_bytes: usize, alloc: std.mem.Allocator) !BlockCache {
        return .{
            .entries = .empty,
            .map = std.AutoHashMap(u64, usize).init(alloc),
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
        // Evict until there's space
        while (self.used_bytes + data.len > self.capacity_bytes and self.entries.items.len > 0) {
            self.evict();
        }
        if (data.len > self.capacity_bytes) return; // single block larger than cache; skip

        const data_copy = try self.alloc.dupe(u8, data);
        errdefer self.alloc.free(data_copy);

        const key = CacheKey{ .sstable_id = sstable_id, .block_index = block_index };
        const h = hashKey(key);
        const idx = self.entries.items.len;
        try self.entries.append(self.alloc, .{
            .key = key,
            .data = data_copy,
            .size = data.len,
            .referenced = false,
        });
        try self.map.put(h, idx);
        self.used_bytes += data.len;
    }

    fn evict(self: *BlockCache) void {
        const len = self.entries.items.len;
        if (len == 0) return;

        // 2-clock: advance hand until we find an unreferenced entry
        var attempts: usize = 0;
        while (attempts < len * 2) : (attempts += 1) {
            const idx = self.clock_hand % len;
            const entry = &self.entries.items[idx];
            if (entry.referenced) {
                entry.referenced = false;
                self.clock_hand = (self.clock_hand + 1) % len;
            } else {
                // Evict this entry
                const h = hashKey(entry.key);
                _ = self.map.remove(h);
                self.used_bytes -= entry.size;
                self.alloc.free(entry.data);
                _ = self.entries.swapRemove(idx);
                // Update map for the entry that was swapped in
                if (idx < self.entries.items.len) {
                    const swapped_h = hashKey(self.entries.items[idx].key);
                    self.map.put(swapped_h, idx) catch {};
                }
                if (len > 1) {
                    self.clock_hand = idx % (len - 1);
                } else {
                    self.clock_hand = 0;
                }
                return;
            }
        }
        // All entries referenced; evict the one at clock_hand anyway
        const idx = self.clock_hand % self.entries.items.len;
        const entry = &self.entries.items[idx];
        const h = hashKey(entry.key);
        _ = self.map.remove(h);
        self.used_bytes -= entry.size;
        self.alloc.free(entry.data);
        _ = self.entries.swapRemove(idx);
        if (idx < self.entries.items.len) {
            const swapped_h = hashKey(self.entries.items[idx].key);
            self.map.put(swapped_h, idx) catch {};
        }
        self.clock_hand = 0;
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
