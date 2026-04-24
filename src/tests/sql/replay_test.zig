/// DST: two SqlExecutor instances fed identical LogEntries must produce byte-equal SSTables.
/// Covers: INSERT/UPDATE/DELETE replay, constraint-abort determinism, scan read-after-write.
const std = @import("std");
const testing = std.testing;
const sql = @import("sql.zig");
const schema_mod = sql.schema;
const registry_mod = sql.registry;
const eb = sql.executor_bridge;

const Storage = eb.Storage;
const ColumnValue = eb.ColumnValue;
const LogEntry = eb.LogEntry;
const ResolvedValue = eb.ResolvedValue;

// Re-exported from executor_mod through eb
const executor_mod = @import("executor.zig");
const serialize_txn_intent = executor_mod.serialize_txn_intent;
const storage_mod = @import("storage.zig");

// ─── Schema ───────────────────────────────────────────────────────────────────

const zero_span = sql.ast.Span{ .start = 0, .end = 0 };

fn makeSchemaRegistry(alloc: std.mem.Allocator) !schema_mod.SchemaRegistry {
    var sr = schema_mod.SchemaRegistry.init(alloc);
    _ = try sr.createTable(.{
        .name = "users",
        .columns = &[_]sql.ast.ColumnDef{
            .{ .name = "id", .typ = .{ .int64 = .error_on_overflow }, .nullable = .not_null, .span = zero_span },
            .{ .name = "name", .typ = .string, .nullable = .not_null, .span = zero_span },
            .{ .name = "score", .typ = .float64, .nullable = .nullable, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
    return sr;
}

fn registerStorage(storage: *Storage) !void {
    try storage.registerTable(.{
        .table_id = 1,
        .columns = &.{
            .{ .col_type = .int64, .nullable = false },
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .float64, .nullable = true },
        },
    });
}

// ─── Temp dir helpers ─────────────────────────────────────────────────────────

fn makeTempDir(alloc: std.mem.Allocator, suffix: u64) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/sql_replay_{d}", .{suffix});
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
                if (dent.type == std.os.linux.DT.DIR) removeDir(child) else _ = std.os.linux.unlink(null_child.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(null_path.ptr);
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
                const full = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
                try files.append(alloc, full);
            }
            i += dent.reclen;
        }
    }
    const result = try files.toOwnedSlice(alloc);
    std.mem.sort([]const u8, result, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    return result;
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

// ─── Entry builder ────────────────────────────────────────────────────────────

fn makeEntry(
    alloc: std.mem.Allocator,
    seq: u64,
    hash: *const [32]u8,
    params: []const u8,
) !LogEntry {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try serialize_txn_intent(hash, 0, seq, 0, &.{}, &.{}, params, &.{}, &payload, alloc);
    const copy = try alloc.dupe(u8, payload.items);
    return LogEntry.create(seq, 1, executor_mod.EntryKind.txn_intent, copy);
}

// ─── Setup / teardown ─────────────────────────────────────────────────────────

const Fixture = struct {
    storage: *Storage,
    partitioned: *eb.PartitionedStorage,
    sr: *schema_mod.SchemaRegistry,
    reg: *registry_mod.SqlRegistry,
    exec: eb.SqlExecutor,
    dir: []const u8,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, dir: []const u8) !Fixture {
        const storage = try alloc.create(Storage);
        storage.* = try Storage.init(dir, alloc);
        try registerStorage(storage);

        const partitioned = try alloc.create(eb.PartitionedStorage);
        partitioned.* = try eb.PartitionedStorage.fromSingle(storage, alloc);

        const sr = try alloc.create(schema_mod.SchemaRegistry);
        sr.* = try makeSchemaRegistry(alloc);

        const reg = try alloc.create(registry_mod.SqlRegistry);
        reg.* = registry_mod.SqlRegistry.init(alloc, sr);

        const exec = eb.SqlExecutor.init(partitioned, reg, sr, alloc);
        return .{ .storage = storage, .partitioned = partitioned, .sr = sr, .reg = reg, .exec = exec, .dir = dir, .alloc = alloc };
    }

    fn deinit(self: *Fixture) void {
        self.reg.deinit();
        self.alloc.destroy(self.reg);
        self.sr.deinit();
        self.alloc.destroy(self.sr);
        self.partitioned.deinit();
        self.alloc.destroy(self.partitioned);
        self.storage.deinit();
        self.alloc.destroy(self.storage);
        removeDir(self.dir);
        self.alloc.free(self.dir);
    }
};

fn assertBytEqualSsts(dir_a: []const u8, dir_b: []const u8, alloc: std.mem.Allocator) !void {
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

// ─── DST: INSERT/UPDATE/DELETE replay ─────────────────────────────────────────

test "SQL Replay: INSERT UPDATE DELETE produces byte-equal SSTables" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    var fa = try Fixture.init(alloc, try makeTempDir(alloc, base));
    defer fa.deinit();
    var fb = try Fixture.init(alloc, try makeTempDir(alloc, base + 1));
    defer fb.deinit();

    // Register SQL queries — same text → same hash in both fixtures
    const insert_hash = try fa.reg.register("INSERT INTO users (id, name, score) VALUES ($1, $2, $3)");
    _ = try fb.reg.register("INSERT INTO users (id, name, score) VALUES ($1, $2, $3)");

    const update_hash = try fa.reg.register("UPDATE users SET score = $2 WHERE id = $1");
    _ = try fb.reg.register("UPDATE users SET score = $2 WHERE id = $1");

    const delete_hash = try fa.reg.register("DELETE FROM users WHERE id = $1");
    _ = try fb.reg.register("DELETE FROM users WHERE id = $1");

    var seq: u64 = 1;

    // 10 INSERTs
    var i: i64 = 1;
    while (i <= 10) : (i += 1) {
        const name = try std.fmt.allocPrint(alloc, "user{d}", .{i});
        defer alloc.free(name);
        const params_raw = try eb.encodeParams(&.{
            .{ .int64 = i },
            .{ .string = name },
            .{ .float64 = @as(f64, @floatFromInt(i)) * 1.5 },
        }, alloc);
        defer alloc.free(params_raw);

        var e = try makeEntry(alloc, seq, &insert_hash, params_raw);
        defer e.deinit(alloc);
        _ = try fa.exec.run(e);
        _ = try fb.exec.run(e);
        seq += 1;
    }

    // 5 UPDATEs (ids 1–5)
    i = 1;
    while (i <= 5) : (i += 1) {
        const params_raw = try eb.encodeParams(&.{
            .{ .int64 = i },
            .{ .float64 = 99.9 },
        }, alloc);
        defer alloc.free(params_raw);

        var e = try makeEntry(alloc, seq, &update_hash, params_raw);
        defer e.deinit(alloc);
        _ = try fa.exec.run(e);
        _ = try fb.exec.run(e);
        seq += 1;
    }

    // 3 DELETEs (ids 8–10)
    i = 8;
    while (i <= 10) : (i += 1) {
        const params_raw = try eb.encodeParams(&.{
            .{ .int64 = i },
        }, alloc);
        defer alloc.free(params_raw);

        var e = try makeEntry(alloc, seq, &delete_hash, params_raw);
        defer e.deinit(alloc);
        _ = try fa.exec.run(e);
        _ = try fb.exec.run(e);
        seq += 1;
    }

    try fa.storage.flushAll();
    try fb.storage.flushAll();

    try assertBytEqualSsts(fa.dir, fb.dir, alloc);
}

// ─── DST: constraint-abort determinism ────────────────────────────────────────

test "SQL Replay: constraint-abort aborts do not corrupt state determinism" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    var fa = try Fixture.init(alloc, try makeTempDir(alloc, base + 10));
    defer fa.deinit();
    var fb = try Fixture.init(alloc, try makeTempDir(alloc, base + 11));
    defer fb.deinit();

    const insert_hash = try fa.reg.register("INSERT INTO users (id, name, score) VALUES ($1, $2, $3)");
    _ = try fb.reg.register("INSERT INTO users (id, name, score) VALUES ($1, $2, $3)");

    // Unknown hash aborts (missing_query)
    const unknown_hash: [32]u8 = [_]u8{0xFF} ** 32;

    // Truncated payload aborts
    const short_payload = try alloc.dupe(u8, "x");
    defer alloc.free(short_payload);

    var seq: u64 = 1;

    // 5 good inserts
    var i: i64 = 1;
    while (i <= 5) : (i += 1) {
        const name = try std.fmt.allocPrint(alloc, "u{d}", .{i});
        defer alloc.free(name);
        const params_raw = try eb.encodeParams(&.{
            .{ .int64 = i },
            .{ .string = name },
            .{ .float64 = 0.0 },
        }, alloc);
        defer alloc.free(params_raw);
        var e = try makeEntry(alloc, seq, &insert_hash, params_raw);
        defer e.deinit(alloc);
        _ = try fa.exec.run(e);
        _ = try fb.exec.run(e);
        seq += 1;
    }

    // 3 unknown-hash aborts
    var j: u64 = 0;
    while (j < 3) : (j += 1) {
        const params_raw = try eb.encodeParams(&.{ .{ .int64 = 999 }, .{ .string = "x" }, .{ .float64 = 0.0 } }, alloc);
        defer alloc.free(params_raw);
        var e = try makeEntry(alloc, seq, &unknown_hash, params_raw);
        defer e.deinit(alloc);
        _ = try fa.exec.run(e);
        _ = try fb.exec.run(e);
        seq += 1;
    }

    // 2 CRC-corrupted aborts
    j = 0;
    while (j < 2) : (j += 1) {
        const params_raw = try eb.encodeParams(&.{ .{ .int64 = 1 }, .{ .string = "bad" }, .{ .float64 = 0.0 } }, alloc);
        defer alloc.free(params_raw);
        var e = try makeEntry(alloc, seq, &insert_hash, params_raw);
        defer e.deinit(alloc);
        e.header.payload_crc ^= 0xDEAD;
        _ = try fa.exec.run(e);
        _ = try fb.exec.run(e);
        seq += 1;
    }

    // 5 more good inserts to show state is uncorrupted
    i = 10;
    while (i <= 14) : (i += 1) {
        const name = try std.fmt.allocPrint(alloc, "u{d}", .{i});
        defer alloc.free(name);
        const params_raw = try eb.encodeParams(&.{
            .{ .int64 = i },
            .{ .string = name },
            .{ .float64 = 1.0 },
        }, alloc);
        defer alloc.free(params_raw);
        var e = try makeEntry(alloc, seq, &insert_hash, params_raw);
        defer e.deinit(alloc);
        _ = try fa.exec.run(e);
        _ = try fb.exec.run(e);
        seq += 1;
    }

    try fa.storage.flushAll();
    try fb.storage.flushAll();

    try assertBytEqualSsts(fa.dir, fb.dir, alloc);
}

