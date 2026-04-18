/// Unit tests for the Gateway module (M6).
const std = @import("std");
const testing = std.testing;
const gateway_mod = @import("gateway.zig");
const storage_mod = @import("storage.zig");
const sql_mod = @import("sql.zig");

const Gateway = gateway_mod.Gateway;
const QueryHash = gateway_mod.QueryHash;
const ColumnValue = gateway_mod.ColumnValue;
const Seq = gateway_mod.Seq;

fn makeTempDir() ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/gateway_test_{d}", .{ns});
}

fn removeDirRecursive(path: []const u8) void {
    const z = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(z);
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
                _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

test "Gateway: init and deinit" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try testing.expectEqual(@as(Seq, 0), gateway.currentSeq());
}

test "Gateway: register simple SELECT" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    const create_sql = "CREATE TABLE users (id INT64 NOT NULL, name STRING NOT NULL, PRIMARY KEY (id))";
    try gateway.applyDdl(create_sql);

    const select_sql = "SELECT id, name FROM users WHERE id = $1";
    const result = try gateway.register(select_sql);

    try testing.expect(result.hash.len == 32);
    try testing.expect(result.schema_version > 0);
}

test "Gateway: register is idempotent" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    const create_sql = "CREATE TABLE items (id INT64 NOT NULL, value INT64 NOT NULL, PRIMARY KEY (id))";
    try gateway.applyDdl(create_sql);

    const select_sql = "SELECT id, value FROM items WHERE id = $1";
    const result1 = try gateway.register(select_sql);
    const result2 = try gateway.register(select_sql);

    try testing.expectEqualSlices(u8, &result1.hash, &result2.hash);
    try testing.expectEqual(result1.schema_version, result2.schema_version);
}

test "Gateway: execute INSERT" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    const create_sql = "CREATE TABLE accounts (id INT64 NOT NULL, balance INT64 NOT NULL, PRIMARY KEY (id))";
    try gateway.applyDdl(create_sql);

    const insert_sql = "INSERT INTO accounts (id, balance) VALUES ($1, $2)";
    const reg_result = try gateway.register(insert_sql);

    const params = [_]ColumnValue{
        .{ .int64 = 1 },
        .{ .int64 = 1000 },
    };

    const exec_result = try gateway.execute(reg_result.hash, &params, &.{});
    try testing.expectEqual(@as(u64, 1), exec_result.rows_affected);
}

test "Gateway: execute UPDATE" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    const create_sql = "CREATE TABLE accounts (id INT64 NOT NULL, balance INT64 NOT NULL, PRIMARY KEY (id))";
    try gateway.applyDdl(create_sql);

    const insert_sql = "INSERT INTO accounts (id, balance) VALUES ($1, $2)";
    const insert_reg = try gateway.register(insert_sql);
    const insert_params = [_]ColumnValue{
        .{ .int64 = 1 },
        .{ .int64 = 1000 },
    };
    _ = try gateway.execute(insert_reg.hash, &insert_params, &.{});

    const update_sql = "UPDATE accounts SET balance = $1 WHERE id = $2";
    const update_reg = try gateway.register(update_sql);
    const update_params = [_]ColumnValue{
        .{ .int64 = 2000 },
        .{ .int64 = 1 },
    };
    const update_result = try gateway.execute(update_reg.hash, &update_params, &.{});
    try testing.expectEqual(@as(u64, 1), update_result.rows_affected);
}

test "Gateway: execute DELETE" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    const create_sql = "CREATE TABLE accounts (id INT64 NOT NULL, balance INT64 NOT NULL, PRIMARY KEY (id))";
    try gateway.applyDdl(create_sql);

    const insert_sql = "INSERT INTO accounts (id, balance) VALUES ($1, $2)";
    const insert_reg = try gateway.register(insert_sql);
    const insert_params = [_]ColumnValue{
        .{ .int64 = 1 },
        .{ .int64 = 1000 },
    };
    _ = try gateway.execute(insert_reg.hash, &insert_params, &.{});

    const delete_sql = "DELETE FROM accounts WHERE id = $1";
    const delete_reg = try gateway.register(delete_sql);
    const delete_params = [_]ColumnValue{
        .{ .int64 = 1 },
    };
    const delete_result = try gateway.execute(delete_reg.hash, &delete_params, &.{});
    try testing.expectEqual(@as(u64, 1), delete_result.rows_affected);
}

