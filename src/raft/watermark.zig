/// Commit watermark: persists the highest committed sequence number to stable
/// storage. On recovery, if the log head is below the watermark, the node knows
/// it has lost committed data and must enter degraded mode (refuse to vote or
/// propose until resynced from peers).
///
/// On-disk layout (20 bytes):
///   commit_index: u64 (LE)
///   commit_term:  u64 (LE)
///   crc:          u32 (CRC32 of first 16 bytes)
const std = @import("std");
const crc_mod = @import("log.zig");

const assert = std.debug.assert;

const FILE_SIZE: u32 = 20;
const FILENAME = "commit_watermark.bin";

comptime {
    assert(FILE_SIZE == 8 + 8 + 4);
}

pub const Watermark = struct {
    commit_index: u64,
    commit_term: u64,
};

fn buildPath(dir: []const u8, allocator: std.mem.Allocator) ![]u8 {
    assert(dir.len > 0);
    return std.mem.concat(allocator, u8, &.{ dir, "/", FILENAME });
}

fn toNullZ(path: []const u8, allocator: std.mem.Allocator) ![:0]u8 {
    const buf = try allocator.allocSentinel(u8, path.len, 0);
    @memcpy(buf[0..path.len], path);
    return buf;
}

pub fn load(dir: []const u8, allocator: std.mem.Allocator) !?Watermark {
    assert(dir.len > 0);

    const path = try buildPath(dir, allocator);
    defer allocator.free(path);
    const z = try toNullZ(path, allocator);
    defer allocator.free(z);

    const raw_fd = std.os.linux.open(z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return null; // No watermark yet — first start.
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));

    var buf: [FILE_SIZE]u8 = undefined;
    const n_raw = std.os.linux.read(@intCast(fd), &buf, FILE_SIZE);
    const n: isize = @bitCast(n_raw);
    if (n != FILE_SIZE) return null;

    const stored_crc = std.mem.readInt(u32, buf[16..20], .little);
    const computed = crc_mod.crc32c(buf[0..16]);
    if (stored_crc != computed) return null; // Corrupt — treat as absent.

    const commit_index = std.mem.readInt(u64, buf[0..8], .little);
    const commit_term = std.mem.readInt(u64, buf[8..16], .little);
    return Watermark{ .commit_index = commit_index, .commit_term = commit_term };
}

pub fn save(dir: []const u8, allocator: std.mem.Allocator, commit_index: u64, commit_term: u64) !void {
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
    std.mem.writeInt(u64, buf[0..8], commit_index, .little);
    std.mem.writeInt(u64, buf[8..16], commit_term, .little);
    const c = crc_mod.crc32c(buf[0..16]);
    std.mem.writeInt(u32, buf[16..20], c, .little);

    const w: isize = @bitCast(std.os.linux.write(@intCast(fd), &buf, FILE_SIZE));
    if (w != FILE_SIZE) return error.WriteError;

    const s: isize = @bitCast(std.os.linux.fsync(@intCast(fd)));
    if (s < 0) return error.FsyncError;
}
