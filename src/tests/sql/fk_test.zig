/// FK constraint enforcement tests: INSERT/UPDATE/DELETE via SqlExecutor.
const std = @import("std");
const testing = std.testing;
const sql = @import("sql.zig");
const schema_mod = sql.schema;
const registry_mod = sql.registry;
const eb = sql.executor_bridge;
const executor_mod = @import("executor.zig");
const storage_mod = @import("storage.zig");

const Storage = eb.Storage;
const ColumnValue = eb.ColumnValue;
const LogEntry = eb.LogEntry;

const serializeTxnIntent = executor_mod.serializeTxnIntent;
const zero_span = sql.ast.Span{ .start = 0, .end = 0 };

// ─── Schema ───────────────────────────────────────────────────────────────────

// parents(id STRING NOT NULL PK)
// children(id STRING NOT NULL PK, parent_id STRING NOT NULL, FK→parents(id))
fn makeFkSchema(alloc: std.mem.Allocator) !schema_mod.SchemaRegistry {
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

fn registerStorageFk(storage: *Storage) !void {
    try storage.registerTable(.{ .table_id = 1, .columns = &.{.{ .col_type = .string, .nullable = false }} });
    try storage.registerTable(.{ .table_id = 2, .columns = &.{
        .{ .col_type = .string, .nullable = false },
        .{ .col_type = .string, .nullable = false },
    } });
}

// ─── Temp dir helpers ─────────────────────────────────────────────────────────

fn makeTempDir(alloc: std.mem.Allocator, suffix: u64) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/fk_test_{d}", .{suffix});
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

// ─── Entry builder ────────────────────────────────────────────────────────────

fn makeEntry(alloc: std.mem.Allocator, seq: u64, hash: *const [32]u8, params: []const u8) !LogEntry {
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(alloc);
    try serializeTxnIntent(hash, 0, seq, &.{}, &.{}, params, &.{}, &payload, alloc);
    const copy = try alloc.dupe(u8, payload.items);
    return LogEntry.create(seq, 1, executor_mod.EntryKind.txn_intent, copy);
}

// ─── Fixture ──────────────────────────────────────────────────────────────────

const Fixture = struct {
    storage: *Storage,
    sr: *schema_mod.SchemaRegistry,
    reg: *registry_mod.SqlRegistry,
    exec: eb.SqlExecutor,
    dir: []const u8,
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator, dir: []const u8) !Fixture {
        const storage = try alloc.create(Storage);
        storage.* = try Storage.init(dir, alloc);
        try registerStorageFk(storage);

        const sr = try alloc.create(schema_mod.SchemaRegistry);
        sr.* = try makeFkSchema(alloc);

        const reg = try alloc.create(registry_mod.SqlRegistry);
        reg.* = registry_mod.SqlRegistry.init(alloc, sr);

        const exec = eb.SqlExecutor.init(storage, reg, sr, alloc);
        return .{ .storage = storage, .sr = sr, .reg = reg, .exec = exec, .dir = dir, .alloc = alloc };
    }

    fn deinit(self: *Fixture) void {
        self.reg.deinit();
        self.alloc.destroy(self.reg);
        self.sr.deinit();
        self.alloc.destroy(self.sr);
        self.storage.deinit();
        self.alloc.destroy(self.storage);
        removeDir(self.dir);
        self.alloc.free(self.dir);
    }

    fn run(self: *Fixture, seq: u64, hash: *const [32]u8, params: []const ColumnValue) !void {
        const params_raw = try eb.encodeParams(params, self.alloc);
        defer self.alloc.free(params_raw);
        var e = try makeEntry(self.alloc, seq, hash, params_raw);
        defer e.deinit(self.alloc);
        _ = try self.exec.run(e);
    }
};

// ─── Tests ────────────────────────────────────────────────────────────────────

var ts_seed: u64 = 0;
fn nextDir(alloc: std.mem.Allocator) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    ts_seed += 1;
    const base = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec)) +% ts_seed;
    return makeTempDir(alloc, base);
}

test "FK: INSERT into child with valid parent succeeds" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, try nextDir(alloc));
    defer f.deinit();

    const ins_parent = try f.reg.register("INSERT INTO parents (id) VALUES ($1)");
    const ins_child = try f.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");

    try f.run(1, &ins_parent, &.{.{ .string = "p1" }});
    try f.run(2, &ins_child, &.{ .{ .string = "c1" }, .{ .string = "p1" } });
}

test "FK: INSERT into child with missing parent is rejected" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, try nextDir(alloc));
    defer f.deinit();

    const ins_child = try f.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");

    const params_raw = try eb.encodeParams(&.{ .{ .string = "c1" }, .{ .string = "nobody" } }, alloc);
    defer alloc.free(params_raw);
    var e = try makeEntry(alloc, 1, &ins_child, params_raw);
    defer e.deinit(alloc);
    const result = f.exec.run(e);
    try testing.expect(result == error.ForeignKeyViolation);
}

