const std = @import("std");
const object_store = @import("object_store.zig");
const ObjectStore = object_store.ObjectStore;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const S3Config = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8,
    endpoint_ip: [4]u8,
    endpoint_port: u16,
    bucket: []const u8,
    alloc: std.mem.Allocator,
};

pub const S3ObjectStore = struct {
    config: S3Config,

    const vtable = ObjectStore.VTable{
        .put_fn = putImpl,
        .get_fn = getImpl,
        .delete_fn = deleteImpl,
        .exists_fn = existsImpl,
        .list_fn = listImpl,
    };

    pub fn init(config: S3Config) S3ObjectStore {
        return .{ .config = config };
    }

    pub fn objectStore(self: *S3ObjectStore) ObjectStore {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn putImpl(ptr: *anyopaque, key: []const u8, data: []const u8) anyerror!void {
        const self: *S3ObjectStore = @ptrCast(@alignCast(ptr));
        const alloc = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        var body_hash: [64]u8 = undefined;
        sha256hex(data, &body_hash);

        const path = try std.fmt.allocPrint(alloc, "/{s}/{s}", .{ self.config.bucket, key });
        defer alloc.free(path);

        const host = try formatHost(alloc, self.config.endpoint_ip, self.config.endpoint_port);
        defer alloc.free(host);

        const auth = try buildAuth(alloc, self.config, "PUT", path, host, &ts_buf, &date_buf, &body_hash, data.len);
        defer alloc.free(auth);

        const request = try std.fmt.allocPrint(alloc, "PUT {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\n\r\n", .{ path, host, data.len, &body_hash, &ts_buf, auth });
        defer alloc.free(request);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));

        try sendAll(fd, request);
        try sendAll(fd, data);

        const resp = try readResponse(alloc, fd);
        defer alloc.free(resp);

        const status = parseStatus(resp);
        if (status < 200 or status >= 300) return error.S3PutFailed;
    }

    fn getImpl(ptr: *anyopaque, key: []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *S3ObjectStore = @ptrCast(@alignCast(ptr));
        const cfg_alloc = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        const path = try std.fmt.allocPrint(cfg_alloc, "/{s}/{s}", .{ self.config.bucket, key });
        defer cfg_alloc.free(path);

        const host = try formatHost(cfg_alloc, self.config.endpoint_ip, self.config.endpoint_port);
        defer cfg_alloc.free(host);

        const auth = try buildAuth(cfg_alloc, self.config, "GET", path, host, &ts_buf, &date_buf, empty_hash[0..64], 0);
        defer cfg_alloc.free(auth);

        const request = try std.fmt.allocPrint(cfg_alloc, "GET {s} HTTP/1.1\r\nHost: {s}\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\nConnection: close\r\n\r\n", .{ path, host, empty_hash, &ts_buf, auth });
        defer cfg_alloc.free(request);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));

        try sendAll(fd, request);

        const resp = try readResponse(cfg_alloc, fd);
        defer cfg_alloc.free(resp);

        const status = parseStatus(resp);
        if (status == 404) return error.KeyNotFound;
        if (status < 200 or status >= 300) return error.S3GetFailed;

        const body = extractBody(resp);
        return alloc.dupe(u8, body);
    }

    fn deleteImpl(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *S3ObjectStore = @ptrCast(@alignCast(ptr));
        const alloc = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        const path = try std.fmt.allocPrint(alloc, "/{s}/{s}", .{ self.config.bucket, key });
        defer alloc.free(path);

        const host = try formatHost(alloc, self.config.endpoint_ip, self.config.endpoint_port);
        defer alloc.free(host);

        const auth = try buildAuth(alloc, self.config, "DELETE", path, host, &ts_buf, &date_buf, empty_hash[0..64], 0);
        defer alloc.free(auth);

        const request = try std.fmt.allocPrint(alloc, "DELETE {s} HTTP/1.1\r\nHost: {s}\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\nConnection: close\r\n\r\n", .{ path, host, empty_hash, &ts_buf, auth });
        defer alloc.free(request);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));

        try sendAll(fd, request);

        const resp = try readResponse(alloc, fd);
        defer alloc.free(resp);

        const status = parseStatus(resp);
        if (status < 200 or status >= 300) return error.S3DeleteFailed;
    }

    fn existsImpl(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *S3ObjectStore = @ptrCast(@alignCast(ptr));
        const alloc = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        const path = try std.fmt.allocPrint(alloc, "/{s}/{s}", .{ self.config.bucket, key });
        defer alloc.free(path);

        const host = try formatHost(alloc, self.config.endpoint_ip, self.config.endpoint_port);
        defer alloc.free(host);

        const auth = try buildAuth(alloc, self.config, "HEAD", path, host, &ts_buf, &date_buf, empty_hash[0..64], 0);
        defer alloc.free(auth);

        const request = try std.fmt.allocPrint(alloc, "HEAD {s} HTTP/1.1\r\nHost: {s}\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\nConnection: close\r\n\r\n", .{ path, host, empty_hash, &ts_buf, auth });
        defer alloc.free(request);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));

        try sendAll(fd, request);

        const resp = try readResponse(alloc, fd);
        defer alloc.free(resp);

        const status = parseStatus(resp);
        return status == 200;
    }

    fn listImpl(ptr: *anyopaque, prefix: []const u8, alloc: std.mem.Allocator) anyerror![][]const u8 {
        const self: *S3ObjectStore = @ptrCast(@alignCast(ptr));
        const cfg_alloc = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        const path = try std.fmt.allocPrint(cfg_alloc, "/{s}?list-type=2&prefix={s}", .{ self.config.bucket, prefix });
        defer cfg_alloc.free(path);

        const host = try formatHost(cfg_alloc, self.config.endpoint_ip, self.config.endpoint_port);
        defer cfg_alloc.free(host);

        // For signing, path without query string
        const sign_path = try std.fmt.allocPrint(cfg_alloc, "/{s}", .{self.config.bucket});
        defer cfg_alloc.free(sign_path);

        const auth = try buildAuth(cfg_alloc, self.config, "GET", sign_path, host, &ts_buf, &date_buf, empty_hash[0..64], 0);
        defer cfg_alloc.free(auth);

        const request = try std.fmt.allocPrint(cfg_alloc, "GET {s} HTTP/1.1\r\nHost: {s}\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\nConnection: close\r\n\r\n", .{ path, host, empty_hash, &ts_buf, auth });
        defer cfg_alloc.free(request);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));

        try sendAll(fd, request);

        const resp = try readResponse(cfg_alloc, fd);
        defer cfg_alloc.free(resp);

        const status = parseStatus(resp);
        if (status < 200 or status >= 300) return error.S3ListFailed;

        const body = extractBody(resp);
        return parseXmlKeys(body, alloc);
    }
};

