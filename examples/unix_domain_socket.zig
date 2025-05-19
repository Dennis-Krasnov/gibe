const std = @import("std");
const gibe = @import("gibe");

/// curl -v -X POST --unix-socket /tmp/gibe.sock http://localhost --data-raw "hello"
pub fn main() !void {
    const socket_path = "/tmp/gibe.sock";

    std.fs.cwd().deleteFile(socket_path) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    const uds_server: std.posix.fd_t = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    defer std.posix.close(uds_server);

    const address = try std.net.Address.initUnix(socket_path);
    try std.posix.bind(uds_server, &address.any, address.getOsSockLen());
    try std.posix.listen(uds_server, 1024);
    std.log.info("listening on {s}", .{socket_path});

    var http_server = gibe.Server.init(std.heap.smp_allocator);
    defer http_server.deinit();

    while (true) {
        const uds_client: std.posix.fd_t = try std.posix.accept(uds_server, null, null, 0);
        // defer std.posix.close(uds_client);

        try http_server.run(uds_client, void, handle, {});
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