test "FK: DELETE parent with no children succeeds" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, try nextDir(alloc));
    defer f.deinit();

    const ins_parent = try f.reg.register("INSERT INTO parents (id) VALUES ($1)");
    const del_parent = try f.reg.register("DELETE FROM parents WHERE id = $1");

    try f.run(1, &ins_parent, &.{.{ .string = "p1" }});
    try f.run(2, &del_parent, &.{.{ .string = "p1" }});
}

test "FK: DELETE parent referenced by child is rejected" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, try nextDir(alloc));
    defer f.deinit();

    const ins_parent = try f.reg.register("INSERT INTO parents (id) VALUES ($1)");
    const ins_child = try f.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");
    const del_parent = try f.reg.register("DELETE FROM parents WHERE id = $1");

    try f.run(1, &ins_parent, &.{.{ .string = "p1" }});
    try f.run(2, &ins_child, &.{ .{ .string = "c1" }, .{ .string = "p1" } });

    const params_raw = try eb.encodeParams(&.{.{ .string = "p1" }}, alloc);
    defer alloc.free(params_raw);
    var e = try makeEntry(alloc, 3, &del_parent, params_raw);
    defer e.deinit(alloc);
    const result = f.exec.run(e);
    try testing.expect(result == error.ForeignKeyViolation);
}

test "FK: DELETE child then parent succeeds" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, try nextDir(alloc));
    defer f.deinit();

    const ins_parent = try f.reg.register("INSERT INTO parents (id) VALUES ($1)");
    const ins_child = try f.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");
    const del_child = try f.reg.register("DELETE FROM children WHERE id = $1");
    const del_parent = try f.reg.register("DELETE FROM parents WHERE id = $1");

    try f.run(1, &ins_parent, &.{.{ .string = "p1" }});
    try f.run(2, &ins_child, &.{ .{ .string = "c1" }, .{ .string = "p1" } });
    try f.run(3, &del_child, &.{.{ .string = "c1" }});
    try f.run(4, &del_parent, &.{.{ .string = "p1" }});
}

test "FK: UPDATE child FK column to valid parent succeeds" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, try nextDir(alloc));
    defer f.deinit();

    const ins_parent = try f.reg.register("INSERT INTO parents (id) VALUES ($1)");
    const ins_child = try f.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");
    const upd_child = try f.reg.register("UPDATE children SET parent_id = $2 WHERE id = $1");

    try f.run(1, &ins_parent, &.{.{ .string = "p1" }});
    try f.run(2, &ins_parent, &.{.{ .string = "p2" }});
    try f.run(3, &ins_child, &.{ .{ .string = "c1" }, .{ .string = "p1" } });
    try f.run(4, &upd_child, &.{ .{ .string = "c1" }, .{ .string = "p2" } });
}

test "FK: UPDATE child FK column to missing parent is rejected" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, try nextDir(alloc));
    defer f.deinit();

    const ins_parent = try f.reg.register("INSERT INTO parents (id) VALUES ($1)");
    const ins_child = try f.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");
    const upd_child = try f.reg.register("UPDATE children SET parent_id = $2 WHERE id = $1");

    try f.run(1, &ins_parent, &.{.{ .string = "p1" }});
    try f.run(2, &ins_child, &.{ .{ .string = "c1" }, .{ .string = "p1" } });

    const params_raw = try eb.encodeParams(&.{ .{ .string = "c1" }, .{ .string = "ghost" } }, alloc);
    defer alloc.free(params_raw);
    var e = try makeEntry(alloc, 3, &upd_child, params_raw);
    defer e.deinit(alloc);
    const result = f.exec.run(e);
    try testing.expect(result == error.ForeignKeyViolation);
}

test "FK: violation error detail names the constraint and table" {
    const alloc = testing.allocator;
    var f = try Fixture.init(alloc, try nextDir(alloc));
    defer f.deinit();

    const ins_child = try f.reg.register("INSERT INTO children (id, parent_id) VALUES ($1, $2)");

    const params_raw = try eb.encodeParams(&.{ .{ .string = "c1" }, .{ .string = "nobody" } }, alloc);
    defer alloc.free(params_raw);
    var e = try makeEntry(alloc, 1, &ins_child, params_raw);
    defer e.deinit(alloc);
    _ = f.exec.run(e) catch {};

    const detail = f.exec.lastDetail();
    try testing.expect(detail.len > 0);
    // Detail must mention the constraint name and referenced table
    try testing.expect(std.mem.indexOf(u8, detail, "fk_parent") != null);
    try testing.expect(std.mem.indexOf(u8, detail, "parents") != null);
}
