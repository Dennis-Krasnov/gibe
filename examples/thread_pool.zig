const std = @import("std");
const gibe = @import("gibe");

pub fn main() !void {
    const address = try std.net.Address.parseIp("127.0.0.1", 5882);

    for (0..8) |_| {
        _ = try std.Thread.spawn(.{}, worker, .{address});
    }

    // park thread
    while (true) {
        std.Thread.sleep(1 * std.time.ns_per_day);
    }
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

    while (true) {
        const tcp_client: std.posix.fd_t = try std.posix.accept(tcp_server, null, null, 0);
        // defer std.posix.close(tcp_client);

        try http_server.run(tcp_client, void, handle, {});
    }
}

fn handle(_: std.mem.Allocator, request: *gibe.Request, response: *gibe.Response) !void {
    std.log.info("handling request on thread #{d}", .{std.Thread.getCurrentId()});
    response.body = request.body;
}

test "smoke" {
    // given
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var request = try gibe.Request.init(arena.allocator());
    request.body = "hello";

    var response = try gibe.Response.init(arena.allocator());

    // when
    try handle(arena.allocator(), &request, &response);

    // then
    try std.testing.expectEqual(response.status, .ok);
    try std.testing.expectEqualStrings(response.body, "hello");
}
