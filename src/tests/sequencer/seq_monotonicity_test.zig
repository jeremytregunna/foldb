/// Sequencer seq monotonicity DST.
///
/// Property: for any sequence of commits on a single-node sequencer, the
/// assigned seq numbers are strictly monotonically increasing with no gaps.
///
/// This is the core invariant that Fix 2 (commitInner counter ordering)
/// must preserve. Before the fix, next_seq was incremented before raft.propose;
/// if propose returned null the counter advanced without writing an entry,
/// permanently gapping the partition log. This sweep drives many submission
/// counts across different seeds and asserts the invariant holds for each.
const std = @import("std");
const testing = std.testing;
const sequencer_mod = @import("sequencer.zig");

const Sequencer = sequencer_mod.Sequencer;
const PendingSubmit = sequencer_mod.PendingSubmit;

// ---------------------------------------------------------------------------
// Temp dir helpers
// ---------------------------------------------------------------------------

fn makeTempDir(seed: u64, alloc: std.mem.Allocator) ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) *% 1_000_000_000 +% @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(alloc, "/tmp/seq_mono_{d}_{d}", .{ seed, ns });
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
                const DT_DIR: u8 = 4;
                if (dent.type == DT_DIR) removeDirRecursive(child) else _ = std.os.linux.unlink(cz.ptr);
            }
            i += dent.reclen;
        }
    }
    _ = std.os.linux.rmdir(z.ptr);
}

// ---------------------------------------------------------------------------
// Core property check
// ---------------------------------------------------------------------------

/// Submit `n_entries` to a fresh single-node sequencer and verify:
/// 1. Every submission succeeds (single-node self-elects, propose never fails).
/// 2. The returned seqs are 1, 2, ..., n_entries (no gaps, no reuse).
/// 3. The partition log contains exactly those entries in order.
fn runMonotonicityCheck(seed: u64, n_entries: usize, alloc: std.mem.Allocator) !void {
    std.debug.assert(n_entries >= 1);
    std.debug.assert(n_entries <= 64);

    const dir = try makeTempDir(seed, alloc);
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    var seq = try Sequencer.init(dir, .{
        .node_id = 1,
        .partition_count = 1,
        .tick_interval_ms = 5,
        .election_timeout_min_ms = 10,
        .election_timeout_max_ms = 20,
    }, alloc);
    defer seq.deinit();
    try seq.start();

    // Single-node sequencer self-elects immediately; no need to wait.
    std.debug.assert(seq.isLeader());

    // Use seed to vary payload lengths (exercises the serialization path under
    // different data sizes without changing the monotonicity property).
    var prng = std.Random.Xoroshiro128.init(seed);
    const rand = prng.random();

    var assigned_seqs = try alloc.alloc(sequencer_mod.Seq, n_entries);
    defer alloc.free(assigned_seqs);

    for (0..n_entries) |i| {
        const payload_len: usize = 4 + rand.uintLessThan(usize, 60);
        const payload = try alloc.alloc(u8, payload_len);
        defer alloc.free(payload);
        rand.bytes(payload);

        // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.
        var pending: PendingSubmit = undefined;
        const result = try seq.submitBytes(
            &pending,
            payload,
            1,
            @intCast(i + 1),
            .txn_intent,
        ).awaitCommit(null);
        assigned_seqs[i] = result.seq;
    }

    // Assert: seqs are exactly 1..n_entries with no gaps or repeats.
    for (assigned_seqs, 0..) |s, i| {
        try testing.expectEqual(@as(sequencer_mod.Seq, i + 1), s);
    }

    // Assert: partition log contains every seq in order.
    const log = seq.partitionLog(0);
    const entries = try log.read(1, n_entries, alloc);
    defer {
        for (entries) |*e| e.deinit(alloc);
        alloc.free(entries);
    }
    try testing.expectEqual(n_entries, entries.len);
    for (entries, 0..) |e, i| {
        try testing.expectEqual(@as(sequencer_mod.Seq, i + 1), e.header.seq);
    }
}

// ---------------------------------------------------------------------------
// DST sweep
// ---------------------------------------------------------------------------

test "seq monotonicity: sweep across seeds and entry counts" {
    // For each seed, choose a different entry count (2–20 range, cycling).
    // This exercises commitInner under varying batch sizes and payload patterns.
    const alloc = testing.allocator;
    const n_seeds: u64 = 20;

    for (0..n_seeds) |s| {
        const seed: u64 = @as(u64, @intCast(s)) *% 0x9e3779b97f4a7c15;
        const n: usize = 2 + (s % 19);
        try runMonotonicityCheck(seed, n, alloc);
    }
}

test "seq monotonicity: idempotency dedup does not create gaps" {
    // If the same (client_id, client_seq) is submitted twice, the sequencer
    // returns the cached result and must not advance next_seq a second time.
    // Verifies that idempotency hits don't corrupt the counter.
    const alloc = testing.allocator;
    const dir = try makeTempDir(0xdeadbeef, alloc);
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    var seq = try Sequencer.init(dir, .{
        .node_id = 1,
        .partition_count = 1,
        .tick_interval_ms = 5,
        .election_timeout_min_ms = 10,
        .election_timeout_max_ms = 20,
    }, alloc);
    defer seq.deinit();
    try seq.start();

    std.debug.assert(seq.isLeader());

    // First submit: client_id=1, client_seq=1
    var pending1: PendingSubmit = undefined;
    const r1 = try seq.submitBytes(&pending1, "first", 1, 1, .txn_intent).awaitCommit(null);
    try testing.expectEqual(@as(sequencer_mod.Seq, 1), r1.seq);

    // Duplicate submit: same (client_id=1, client_seq=1) — idempotency hit.
    var pending2: PendingSubmit = undefined;
    const r2 = try seq.submitBytes(&pending2, "first", 1, 1, .txn_intent).awaitCommit(null);
    try testing.expectEqual(r1.seq, r2.seq); // same seq, cached result

    // New submit: client_seq=2 — must get seq=2, not seq=3 (no gap from dedup).
    var pending3: PendingSubmit = undefined;
    const r3 = try seq.submitBytes(&pending3, "second", 1, 2, .txn_intent).awaitCommit(null);
    try testing.expectEqual(@as(sequencer_mod.Seq, 2), r3.seq);

    // Partition log must have exactly seqs 1 and 2.
    const log = seq.partitionLog(0);
    const entries = try log.read(1, 4, alloc);
    defer {
        for (entries) |*e| e.deinit(alloc);
        alloc.free(entries);
    }
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(sequencer_mod.Seq, 1), entries[0].header.seq);
    try testing.expectEqual(@as(sequencer_mod.Seq, 2), entries[1].header.seq);
}
