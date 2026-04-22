const std = @import("std");
const object_store = @import("object_store.zig");
const ObjectStore = object_store.ObjectStore;

const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Sha256 = std.crypto.hash.sha2.Sha256;

/// How the bucket name appears in requests.
/// path:           Host: endpoint_host[:port]   URI: /{bucket}/{key}
/// virtual_hosted: Host: {bucket}.endpoint_host  URI: /{key}
pub const BucketStyle = enum { path, virtual_hosted };

pub const S3Config = struct {
    access_key: []const u8,
    secret_key: []const u8,
    region: []const u8,
    /// IPv4 address for the TCP connection.
    endpoint_ip: [4]u8,
    endpoint_port: u16,
    /// Hostname used in the Host header and AWS signing (e.g. "s3.amazonaws.com",
    /// "minio.local", "192.168.1.1"). May differ from endpoint_ip for virtual-hosted style.
    endpoint_host: []const u8,
    bucket: []const u8,
    /// path = S3-compatible / MinIO default; virtual_hosted = AWS S3 standard.
    bucket_style: BucketStyle = .path,
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
        const a = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        var body_hash: [64]u8 = undefined;
        sha256hex(data, &body_hash);

        const uri = try buildUri(a, &self.config, key);
        defer a.free(uri);
        const host = try buildHost(a, &self.config);
        defer a.free(host);
        const sign_uri = try buildSignUri(a, &self.config, key);
        defer a.free(sign_uri);

        const auth = try buildAuth(a, self.config, "PUT", sign_uri, host, "", &ts_buf, &date_buf, &body_hash);
        defer a.free(auth);

        const req = try std.fmt.allocPrint(a, "PUT {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: {d}\r\nContent-Type: application/octet-stream\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\n\r\n", .{ uri, host, data.len, &body_hash, &ts_buf, auth });
        defer a.free(req);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));
        try sendAll(fd, req);
        try sendAll(fd, data);

        const resp = try readResponse(a, fd);
        defer a.free(resp);
        if (parseStatus(resp) / 100 != 2) return error.S3PutFailed;
    }

    fn getImpl(ptr: *anyopaque, key: []const u8, alloc: std.mem.Allocator) anyerror![]u8 {
        const self: *S3ObjectStore = @ptrCast(@alignCast(ptr));
        const a = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        const uri = try buildUri(a, &self.config, key);
        defer a.free(uri);
        const host = try buildHost(a, &self.config);
        defer a.free(host);
        const sign_uri = try buildSignUri(a, &self.config, key);
        defer a.free(sign_uri);

        const auth = try buildAuth(a, self.config, "GET", sign_uri, host, "", &ts_buf, &date_buf, empty_hash[0..64]);
        defer a.free(auth);

        const req = try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: {s}\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\nConnection: close\r\n\r\n", .{ uri, host, empty_hash, &ts_buf, auth });
        defer a.free(req);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));
        try sendAll(fd, req);

        const resp = try readResponse(a, fd);
        defer a.free(resp);

        const status = parseStatus(resp);
        if (status == 404) return error.KeyNotFound;
        if (status / 100 != 2) return error.S3GetFailed;
        return alloc.dupe(u8, extractBody(resp));
    }

    fn deleteImpl(ptr: *anyopaque, key: []const u8) anyerror!void {
        const self: *S3ObjectStore = @ptrCast(@alignCast(ptr));
        const a = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        const uri = try buildUri(a, &self.config, key);
        defer a.free(uri);
        const host = try buildHost(a, &self.config);
        defer a.free(host);
        const sign_uri = try buildSignUri(a, &self.config, key);
        defer a.free(sign_uri);

        const auth = try buildAuth(a, self.config, "DELETE", sign_uri, host, "", &ts_buf, &date_buf, empty_hash[0..64]);
        defer a.free(auth);

        const req = try std.fmt.allocPrint(a, "DELETE {s} HTTP/1.1\r\nHost: {s}\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\nConnection: close\r\n\r\n", .{ uri, host, empty_hash, &ts_buf, auth });
        defer a.free(req);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));
        try sendAll(fd, req);

        const resp = try readResponse(a, fd);
        defer a.free(resp);
        if (parseStatus(resp) / 100 != 2) return error.S3DeleteFailed;
    }

    fn existsImpl(ptr: *anyopaque, key: []const u8) anyerror!bool {
        const self: *S3ObjectStore = @ptrCast(@alignCast(ptr));
        const a = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        const uri = try buildUri(a, &self.config, key);
        defer a.free(uri);
        const host = try buildHost(a, &self.config);
        defer a.free(host);
        const sign_uri = try buildSignUri(a, &self.config, key);
        defer a.free(sign_uri);

        const auth = try buildAuth(a, self.config, "HEAD", sign_uri, host, "", &ts_buf, &date_buf, empty_hash[0..64]);
        defer a.free(auth);

        const req = try std.fmt.allocPrint(a, "HEAD {s} HTTP/1.1\r\nHost: {s}\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\nConnection: close\r\n\r\n", .{ uri, host, empty_hash, &ts_buf, auth });
        defer a.free(req);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));
        try sendAll(fd, req);

        const resp = try readResponse(a, fd);
        defer a.free(resp);
        return parseStatus(resp) == 200;
    }

    fn listImpl(ptr: *anyopaque, prefix: []const u8, alloc: std.mem.Allocator) anyerror![][]const u8 {
        const self: *S3ObjectStore = @ptrCast(@alignCast(ptr));
        const a = self.config.alloc;

        var ts_buf: [16]u8 = undefined;
        var date_buf: [8]u8 = undefined;
        getTimestamp(&ts_buf, &date_buf);

        const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

        // Canonical query string (params sorted alphabetically).
        const query = try std.fmt.allocPrint(a, "list-type=2&prefix={s}", .{prefix});
        defer a.free(query);

        // Full request URI includes query; signing URI is path only.
        const sign_uri = try buildSignUri(a, &self.config, "");
        defer a.free(sign_uri);
        // sign_uri for list: path style = "/{bucket}", vhosted = "/"
        const list_uri = try std.fmt.allocPrint(a, "{s}?{s}", .{ sign_uri, query });
        defer a.free(list_uri);

        const host = try buildHost(a, &self.config);
        defer a.free(host);

        const auth = try buildAuth(a, self.config, "GET", sign_uri, host, query, &ts_buf, &date_buf, empty_hash[0..64]);
        defer a.free(auth);

        const req = try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: {s}\r\nx-amz-content-sha256: {s}\r\nx-amz-date: {s}\r\nAuthorization: {s}\r\nConnection: close\r\n\r\n", .{ list_uri, host, empty_hash, &ts_buf, auth });
        defer a.free(req);

        const fd = try connect(self.config.endpoint_ip, self.config.endpoint_port);
        defer _ = std.os.linux.close(@intCast(fd));
        try sendAll(fd, req);

        const resp = try readResponse(a, fd);
        defer a.free(resp);
        if (parseStatus(resp) / 100 != 2) return error.S3ListFailed;

        return parseXmlKeys(extractBody(resp), alloc);
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

/// Build the Host header value. Virtual-hosted prepends the bucket as a subdomain.
/// Port is omitted for standard HTTP (80) and HTTPS (443) ports.
fn buildHost(alloc: std.mem.Allocator, cfg: *const S3Config) ![]u8 {
    const omit_port = cfg.endpoint_port == 0 or cfg.endpoint_port == 80 or cfg.endpoint_port == 443;
    return switch (cfg.bucket_style) {
        .path => if (omit_port)
            alloc.dupe(u8, cfg.endpoint_host)
        else
            std.fmt.allocPrint(alloc, "{s}:{d}", .{ cfg.endpoint_host, cfg.endpoint_port }),
        .virtual_hosted => if (omit_port)
            std.fmt.allocPrint(alloc, "{s}.{s}", .{ cfg.bucket, cfg.endpoint_host })
        else
            std.fmt.allocPrint(alloc, "{s}.{s}:{d}", .{ cfg.bucket, cfg.endpoint_host, cfg.endpoint_port }),
    };
}

/// Build the request URI (what goes after the method in the request line).
/// Path:          /{bucket}/{key}   (key may be empty for list → "/{bucket}")
/// Virtual-hosted: /{key}           (key may be empty for list → "/")
fn buildUri(alloc: std.mem.Allocator, cfg: *const S3Config, key: []const u8) ![]u8 {
    return switch (cfg.bucket_style) {
        .path => if (key.len > 0)
            std.fmt.allocPrint(alloc, "/{s}/{s}", .{ cfg.bucket, key })
        else
            std.fmt.allocPrint(alloc, "/{s}", .{cfg.bucket}),
        .virtual_hosted => if (key.len > 0)
            std.fmt.allocPrint(alloc, "/{s}", .{key})
        else
            alloc.dupe(u8, "/"),
    };
}

/// Build the canonical URI used in AWS Sig v4 signing (same as request URI, no query string).
fn buildSignUri(alloc: std.mem.Allocator, cfg: *const S3Config, key: []const u8) ![]u8 {
    return buildUri(alloc, cfg, key);
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testConfig(bucket_style: BucketStyle) S3Config {
    return .{
        .access_key = "testkey",
        .secret_key = "testsecret",
        .region = "us-east-1",
        .endpoint_ip = .{ 127, 0, 0, 1 },
        .endpoint_port = 9000,
        .endpoint_host = "minio.local",
        .bucket = "mybucket",
        .bucket_style = bucket_style,
        .alloc = testing.allocator,
    };
}

test "buildHost: path style with port" {
    const cfg = testConfig(.path);
    const host = try buildHost(testing.allocator, &cfg);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("minio.local:9000", host);
}

test "buildHost: path style omits standard port 80" {
    var cfg = testConfig(.path);
    cfg.endpoint_port = 80;
    const host = try buildHost(testing.allocator, &cfg);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("minio.local", host);
}

test "buildHost: path style omits standard port 443" {
    var cfg = testConfig(.path);
    cfg.endpoint_port = 443;
    const host = try buildHost(testing.allocator, &cfg);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("minio.local", host);
}

test "buildHost: virtual_hosted with port" {
    const cfg = testConfig(.virtual_hosted);
    const host = try buildHost(testing.allocator, &cfg);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("mybucket.minio.local:9000", host);
}

test "buildHost: virtual_hosted omits port 443" {
    var cfg = testConfig(.virtual_hosted);
    cfg.endpoint_port = 443;
    const host = try buildHost(testing.allocator, &cfg);
    defer testing.allocator.free(host);
    try testing.expectEqualStrings("mybucket.minio.local", host);
}

test "buildUri: path style with key" {
    const cfg = testConfig(.path);
    const uri = try buildUri(testing.allocator, &cfg, "data/snapshot.bin");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("/mybucket/data/snapshot.bin", uri);
}

test "buildUri: path style empty key (list)" {
    const cfg = testConfig(.path);
    const uri = try buildUri(testing.allocator, &cfg, "");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("/mybucket", uri);
}

test "buildUri: virtual_hosted with key" {
    const cfg = testConfig(.virtual_hosted);
    const uri = try buildUri(testing.allocator, &cfg, "data/snapshot.bin");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("/data/snapshot.bin", uri);
}

test "buildUri: virtual_hosted empty key (list)" {
    const cfg = testConfig(.virtual_hosted);
    const uri = try buildUri(testing.allocator, &cfg, "");
    defer testing.allocator.free(uri);
    try testing.expectEqualStrings("/", uri);
}

test "sha256hex: empty string" {
    var out: [64]u8 = undefined;
    sha256hex("", &out);
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &out,
    );
}

test "sha256hex: known vector" {
    var out: [64]u8 = undefined;
    sha256hex("abc", &out);
    try testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        &out,
    );
}

