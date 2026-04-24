/// Injectable time/randomness sources and nondeterministic SQL function resolution.
const std = @import("std");

const ResolvedValue = @import("types.zig").ResolvedValue;

/// Injectable clock source. Production uses real clock_gettime; sim substitutes VirtualClock.
/// now_micros_fn returns unix microseconds as i64.
pub const ClockSource = struct {
    clock_ctx: ?*anyopaque = null,
    now_micros_fn: *const fn (?*anyopaque) i64 = realNowMicros,

    pub fn now(self: ClockSource) i64 {
        return self.now_micros_fn(self.clock_ctx);
    }

    fn realNowMicros(_: ?*anyopaque) i64 {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        const sec_us: i64 = @as(i64, @intCast(ts.sec)) * 1_000_000;
        const nsec_us: i64 = @as(i64, @intCast(@divTrunc(ts.nsec, 1_000)));
        return sec_us + nsec_us;
    }
};

/// Injectable random source. Production uses clock-seeded PRNG; sim substitutes SimScheduler.
pub const RandSource = struct {
    rand_ctx: ?*anyopaque = null,
    fill_fn: *const fn (?*anyopaque, []u8) void = realFill,

    pub fn fill(self: RandSource, buf: []u8) void {
        self.fill_fn(self.rand_ctx, buf);
    }

    fn realFill(_: ?*anyopaque, buf: []u8) void {
        var ts: std.os.linux.timespec = undefined;
        _ = std.os.linux.clock_gettime(std.os.linux.clockid_t.REALTIME, &ts);
        const seed: u64 = @as(u64, @intCast(ts.sec)) * 1_000_000_000 +
            @as(u64, @intCast(ts.nsec));
        var rand = std.Random.Xoroshiro128.init(seed);
        rand.fill(buf);
    }
};

/// Nondeterminism resolver - computes values for NOW(), RANDOM(), UUID()
pub const NondetResolver = struct {
    clock: ClockSource,
    rand: RandSource,

    pub fn init(clock: ClockSource, rand: RandSource) NondetResolver {
        return .{ .clock = clock, .rand = rand };
    }

    pub fn resolveNow(self: NondetResolver) ResolvedValue {
        return .{ .now = self.clock.now() };
    }

    pub fn resolveRandom(self: NondetResolver) ResolvedValue {
        var bytes: [16]u8 = undefined;
        self.rand.fill(&bytes);
        return .{ .random = bytes };
    }

    pub fn resolveUuidV7(self: NondetResolver) ResolvedValue {
        const micros = self.clock.now();
        var uuid: [16]u8 = undefined;
        const ms: u64 = @intCast(@divTrunc(micros, 1_000));
        std.mem.writeInt(u64, &uuid[0..8].*, ms, .big);
        uuid[6] = (uuid[6] & 0x0F) | 0x70;
        var rand_bytes: [8]u8 = undefined;
        self.rand.fill(&rand_bytes);
        @memcpy(uuid[8..16], &rand_bytes);
        uuid[8] = (uuid[8] & 0x3F) | 0x80;
        return .{ .uuid_v7 = uuid };
    }
};

/// Scan sql_text for NOW(), RANDOM(), UUID() calls (case-insensitive) and resolve each.
pub fn resolveNondet(sql_text: []const u8, resolver: *const NondetResolver, alloc: std.mem.Allocator) ![]ResolvedValue {
    var results: std.ArrayList(ResolvedValue) = .empty;
    errdefer results.deinit(alloc);

    var i: usize = 0;
    while (std.mem.indexOfAnyPos(u8, sql_text, i, "nNrRuU")) |pos| {
        if (matchToken(sql_text, pos, "now(")) {
            try results.append(alloc, resolver.resolveNow());
            i = pos + 4;
        } else if (matchToken(sql_text, pos, "random(")) {
            try results.append(alloc, resolver.resolveRandom());
            i = pos + 7;
        } else if (matchToken(sql_text, pos, "uuid(")) {
            try results.append(alloc, resolver.resolveUuidV7());
            i = pos + 5;
        } else {
            i = pos + 1;
        }
    }

    return results.toOwnedSlice(alloc);
}

fn matchToken(haystack: []const u8, pos: usize, needle: []const u8) bool {
    if (pos + needle.len > haystack.len) return false;
    for (needle, 0..) |c, j| {
        const h = haystack[pos + j];
        const hc = if (h >= 'A' and h <= 'Z') h + 32 else h;
        if (hc != c) return false;
    }
    return true;
}