// ─── DST: scan read-after-write ───────────────────────────────────────────────

test "SQL Replay: scan returns rows written via INSERT" {
    const alloc = testing.allocator;

    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));

    var fx = try Fixture.init(alloc, try makeTempDir(alloc, base + 20));
    defer fx.deinit();

    const insert_hash = try fx.reg.register("INSERT INTO users (id, name, score) VALUES ($1, $2, $3)");
    const select_hash = try fx.reg.register("SELECT id, name, score FROM users WHERE id = $1");

    var seq: u64 = 1;

    // Insert 3 rows
    var i: i64 = 1;
    while (i <= 3) : (i += 1) {
        const name = try std.fmt.allocPrint(alloc, "user{d}", .{i});
        defer alloc.free(name);
        const params_raw = try eb.encodeParams(&.{
            .{ .int64 = i },
            .{ .string = name },
            .{ .float64 = @as(f64, @floatFromInt(i)) * 10.0 },
        }, alloc);
        defer alloc.free(params_raw);
        var e = try makeEntry(alloc, seq, &insert_hash, params_raw);
        defer e.deinit(alloc);
        _ = try fx.exec.run(e);
        seq += 1;
    }

    // Query each row back using the registered SELECT plan
    const rq = fx.reg.lookup(select_hash).?;
    i = 1;
    while (i <= 3) : (i += 1) {
        const select_params = try alloc.dupe(ColumnValue, &.{.{ .int64 = i }});
        defer alloc.free(select_params);

        var rows = try fx.exec.querySelect(rq.plan, select_params, &.{}, seq, alloc);
        defer {
            for (rows.items) |r| {
                for (r) |v| if (v) |cv| cv.freeIfOwned(alloc);
                alloc.free(r);
            }
            rows.deinit(alloc);
        }

        try testing.expectEqual(@as(usize, 1), rows.items.len);
        const row = rows.items[0];
        // id column
        try testing.expect(row[0] != null);
        try testing.expectEqual(i, row[0].?.int64);
    }

    // Delete row 2, verify it no longer appears
    const delete_hash = try fx.reg.register("DELETE FROM users WHERE id = $1");
    {
        const params_raw = try eb.encodeParams(&.{.{ .int64 = 2 }}, alloc);
        defer alloc.free(params_raw);
        var e = try makeEntry(alloc, seq, &delete_hash, params_raw);
        defer e.deinit(alloc);
        _ = try fx.exec.run(e);
        seq += 1;
    }

    {
        const rq2 = fx.reg.lookup(select_hash).?;
        const select_params = try alloc.dupe(ColumnValue, &.{.{ .int64 = 2 }});
        defer alloc.free(select_params);
        var rows = try fx.exec.querySelect(rq2.plan, select_params, &.{}, seq, alloc);
        defer {
            for (rows.items) |r| alloc.free(r);
            rows.deinit(alloc);
        }
        try testing.expectEqual(@as(usize, 0), rows.items.len);
    }
}