test "parseStatus: 200 OK" {
    try testing.expectEqual(@as(u16, 200), parseStatus("HTTP/1.1 200 OK\r\n"));
}

test "parseStatus: 404 Not Found" {
    try testing.expectEqual(@as(u16, 404), parseStatus("HTTP/1.1 404 Not Found\r\n"));
}

test "parseStatus: too short returns 0" {
    try testing.expectEqual(@as(u16, 0), parseStatus("HTTP"));
}

test "extractBody: splits on CRLFCRLF" {
    const resp = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello";
    try testing.expectEqualStrings("hello", extractBody(resp));
}

test "extractBody: no separator returns empty" {
    try testing.expectEqualStrings("", extractBody("HTTP/1.1 200 OK"));
}

test "parseXmlKeys: single key" {
    const xml = "<ListBucketResult><Contents><Key>foo/bar.bin</Key></Contents></ListBucketResult>";
    const keys = try parseXmlKeys(xml, testing.allocator);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    try testing.expectEqual(@as(usize, 1), keys.len);
    try testing.expectEqualStrings("foo/bar.bin", keys[0]);
}

test "parseXmlKeys: multiple keys" {
    const xml = "<ListBucketResult><Contents><Key>a</Key></Contents><Contents><Key>b</Key></Contents></ListBucketResult>";
    const keys = try parseXmlKeys(xml, testing.allocator);
    defer {
        for (keys) |k| testing.allocator.free(k);
        testing.allocator.free(keys);
    }
    try testing.expectEqual(@as(usize, 2), keys.len);
    try testing.expectEqualStrings("a", keys[0]);
    try testing.expectEqualStrings("b", keys[1]);
}

