const std = @import("std");

pub fn crc32c(data: []const u8) u32 {
    var ctx = std.hash.Crc32.init();
    ctx.update(data);
    return ctx.final();
}
