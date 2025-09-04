const std = @import("std");
const gibe = @import("gibe");

/// open http://127.0.0.1:5882 in a browser
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

fn handle(arena: std.mem.Allocator, request: *gibe.Request, response: *gibe.Response) !void {
    if (request.method == .get and std.mem.eql(u8, request.path, "/")) {
        response.body = webpage;
        try response.headers.append(gibe.Header{ .key = "Content-Type", .value = "text/html" });
        return;
    } else if (request.method == .post and std.mem.eql(u8, request.path, "/form")) {
        const form = try request.multipartFormData(arena);

        const username = form.findPart("username") orelse {
            response.status = .bad_request;
            return;
        };

        response.body = username.data;
        return;
    }

    response.status = .not_found;
}

const webpage =
    \\
    \\<!DOCTYPE html>
    \\<html lang="en">
    \\<head>
    \\  <meta charset="UTF-8">
    \\  <title>Multipart form example</title>
    \\</head>
    \\<body>
    \\  <h1>Multipart form example</h1>
    \\  <form action="/form" method="post" enctype="multipart/form-data">
    \\    <label>
    \\      Username:
    \\      <input type="text" name="username">
    \\    </label>
    \\    <br><br>
    \\    <button type="submit">Submit</button>
    \\  </form>
    \\</body>
    \\</html>
;

test "smoke" {
    // given
    const arena, var request, var response = gibe.leakyInit();
    request.body = "hello";

    // when
    try handle(arena, &request, &response);

    // then
    try std.testing.expectEqual(response.status, .ok);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "</form>") != null);
}
