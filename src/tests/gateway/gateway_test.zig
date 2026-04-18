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

    const exec_result = try gateway.execute(std.testing.io, reg_result.hash, &params, &.{});
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
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &insert_params, &.{});

    const update_sql = "UPDATE accounts SET balance = $1 WHERE id = $2";
    const update_reg = try gateway.register(update_sql);
    const update_params = [_]ColumnValue{
        .{ .int64 = 2000 },
        .{ .int64 = 1 },
    };
    const update_result = try gateway.execute(std.testing.io, update_reg.hash, &update_params, &.{});
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
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &insert_params, &.{});

    const delete_sql = "DELETE FROM accounts WHERE id = $1";
    const delete_reg = try gateway.register(delete_sql);
    const delete_params = [_]ColumnValue{
        .{ .int64 = 1 },
    };
    const delete_result = try gateway.execute(std.testing.io, delete_reg.hash, &delete_params, &.{});
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
    _ = try gateway.execute(std.testing.io, reg.hash, &params, &.{});

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

    const result = gateway.execute(std.testing.io, fake_hash, &.{}, &.{});
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
    _ = try gateway.execute(std.testing.io, insert_user.hash, &user_params, &.{});

    const insert_post = try gateway.register("INSERT INTO posts (id, user_id, content) VALUES ($1, $2, $3)");
    const post_params = [_]ColumnValue{
        .{ .int64 = 1 },
        .{ .int64 = 1 },
        .{ .string = try testing.allocator.dupe(u8, "hello world") },
    };
    defer testing.allocator.free(post_params[2].string);
    _ = try gateway.execute(std.testing.io, insert_post.hash, &post_params, &.{});
}

test "Gateway: querySelect returns inserted rows" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE accounts (id INT64 NOT NULL, balance INT64 NOT NULL, PRIMARY KEY (id))");

    const insert_reg = try gateway.register("INSERT INTO accounts (id, balance) VALUES ($1, $2)");
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 100 } }, &.{});
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 2 }, .{ .int64 = 200 } }, &.{});

    const select_reg = try gateway.register("SELECT id, balance FROM accounts");
    var rs = try gateway.querySelect(select_reg.hash, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 2), rs.rows.len);

    // Find the row with id=1 and verify balance=100
    var found_row1 = false;
    var found_row2 = false;
    for (rs.rows) |row| {
        const id_val = row[0] orelse continue;
        const bal_val = row[1] orelse continue;
        if (id_val == .int64 and id_val.int64 == 1) {
            try testing.expectEqual(@as(i64, 100), bal_val.int64);
            found_row1 = true;
        } else if (id_val == .int64 and id_val.int64 == 2) {
            try testing.expectEqual(@as(i64, 200), bal_val.int64);
            found_row2 = true;
        }
    }
    try testing.expect(found_row1);
    try testing.expect(found_row2);
}

test "Gateway: readAt returns data at correct seq" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE log (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const seq_before = gateway.currentSeq();

    const insert_reg = try gateway.register("INSERT INTO log (id, val) VALUES ($1, $2)");
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 42 } }, &.{});

    const seq_after = gateway.currentSeq();

    const select_reg = try gateway.register("SELECT id, val FROM log");

    // Read at seq_after: should see the inserted row
    var rs_after = try gateway.readAt(select_reg.hash, &.{}, seq_after);
    defer rs_after.deinit();
    try testing.expectEqual(@as(usize, 1), rs_after.rows.len);

    // Read at seq_before: should see nothing (row not yet committed at that point)
    var rs_before = try gateway.readAt(select_reg.hash, &.{}, seq_before);
    defer rs_before.deinit();
    try testing.expectEqual(@as(usize, 0), rs_before.rows.len);
}