test "parseXmlKeys: no keys returns empty slice" {
    const keys = try parseXmlKeys("<ListBucketResult></ListBucketResult>", testing.allocator);
    defer testing.allocator.free(keys);
    try testing.expectEqual(@as(usize, 0), keys.len);
}

test "unixToDateTime: epoch zero" {
    const y, const mo, const d, const h, const m, const s = unixToDateTime(0);
    try testing.expectEqual(@as(u64, 1970), y);
    try testing.expectEqual(@as(u64, 1), mo);
    try testing.expectEqual(@as(u64, 1), d);
    try testing.expectEqual(@as(u64, 0), h);
    try testing.expectEqual(@as(u64, 0), m);
    try testing.expectEqual(@as(u64, 0), s);
}

test "unixToDateTime: one day later" {
    const y, const mo, const d, const h, const m, const s = unixToDateTime(86400);
    try testing.expectEqual(@as(u64, 1970), y);
    try testing.expectEqual(@as(u64, 1), mo);
    try testing.expectEqual(@as(u64, 2), d);
    try testing.expectEqual(@as(u64, 0), h);
    try testing.expectEqual(@as(u64, 0), m);
    try testing.expectEqual(@as(u64, 0), s);
}

test "unixToDateTime: 2023-01-01" {
    // 2023-01-01T00:00:00Z = 1672531200
    const y, const mo, const d, const h, const m, const s = unixToDateTime(1672531200);
    try testing.expectEqual(@as(u64, 2023), y);
    try testing.expectEqual(@as(u64, 1), mo);
    try testing.expectEqual(@as(u64, 1), d);
    try testing.expectEqual(@as(u64, 0), h);
    try testing.expectEqual(@as(u64, 0), m);
    try testing.expectEqual(@as(u64, 0), s);
}

