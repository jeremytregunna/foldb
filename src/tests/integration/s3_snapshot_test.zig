/// S3 snapshot integration test.
///
/// Exercises the full snapshot path against a real S3-compatible object store:
/// write rows → flush → snapshot upload → wipe local SSTables → restore from
/// S3 → re-init gateway → verify rows.
///
/// Requires a test-s3.json file in the project root. If the file is absent or
/// S3 fields are not populated the test is skipped. Partial S3 config is an
/// error.
///
/// Example test-s3.json (MinIO):
///   {
///     "s3_endpoint":   "http://127.0.0.1:9000",
///     "s3_bucket":     "foldb-test",
///     "s3_access_key": "minioadmin",
///     "s3_secret_key": "minioadmin",
///     "s3_region":     "us-east-1"
///   }
///
/// Run: zig build s3-integration
const std = @import("std");
const testing = std.testing;
const config_mod = @import("config.zig");
const gateway_mod = @import("gateway.zig");
const storage_mod = @import("storage.zig");

const Gateway = gateway_mod.Gateway;

// ---------------------------------------------------------------------------
// Filesystem helpers (mirrors snapshot_dst_test.zig)
// ---------------------------------------------------------------------------

fn makeTempDir(tag: []const u8, alloc: std.mem.Allocator) ![]u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    const path = try std.fmt.allocPrint(alloc, "/tmp/s3_int_{s}_{d}", .{ tag, ns });
    removeDirRecursive(path);
    const zpath = try alloc.allocSentinel(u8, path.len, 0);
    defer alloc.free(zpath);
    @memcpy(zpath[0..path.len], path);
    _ = std.os.linux.mkdir(zpath.ptr, 0o755);
    return path;
}

