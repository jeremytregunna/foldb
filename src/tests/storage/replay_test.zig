/// Deterministic replay test: two Storage instances with identical mutations
/// must produce byte-identical SSTables after a full flush.
const std = @import("std");
const testing = std.testing;
const storage = @import("storage.zig");

const TableSchema = storage.TableSchema;
const ColumnValue = storage.ColumnValue;
const Mutation = storage.Mutation;
const Storage = storage.Storage;

fn makeSchema() TableSchema {
    return .{
        .table_id = 1,
        .columns = &.{
            .{ .col_type = .uint64, .nullable = false },
            .{ .col_type = .string, .nullable = false },
        },
    };
}

fn makeTempDir(alloc: std.mem.Allocator, suffix: u64) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/replay_test_{d}", .{suffix});
    const null_path = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(null_path);
    @memcpy(null_path[0..path.len], path);
    _ = std.os.linux.mkdir(null_path.ptr, 0o755);
    return path;
}

fn removeDir(path: []const u8) void {
    const null_path = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
    if (fd < 0) return;
    defer _ = std.os.linux.close(@intCast(fd));

    var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const ret = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
        const n: isize = @bitCast(ret);
        if (n <= 0) break;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) {
            const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[i..].ptr));
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const child = std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}", .{ path, name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const null_child = std.heap.page_allocator.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(null_child);
                @memcpy(null_child[0..child.len], child);
                if (dent.type == std.os.linux.DT.DIR) {
                    removeDir(child);
                } else {
                    _ = std.os.linux.unlink(null_child.ptr);
                }
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(null_path.ptr);
}

fn readFileBytes(path: []const u8, alloc: std.mem.Allocator) ![]u8 {
    const null_path = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..path.len], path);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
    if (fd < 0) return error.FileOpenError;
    defer _ = std.os.linux.close(@intCast(fd));

    const size_raw = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.END);
    const size_signed: isize = @bitCast(size_raw);
    if (size_signed < 0) return error.SeekError;
    _ = std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.SET);
    const size: usize = @intCast(size_signed);
    const buf = try alloc.alloc(u8, size);
    errdefer alloc.free(buf);
    var total: usize = 0;
    while (total < size) {
        const n = std.os.linux.read(@intCast(fd), buf.ptr + total, size - total);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.ReadError;
        total += @intCast(ni);
    }
    return buf;
}

fn listSstFiles(dir: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    const null_path = try std.heap.page_allocator.allocSentinel(u8, dir.len, 0);
    defer std.heap.page_allocator.free(null_path);
    @memcpy(null_path[0..dir.len], dir);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const fd: std.posix.fd_t = @intCast(@as(isize, @bitCast(raw_fd)));
    if (fd < 0) return &.{};
    defer _ = std.os.linux.close(@intCast(fd));

    var files: std.ArrayList([]const u8) = .empty;
    var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const ret = std.os.linux.getdents64(@intCast(fd), &buf, buf.len);
        const n: isize = @bitCast(ret);
        if (n <= 0) break;
        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) {
            const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[i..].ptr));
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            if (std.mem.endsWith(u8, name, ".sst")) {
                const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
                try files.append(alloc, path);
            }
            i += dent.reclen;
        }
    }
    const result = try files.toOwnedSlice(alloc);
    std.sort.pdq([]const u8, result, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return result;
}