test "buildAuth: output format and determinism" {
    const alloc = testing.allocator;
    const cfg = testConfig(.path);
    const timestamp: [16]u8 = "20230101T000000Z".*;
    const date: [8]u8 = "20230101".*;
    const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    const auth1 = try buildAuth(alloc, cfg, "GET", "/mybucket/key", "minio.local:9000", "", &timestamp, &date, empty_hash[0..64]);
    defer alloc.free(auth1);
    const auth2 = try buildAuth(alloc, cfg, "GET", "/mybucket/key", "minio.local:9000", "", &timestamp, &date, empty_hash[0..64]);
    defer alloc.free(auth2);

    try testing.expectEqualStrings(auth1, auth2);
    try testing.expect(std.mem.startsWith(u8, auth1, "AWS4-HMAC-SHA256 Credential=testkey/20230101/us-east-1/s3/aws4_request"));
    try testing.expect(std.mem.indexOf(u8, auth1, "SignedHeaders=host;x-amz-content-sha256;x-amz-date") != null);
    try testing.expect(std.mem.indexOf(u8, auth1, "Signature=") != null);
    // Signature must be 64 hex chars
    const sig_pos = std.mem.indexOf(u8, auth1, "Signature=").? + "Signature=".len;
    try testing.expectEqual(@as(usize, 64), auth1[sig_pos..].len);
}

