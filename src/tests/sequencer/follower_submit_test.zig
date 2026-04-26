/// Sequencer follower submission tests: validates Fix 2 (commitInner returns NotLeader
/// instead of asserting) and Fix 3 (awaitCommit returns error instead of asserting).
const std = @import("std");
const testing = std.testing;
const sequencer_mod = @import("sequencer.zig");

const Sequencer = sequencer_mod.Sequencer;
const PendingSubmit = sequencer_mod.PendingSubmit;
const SequencerError = sequencer_mod.SequencerError;

fn makeTempDir(suffix: []const u8) ![]const u8 {
    // SAFETY: clock_gettime fills ts before any field is read.
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
    const ns = @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
    return std.fmt.allocPrint(testing.allocator, "/tmp/follower_submit_{s}_{d}", .{ suffix, ns });
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

/// Build a sequencer that will not win an election because it has a peer it can never contact.
/// The high election timeout (500–1000 ms) ensures it stays in follower state throughout the test.
fn initFollower(dir: []const u8, alloc: std.mem.Allocator) !Sequencer {
    const peers = [_]sequencer_mod.PeerAddr{.{ .id = 2, .addr = "127.0.0.1:1" }};
    return Sequencer.init(dir, .{
        .node_id = 1,
        .partition_count = 1,
        .tick_interval_ms = 5,
        .election_timeout_min_ms = 500,
        .election_timeout_max_ms = 1000,
        .listen_port = 0,
        .peers = &peers,
    }, alloc);
}

test "follower submitBytes: returns NotLeader, does not panic" {
    // Before Fix 2, commitInner began with assert(self.raft.role == .leader),
    // which panicked in debug builds when a follower submitted a request.
    // After the fix, it returns SequencerError.NotLeader instead.
    const alloc = testing.allocator;
    const dir = try makeTempDir("notleader");
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    var seq = try initFollower(dir, alloc);
    defer seq.deinit();
    try seq.start();

    try testing.expect(!seq.isLeader());

    // SAFETY: submitBytes writes to pending before awaitCommit is called on the returned handle.
    var pending: PendingSubmit = undefined;
    const result = seq.submitBytes(&pending, "test_payload", 1, 1, .txn_intent).awaitCommit(null);
    try testing.expectError(SequencerError.NotLeader, result);
}

test "follower submitBytes: next_seq unchanged after NotLeader return" {
    // Before Fix 2, commitInner incremented next_seq and next_epoch BEFORE calling
    // raft.propose. If propose returned null (not leader), those counters were already
    // corrupted — permanently skipping sequence numbers and breaking the partition log
    // invariant. After the fix, counters advance only after a successful propose.
    const alloc = testing.allocator;
    const dir = try makeTempDir("seq_unchanged");
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    var seq = try initFollower(dir, alloc);
    defer seq.deinit();
    try seq.start();

    try testing.expect(!seq.isLeader());
    const seq_before = seq.next_seq;
    const epoch_before = seq.next_epoch;

    var pending: PendingSubmit = undefined;
    _ = seq.submitBytes(&pending, "test_payload", 1, 1, .txn_intent).awaitCommit(null) catch {};

    // Counters must be identical — the failed proposal must not advance them.
    try testing.expectEqual(seq_before, seq.next_seq);
    try testing.expectEqual(epoch_before, seq.next_epoch);
}

test "follower submitBytes: multiple submissions all return NotLeader" {
    // Verify consistent behaviour across multiple back-to-back submissions.
    const alloc = testing.allocator;
    const dir = try makeTempDir("multi_notleader");
    defer {
        removeDirRecursive(dir);
        alloc.free(dir);
    }

    var seq = try initFollower(dir, alloc);
    defer seq.deinit();
    try seq.start();

    try testing.expect(!seq.isLeader());
    const seq_before = seq.next_seq;

    for (1..4) |i| {
        var pending: PendingSubmit = undefined;
        const result = seq.submitBytes(&pending, "payload", 1, @intCast(i), .txn_intent).awaitCommit(null);
        try testing.expectError(SequencerError.NotLeader, result);
    }

    try testing.expectEqual(seq_before, seq.next_seq);
}