test "Replay: two identical instances produce byte-equal SSTables" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    const dir_a = try makeTempDir(alloc, base);
    defer alloc.free(dir_a);
    defer removeDir(dir_a);

    const dir_b = try makeTempDir(alloc, base + 1);
    defer alloc.free(dir_b);
    defer removeDir(dir_b);

    const schema = makeSchema();

    // Apply 50 mutations to both instances identically
    var store_a = try Storage.init(dir_a, alloc);
    defer store_a.deinit();
    try store_a.registerTable(schema);

    var store_b = try Storage.init(dir_b, alloc);
    defer store_b.deinit();
    try store_b.registerTable(schema);

    var seq: u64 = 1;
    var ki: u64 = 0;
    while (ki < 50) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "key{d:04}", .{ki % 20});
        defer alloc.free(key);
        const v = [_]ColumnValue{ .{ .uint64 = ki }, .{ .string = "value" } };
        const mutation = Mutation{
            .kind = .insert,
            .table_id = 1,
            .key = key,
            .values = &v,
        };
        try store_a.apply(&.{mutation}, seq);
        try store_b.apply(&.{mutation}, seq);
        seq += 1;
    }

    try store_a.flushAll();
    try store_b.flushAll();

    // Compare SSTable files from both instances
    const table_dir_a = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_a});
    defer alloc.free(table_dir_a);
    const table_dir_b = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_b});
    defer alloc.free(table_dir_b);

    const files_a = try listSstFiles(table_dir_a, alloc);
    defer {
        for (files_a) |f| alloc.free(f);
        alloc.free(files_a);
    }
    const files_b = try listSstFiles(table_dir_b, alloc);
    defer {
        for (files_b) |f| alloc.free(f);
        alloc.free(files_b);
    }

    try testing.expectEqual(files_a.len, files_b.len);
    try testing.expect(files_a.len > 0);

    for (0..files_a.len) |i| {
        const bytes_a = try readFileBytes(files_a[i], alloc);
        defer alloc.free(bytes_a);
        const bytes_b = try readFileBytes(files_b[i], alloc);
        defer alloc.free(bytes_b);
        try testing.expectEqualSlices(u8, bytes_a, bytes_b);
    }
}

test "Replay: inserts and deletes produce byte-equal SSTables" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    const dir_a = try makeTempDir(alloc, base + 2);
    defer alloc.free(dir_a);
    defer removeDir(dir_a);

    const dir_b = try makeTempDir(alloc, base + 3);
    defer alloc.free(dir_b);
    defer removeDir(dir_b);

    const schema = makeSchema();

    var store_a = try Storage.init(dir_a, alloc);
    defer store_a.deinit();
    try store_a.registerTable(schema);

    var store_b = try Storage.init(dir_b, alloc);
    defer store_b.deinit();
    try store_b.registerTable(schema);

    // Write 30 inserts across 15 keys, then delete every other key
    var seq: u64 = 1;
    var ki: u64 = 0;
    while (ki < 30) : (ki += 1) {
        const key = try std.fmt.allocPrint(alloc, "key{d:03}", .{ki % 15});
        defer alloc.free(key);
        const v = [_]ColumnValue{ .{ .uint64 = ki }, .{ .string = "data" } };
        const mut = Mutation{ .kind = .insert, .table_id = 1, .key = key, .values = &v };
        try store_a.apply(&.{mut}, seq);
        try store_b.apply(&.{mut}, seq);
        seq += 1;
    }

    // Delete even-numbered keys
    ki = 0;
    while (ki < 15) : (ki += 2) {
        const key = try std.fmt.allocPrint(alloc, "key{d:03}", .{ki});
        defer alloc.free(key);
        const del = Mutation{ .kind = .delete, .table_id = 1, .key = key, .values = null };
        try store_a.apply(&.{del}, seq);
        try store_b.apply(&.{del}, seq);
        seq += 1;
    }

    try store_a.flushAll();
    try store_b.flushAll();

    const table_dir_a = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_a});
    defer alloc.free(table_dir_a);
    const table_dir_b = try std.fmt.allocPrint(alloc, "{s}/t1", .{dir_b});
    defer alloc.free(table_dir_b);

    const files_a = try listSstFiles(table_dir_a, alloc);
    defer {
        for (files_a) |f| alloc.free(f);
        alloc.free(files_a);
    }
    const files_b = try listSstFiles(table_dir_b, alloc);
    defer {
        for (files_b) |f| alloc.free(f);
        alloc.free(files_b);
    }

    try testing.expectEqual(files_a.len, files_b.len);
    try testing.expect(files_a.len > 0);

    for (0..files_a.len) |i| {
        const bytes_a = try readFileBytes(files_a[i], alloc);
        defer alloc.free(bytes_a);
        const bytes_b = try readFileBytes(files_b[i], alloc);
        defer alloc.free(bytes_b);
        try testing.expectEqualSlices(u8, bytes_a, bytes_b);
    }
}
