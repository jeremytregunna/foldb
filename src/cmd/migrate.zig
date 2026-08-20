/// foldb-migrate: upgrade log segment files from old format (25-byte headers)
/// to new format (29-byte headers with header_crc).
///
/// Usage: foldb-migrate --path <log_dir>
///
/// Scans all .seg files in the given directory. For each file:
///   - If already in new format (header CRC validates), skips it.
///   - If in old format, rewrites the file with 29-byte headers.
///   - Sealed segments get their index offsets recomputed.
///
/// The tool is idempotent — running it on already-migrated files is a no-op.
const std = @import("std");
const log = @import("log.zig");

const crc = log.crc;
const LogEntryHeader = log.LogEntryHeader;
const SegmentHeader = log.SegmentHeader;
const SegmentFooter = log.SegmentFooter;
const IndexEntry = log.IndexEntry;

const OLD_HEADER_SIZE: u32 = 25;
const NEW_HEADER_SIZE: u32 = 29;
const SEG_HEADER_SIZE: u32 = 64;
const SEG_FOOTER_SIZE: u32 = 64;

const help =
    \\Usage: foldb-migrate --path <log_dir> [--dry-run]
    \\
    \\Upgrade log segment files from old format (25-byte entry headers) to
    \\new format (29-byte entry headers with header_crc).
    \\
    \\Options:
    \\  --path <dir>     Log directory containing .seg files
    \\  --dry-run        Report what would be done without writing
    \\  -h, --help       Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;

    var path: ?[]const u8 = null;
    var dry_run = false;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // skip argv[0]

    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.log.info(help, .{});
            return;
        } else if (std.mem.eql(u8, arg, "--path")) {
            path = it.next() orelse {
                std.log.err("--path requires an argument", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            dry_run = true;
        } else {
            std.log.err("unknown argument '{s}'", .{arg});
            std.log.info(help, .{});
            std.process.exit(1);
        }
    }

    const log_dir = path orelse {
        std.log.info(help, .{});
        std.process.exit(1);
    };

    std.log.info("Scanning {s} for .seg files...", .{log_dir});
    if (dry_run) std.log.info("(dry run — no files will be modified)\n", .{});

    var migrated: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;

    // Open the directory and iterate over .seg files.
    const null_dir = try toNullZ(alloc, log_dir);
    defer alloc.free(null_dir);

    const raw_dir_fd = std.os.linux.open(null_dir.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    const dir_fd_i: isize = @bitCast(raw_dir_fd);
    if (dir_fd_i < 0) {
        std.log.err("cannot open directory '{s}'", .{log_dir});
        std.process.exit(1);
    }
    const dir_fd: std.posix.fd_t = @intCast(dir_fd_i);
    defer _ = std.os.linux.close(@intCast(dir_fd));

    var buf: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const ret = std.os.linux.getdents64(@intCast(dir_fd), &buf, buf.len);
        const n: isize = @bitCast(ret);
        if (n <= 0) break;

        var i: usize = 0;
        while (i < @as(usize, @intCast(n))) {
            const dent: *const std.os.linux.dirent64 = @ptrCast(@alignCast(buf[i..].ptr));
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&dent.name)));
            const DT_REG: u8 = 8;
            if (dent.type == DT_REG and std.mem.endsWith(u8, name, ".seg")) {
                const full_path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ log_dir, name });
                defer alloc.free(full_path);

                const result = migrateFile(alloc, full_path, dry_run);
                switch (result.status) {
                    .migrated => {
                        migrated += 1;
                        if (dry_run) {
                            std.log.info("  would migrate: {s}", .{name});
                        } else {
                            std.log.info("  migrated: {s}", .{name});
                        }
                    },
                    .already_new => {
                        skipped += 1;
                        std.log.info("  already new format: {s}", .{name});
                    },
                    .empty => {
                        skipped += 1;
                        std.log.info("  empty (header only): {s}", .{name});
                    },
                    .failed => {
                        failed += 1;
                        std.log.err("  FAILED: {s} — {s}", .{ name, result.error_name });
                    },
                }
            }
            i += dent.reclen;
        }
    }

    std.log.info("\nDone: {d} migrated, {d} skipped, {d} failed.", .{ migrated, skipped, failed });
    if (failed > 0) std.process.exit(1);
}

const MigrateResult = struct {
    status: enum { migrated, already_new, empty, failed },
    error_name: []const u8 = "",
};