// ---- helpers ----

fn connect(ip: [4]u8, port: u16) !std.posix.fd_t {
    const AF_INET: u32 = 2;
    const SOCK_STREAM: u32 = 1;
    const SOCK_CLOEXEC: u32 = 0o2000000;

    const raw_fd = std.os.linux.socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0);
    const fd_i: isize = @bitCast(raw_fd);
    if (fd_i < 0) return error.SocketError;
    const fd: std.posix.fd_t = @intCast(fd_i);

    var addr_buf: [16]u8 = std.mem.zeroes([16]u8);
    std.mem.writeInt(u16, addr_buf[0..2], 2, .little);
    std.mem.writeInt(u16, addr_buf[2..4], port, .big);
    addr_buf[4] = ip[0];
    addr_buf[5] = ip[1];
    addr_buf[6] = ip[2];
    addr_buf[7] = ip[3];

    const rc = std.os.linux.connect(fd, @ptrCast(&addr_buf), 16);
    const rc_i: isize = @bitCast(rc);
    if (rc_i < 0) return error.ConnectError;

    return fd;
}

fn sendAll(fd: std.posix.fd_t, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = std.os.linux.write(@intCast(fd), data.ptr + sent, data.len - sent);
        const ni: isize = @bitCast(n);
        if (ni <= 0) return error.SendError;
        sent += @intCast(ni);
    }
}

fn readResponse(alloc: std.mem.Allocator, fd: std.posix.fd_t) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.os.linux.read(@intCast(fd), &tmp, tmp.len);
        const ni: isize = @bitCast(n);
        if (ni < 0) return error.ReadError;
        if (ni == 0) break;
        try buf.appendSlice(alloc, tmp[0..@intCast(ni)]);
    }
    return buf.toOwnedSlice(alloc);
}

fn parseStatus(resp: []const u8) u16 {
    // "HTTP/1.1 200 OK\r\n..."
    if (resp.len < 12) return 0;
    const code_str = resp[9..12];
    return std.fmt.parseInt(u16, code_str, 10) catch 0;
}

fn extractBody(resp: []const u8) []const u8 {
    if (std.mem.indexOf(u8, resp, "\r\n\r\n")) |pos| {
        return resp[pos + 4 ..];
    }
    return &.{};
}

fn parseXmlKeys(xml: []const u8, alloc: std.mem.Allocator) ![][]const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (keys.items) |k| alloc.free(k);
        keys.deinit(alloc);
    }
    var pos: usize = 0;
    while (pos < xml.len) {
        const open_tag = "<Key>";
        const close_tag = "</Key>";
        const start = std.mem.indexOfPos(u8, xml, pos, open_tag) orelse break;
        const key_start = start + open_tag.len;
        const end = std.mem.indexOfPos(u8, xml, key_start, close_tag) orelse break;
        const key = try alloc.dupe(u8, xml[key_start..end]);
        try keys.append(alloc, key);
        pos = end + close_tag.len;
    }
    return keys.toOwnedSlice(alloc);
}

