/// CRC32c (Castagnoli) checksum implementation.
const std = @import("std");

/// Computes CRC32c checksum over the given data.
///
/// # Parameters
/// - `data`: The byte slice to compute the checksum over
///
/// # Returns
/// The 32-bit CRC32c checksum value
pub fn crc32c(data: []const u8) u32 {
    var ctx = std.hash.Crc32.init();
    ctx.update(data);
    return ctx.final();
}
