/// Gateway integration tests for CREATE INDEX.
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");
const storage_mod = @import("storage.zig");

const Gateway = gateway_mod.Gateway;

fn makeTempDir() ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/create_index_test_{d}", .{ns});
}

fn removeDirRecursive(path: []const u8) void {
    const z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(z);
    @memcpy(z[0..path.len], path);
    const raw_fd = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return;
    const fd: std.posix.fd_t = @intCast(fd_i);
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
                const child = std.mem.concat(std.heap.page_allocator, u8, &.{ path, "/", name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const cz = std.heap.page_allocator.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(cz);
                @memcpy(cz[0..child.len], child);
                if (dent.type == std.os.linux.DT.DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

test "CREATE INDEX ORDERED: index created and queries still work" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE products (id INT64 NOT NULL, name INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE ORDERED INDEX idx_products_name ON products (name)");

    const ins = (try gw.register("INSERT INTO products (id, name) VALUES ($1, $2)")).hash;
    _ = try gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .int64 = 42 } }, &.{});

    const q = (try gw.register("SELECT name FROM products WHERE id = 1")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 42), rs.rows[0][0].?.int64);
}

test "CREATE INDEX HASH: index created and queries still work" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE sessions (id INT64 NOT NULL, token INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE HASH INDEX idx_sessions_token ON sessions (token)");

    const ins = (try gw.register("INSERT INTO sessions (id, token) VALUES ($1, $2)")).hash;
    _ = try gw.execute(ins, &.{ .{ .int64 = 1 }, .{ .int64 = 999 } }, &.{});

    const q = (try gw.register("SELECT token FROM sessions WHERE id = 1")).hash;
    var rs = try gw.querySelect(q, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(?i64, 999), rs.rows[0][0].?.int64);
}

test "CREATE INDEX: duplicate index name is rejected" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE products (id INT64 NOT NULL, name INT64 NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE ORDERED INDEX idx_products_name ON products (name)");
    const result = gw.applyDdl("CREATE HASH INDEX idx_products_name ON products (name)");
    try testing.expectError(error.IndexAlreadyExists, result);
}

test "CREATE INDEX: non-existent table is rejected" {
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        testing.allocator.free(dir);
    }
    const gw = try Gateway.init(dir, testing.allocator, .{});
    defer gw.deinit();

    const result = gw.applyDdl("CREATE ORDERED INDEX idx_ghost ON ghost_table (id)");
    try testing.expectError(error.TableNotFound, result);
}

test "ANN: WHERE ANN(col, $1, k) returns nearest neighbours via HNSW index" {
    const alloc = testing.allocator;
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }
    const gw = try Gateway.init(dir, alloc, .{});
    defer gw.deinit();

    // Table with an id (PK) and a 4-dimensional vector column stored as bytes.
    try gw.applyDdl("CREATE TABLE vecs (id STRING NOT NULL, embedding BYTES NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE VECTOR(4) INDEX vec_idx ON vecs (embedding)");

    // Insert three orthogonal unit vectors.
    const insert_hash = blk: {
        const res = try gw.register("INSERT INTO vecs (id, embedding) VALUES ($1, $2)");
        break :blk res.hash;
    };

    const v1: []const f32 = &.{ 1.0, 0.0, 0.0, 0.0 };
    const v2: []const f32 = &.{ 0.0, 1.0, 0.0, 0.0 };
    const v3: []const f32 = &.{ 0.0, 0.0, 1.0, 0.0 };

    for ([_]struct { id: []const u8, vec: []const f32 }{
        .{ .id = "a", .vec = v1 },
        .{ .id = "b", .vec = v2 },
        .{ .id = "c", .vec = v3 },
    }) |row| {
        const encoded = try storage_mod.vector_codec.encode(row.vec, alloc);
        defer alloc.free(encoded);
        _ = try gw.execute(insert_hash, &.{
            .{ .string = row.id },
            .{ .bytes = encoded },
        }, &.{});
    }

    // ANN query: nearest to v1 = [1,0,0,0], top 1.
    const query_hash = blk: {
        const res = try gw.register("SELECT id FROM vecs WHERE ANN(embedding, $1, 1)");
        break :blk res.hash;
    };
    const query_vec = try storage_mod.vector_codec.encode(v1, alloc);
    defer alloc.free(query_vec);

    var result = try gw.querySelect(query_hash, &.{.{ .bytes = query_vec }}, &.{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.rows.len);
    try testing.expectEqualStrings("a", result.rows[0][0].?.string);
}