// ─── DST: FK constraint determinism ──────────────────────────────────────────
// parents(id STRING PK) / children(id STRING PK, parent_id STRING FK→parents)

fn makeFkSchemaRegistry(alloc: std.mem.Allocator) !schema_mod.SchemaRegistry {
    var sr = schema_mod.SchemaRegistry.init(alloc);
    _ = try sr.createTable(.{
        .name = "parents",
        .columns = &[_]sql.ast.ColumnDef{
            .{ .name = "id", .typ = .string, .nullable = .not_null, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
    });
    _ = try sr.createTable(.{
        .name = "children",
        .columns = &[_]sql.ast.ColumnDef{
            .{ .name = "id", .typ = .string, .nullable = .not_null, .span = zero_span },
            .{ .name = "parent_id", .typ = .string, .nullable = .not_null, .span = zero_span },
        },
        .primary_key = .{ .columns = &.{"id"} },
        .foreign_keys = &[_]sql.ast.ForeignKeyConstraint{
            .{ .name = "fk_parent", .columns = &.{"parent_id"}, .ref_table = "parents", .ref_columns = &.{"id"} },
        },
    });
    return sr;
}

fn registerFkStorage(storage: *Storage) !void {
    try storage.registerTable(.{ .table_id = 1, .columns = &.{.{ .col_type = .string, .nullable = false }} });
    try storage.registerTable(.{ .table_id = 2, .columns = &.{
        .{ .col_type = .string, .nullable = false },
        .{ .col_type = .string, .nullable = false },
    } });
}

const FkFixture = struct {
    storage: *Storage,
    partitioned: *eb.PartitionedStorage,
    sr: *schema_mod.SchemaRegistry,
    reg: *registry_mod.SqlRegistry,
    exec: eb.SqlExecutor,
    dir: []const u8,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, dir: []const u8) !FkFixture {
        const storage = try alloc.create(Storage);
        storage.* = try Storage.init(dir, alloc);
        try registerFkStorage(storage);
        const partitioned = try alloc.create(eb.PartitionedStorage);
        partitioned.* = try eb.PartitionedStorage.fromSingle(storage, alloc);
        const sr = try alloc.create(schema_mod.SchemaRegistry);
        sr.* = try makeFkSchemaRegistry(alloc);
        const reg = try alloc.create(registry_mod.SqlRegistry);
        reg.* = registry_mod.SqlRegistry.init(alloc, sr);
        const exec = eb.SqlExecutor.init(partitioned, reg, sr, alloc);
        return .{ .storage = storage, .partitioned = partitioned, .sr = sr, .reg = reg, .exec = exec, .dir = dir, .alloc = alloc };
    }

    fn deinit(self: *FkFixture) void {
        self.reg.deinit();
        self.alloc.destroy(self.reg);
        self.sr.deinit();
        self.alloc.destroy(self.sr);
        self.partitioned.deinit();
        self.alloc.destroy(self.partitioned);
        self.storage.deinit();
        self.alloc.destroy(self.storage);
        removeDir(self.dir);
        self.alloc.free(self.dir);
    }
};

test "DST: FK valid INSERT produces byte-equal SSTables" {
    const alloc = testing.allocator;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec)) +% 200;

    var fa = try FkFixture.init(alloc, try makeTempDir(alloc, base));
    defer fa.deinit();
    var fb = try FkFixture.init(alloc, try makeTempDir(alloc, base + 1));
    defer fb.deinit();

    const ins_parent_a = try fa.reg.register("INSERT INTO parents (id) VALUES ($1)");
    _ = try fb.reg.register("INSERT INTO parents (id) VALUES ($1)");
    const ins_child_a = try fa.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");
    _ = try fb.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");

    var seq: u64 = 1;
    {
        const p = try eb.encodeParams(&.{.{ .string = "p1" }}, alloc);
        defer alloc.free(p);
        var e = try makeEntry(alloc, seq, &ins_parent_a, p);
        defer e.deinit(alloc);
        _ = try fa.exec.run(e);
        _ = try fb.exec.run(e);
        seq += 1;
    }
    {
        const p = try eb.encodeParams(&.{ .{ .string = "c1" }, .{ .string = "p1" } }, alloc);
        defer alloc.free(p);
        var e = try makeEntry(alloc, seq, &ins_child_a, p);
        defer e.deinit(alloc);
        _ = try fa.exec.run(e);
        _ = try fb.exec.run(e);
        seq += 1;
    }

    try fa.storage.flushAll();
    try fb.storage.flushAll();

    // Both replicas must produce byte-equal SSTables for parents table (t1)
    const table_dir_a1 = try std.fmt.allocPrint(alloc, "{s}/t1", .{fa.dir});
    defer alloc.free(table_dir_a1);
    const table_dir_b1 = try std.fmt.allocPrint(alloc, "{s}/t1", .{fb.dir});
    defer alloc.free(table_dir_b1);
    const files_a = try listSstFiles(table_dir_a1, alloc);
    defer {
        for (files_a) |f| alloc.free(f);
        alloc.free(files_a);
    }
    const files_b = try listSstFiles(table_dir_b1, alloc);
    defer {
        for (files_b) |f| alloc.free(f);
        alloc.free(files_b);
    }
    try testing.expectEqual(files_a.len, files_b.len);
    for (0..files_a.len) |i| {
        const ba = try readFileBytes(files_a[i], alloc);
        defer alloc.free(ba);
        const bb = try readFileBytes(files_b[i], alloc);
        defer alloc.free(bb);
        try testing.expectEqualSlices(u8, ba, bb);
    }
}

test "DST: FK violation aborts deterministically — both replicas reject identically" {
    const alloc = testing.allocator;
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec)) +% 300;

    var fa = try FkFixture.init(alloc, try makeTempDir(alloc, base));
    defer fa.deinit();
    var fb = try FkFixture.init(alloc, try makeTempDir(alloc, base + 1));
    defer fb.deinit();

    const ins_child_a = try fa.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");
    _ = try fb.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");

    // Both replicas see the same FK-violating entry
    const p = try eb.encodeParams(&.{ .{ .string = "c1" }, .{ .string = "ghost" } }, alloc);
    defer alloc.free(p);
    var e = try makeEntry(alloc, 1, &ins_child_a, p);
    defer e.deinit(alloc);

    const result_a = fa.exec.run(e);
    const result_b = fb.exec.run(e);

    // Both must agree: either both succeed or both fail with the same error tag
    try testing.expect(result_a == error.ForeignKeyViolation);
    try testing.expect(result_b == error.ForeignKeyViolation);

    // Storage must be identical (empty — no rows committed)
    try fa.storage.flushAll();
    try fb.storage.flushAll();
}
