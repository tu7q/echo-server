// Simple echo server which just echoes data back to the user.
// Here we use alternating recv/send to avoid more than one write buffer.

// Note to future self with an emit function might have a single right buffer with reference counting.

// TODO: Proper timeouts and abortive closes.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const windows = std.os.windows;
const ws2_32 = windows.ws2_32;
const posix = std.posix; // Not necessarily cross-platform but does have some windows error handling.

const MemoryPool = std.heap.MemoryPoolExtra;

const BUFFER_SIZE = 4096; // reasonable buffer size.

const IOOperation = enum(u8) {
    Accept,
    Send,
    Recv,
};

const PerIOContext = extern struct {
    overlapped: windows.OVERLAPPED,
    operation: IOOperation,
    wsabuf: ws2_32.WSABUF,
    buffer: [BUFFER_SIZE]u8,
    incoming: ?ws2_32.SOCKET,

    // Created in accept state.
    pub fn init(self: *@This()) !void {
        // Create a socket.
        const socket = ws2_32.WSASocketW(
            ws2_32.AF.INET,
            ws2_32.SOCK.STREAM,
            ws2_32.IPPROTO.IP,
            null,
            0,
            ws2_32.WSA_FLAG_OVERLAPPED,
        );

        // ws2_32.setsockopt(s: SOCKET, level: i32, optname: i32, optval: ?[*]const u8, optlen: i32)
        // ws2_32.SO.RCVTIMEO

        // Throw an error if it was bad.
        if (socket == ws2_32.INVALID_SOCKET) {
            return error.WSAError;
            // return ws2_32.WSAGetLastError();
        }

        // We could set some fancy buffer protocols here but I'm not going to bother.
        // We could set a linger here but I'm not going to bother.

        // 0 initialize OVERLAPPED.
        self.overlapped = .{
            .Internal = 0,
            .InternalHigh = 0,
            .DUMMYUNIONNAME = .{
                .DUMMYSTRUCTNAME = .{
                    .Offset = 0,
                    .OffsetHigh = 0,
                },
            },
            .hEvent = null,
        };
        self.operation = .Accept;
        // self.buffer = try Buffer.init(allocator);
        self.buffer = undefined;
        self.wsabuf = .{
            .buf = (&self.buffer).ptr,
            .len = BUFFER_SIZE,
        };
        self.incoming = socket;
    }

    pub fn setSend(self: *@This(), msg_len: usize) void {
        self.operation = .Send;
        self.incoming = null;
        self.wsabuf.buf = @ptrCast(&self.buffer);
        self.wsabuf.len = @intCast(msg_len);
    }

    pub fn setRecv(self: *@This()) void {
        self.operation = .Recv;
        self.incoming = null;
        self.wsabuf.buf = @ptrCast(&self.buffer);
        self.wsabuf.len = BUFFER_SIZE;
    }

    // Only valid when self.operation = .Send
    // Caller guarantees that the amounted being advanced will fit inside the buffer.
    pub fn advanceSent(self: *@This(), advance: usize) void {
        self.wsabuf.buf += advance; // move ptr along
        self.wsabuf.len -= @intCast(advance); // reduce len accordingly
    }

    // Only valid when self.operation = .Send
    pub fn numBytesToWrite(self: *@This()) usize {
        return self.wsabuf.len;
    }
};

const PerSocketContext = extern struct {
    socket: ws2_32.SOCKET,
};

