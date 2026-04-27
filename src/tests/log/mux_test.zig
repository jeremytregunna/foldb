/// Tests for LogMux: multi-log merge, ordering, deduplication, and wait.
const std = @import("std");
const testing = std.testing;
const log = @import("log.zig");

const Log = log.Log;
const LogMux = log.LogMux;
const LogEntry = log.LogEntry;
const Seq = log.Seq;

// ---- helpers ----------------------------------------------------------------

fn toNullZ(path: []const u8) ![:0]u8 {
    const buf = try std.heap.page_allocator.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
}

// Log directories are flat (segment + index files only, no subdirs).
fn removeDirFlat(path: []const u8) void {
    const null_path = toNullZ(path) catch return;
    defer std.heap.page_allocator.free(null_path);

    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
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
            const dent_ptr = @as(*const std.os.linux.dirent64, @ptrCast(@alignCast(buf[i..].ptr)));
            const reclen = dent_ptr.reclen;
            // name bytes start immediately after the fixed-size fields in the buffer
            const name_offset = @offsetOf(std.os.linux.dirent64, "name");
            const name: [:0]const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(&buf[i + name_offset])));
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const child = std.mem.concat(std.heap.page_allocator, u8, &.{ path, "/", name }) catch {
                    i += reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child);
                const child_z = toNullZ(child) catch {
                    i += reclen;
                    continue;
                };
                defer std.heap.page_allocator.free(child_z);
                _ = std.os.linux.unlink(child_z.ptr);
            }
            i += reclen;
        }
    }
    _ = std.os.linux.rmdir(null_path.ptr);
}

fn makeTempDir(suffix: []const u8) ![]const u8 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/mux_test_{s}_{d}", .{ suffix, ns });
}

/// Append a minimal txn_intent entry to a log at the next seq.
fn appendEntry(l: *Log, seq: Seq, payload: []const u8) !void {
    const entry = LogEntry.create(seq, 0, .txn_intent, payload);
    try l.append_entry_at(entry);
}

// ---- tests ------------------------------------------------------------------

test "LogMux: single log passthrough" {
    const dir = try makeTempDir("single");
    defer { removeDirFlat(dir); testing.allocator.free(dir); }

    var l = try Log.init(dir, 1, testing.allocator);
    defer l.deinit();

    try appendEntry(&l, 1, "hello");
    try appendEntry(&l, 2, "hello");

    const log_refs = try testing.allocator.alloc(*Log, 1);
    log_refs[0] = &l;
    var mux = LogMux.init(log_refs, testing.allocator);
    defer mux.deinit();

    const entries = try mux.read(1, 10, testing.allocator);
    defer { for (entries) |*e| e.deinit(testing.allocator); testing.allocator.free(entries); }

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(Seq, 1), entries[0].header.seq);
    try testing.expectEqual(@as(Seq, 2), entries[1].header.seq);
}

test "LogMux: two logs interleaved seqs merge in order" {
    const dir0 = try makeTempDir("il0");
    defer { removeDirFlat(dir0); testing.allocator.free(dir0); }
    const dir1 = try makeTempDir("il1");
    defer { removeDirFlat(dir1); testing.allocator.free(dir1); }

    var l0 = try Log.init(dir0, 1, testing.allocator);
    defer l0.deinit();
    var l1 = try Log.init(dir1, 1, testing.allocator);
    defer l1.deinit();

    // l0 has seqs 1, 3, 5 — l1 has seqs 2, 4, 6
    const p = "x";
    try appendEntry(&l0, 1, p);
    try appendEntry(&l1, 2, p);
    try appendEntry(&l0, 3, p);
    try appendEntry(&l1, 4, p);
    try appendEntry(&l0, 5, p);
    try appendEntry(&l1, 6, p);

    const log_refs = try testing.allocator.alloc(*Log, 2);
    log_refs[0] = &l0;
    log_refs[1] = &l1;
    var mux = LogMux.init(log_refs, testing.allocator);
    defer mux.deinit();

    const entries = try mux.read(1, 10, testing.allocator);
    defer { for (entries) |*e| e.deinit(testing.allocator); testing.allocator.free(entries); }

    try testing.expectEqual(@as(usize, 6), entries.len);
    for (entries, 0..) |e, i| {
        try testing.expectEqual(@as(Seq, i + 1), e.header.seq);
    }
}