test "Gateway: querySelect with WHERE param returns matching row only" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE items (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const insert_reg = try gateway.register("INSERT INTO items (id, val) VALUES ($1, $2)");
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 2 }, .{ .int64 = 20 } }, &.{});
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 3 }, .{ .int64 = 30 } }, &.{});

    const select_reg = try gateway.register("SELECT id, val FROM items WHERE id = $1");

    var rs = try gateway.querySelect(select_reg.hash, &[_]ColumnValue{.{ .int64 = 2 }}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 2), rs.rows[0][0].?.int64);
    try testing.expectEqual(@as(i64, 20), rs.rows[0][1].?.int64);
}

test "Gateway: querySelect on empty table returns zero rows" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE empty_tbl (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const select_reg = try gateway.register("SELECT id, val FROM empty_tbl");
    var rs = try gateway.querySelect(select_reg.hash, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 0), rs.rows.len);
}

test "Gateway: DELETE makes row invisible in subsequent SELECT" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE items (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const insert_reg = try gateway.register("INSERT INTO items (id, val) VALUES ($1, $2)");
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 2 }, .{ .int64 = 20 } }, &.{});

    const delete_reg = try gateway.register("DELETE FROM items WHERE id = $1");
    _ = try gateway.execute(std.testing.io, delete_reg.hash, &[_]ColumnValue{.{ .int64 = 1 }}, &.{});

    const select_reg = try gateway.register("SELECT id, val FROM items");
    var rs = try gateway.querySelect(select_reg.hash, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 2), rs.rows[0][0].?.int64);
}

test "Gateway: UPDATE value is visible in subsequent SELECT" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE items (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const insert_reg = try gateway.register("INSERT INTO items (id, val) VALUES ($1, $2)");
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});

    const update_reg = try gateway.register("UPDATE items SET val = $2 WHERE id = $1");
    _ = try gateway.execute(std.testing.io, update_reg.hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 99 } }, &.{});

    const select_reg = try gateway.register("SELECT id, val FROM items WHERE id = $1");
    var rs = try gateway.querySelect(select_reg.hash, &[_]ColumnValue{.{ .int64 = 1 }}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 1), rs.rows.len);
    try testing.expectEqual(@as(i64, 99), rs.rows[0][1].?.int64);
}

test "Gateway: UPDATE with no matching rows returns rows_affected zero" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE items (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const update_reg = try gateway.register("UPDATE items SET val = $2 WHERE id = $1");
    const result = try gateway.execute(std.testing.io, update_reg.hash, &[_]ColumnValue{ .{ .int64 = 999 }, .{ .int64 = 42 } }, &.{});
    try testing.expectEqual(@as(u64, 0), result.rows_affected);
}

test "Gateway: DELETE with no matching rows returns rows_affected zero" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE items (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");

    const delete_reg = try gateway.register("DELETE FROM items WHERE id = $1");
    const result = try gateway.execute(std.testing.io, delete_reg.hash, &[_]ColumnValue{.{ .int64 = 999 }}, &.{});
    try testing.expectEqual(@as(u64, 0), result.rows_affected);
}

test "Gateway: currentSeq advances with each execute" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try testing.expectEqual(@as(Seq, 0), gateway.currentSeq());

    try gateway.applyDdl("CREATE TABLE items (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");
    const insert_reg = try gateway.register("INSERT INTO items (id, val) VALUES ($1, $2)");

    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    try testing.expectEqual(@as(Seq, 1), gateway.currentSeq());

    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 2 }, .{ .int64 = 20 } }, &.{});
    try testing.expectEqual(@as(Seq, 2), gateway.currentSeq());

    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 3 }, .{ .int64 = 30 } }, &.{});
    try testing.expectEqual(@as(Seq, 3), gateway.currentSeq());
}

