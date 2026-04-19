const std = @import("std");
const gateway_mod = @import("gateway.zig");
const server = @import("server.zig");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var storage_dir: []const u8 = "/tmp/foldb-data";
    var port: u16 = 7432;

    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.skip(); // skip argv[0]
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--storage-dir")) {
            if (it.next()) |val| storage_dir = val;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (it.next()) |val| port = try std.fmt.parseInt(u16, val, 10);
        }
    }

    std.debug.print("foldb starting: storage={s} port={d}\n", .{ storage_dir, port });

    const gw = try gateway_mod.Gateway.init(storage_dir, alloc, .{});
    defer gw.deinit();

    try server.serve(io, port, gw, alloc);
}
