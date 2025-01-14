const std = @import("std");
const net = std.net;

pub fn main() !void {
    const Address = net.Address;

    const stdin = std.io.getStdIn().reader();

    const address = try Address.parseIp("127.0.0.1", 5882); // Hardcoded adddress I don't care

    const stream = try net.tcpConnectToAddress(address);

    // Somehow this is getting called on ctrl-c which is a good thing but HOW??????
    // Was actually trying to register handlers and things but they didn't work nearly as well as just
    // having this defer statement
    defer stream.close();

    var write_buffer: [1024]u8 = undefined;
    var read_buffer: [1024]u8 = undefined;

    while (true) {
        const to_write = stdin.readUntilDelimiter(&write_buffer, '\n') catch |err| switch (err) {
            error.StreamTooLong => unreachable,
            error.EndOfStream => break,
            else => return err,
        };

        try stream.writeAll(to_write);

        const amt_read = try stream.read(&read_buffer);
        std.debug.print("recv: {s}\n", .{read_buffer[0..amt_read]});
    }
}