test "Gateway: readAt intermediate state shows partial history" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    const gateway = try Gateway.init(temp_path, testing.allocator);
    defer gateway.deinit();

    try gateway.applyDdl("CREATE TABLE items (id INT64 NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))");
    const insert_reg = try gateway.register("INSERT INTO items (id, val) VALUES ($1, $2)");
    const select_reg = try gateway.register("SELECT id, val FROM items");

    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 1 }, .{ .int64 = 10 } }, &.{});
    const seq1 = gateway.currentSeq();
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 2 }, .{ .int64 = 20 } }, &.{});
    _ = try gateway.execute(std.testing.io, insert_reg.hash, &[_]ColumnValue{ .{ .int64 = 3 }, .{ .int64 = 30 } }, &.{});

    // At seq1 only the first row was committed
    var rs1 = try gateway.readAt(select_reg.hash, &.{}, seq1);
    defer rs1.deinit();
    try testing.expectEqual(@as(usize, 1), rs1.rows.len);

    // At current seq all three rows are visible
    var rs3 = try gateway.readAt(select_reg.hash, &.{}, gateway.currentSeq());
    defer rs3.deinit();
    try testing.expectEqual(@as(usize, 3), rs3.rows.len);
}

// --- PostSnapshotHook test (Gaps 3+11) ---

const HookState = struct {
    called: bool = false,
    last_seq: storage_mod.Seq = 0,
};

fn postSnapshotHookFn(ptr: *anyopaque, seq: storage_mod.Seq) void {
    const state: *HookState = @ptrCast(@alignCast(ptr));
    state.called = true;
    state.last_seq = seq;
}

test "PostSnapshotHook: called after snapshot threshold reached" {
    const temp_path = try makeTempDir();
    defer {
        removeDirRecursive(temp_path);
        testing.allocator.free(temp_path);
    }

    var state = HookState{};
    const hook = storage_mod.PostSnapshotHook{
        .ptr = &state,
        .hookFn = postSnapshotHookFn,
    };

    var mem_store = storage_mod.MemoryObjectStore.init(testing.allocator);
    defer mem_store.deinit();

    // Interval of 2 so we trigger after 2 mutations.
    const policy = storage_mod.SnapshotPolicy{
        .interval = 2,
        .store = mem_store.objectStore(),
        .post_snapshot = hook,
    };

    var storage = try storage_mod.Storage.init(temp_path, testing.allocator);
    defer storage.deinit();

    const schema = storage_mod.TableSchema{
        .table_id = 42,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };
    try storage.registerTable(schema);
    storage.setSnapshotPolicy(policy);

    // Apply 2 mutations — should trigger the snapshot and call the hook.
    const m1 = storage_mod.Mutation{
        .kind = .insert,
        .table_id = 42,
        .key = try testing.allocator.dupe(u8, "k1"),
        .values = blk: {
            const v = try testing.allocator.alloc(storage_mod.ColumnValue, 2);
            v[0] = .{ .string = try testing.allocator.dupe(u8, "k1") };
            v[1] = .{ .int64 = 1 };
            break :blk v;
        },
    };
    defer {
        testing.allocator.free(m1.key);
        if (m1.values) |vs| {
            vs[0].freeIfOwned(testing.allocator);
            vs[1].freeIfOwned(testing.allocator);
            testing.allocator.free(vs);
        }
    }

    const m2 = storage_mod.Mutation{
        .kind = .insert,
        .table_id = 42,
        .key = try testing.allocator.dupe(u8, "k2"),
        .values = blk: {
            const v = try testing.allocator.alloc(storage_mod.ColumnValue, 2);
            v[0] = .{ .string = try testing.allocator.dupe(u8, "k2") };
            v[1] = .{ .int64 = 2 };
            break :blk v;
        },
    };
    defer {
        testing.allocator.free(m2.key);
        if (m2.values) |vs| {
            vs[0].freeIfOwned(testing.allocator);
            vs[1].freeIfOwned(testing.allocator);
            testing.allocator.free(vs);
        }
    }

    try storage.apply(&.{m1}, 1);
    try storage.apply(&.{m2}, 2);

    try testing.expect(state.called);
    try testing.expectEqual(@as(storage_mod.Seq, 2), state.last_seq);
}