fn migrateFile(alloc: std.mem.Allocator, path: []const u8, dry_run: bool) MigrateResult {
    const null_path = toNullZ(alloc, path) catch return .{ .status = .failed, .error_name = "OutOfMemory" };
    defer alloc.free(null_path);

    // Open the file.
    const raw_fd = std.os.linux.open(null_path.ptr, .{ .ACCMODE = .RDWR }, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return .{ .status = .failed, .error_name = "FileOpenError" };
    const fd: std.posix.fd_t = @intCast(fd_i);
    defer _ = std.os.linux.close(@intCast(fd));

    // Read and validate segment header.
    var seg_hdr_buf: [SEG_HEADER_SIZE]u8 align(@alignOf(SegmentHeader)) = undefined;
    if (readFull(fd, &seg_hdr_buf) != seg_hdr_buf.len) return .{ .status = .failed, .error_name = "InvalidSegment" };
    const seg_header = @as(*const SegmentHeader, @ptrCast(@alignCast(&seg_hdr_buf))).*;
    if (!seg_header.is_valid()) return .{ .status = .failed, .error_name = "CorruptSegmentHeader" };

    const file_size: i64 = @bitCast(std.os.linux.lseek(@intCast(fd), 0, std.os.linux.SEEK.END));
    if (file_size < 0) return .{ .status = .failed, .error_name = "SeekError" };
    if (file_size == @as(i64, @intCast(SEG_HEADER_SIZE))) return .{ .status = .empty };

    // Detect format by trying to parse the first entry header.
    const is_new_format = detectNewFormat(fd);
    if (is_new_format) return .{ .status = .already_new };

    if (dry_run) return .{ .status = .migrated };

    // Read all entries in old format.
    const entries = readOldFormatEntries(fd, file_size, alloc) catch return .{ .status = .failed, .error_name = "ReadError" };
    defer {
        for (entries) |e| alloc.free(e.payload);
        alloc.free(entries);
    }

    // Check if sealed (valid footer at end).
    const is_sealed = detectSealed(fd, file_size);

    // Write new format to a temp file, then rename.
    const tmp_path = std.fmt.allocPrint(alloc, "{s}.migrating", .{path}) catch return .{ .status = .failed, .error_name = "OutOfMemory" };
    defer alloc.free(tmp_path);
    const null_tmp = toNullZ(alloc, tmp_path) catch return .{ .status = .failed, .error_name = "OutOfMemory" };
    defer alloc.free(null_tmp);

    const raw_tmp_fd = std.os.linux.open(null_tmp.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    const tmp_fd_i: isize = @bitCast(raw_tmp_fd);
    if (tmp_fd_i < 0) return .{ .status = .failed, .error_name = "FileOpenError" };
    const tmp_fd: std.posix.fd_t = @intCast(tmp_fd_i);
    defer _ = std.os.linux.close(@intCast(tmp_fd));

    // Write segment header.
    writeFull(tmp_fd, &seg_hdr_buf) catch return .{ .status = .failed, .error_name = "WriteError" };

    // Write entries with new headers.
    var offset: u64 = SEG_HEADER_SIZE;
    for (entries) |e| {
        var new_header = LogEntryHeader.init(e.seq, e.epoch, e.kind, e.payload);
        var hdr_buf: [NEW_HEADER_SIZE]u8 = undefined;
        new_header.serialize_to(&hdr_buf);
        writeFull(tmp_fd, &hdr_buf) catch return .{ .status = .failed, .error_name = "WriteError" };
        writeFull(tmp_fd, e.payload) catch return .{ .status = .failed, .error_name = "WriteError" };
        offset += NEW_HEADER_SIZE + @as(u64, @intCast(e.payload.len));
    }

    if (is_sealed) {
        // Write index with updated offsets.
        var idx_offset: u64 = SEG_HEADER_SIZE;
        for (entries) |e| {
            var ie = IndexEntry{ .seq = e.seq, .file_offset = idx_offset };
            var ie_buf: [IndexEntry.entry_size]u8 = undefined;
            ie.serialize_to(&ie_buf);
            writeFull(tmp_fd, &ie_buf) catch return .{ .status = .failed, .error_name = "WriteError" };
            idx_offset += NEW_HEADER_SIZE + @as(u64, @intCast(e.payload.len));
        }

        // Write footer.
        const footer = SegmentFooter.init(@intCast(entries.len), entries[entries.len - 1].seq, offset);
        var footer_buf: [SEG_FOOTER_SIZE]u8 = undefined;
        footer.serialize_to(&footer_buf);
        writeFull(tmp_fd, &footer_buf) catch return .{ .status = .failed, .error_name = "WriteError" };
    }

    // Sync temp file.
    _ = std.os.linux.fdatasync(@intCast(tmp_fd));
    _ = std.os.linux.close(@intCast(tmp_fd));

    // Rename over original.
    const rename_result = std.os.linux.rename(null_tmp.ptr, null_path.ptr);
    if (rename_result < 0) {
        _ = std.os.linux.unlink(null_tmp.ptr);
        return .{ .status = .failed, .error_name = "RenameError" };
    }

    return .{ .status = .migrated };
}

/// Returns true if the first entry in the file uses the new 29-byte header format
/// (header_crc validates).
fn detectNewFormat(fd: std.posix.fd_t) bool {
    var hdr_buf: [NEW_HEADER_SIZE]u8 = undefined;
    const n = std.os.linux.pread(@intCast(fd), &hdr_buf, NEW_HEADER_SIZE, SEG_HEADER_SIZE);
    if (n != NEW_HEADER_SIZE) return false;
    const header = LogEntryHeader.deserialize_from(&hdr_buf) catch return false;
    return header.verify_header_crc();
}

/// Returns true if the file has a valid sealed footer.
fn detectSealed(fd: std.posix.fd_t, file_size: i64) bool {
    if (file_size < @as(i64, @intCast(SEG_HEADER_SIZE + SEG_FOOTER_SIZE))) return false;
    const footer_pos: i64 = file_size - @as(i64, @intCast(SEG_FOOTER_SIZE));
    var footer_buf: [SEG_FOOTER_SIZE]u8 = undefined;
    const n = std.os.linux.pread(@intCast(fd), &footer_buf, SEG_FOOTER_SIZE, footer_pos);
    if (n != SEG_FOOTER_SIZE) return false;
    _ = SegmentFooter.deserialize_from(&footer_buf) catch return false;
    return true;
}

const OldEntry = struct {
    seq: u64,
    epoch: u64,
    kind: log.EntryKind,
    payload: []u8,
};

/// Read all entries from an old-format (25-byte header) segment file.
fn readOldFormatEntries(fd: std.posix.fd_t, file_size: i64, alloc: std.mem.Allocator) ![]OldEntry {
    var entries: std.ArrayList(OldEntry) = .empty;
    errdefer {
        for (entries.items) |e| alloc.free(e.payload);
        entries.deinit(alloc);
    }

    var offset: i64 = @intCast(SEG_HEADER_SIZE);
    const end: i64 = if (detectSealed(fd, file_size)) file_size - @as(i64, @intCast(SEG_FOOTER_SIZE)) else file_size;
    // For sealed files, we also need to stop before the index.
    // We'll detect this by checking if remaining bytes make sense.

    while (offset < end) {
        var hdr_buf: [OLD_HEADER_SIZE]u8 = undefined;
        const n = std.os.linux.pread(@intCast(fd), &hdr_buf, OLD_HEADER_SIZE, offset);
        if (n != OLD_HEADER_SIZE) break;

        const seq = std.mem.readInt(u64, hdr_buf[0..8], .little);
        const epoch = std.mem.readInt(u64, hdr_buf[8..16], .little);
        const kind_byte = hdr_buf[16];
        const payload_len = std.mem.readInt(u32, hdr_buf[17..21], .little);

        const kind = log.EntryKind.fromByte(kind_byte) catch break;
        if (payload_len > log.payload_len_max) break;

        // For sealed segments, stop if we've entered the index/footer region.
        // Index entries are 16 bytes each; if payload_len would take us past
        // the file end minus footer, we've hit the index.
        if (offset + @as(i64, @intCast(OLD_HEADER_SIZE)) + @as(i64, @intCast(payload_len)) > end) break;

        const payload = try alloc.alloc(u8, payload_len);
        errdefer alloc.free(payload);
        if (payload_len > 0) {
            const pn = std.os.linux.pread(@intCast(fd), payload.ptr, payload_len, offset + @as(i64, @intCast(OLD_HEADER_SIZE)));
            if (pn != payload_len) {
                alloc.free(payload);
                break;
            }
        }

        try entries.append(alloc, .{ .seq = seq, .epoch = epoch, .kind = kind, .payload = payload });
        offset += @as(i64, @intCast(OLD_HEADER_SIZE)) + @as(i64, @intCast(payload_len));
    }

    return try entries.toOwnedSlice(alloc);
}

fn readFull(fd: std.posix.fd_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.os.linux.read(@intCast(fd), buf[total..].ptr, buf.len - total);
        const ni: isize = @bitCast(n);
        if (ni <= 0) break;
        total += @intCast(ni);
    }
    return total;
}

fn writeFull(fd: std.posix.fd_t, buf: []const u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = std.os.linux.write(@intCast(fd), buf[total..].ptr, buf.len - total);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.WriteError;
        total += @intCast(ni);
    }
}

fn toNullZ(alloc: std.mem.Allocator, s: []const u8) ![:0]u8 {
    const buf = try alloc.allocSentinel(u8, s.len, 0);
    @memcpy(buf[0..s.len], s);
    return buf;
}