test "buildAuth: different methods produce different signatures" {
    const alloc = testing.allocator;
    const cfg = testConfig(.path);
    const timestamp: [16]u8 = "20230101T000000Z".*;
    const date: [8]u8 = "20230101".*;
    const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    const get_auth = try buildAuth(alloc, cfg, "GET", "/mybucket/key", "minio.local:9000", "", &timestamp, &date, empty_hash[0..64]);
    defer alloc.free(get_auth);
    const put_auth = try buildAuth(alloc, cfg, "PUT", "/mybucket/key", "minio.local:9000", "", &timestamp, &date, empty_hash[0..64]);
    defer alloc.free(put_auth);

    try testing.expect(!std.mem.eql(u8, get_auth, put_auth));
}

test "buildAuth: query string included in canonical request" {
    const alloc = testing.allocator;
    const cfg = testConfig(.path);
    const timestamp: [16]u8 = "20230101T000000Z".*;
    const date: [8]u8 = "20230101".*;
    const empty_hash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    const no_query = try buildAuth(alloc, cfg, "GET", "/mybucket", "minio.local:9000", "", &timestamp, &date, empty_hash[0..64]);
    defer alloc.free(no_query);
    const with_query = try buildAuth(alloc, cfg, "GET", "/mybucket", "minio.local:9000", "list-type=2&prefix=snap", &timestamp, &date, empty_hash[0..64]);
    defer alloc.free(with_query);

    try testing.expect(!std.mem.eql(u8, no_query, with_query));
}

fn sha256hex(data: []const u8, out: *[64]u8) void {
    var hash: [32]u8 = undefined;
    Sha256.hash(data, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    @memcpy(out, &hex);
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
    /// Canonical query string for signing (e.g. "list-type=2&prefix=foo"). Empty for most ops.
    query_string: []const u8,
    timestamp: *const [16]u8,
    date: *const [8]u8,
    body_hash: []const u8,
) ![]u8 {
    // Canonical headers (sorted)
    const canonical_headers = try std.fmt.allocPrint(alloc, "host:{s}\nx-amz-content-sha256:{s}\nx-amz-date:{s}\n", .{ host, body_hash, timestamp });
    defer alloc.free(canonical_headers);

    const signed_headers = "host;x-amz-content-sha256;x-amz-date";

    // Canonical request — query string on its own line between URI and headers.
    const canonical_request = try std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{ method, path, query_string, canonical_headers, signed_headers, body_hash });
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
    const sig_hex_arr = std.fmt.bytesToHex(signature_raw, .lower);
    @memcpy(&sig_hex, &sig_hex_arr);

    const credential = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ config.access_key, scope });
    defer alloc.free(credential);

    return std.fmt.allocPrint(alloc, "AWS4-HMAC-SHA256 Credential={s}, SignedHeaders={s}, Signature={s}", .{ credential, signed_headers, &sig_hex });
}
