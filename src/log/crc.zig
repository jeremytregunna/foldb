/// CRC32c (Castagnoli) checksum implementation.
const std = @import("std");

/// Computes CRC32c checksum over the given data.
pub fn crc32c(data: []const u8) u32 {
    var crc_state = std.hash.Crc32.init();
    crc_state.update(data);
    return crc_state.final();
}
