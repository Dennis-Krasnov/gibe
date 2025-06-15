const std = @import("std");
const gibe = @import("gibe");

// TODO: client ip example

/// curl -v -X POST http://127.0.0.1:5882/greeting
/// curl -v -X POST "http://[::1]:5882" --data-raw "hello"
pub fn main() !void {
    const address = try std.net.Address.parseIp("::", 5882); // dual stack

    const tcp_server: std.posix.fd_t = try std.posix.socket(address.any.family, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(tcp_server);

    try std.posix.setsockopt(tcp_server, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));

    try std.posix.bind(tcp_server, &address.any, address.getOsSockLen());
    try std.posix.listen(tcp_server, 1024);
    std.log.info("listening on 127.0.0.1:5882", .{});

    var http_server = gibe.Server.init(std.heap.smp_allocator);
    defer http_server.deinit();

    while (true) {
        const tcp_client: std.posix.fd_t = try std.posix.accept(tcp_server, null, null, 0);
        // defer std.posix.close(tcp_client);

        http_server.run(tcp_client, void, handle, {}) catch |err| {
            std.log.err("HTTP server error: {}", .{err});
        };
    }
}

const staticRoutes = std.StaticStringMap(*const fn (*gibe.Request, *gibe.Response) anyerror!void).initComptime(.{
    .{ "/greeting", handleGreeting },
    .{ "/farewell", handleFarewell },
});

fn handle(_: std.mem.Allocator, request: *gibe.Request, response: *gibe.Response) !void {
    // TODO: strip trailing slash

    if (staticRoutes.get(request.path)) |route| {
        return route(request, response);
    }

    // alternatively:
    // if (std.mem.eql(u8, request.path, "/greeting")) return handleGreeting(request, response);
    // if (std.mem.eql(u8, request.path, "/farewell")) return handleFarewell(request, response);

    if (std.mem.startsWith(u8, request.path, "/user")) {
        request.path = request.path["/user".len..];
        return handleUser(request, response);
    }

    response.status = .not_found;
}

fn handleGreeting(_: *gibe.Request, response: *gibe.Response) !void {
    response.body = "hello";
}

fn handleFarewell(_: *gibe.Request, response: *gibe.Response) !void {
    response.body = "goodbye";
}

fn handleUser(request: *gibe.Request, response: *gibe.Response) !void {
    response.body = request.path;
}

test "serves top-level route" {
    // given
    const arena, var request, var response = gibe.leakyInit();
    request.path = "/greeting";

    // when
    try handle(arena, &request, &response);

    // then
    try std.testing.expectEqual(response.status, .ok);
    try std.testing.expectEqualStrings(response.body, "hello");
}

test "strips off prefix" {
    // given
    const arena, var request, var response = gibe.leakyInit();
    request.path = "/user/detail";

    // when
    try handle(arena, &request, &response);

    // then
    try std.testing.expectEqual(response.status, .ok);
    try std.testing.expectEqualStrings(response.body, "/detail");
}

test "falls back to 404" {
    // given
    const arena, var request, var response = gibe.leakyInit();

    // when
    try handle(arena, &request, &response);

    // then
    try std.testing.expectEqual(response.status, .not_found);
}