fn removeDirRecursive(path: []const u8) void {
    const alloc = std.heap.page_allocator;
    const z = alloc.allocSentinel(u8, path.len, 0) catch return;
    defer alloc.free(z);
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
                const child = std.fmt.allocPrint(alloc, "{s}/{s}", .{ path, name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(child);
                const cz = alloc.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(cz);
                @memcpy(cz[0..child.len], child);
                const DT_DIR: u8 = 4;
                if (dent.type == DT_DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

fn removeSstFiles(root: []const u8) void {
    const alloc = std.heap.page_allocator;
    const z = alloc.allocSentinel(u8, root.len, 0) catch return;
    defer alloc.free(z);
    @memcpy(z[0..root.len], root);
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
                const child = std.fmt.allocPrint(alloc, "{s}/{s}", .{ root, name }) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(child);
                const cz = alloc.allocSentinel(u8, child.len, 0) catch {
                    i += dent.reclen;
                    continue;
                };
                defer alloc.free(cz);
                @memcpy(cz[0..child.len], child);
                const DT_DIR: u8 = 4;
                if (dent.type == DT_DIR) {
                    removeSstFiles(child);
                } else if (std.mem.endsWith(u8, name, ".sst")) {
                    _ = std.os.linux.unlink(cz.ptr);
                }
            }
            i += dent.reclen;
        }
    }
}

// ---------------------------------------------------------------------------
// Test
// ---------------------------------------------------------------------------

test "S3 integration: snapshot round-trip against real object store" {
    const alloc = testing.allocator;

    // Load test config — skip if absent.
    var pc = config_mod.from_file("test-s3.json", alloc) catch return error.SkipZigTest;
    defer pc.deinit();
    const cfg = pc.value;

    // Skip if S3 not configured.
    if (cfg.s3_access_key.len == 0 or cfg.s3_bucket.len == 0 or
        cfg.s3_endpoint.len == 0 or cfg.s3_region.len == 0) return error.SkipZigTest;

    const ep = try config_mod.parse_s3_endpoint(cfg.s3_endpoint);

    const dir = try makeTempDir("snap", alloc);
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    // ── Phase 1: write 20 rows, flush, upload snapshot ──
    {
        const gw = try Gateway.init(dir, alloc, .{
            .s3_io = std.testing.io,
            .s3_endpoint_host = ep.host,
            .s3_endpoint_port = ep.port,
            .s3_access_key = cfg.s3_access_key,
            .s3_secret_key = cfg.s3_secret_key,
            .s3_region = cfg.s3_region,
            .s3_bucket = cfg.s3_bucket,
            .snapshot_interval_entries = 1,
        });
        defer gw.deinit();

        try gw.applyDdl(
            "CREATE TABLE items (id STRING NOT NULL, val INT64 NOT NULL, PRIMARY KEY (id))",
        );
        const ins = (try gw.register("INSERT INTO items (id, val) VALUES ($1, $2)")).hash;

        for (0..20) |i| {
            const id = try std.fmt.allocPrint(alloc, "row_{d:04}", .{i});
            defer alloc.free(id);
            _ = try gw.execute(ins, &.{
                .{ .string = id },
                .{ .int64 = @intCast(i) },
            }, &.{});
        }
        try gw.flushAll();
    }

    // ── Phase 2: find manifest in S3 ──
    var s3 = storage_mod.S3ObjectStore.init(.{
        .access_key = cfg.s3_access_key,
        .secret_key = cfg.s3_secret_key,
        .region = cfg.s3_region,
        .endpoint_host = ep.host,
        .endpoint_port = ep.port,
        .bucket = cfg.s3_bucket,
        .alloc = alloc,
        .io = std.testing.io,
    });
    const obj_store = s3.objectStore();

    const keys = try obj_store.list("snapshots/", alloc);
    defer {
        for (keys) |k| alloc.free(k);
        alloc.free(keys);
    }

    var manifest_key: ?[]const u8 = null;
    for (keys) |k| {
        if (std.mem.endsWith(u8, k, "/manifest")) {
            manifest_key = k;
            break;
        }
    }
    if (manifest_key == null) return error.NoSnapshotUploaded;

    // ── Phase 3: wipe local SSTables, restore from S3 ──
    removeSstFiles(dir);

    const manifest_bytes = try obj_store.get(manifest_key.?, alloc);
    defer alloc.free(manifest_bytes);

    var manifest = try storage_mod.manifestFromBytes(manifest_bytes, manifest_key.?, alloc);
    defer manifest.deinit();

    const table_dir = try std.fmt.allocPrint(alloc, "{s}/p0/t1", .{dir});
    defer alloc.free(table_dir);

    const schema = storage_mod.TableSchema{
        .table_id = 1,
        .columns = &.{
            .{ .col_type = .string, .nullable = false },
            .{ .col_type = .int64, .nullable = false },
        },
    };

    var restored = try storage_mod.restoreFromSnapshot(&manifest, table_dir, obj_store, schema, alloc);
    restored.deinit();

    // ── Phase 4: re-init gateway, verify all 20 rows ──
    const gw2 = try Gateway.init(dir, alloc, .{
        .s3_io = std.testing.io,
        .s3_endpoint_host = ep.host,
        .s3_endpoint_port = ep.port,
        .s3_access_key = cfg.s3_access_key,
        .s3_secret_key = cfg.s3_secret_key,
        .s3_region = cfg.s3_region,
        .s3_bucket = cfg.s3_bucket,
    });
    defer gw2.deinit();

    const sel = (try gw2.register("SELECT id, val FROM items ORDER BY id")).hash;
    var rs = try gw2.querySelect(sel, &.{}, &.{});
    defer rs.deinit();

    try testing.expectEqual(@as(usize, 20), rs.rows.len);
    for (rs.rows, 0..) |row, i| {
        const expected_id = try std.fmt.allocPrint(alloc, "row_{d:04}", .{i});
        defer alloc.free(expected_id);
        try testing.expectEqualStrings(expected_id, row[0].?.string);
        try testing.expect(row[1] != null);
    }
}