test "LogMux: three logs one empty returns non-empty correctly" {
    const dir0 = try makeTempDir("te0");
    defer { removeDirFlat(dir0); testing.allocator.free(dir0); }
    const dir1 = try makeTempDir("te1");
    defer { removeDirFlat(dir1); testing.allocator.free(dir1); }
    const dir2 = try makeTempDir("te2");
    defer { removeDirFlat(dir2); testing.allocator.free(dir2); }

    var l0 = try Log.init(dir0, 1, testing.allocator);
    defer l0.deinit();
    var l1 = try Log.init(dir1, 1, testing.allocator); // empty
    defer l1.deinit();
    var l2 = try Log.init(dir2, 1, testing.allocator);
    defer l2.deinit();

    const p = "y";
    try appendEntry(&l0, 1, p);
    try appendEntry(&l2, 2, p);
    try appendEntry(&l0, 3, p);

    const log_refs = try testing.allocator.alloc(*Log, 3);
    log_refs[0] = &l0;
    log_refs[1] = &l1;
    log_refs[2] = &l2;
    var mux = LogMux.init(log_refs, testing.allocator);
    defer mux.deinit();

    const entries = try mux.read(1, 10, testing.allocator);
    defer { for (entries) |*e| e.deinit(testing.allocator); testing.allocator.free(entries); }

    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqual(@as(Seq, 1), entries[0].header.seq);
    try testing.expectEqual(@as(Seq, 2), entries[1].header.seq);
    try testing.expectEqual(@as(Seq, 3), entries[2].header.seq);
}

test "LogMux: same seq in two logs is deduplicated" {
    const dir0 = try makeTempDir("dup0");
    defer { removeDirFlat(dir0); testing.allocator.free(dir0); }
    const dir1 = try makeTempDir("dup1");
    defer { removeDirFlat(dir1); testing.allocator.free(dir1); }

    var l0 = try Log.init(dir0, 1, testing.allocator);
    defer l0.deinit();
    var l1 = try Log.init(dir1, 1, testing.allocator);
    defer l1.deinit();

    // Both logs have seq 1 (broadcast scenario)
    const p = "dup";
    try appendEntry(&l0, 1, p);
    try appendEntry(&l1, 1, p);
    try appendEntry(&l0, 2, p);

    const log_refs = try testing.allocator.alloc(*Log, 2);
    log_refs[0] = &l0;
    log_refs[1] = &l1;
    var mux = LogMux.init(log_refs, testing.allocator);
    defer mux.deinit();

    const entries = try mux.read(1, 10, testing.allocator);
    defer { for (entries) |*e| e.deinit(testing.allocator); testing.allocator.free(entries); }

    // seq 1 appears twice but must be returned once; seq 2 appears once
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(Seq, 1), entries[0].header.seq);
    try testing.expectEqual(@as(Seq, 2), entries[1].header.seq);
}

test "LogMux: read with max < total returns exactly max entries" {
    const dir0 = try makeTempDir("max0");
    defer { removeDirFlat(dir0); testing.allocator.free(dir0); }
    const dir1 = try makeTempDir("max1");
    defer { removeDirFlat(dir1); testing.allocator.free(dir1); }

    var l0 = try Log.init(dir0, 1, testing.allocator);
    defer l0.deinit();
    var l1 = try Log.init(dir1, 1, testing.allocator);
    defer l1.deinit();

    const p = "z";
    try appendEntry(&l0, 1, p);
    try appendEntry(&l1, 2, p);
    try appendEntry(&l0, 3, p);
    try appendEntry(&l1, 4, p);

    const log_refs = try testing.allocator.alloc(*Log, 2);
    log_refs[0] = &l0;
    log_refs[1] = &l1;
    var mux = LogMux.init(log_refs, testing.allocator);
    defer mux.deinit();

    const entries = try mux.read(1, 2, testing.allocator);
    defer { for (entries) |*e| e.deinit(testing.allocator); testing.allocator.free(entries); }

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(Seq, 1), entries[0].header.seq);
    try testing.expectEqual(@as(Seq, 2), entries[1].header.seq);
}

test "LogMux: from filter excludes earlier seqs" {
    const dir = try makeTempDir("from");
    defer { removeDirFlat(dir); testing.allocator.free(dir); }

    var l = try Log.init(dir, 1, testing.allocator);
    defer l.deinit();

    const p = "f";
    try appendEntry(&l, 1, p);
    try appendEntry(&l, 2, p);
    try appendEntry(&l, 3, p);

    const log_refs = try testing.allocator.alloc(*Log, 1);
    log_refs[0] = &l;
    var mux = LogMux.init(log_refs, testing.allocator);
    defer mux.deinit();

    const entries = try mux.read(2, 10, testing.allocator);
    defer { for (entries) |*e| e.deinit(testing.allocator); testing.allocator.free(entries); }

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(Seq, 2), entries[0].header.seq);
    try testing.expectEqual(@as(Seq, 3), entries[1].header.seq);
}