test "Gateway: nondet resolver NOW" {
    const resolver = gateway_mod.NondetResolver.init(testing.allocator);

    const now1 = resolver.resolveNow();
    const now2 = resolver.resolveNow();

    try testing.expect(now1 == .now);
    try testing.expect(now2 == .now);
    try testing.expect(now2.now >= now1.now);
}

test "Gateway: nondet resolver RANDOM" {
    var resolver = gateway_mod.NondetResolver.init(testing.allocator);

    const rand1 = resolver.resolveRandom();
    const rand2 = resolver.resolveRandom();

    try testing.expect(rand1 == .random);
    try testing.expect(rand2 == .random);
    try testing.expect(rand1.random.len == 16);
    try testing.expect(rand2.random.len == 16);
}

test "Gateway: nondet resolver UUIDv7" {
    const resolver = gateway_mod.NondetResolver.init(testing.allocator);

    const uuid1 = resolver.resolveUuidV7();
    const uuid2 = resolver.resolveUuidV7();

    try testing.expect(uuid1 == .uuid_v7);
    try testing.expect(uuid2 == .uuid_v7);
    try testing.expect(uuid1.uuid_v7.len == 16);
    try testing.expect(uuid2.uuid_v7.len == 16);

    // Version 7: byte 6 upper nibble must be 0x7
    try testing.expect((uuid1.uuid_v7[6] & 0xF0) == 0x70);
    // Variant: byte 8 upper 2 bits must be 10
    try testing.expect((uuid1.uuid_v7[8] & 0xC0) == 0x80);
}

test "Gateway: flushAll" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    const create_sql = "CREATE TABLE test (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))";
    try gateway.applyDdl(create_sql);

    const insert_sql = "INSERT INTO test (id, val) VALUES ($1, $2)";
    const reg = try gateway.register(insert_sql);
    const params = [_]ColumnValue{
        .{ .int64 = 1 },
        .{ .int64 = 42 },
    };
    _ = try gateway.execute(reg.hash, &params, &.{});

    try gateway.flushAll();
}

test "Gateway: query not found returns error" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    var fake_hash: QueryHash = undefined;
    @memset(&fake_hash, 0xFF);

    const result = gateway.execute(fake_hash, &.{}, &.{});
    try testing.expectError(error.QueryNotFound, result);
}

test "Gateway: multiple tables" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE users (id INT64 NOT NULL, name STRING NOT NULL, PRIMARY KEY (id))");
    try gateway.applyDdl("CREATE TABLE posts (id INT64 NOT NULL, user_id INT64 NOT NULL, content STRING NOT NULL, PRIMARY KEY (id))");

    const insert_user = try gateway.register("INSERT INTO users (id, name) VALUES ($1, $2)");
    const user_params = [_]ColumnValue{
        .{ .int64 = 1 },
        .{ .string = try testing.allocator.dupe(u8, "alice") },
    };
    defer testing.allocator.free(user_params[1].string);
    _ = try gateway.execute(insert_user.hash, &user_params, &.{});

    const insert_post = try gateway.register("INSERT INTO posts (id, user_id, content) VALUES ($1, $2, $3)");
    const post_params = [_]ColumnValue{
        .{ .int64 = 1 },
        .{ .int64 = 1 },
        .{ .string = try testing.allocator.dupe(u8, "hello world") },
    };
    defer testing.allocator.free(post_params[2].string);
    _ = try gateway.execute(insert_post.hash, &post_params, &.{});
}