fn formatHost(alloc: std.mem.Allocator, ip: [4]u8, port: u16) ![]u8 {
    return std.fmt.allocPrint(alloc, "{d}.{d}.{d}.{d}:{d}", .{ ip[0], ip[1], ip[2], ip[3], port });
}

fn getTimestamp(ts_out: *[16]u8, date_out: *[8]u8) void {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
    const unix_secs: i64 = ts.sec;
    const secs = if (unix_secs >= 0) @as(u64, @intCast(unix_secs)) else 0;

    const year, const month, const day, const hour, const min, const sec = unixToDateTime(secs);

    _ = std.fmt.bufPrint(ts_out, "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z", .{
        year, month, day, hour, min, sec,
    }) catch {
        @memcpy(ts_out, "19700101T000000Z");
    };
    _ = std.fmt.bufPrint(date_out, "{d:0>4}{d:0>2}{d:0>2}", .{ year, month, day }) catch {
        @memcpy(date_out, "19700101");
    };
}

fn unixToDateTime(unix_secs: u64) struct { u64, u64, u64, u64, u64, u64 } {
    const SECS_PER_MIN: u64 = 60;
    const SECS_PER_HOUR: u64 = 3600;
    const SECS_PER_DAY: u64 = 86400;

    const sec = unix_secs % SECS_PER_MIN;
    const min = (unix_secs / SECS_PER_MIN) % 60;
    const hour = (unix_secs / SECS_PER_HOUR) % 24;

    var days = unix_secs / SECS_PER_DAY;
    var year: u64 = 1970;
    while (true) {
        const days_in_year: u64 = if (isLeap(year)) 366 else 365;
        if (days < days_in_year) break;
        days -= days_in_year;
        year += 1;
    }
    const leap = isLeap(year);
    const month_days = [_]u64{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var month: u64 = 1;
    for (month_days) |md| {
        if (days < md) break;
        days -= md;
        month += 1;
    }
    const day = days + 1;
    return .{ year, month, day, hour, min, sec };
}

fn isLeap(y: u64) bool {
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
}

fn sha256hex(data: []const u8, out: *[64]u8) void {
    var hash: [32]u8 = undefined;
    Sha256.hash(data, &hash, .{});
    _ = std.fmt.bufPrint(out, "{}", .{std.fmt.fmtSliceHexLower(&hash)}) catch unreachable;
}

fn hmacSha256(key: []const u8, data: []const u8, out: *[32]u8) void {
    HmacSha256.create(out, data, key);
}

fn buildAuth(
    alloc: std.mem.Allocator,
    config: S3Config,
    method: []const u8,
    path: []const u8,
    host: []const u8,
    timestamp: *const [16]u8,
    date: *const [8]u8,
    body_hash: []const u8,
    body_len: usize,
) ![]u8 {
    _ = body_len;

    // Canonical headers (sorted)
    const canonical_headers = try std.fmt.allocPrint(alloc, "host:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n", .{ host, body_hash, timestamp });
    defer alloc.free(canonical_headers);

    const signed_headers = "host;x-amz-content-sha256;x-amz-date";

    // Canonical request
    const canonical_request = try std.fmt.allocPrint(alloc, "{s}\n{s}\n\n{s}\n{s}\n{s}", .{ method, path, canonical_headers, signed_headers, body_hash });
    defer alloc.free(canonical_request);

    var cr_hash: [64]u8 = undefined;
    sha256hex(canonical_request, &cr_hash);

    // Credential scope
    const scope = try std.fmt.allocPrint(alloc, "{s}/{s}/s3/aws4_request", .{ date, config.region });
    defer alloc.free(scope);

    // String to sign
    const string_to_sign = try std.fmt.allocPrint(alloc, "AWS4-HMAC-SHA256\n{s}\n{s}\n{s}", .{ timestamp, scope, &cr_hash });
    defer alloc.free(string_to_sign);

    // Signing key
    var k_date: [32]u8 = undefined;
    var k_region: [32]u8 = undefined;
    var k_service: [32]u8 = undefined;
    var k_signing: [32]u8 = undefined;

    const key_prefix = try std.fmt.allocPrint(alloc, "AWS4{s}", .{config.secret_key});
    defer alloc.free(key_prefix);

    hmacSha256(key_prefix, date, &k_date);
    hmacSha256(&k_date, config.region, &k_region);
    hmacSha256(&k_region, "s3", &k_service);
    hmacSha256(&k_service, "aws4_request", &k_signing);

    var signature_raw: [32]u8 = undefined;
    hmacSha256(&k_signing, string_to_sign, &signature_raw);

    var sig_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&sig_hex, "{}", .{std.fmt.fmtSliceHexLower(&signature_raw)}) catch unreachable;

    const credential = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ config.access_key, scope });
    defer alloc.free(credential);

    return std.fmt.allocPrint(alloc, "AWS4-HMAC-SHA256 Credential={s}, SignedHeaders={s}, Signature={s}", .{ credential, signed_headers, &sig_hex });
}