test "ANN: k > 1 returns multiple results ordered by distance" {
    const alloc = testing.allocator;
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }
    const gw = try Gateway.init(dir, alloc, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE vecs (id STRING NOT NULL, embedding BYTES NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE VECTOR(4) INDEX vec_idx ON vecs (embedding)");

    const insert_hash = blk: {
        const res = try gw.register("INSERT INTO vecs (id, embedding) VALUES ($1, $2)");
        break :blk res.hash;
    };

    const v1: []const f32 = &.{ 1.0, 0.0, 0.0, 0.0 };
    const v2: []const f32 = &.{ 0.9, 0.1, 0.0, 0.0 }; // close to v1
    const v3: []const f32 = &.{ 0.0, 0.0, 1.0, 0.0 }; // far from v1

    for ([_]struct { id: []const u8, vec: []const f32 }{
        .{ .id = "a", .vec = v1 },
        .{ .id = "b", .vec = v2 },
        .{ .id = "c", .vec = v3 },
    }) |row| {
        const encoded = try storage_mod.vector_codec.encode(row.vec, alloc);
        defer alloc.free(encoded);
        _ = try gw.execute(insert_hash, &.{
            .{ .string = row.id },
            .{ .bytes = encoded },
        }, &.{});
    }

    const query_hash = blk: {
        const res = try gw.register("SELECT id FROM vecs WHERE ANN(embedding, $1, 2)");
        break :blk res.hash;
    };
    const query_vec = try storage_mod.vector_codec.encode(v1, alloc);
    defer alloc.free(query_vec);

    var result = try gw.querySelect(query_hash, &.{.{ .bytes = query_vec }}, &.{});
    defer result.deinit();

    // Top 2 nearest to v1 should be "a" and "b", not "c".
    try testing.expectEqual(@as(usize, 2), result.rows.len);
    const ids = [_][]const u8{ result.rows[0][0].?.string, result.rows[1][0].?.string };
    try testing.expect(std.mem.eql(u8, ids[0], "a") or std.mem.eql(u8, ids[0], "b"));
    try testing.expect(std.mem.eql(u8, ids[1], "a") or std.mem.eql(u8, ids[1], "b"));
    try testing.expect(!std.mem.eql(u8, ids[0], ids[1]));
}

test "ANN: empty index returns zero rows" {
    const alloc = testing.allocator;
    const dir = try makeTempDir();
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }
    const gw = try Gateway.init(dir, alloc, .{});
    defer gw.deinit();

    try gw.applyDdl("CREATE TABLE vecs (id STRING NOT NULL, embedding BYTES NOT NULL, PRIMARY KEY (id))");
    try gw.applyDdl("CREATE VECTOR(4) INDEX vec_idx ON vecs (embedding)");

    const query_hash = blk: {
        const res = try gw.register("SELECT id FROM vecs WHERE ANN(embedding, $1, 5)");
        break :blk res.hash;
    };
    const query_vec = try storage_mod.vector_codec.encode(&[_]f32{ 1.0, 0.0, 0.0, 0.0 }, alloc);
    defer alloc.free(query_vec);

    var result = try gw.querySelect(query_hash, &.{.{ .bytes = query_vec }}, &.{});
    defer result.deinit();

    try testing.expectEqual(@as(usize, 0), result.rows.len);
}