pub fn main() !void {
    // TODO: Functionalize this better.
    // TODO: Handle more error cases ie Listener socket closing unexpectedly etc.
    // TODO: Add timeout handling for sockets.
    // Cant actually do the TODO below since it doesn't make that much sense.
    // TODO: Handling reading and writing at the same time. IE, closing socket : Checking for outstanding IO before deleting context,

    if (comptime builtin.os.tag != .windows) {
        @compileError("This is a windows only project");
    }

    var gpa_impl = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_impl.deinit();
    const allocator = gpa_impl.allocator();

    // Pool of memory holding all of the connections.
    var socket_pool = MemoryPool(PerSocketContext, .{}).init(allocator);
    defer socket_pool.deinit();

    var io_pool = MemoryPool(PerIOContext, .{}).init(allocator);
    defer io_pool.deinit();

    // Make sure WSA is enabled.
    try windows.callWSAStartup();
    defer windows.WSACleanup() catch {}; // Can error but it doesn't matter anyway...

    // Create the IOCP
    const iocp = try windows.CreateIoCompletionPort(
        windows.INVALID_HANDLE_VALUE,
        null,
        0,
        0,
    );

    // Create the listening socket.
    const address = try std.net.Address.parseIp("127.0.0.1", 5882);

    const tpe = ws2_32.SOCK.STREAM;
    const protocol = ws2_32.IPPROTO.TCP;

    const listener = try windows.WSASocketW(
        @bitCast(@as(u32, address.any.family)), // Widen u16 to u32 then cast to i32,
        tpe,
        protocol,
        null,
        0,
        ws2_32.WSA_FLAG_OVERLAPPED,
    );
    defer _ = ws2_32.closesocket(listener); // Doesn't matter since its at the end.

    // Enable reusing of addresses.
    try posix.setsockopt(
        listener,
        ws2_32.SOL.SOCKET,
        ws2_32.SO.REUSEADDR,
        &std.mem.toBytes(@as(c_int, 1)),
    );
    try posix.bind(listener, &address.any, address.getOsSockLen());
    try posix.listen(listener, 128);

    const listener_context = try socket_pool.create();
    defer socket_pool.destroy(listener_context);

    listener_context.socket = listener;

    // Note the completion key should refer to the specific PerSocketContext.
    // Each operation refers to the PerIOContext.

    _ = try windows.CreateIoCompletionPort(
        listener,
        iocp,
        @intFromPtr(listener_context),
        0,
    );

    // Unused... (only bcs function is required.)
    var _bytes: windows.DWORD = undefined;

    // Post initial AcceptEx to the queue.
    const acceptex_guid = ws2_32.WSAID_ACCEPTEX;

    // Get the accept fn.
    var fnAcceptEx: ws2_32.LPFN_ACCEPTEX = undefined;

    if (ws2_32.WSAIoctl(
        listener,
        ws2_32.SIO_GET_EXTENSION_FUNCTION_POINTER,
        &acceptex_guid,
        @sizeOf(windows.GUID),
        @ptrCast(&fnAcceptEx),
        @sizeOf(ws2_32.LPFN_ACCEPTEX),
        &_bytes,
        null,
        null,
    ) == ws2_32.SOCKET_ERROR) {
        return error.WSAError;
    }

    // Create outstanding IO operation to accept incoming connection.
    const initial_accept_context = try io_pool.create();
    try initial_accept_context.init();

    // https://learn.microsoft.com/en-us/windows/win32/api/mswsock/nf-mswsock-acceptex
    // The address lengths need to be 16 bytes more than max addr length.
    const addr_length = @sizeOf(ws2_32.sockaddr.storage) + 16;
    const remaining_buffer_length = BUFFER_SIZE - 2 * addr_length;
    var _recv_num_bytes: u32 = undefined; // I don't think this is ever set.  (Doesn't matter anyway)

    if (fnAcceptEx(
        listener,
        initial_accept_context.incoming.?,
        @ptrCast(&initial_accept_context.buffer),
        remaining_buffer_length,
        addr_length,
        addr_length,
        &_recv_num_bytes,
        @ptrCast(initial_accept_context),
    ) == ws2_32.SOCKET_ERROR and ws2_32.WSAGetLastError() != .WSA_IO_PENDING) {
        return error.WSAError; // Because WinsockError is an enum not an Error type.
    }

    while (true) {
        var bytes_transferred: windows.DWORD = undefined;
        var completion_key: usize = undefined;
        var overlapped: ?*windows.OVERLAPPED = undefined;

        // if (windows.GetQueuedCompletionStatus(
        //     iocp,
        //     &bytes_transferred,
        //     &completion_key,
        //     &overlapped,
        //     windows.INFINITE,
        // ) != .Normal) {
        //     // return ws2_32.WSAGetLastError();
        //     return error.WSAError;
        // }

        GetQueuedCompletionStatus(
            iocp,
            &bytes_transferred,
            &completion_key,
            &overlapped,
            windows.INFINITE,
        ) catch |err| switch (err) {
            error.Timeout => {},
            error.Unexpected => unreachable, // Should only occur due to misuse of the function.
            else => return err,
        };

        // Context of the io operation.
        const io_context: *PerIOContext = @ptrCast(overlapped);
        // Context of the socket.
        const socket_context: *PerSocketContext = @ptrFromInt(completion_key);

        std.debug.print("{any}\n", .{io_context.operation});
        std.debug.print("{any}\n", .{bytes_transferred});
        std.debug.print("{s}\n", .{io_context.buffer});

        // Should be 0 here. Otherwise a 0 byte-read is going on somewhere which would be bad.
        if (bytes_transferred == 0 and io_context.operation != .Accept) {
            _ = ws2_32.closesocket(socket_context.socket);
            socket_pool.destroy(socket_context);
            io_pool.destroy(io_context);
            continue;
        }

        switch (io_context.operation) {
            .Accept => {
                // Note client address information is somewhere in the back of the buffers and is just ignored.
                // ws2_32.GetAcceptExSockaddrs(lpOutputBuffer: *anyopaque, dwReceiveDataLength: u32, dwLocalAddressLength: u32, dwRemoteAddressLength: u32, LocalSockaddr: **sockaddr, LocalSockaddrLength: *i32, RemoteSockaddr: **sockaddr, RemoteSockaddrLength: *i32)

                // Guaranteed to unwrap since this must have come from an AcceptIOOperation
                // Which must have an incoming socket.
                const accepted_socket = io_context.incoming.?;

                // When AcceptEx returns, the accept_socket is in the default state for a connected socket.
                // The accept_socket does not inherit the properties of the socket associated with
                // listen socket  until SO_UPDATE_ACCEPT_CONTEXT is set on the socket.
                if (ws2_32.setsockopt(
                    accepted_socket,
                    ws2_32.SOL.SOCKET,
                    ws2_32.SO.UPDATE_ACCEPT_CONTEXT,
                    @ptrCast(&listener),
                    @sizeOf(ws2_32.SOCKET),
                ) == ws2_32.SOCKET_ERROR) {
                    std.debug.print("err: {any}\n", .{ws2_32.WSAGetLastError()});
                    return error.WinsockError; // See above,
                }

                // Create context for the newly accepted socket.
                const accepted_context = try socket_pool.create();
                accepted_context.socket = accepted_socket;

                // Register the socket to be handled by the completion port.
                _ = try windows.CreateIoCompletionPort(
                    accepted_socket,
                    iocp,
                    @intFromPtr(accepted_context),
                    0, // ignored
                );

                if (bytes_transferred > 0) {

                    // We have data to write.

                    // Modify the io operation to send.
                    io_context.setSend(bytes_transferred);

                    if (ws2_32.WSASend(
                        accepted_socket,
                        @ptrCast(&io_context.wsabuf),
                        1,
                        null,
                        0,
                        @ptrCast(io_context),
                        null,
                    ) == ws2_32.SOCKET_ERROR and ws2_32.WSAGetLastError() != .WSA_IO_PENDING) {
                        _ = ws2_32.closesocket(accepted_socket);
                        socket_pool.destroy(accepted_context);
                        io_pool.destroy(io_context);
                    }
                } else {
                    // Need to post an outstanding read.

                    // Modify the io operation to recv.
                    io_context.setRecv();

                    var lp_flags: windows.DWORD = 0;

                    if (ws2_32.WSARecv(
                        accepted_socket,
                        @ptrCast(&io_context.wsabuf),
                        1,
                        null,
                        &lp_flags,
                        @ptrCast(io_context),
                        null,
                    ) == ws2_32.SOCKET_ERROR and ws2_32.WSAGetLastError() != .WSA_IO_PENDING) {
                        // Close accepted socket.
                        _ = ws2_32.closesocket(accepted_socket);
                        socket_pool.destroy(accepted_context);
                        io_pool.destroy(io_context);
                    }
                }

                // Post another AcceptEx (wait for new client to accept)

                // Create outstanding IO operation to accept incoming connection.
                const new_accept_context = try io_pool.create();
                try new_accept_context.init();

                // Actually perform the operation.
                if (fnAcceptEx(
                    listener,
                    new_accept_context.incoming.?,
                    @ptrCast(&new_accept_context.buffer),
                    remaining_buffer_length,
                    addr_length,
                    addr_length,
                    &_recv_num_bytes,
                    @ptrCast(new_accept_context),
                ) == 0 and ws2_32.WSAGetLastError() != .WSA_IO_PENDING) {
                    return error.WinsockError; // See above
                }
            },
            .Recv => {
                // Recv operation has completed. Now post a write operation to echo the data back to the
                // client using the same data buffer.

                io_context.setSend(bytes_transferred);

                if (ws2_32.WSASend(
                    socket_context.socket,
                    @ptrCast(&io_context.wsabuf),
                    1,
                    null,
                    0,
                    @ptrCast(io_context),
                    null,
                ) == ws2_32.SOCKET_ERROR and ws2_32.WSAGetLastError() != .WSA_IO_PENDING) {
                    _ = ws2_32.closesocket(socket_context.socket);
                    socket_pool.destroy(socket_context);
                    io_pool.destroy(io_context);
                }
            },

            .Send => {

                // Just wrote some data. Determine if all of the data intended to be send was actually sent.
                if (bytes_transferred < io_context.numBytesToWrite()) {
                    // Not all data intended to be sent was actually sent.
                    // Need to post another send event to complete it.

                    io_context.advanceSent(bytes_transferred);

                    if (ws2_32.WSASend(
                        socket_context.socket,
                        @ptrCast(&io_context.wsabuf),
                        1,
                        null,
                        0,
                        @ptrCast(io_context),
                        null,
                    ) == ws2_32.SOCKET_ERROR and ws2_32.WSAGetLastError() != .WSA_IO_PENDING) {
                        _ = ws2_32.closesocket(socket_context.socket);
                        socket_pool.destroy(socket_context);
                        io_pool.destroy(io_context);
                    }
                } else {
                    // Previous send operation completed for this socket. Post another recv
                    io_context.setRecv();

                    var lp_flags: windows.DWORD = 0;

                    if (ws2_32.WSARecv(
                        socket_context.socket,
                        @ptrCast(&io_context.wsabuf),
                        1,
                        null,
                        &lp_flags,
                        @ptrCast(io_context),
                        null,
                    ) == ws2_32.SOCKET_ERROR and ws2_32.WSAGetLastError() != .WSA_IO_PENDING) {
                        _ = ws2_32.closesocket(socket_context.socket);
                        socket_pool.destroy(socket_context);
                        io_pool.destroy(io_context);
                    }
                }
            },
        }
    }
}

// Because ws2_32 doesn't handle all cases we need to manually define it.
const kernel32 = windows.kernel32;
const UnexpectedError = std.posix.UnexpectedError;

const GetQueuedCompletionStatusError = error{
    Aborted,
    Cancelled,
    EOF,
    Timeout,
} || UnexpectedError;

pub fn GetQueuedCompletionStatus(
    completion_port: windows.HANDLE,
    bytes_transferred_count: *windows.DWORD,
    lpCompletionKey: *usize,
    lpOverlapped: *?*windows.OVERLAPPED,
    dwMilliseconds: windows.DWORD,
) !void {
    if (kernel32.GetQueuedCompletionStatus(
        completion_port,
        bytes_transferred_count,
        lpCompletionKey,
        lpOverlapped,
        dwMilliseconds,
    ) == windows.FALSE) {
        switch (kernel32.GetLastError()) {
            .ABANDONED_WAIT_0 => return error.Aborted,
            .OPERATION_ABORTED => return error.Cancelled,
            .HANDLE_EOF => return error.EOF,
            .WAIT_TIMEOUT => return error.Timeout,
            else => return error.Unexpected, // Should only occur if function is used incorrectly.
        }
    }
}
