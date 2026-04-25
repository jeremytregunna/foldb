/// Persistent Raft state: currentTerm and votedFor.
///
/// On-disk layout (20 bytes):
///   term:      u64 (LE)
///   voted_for: u64 (LE) — 0 means "none"
///   crc:       u32 (CRC32c of first 16 bytes)
const std = @import("std");
const crc_mod = @import("log.zig");
const types = @import("types.zig");

const assert = std.debug.assert;

pub const Term = types.Term;
pub const NodeId = @import("log.zig").NodeId;

const FILE_SIZE: u32 = 20;
const FILENAME = "raft_state.bin";

comptime {
    // term(8) + voted_for(8) + crc(4) = 20 bytes.
    assert(FILE_SIZE == 8 + 8 + 4);
}

fn buildPath(dir: []const u8, allocator: std.mem.Allocator) ![]u8 {
    assert(dir.len > 0);
    return std.mem.concat(allocator, u8, &.{ dir, "/", FILENAME });
}

fn toNullZ(path: []const u8, allocator: std.mem.Allocator) ![:0]u8 {
    const buf = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
}

pub const PersistentState = struct {
    term: Term,
    voted_for: ?NodeId,
};

pub fn load(dir: []const u8, allocator: std.mem.Allocator) !PersistentState {
    assert(dir.len > 0);

    const path = try buildPath(dir, allocator);
    defer allocator.free(path);
    const z = try toNullZ(path, allocator);
    defer allocator.free(z);

    const raw_fd = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return .{ .term = 0, .voted_for = null };
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));

    var buf: [FILE_SIZE]u8 = undefined;
    const n_raw = std.os.linux.read(@intCast(fd), &buf, FILE_SIZE);
    const n: isize = @bitCast(n_raw);
    if (n != FILE_SIZE) return .{ .term = 0, .voted_for = null };

    const stored_crc = std.mem.readInt(u32, buf[16..20], .little);
    const computed = crc_mod.crc32c(buf[0..16]);
    if (stored_crc != computed) return .{ .term = 0, .voted_for = null };

    const term = std.mem.readInt(u64, buf[0..8], .little);
    const vf_raw = std.mem.readInt(u64, buf[8..16], .little);
    return .{
        .term = term,
        .voted_for = if (vf_raw == 0) null else vf_raw,
    };
}

pub fn save(dir: []const u8, allocator: std.mem.Allocator, term: Term, voted_for: ?NodeId) !void {
    assert(dir.len > 0);

    const path = try buildPath(dir, allocator);
    defer allocator.free(path);
    const z = try toNullZ(path, allocator);
    defer allocator.free(z);

    const raw_fd = std.os.linux.open(
        z.ptr,
        .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true },
        0o644,
    );
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return error.FileOpenError;
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));

    var buf: [FILE_SIZE]u8 = undefined;
    std.mem.writeInt(u64, buf[0..8], term, .little);
    std.mem.writeInt(u64, buf[8..16], if (voted_for) |v| v else 0, .little);
    const c = crc_mod.crc32c(buf[0..16]);
    std.mem.writeInt(u32, buf[16..20], c, .little);

    const w: isize = @bitCast(std.os.linux.write(@intCast(fd), &buf, FILE_SIZE));
    if (w != FILE_SIZE) return error.WriteError;

    const s: isize = @bitCast(std.os.linux.fsync(@intCast(fd)));
    if (s < 0) return error.FsyncError;
}
