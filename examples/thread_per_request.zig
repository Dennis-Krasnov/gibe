const std = @import("std");
const gibe = @import("gibe");

/// curl -v -X POST http://127.0.0.1:5882 --data-raw "hello"
/// curl -v -X POST "http://[::1]:5882" --data-raw "hello"
pub fn main() !void {
    const address = try std.net.Address.parseIp("::", 5882); // dual stack

    const tcp_server: std.posix.fd_t = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(tcp_server);

    try std.posix.setsockopt(tcp_server, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    try std.posix.bind(tcp_server, &address.any, address.getOsSockLen());
    try std.posix.listen(tcp_server, 1024);
    std.log.info("listening on 127.0.0.1:5882", .{});

    while (true) {
        const tcp_client: std.posix.fd_t = try std.posix.accept(tcp_server, null, null, 0);
        _ = try std.Thread.spawn(.{}, worker, .{tcp_client});
    }
}

/// Takes ownership of tcp_client.
fn worker(tcp_client: std.posix.fd_t) !void {
    // defer std.posix.close(tcp_client);

    var http_server = gibe.Server.init(std.heap.smp_allocator);
    defer http_server.deinit();

    http_server.run(tcp_client, void, handle, {}) catch |err| {
        std.log.err("HTTP server error: {}", .{err});
    };
}

fn handle(_: std.mem.Allocator, request: *gibe.Request, response: *gibe.Response) !void {
    std.log.info("handling request on thread #{d}", .{std.Thread.getCurrentId()});
    response.body = request.body;
}

test "smoke" {
    // given
    const arena, var request, var response = gibe.leakyInit();
    request.body = "hello";

    // when
    try handle(arena, &request, &response);

    // then
    try std.testing.expectEqual(response.status, .ok);
    try std.testing.expectEqualStrings(response.body, "hello");
}
