const std = @import("std");

pub const ObjectStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put_fn: *const fn (*anyopaque, key: []const u8, data: []const u8) anyerror!void,
        get_fn: *const fn (*anyopaque, key: []const u8, alloc: std.mem.Allocator) anyerror![]u8,
        delete_fn: *const fn (*anyopaque, key: []const u8) anyerror!void,
        exists_fn: *const fn (*anyopaque, key: []const u8) anyerror!bool,
        list_fn: *const fn (*anyopaque, prefix: []const u8, alloc: std.mem.Allocator) anyerror![][]const u8,
    };

    pub fn put(self: ObjectStore, key: []const u8, data: []const u8) anyerror!void {
        return self.vtable.put_fn(self.ptr, key, data);
    }

    pub fn get(self: ObjectStore, key: []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        return self.vtable.get_fn(self.ptr, key, alloc);
    }

    pub fn delete(self: ObjectStore, key: []const u8) anyerror!void {
        return self.vtable.delete_fn(self.ptr, key);
    }

    pub fn exists(self: ObjectStore, key: []const u8) anyerror!bool {
        return self.vtable.exists_fn(self.ptr, key);
    }

    pub fn list(self: ObjectStore, prefix: []const u8, alloc: std.mem.Allocator) anyerror![][]const u8 {
        return self.vtable.list_fn(self.ptr, prefix, alloc);
    }
};

pub const MemoryObjectStore = struct {
    map: std.StringHashMap([]u8),
    alloc: std.mem.Allocator,

    const vtable = ObjectStore.VTable{
        .put_fn = putImpl,
        .get_fn = getImpl,
        .delete_fn = deleteImpl,
        .exists_fn = existsImpl,
        .list_fn = listImpl,
    };

    pub fn init(alloc: std.mem.Allocator) MemoryObjectStore {
        return .{
            .map = std.StringHashMap([]u8).init(alloc),
            .alloc = alloc,
        };
    }

    pub fn deinit(self: *MemoryObjectStore) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.alloc.free(entry.key_ptr.*);
            self.alloc.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn objectStore(self: *MemoryObjectStore) ObjectStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn putImpl(ptr: *anyopaque, key: []const u8, data: []const u8) anyerror!void {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(ptr));
        const key_copy = try self.alloc.dupe(u8, key);
        errdefer self.alloc.free(key_copy);
        const data_copy = try self.alloc.dupe(u8, data);
        errdefer self.alloc.free(data_copy);

        const result = try self.map.getOrPut(key_copy);
        if (result.found_existing) {
            self.alloc.free(result.key_ptr.*);
            self.alloc.free(result.value_ptr.*);
            result.key_ptr.* = key_copy;
        }
        result.value_ptr.* = data_copy;
    }

    fn getImpl(ptr: *anyopaque, key: []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(ptr));
        const val = self.map.get(key) orelse return error.KeyNotFound;
        return alloc.dupe(u8, val);
    }

    fn deleteImpl(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(ptr));
        if (self.map.fetchRemove(key)) |entry| {
            self.alloc.free(entry.key);
            self.alloc.free(entry.value);
        }
    }

    fn existsImpl(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(ptr));
        return self.map.contains(key);
    }

    fn listImpl(ptr: *anyopaque, prefix: []const u8, alloc: std.mem.Allocator) anyerror![][]const u8 {
        const self: *MemoryObjectStore = @ptrCast(@alignCast(ptr));
        var result: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (result.items) |s| alloc.free(s);
            result.deinit(alloc);
        }
        var it = self.map.keyIterator();
        while (it.next()) |k| {
            if (std.mem.startsWith(u8, k.*, prefix)) {
                const copy = try alloc.dupe(u8, k.*);
                try result.append(alloc, copy);
            }
        }
        return result.toOwnedSlice(alloc);
    }
};
