//! Based on thread_pool.zig.

const std = @import("std");
const gibe = @import("gibe");

const is_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub fn main() !void {
    for (.{ std.posix.SIG.INT, std.posix.SIG.TERM }) |signal| {
        std.posix.sigaction(signal, &.{ .handler = .{ .handler = shutdown }, .mask = std.posix.empty_sigset, .flags = 0 }, null);
    }

    const address = try std.net.Address.parseIp("127.0.0.1", 5882);

    var thread_handles = std.ArrayList(std.Thread).init(std.heap.smp_allocator);
    defer thread_handles.deinit();

    for (0..8) |_| {
        const thread_handle = try std.Thread.spawn(.{}, worker, .{address});
        try thread_handles.append(thread_handle);
    }

    for (thread_handles.items) |thread_handle| {
        thread_handle.join();
    }
}

fn shutdown(_: c_int) callconv(.C) void {
    is_shutdown.store(true, .monotonic);
}

fn worker(address: std.net.Address) !void {
    const tcp_server: std.posix.fd_t = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(tcp_server);

    try std.posix.setsockopt(tcp_server, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    try std.posix.setsockopt(tcp_server, std.posix.SOL.SOCKET, std.posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1))); // essential for performance

    try std.posix.bind(tcp_server, &address.any, address.getOsSockLen());
    try std.posix.listen(tcp_server, 1024);
    std.log.info("listening on 127.0.0.1:5882", .{});

    var http_server = gibe.Server.init(std.heap.smp_allocator);
    defer http_server.deinit();

    while (!is_shutdown.load(.monotonic)) {
        const tcp_client: std.posix.fd_t = try std.posix.accept(tcp_server, null, null, 0);
        // defer std.posix.close(tcp_client);

        http_server.run(tcp_client, void, handle, {}) catch |err| {
            std.log.err("HTTP server error: {}", .{err});
        };
    }
}

fn handle(_: std.mem.Allocator, request: *gibe.Request, response: *gibe.Response) !void {
    if (is_shutdown.load(.monotonic)) return error.Shutdown; // TODO: pass as state, two unit tests

    std.log.info("handling request on thread #{d}", .{std.Thread.getCurrentId()});
    response.body = request.body;
}

test "smoke" {
    // given
    const arena, const request, var response = gibe.leakyInit();
    request.body = "hello";

    // when
    try handle(arena, &request, &response);

    // then
    try std.testing.expectEqual(response.status, .ok);
    try std.testing.expectEqualStrings(response.body, "hello");
}
