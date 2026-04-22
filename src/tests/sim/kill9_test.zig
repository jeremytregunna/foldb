/// Kill-9 mid-flush recovery test.
///
/// Simulates a crash that occurs while SSTableWriter.finish() is in progress —
/// the scenario where the OS kills the process after some blocks have been
/// written to disk but before the footer is finalized. This leaves a partial
/// (structurally invalid) .sst file on disk.
///
/// Recovery invariants on restart:
///   - loadSSTables silently skips files that fail SSTableReader.open
///     (FileTooSmall, InvalidMagic, InvalidFooter) — partial file is ignored
///   - all committed rows (both flushed to SSTables AND still in memtable at
///     crash time) are recovered via partition log replay — no data loss for
///     operations that were written to the log before the crash
///
/// The partial file is injected by writing raw junk bytes with a valid .sst
/// filename directly to the table directory after a successful flush — this
/// accurately models the on-disk state left by a mid-finish kill-9.
const std = @import("std");
const testing = std.testing;
const sim = @import("sim.zig");
const gateway_mod = @import("gateway.zig");
const storage_mod = @import("storage.zig");
const wl = sim.workload;

const Gateway = gateway_mod.Gateway;
const ColumnValue = gateway_mod.ColumnValue;

const PartialKind = enum { empty, truncated, wrong_magic };

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn makeTempDir(tag: []const u8, id: u64, alloc: std.mem.Allocator) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "/tmp/kill9_{s}_{d}", .{ tag, id });
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

/// Write a structurally invalid .sst file at `path` (simulates a partial write
/// from SSTableWriter.finish() interrupted by kill-9). Three flavours:
///   - empty: zero bytes (fails FileTooSmall)
///   - truncated header: 8 bytes of garbage (fails FileTooSmall)
///   - wrong magic: full-ish size but bad MAGIC (fails InvalidMagic)
fn writePartialSst(path: []const u8, kind: PartialKind) void {
    const zpath = std.heap.page_allocator.allocSentinel(u8, path.len, 0) catch return;
    defer std.heap.page_allocator.free(zpath);
    @memcpy(zpath[0..path.len], path);

    const raw_fd = std.os.linux.open(
        zpath.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
        0o644,
    );
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return;
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));

    switch (kind) {
        .empty => {}, // nothing written → FileTooSmall
        .truncated => {
            const junk = [_]u8{0xDE} ** 8;
            _ = std.os.linux.write(@intCast(fd), &junk, junk.len);
        },
        .wrong_magic => {
            // Write enough bytes to pass size check but with wrong magic bytes.
            // SSTableHeader is 64 B; SSTableFooter is 32 B; need at least 96 B.
            var blob = [_]u8{0xAB} ** 128;
            // Overwrite magic bytes at offset 0 with something invalid
            blob[0] = 'X';
            blob[1] = 'X';
            blob[2] = 'X';
            blob[3] = 'X';
            _ = std.os.linux.write(@intCast(fd), &blob, blob.len);
        },
    }
}

// ---------------------------------------------------------------------------
// Core test
// ---------------------------------------------------------------------------

fn runKill9Test(seed: u64, partial_kind: PartialKind, alloc: std.mem.Allocator) !void {
    var rng = sim.SimScheduler.init(seed);

    const dir = try makeTempDir("k9", seed, alloc);
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    // ── Phase 1: insert pre-crash rows, flush cleanly ──
    // Use page_allocator for the "crash" gateway — abandoned without deinit.
    {
        const gw = try Gateway.init(dir, std.heap.page_allocator, .{});
        try gw.applyDdl(wl.TABLE_DDL);
        const ins = (try gw.register(wl.INSERT_SQL)).hash;

        // Insert 10 rows and flush — these survive the crash.
        for (1..11) |i| {
            const val: i64 = rng.random().intRangeAtMost(i64, 100, 999);
            const params = [_]ColumnValue{ .{ .int64 = @intCast(i) }, .{ .int64 = val } };
            _ = try gw.execute(std.testing.io, ins, &params, &.{});
        }
        try gw.flushAll();

        // Insert 5 more rows into the memtable — these are lost on crash.
        for (11..16) |i| {
            const val: i64 = rng.random().intRangeAtMost(i64, 100, 999);
            const params = [_]ColumnValue{ .{ .int64 = @intCast(i) }, .{ .int64 = val } };
            _ = try gw.execute(std.testing.io, ins, &params, &.{});
        }

        // Simulate kill-9: inject a partial .sst file into the table directory
        // to represent SSTableWriter.finish() interrupted mid-write.
        // Table dir: {storage_dir}/p0/t1 (table_id=1, first CREATE TABLE).
        const partial_path = try std.fmt.allocPrint(
            std.heap.page_allocator,
            "{s}/p0/t1/L0_9999999999.sst",
            .{dir},
        );
        defer std.heap.page_allocator.free(partial_path);
        writePartialSst(partial_path, partial_kind);

        // Abandon without deinit — simulates kill-9.
    }

    // ── Phase 2: restart, verify all rows present and partial file ignored ──
    //
    // All 15 rows are recoverable: the gateway writes txn_intent entries to the
    // partition log before applying to storage, so log replay on restart picks up
    // all committed operations — both the flushed rows (1–10) and the memtable
    // rows (11–15). The partial .sst file is silently skipped by loadSSTables.
    {
        const gw = try Gateway.init(dir, alloc, .{});
        defer gw.deinit();

        const scan = (try gw.register(wl.SCAN_SQL)).hash;
        var rs = try gw.querySelect(scan, &.{}, &.{});
        defer rs.deinit();

        // All 15 rows recovered via log replay — no data loss for committed ops.
        try testing.expectEqual(@as(usize, 15), rs.rows.len);

        // All IDs in [1, 15] — no phantom rows from the corrupt partial file.
        for (rs.rows) |row| {
            const id = row[0].?.int64;
            try testing.expect(id >= 1 and id <= 15);
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "kill-9 mid-flush: empty partial file is skipped on restart" {
    try runKill9Test(1, .empty, testing.allocator);
}

test "kill-9 mid-flush: truncated partial file is skipped on restart" {
    try runKill9Test(42, .truncated, testing.allocator);
}

test "kill-9 mid-flush: wrong-magic partial file is skipped on restart" {
    try runKill9Test(99, .wrong_magic, testing.allocator);
}

test "kill-9 mid-flush: multi-seed, all partial file kinds" {
    const cases = [_]struct { seed: u64, kind: PartialKind }{
        .{ .seed = 7, .kind = .empty },
        .{ .seed = 13, .kind = .truncated },
        .{ .seed = 0xDEAD, .kind = .wrong_magic },
        .{ .seed = 0xBEEF, .kind = .empty },
        .{ .seed = 0x1234, .kind = .truncated },
    };
    for (cases) |c| {
        try runKill9Test(c.seed, c.kind, testing.allocator);
    }
}
