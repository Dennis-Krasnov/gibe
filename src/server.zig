const std = @import("std");

const model = @import("model.zig");

/// ...
pub const Server = struct {
    arena: std.heap.ArenaAllocator,

    /// ...
    /// TODO: pass config: .{ .buffer_size = 4096 } before handler+state
    pub fn init(allocator: std.mem.Allocator) Server {
        return Server{
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    /// ...
    pub fn deinit(self: Server) void {
        self.arena.deinit();
    }

    /// ...
    pub fn run(self: *Server, socket: std.posix.fd_t, comptime State: type, handler: Handler(State), state: State) !void {
        defer _ = self.arena.reset(.retain_capacity);
        const arena_allocator = self.arena.allocator();

        var request = try model.Request.init(arena_allocator);
        try readInto(socket, &request);

        var response = try model.Response.init(arena_allocator);

        if (State == void) {
            try handler(arena_allocator, &request, &response);
        } else {
            try handler(arena_allocator, &request, &response, state);
        }

        // TODO: test
        // https://datatracker.ietf.org/doc/html/rfc9110#name-content-length
        if (request.method != .head and response.status != .not_modified and !response.status.isInformational() and response.status != .no_content) {
            // TODO: check not already there, check haven't set chunked transfer encoding
            var buffer: [20]u8 = undefined;
            const content_length = std.fmt.bufPrintIntToSlice(&buffer, response.body.len, 10, .lower, .{});
            try response.headers.append(model.Header{ .key = "content-length", .value = content_length });
        }

        try writeInto(socket, &response);
    }
};

fn Handler(comptime State: type) type {
    // inspired by karlseguin/http.zig
    if (State == void) {
        return *const fn (std.mem.Allocator, *model.Request, *model.Response) anyerror!void;
    }

    return *const fn (std.mem.Allocator, *model.Request, *model.Response, State) anyerror!void;
}

const stringToMethod = std.StaticStringMap(model.Method).initComptime(.{
    .{ "GET", .get },
    .{ "HEAD", .head },
    .{ "OPTIONS", .options },
    .{ "TRACE", .trace },
    .{ "PUT", .put },
    .{ "DELETE", .delete },
    .{ "POST", .post },
    .{ "PATCH", .patch },
    .{ "CONNECT", .connect },
});

fn readInto(socket: std.posix.fd_t, request: *model.Request) !void {
    var buffer: [1024]u8 = undefined;
    var bytes_parsed: usize = 0;
    var bytes_read: usize = 0;

    while (true) {
        // TODO: if (bytes_read == buffer.len) return error.RequestTooBig;

        // TODO: place after if for symmetry. do one unconditional before the loop?
        const n = try std.posix.read(socket, buffer[bytes_read..]);
        if (n == 0) return error.EOF; // TODO: more descriptive error
        bytes_read += n;

        if (std.mem.indexOf(u8, buffer[bytes_parsed..bytes_read], " ")) |space_idx| {
            if (space_idx == 0) return error.MissingMethod;
            const raw_method = buffer[bytes_parsed .. bytes_parsed + space_idx];
            if (!isAscii(raw_method)) return error.NotAscii;

            request.method = stringToMethod.get(raw_method) orelse .{ .other = raw_method };

            bytes_parsed += space_idx + " ".len;
            break;
        }
    }

    while (true) {
        if (std.mem.indexOf(u8, buffer[bytes_parsed..bytes_read], " ")) |space_idx| {
            if (space_idx == 0) return error.MissingPath;
            const raw_path = buffer[bytes_parsed .. bytes_parsed + space_idx];
            if (!isAscii(raw_path)) return error.NotAscii;

            if (std.mem.indexOf(u8, raw_path, "?")) |question_idx| {
                if (question_idx == 0) return error.MissingPath;
                request.path = raw_path[0..question_idx];

                var iter = std.mem.splitScalar(u8, raw_path[question_idx + "?".len ..], '&');
                while (iter.next()) |raw_param| {
                    const query_param = if (std.mem.indexOf(u8, raw_param, "=")) |equal_idx|
                        model.QueryParameter{ .key = raw_param[0..equal_idx], .value = raw_param[equal_idx + "=".len ..] }
                    else
                        model.QueryParameter{ .key = raw_param, .value = null };

                    try request.query.append(query_param);
                }
            } else {
                request.path = raw_path;
            }

            bytes_parsed += space_idx + " ".len;
            break;
        }

        const n = try std.posix.read(socket, buffer[bytes_read..]);
        if (n == 0) return error.EOF;
        bytes_read += n;
    }

    while (true) {
        if (std.mem.indexOf(u8, buffer[bytes_parsed..bytes_read], "\r\n")) |crlf_idx| {
            const raw_version = buffer[bytes_parsed .. bytes_parsed + crlf_idx];

            if (!std.mem.eql(u8, raw_version, "HTTP/1.1")) {
                return error.UnsupportedHttpVersion;
            }

            bytes_parsed += crlf_idx + "\r\n".len;
            break;
        }

        const n = try std.posix.read(socket, buffer[bytes_read..]);
        if (n == 0) return error.EOF;
        bytes_read += n;
    }

    var content_length: ?usize = null;

    while (true) {
        if (std.mem.indexOf(u8, buffer[bytes_parsed..bytes_read], "\r\n")) |crlf_idx| {
            if (crlf_idx == 0) {
                bytes_parsed += "\r\n".len;
                break;
            }

            const raw_header = buffer[bytes_parsed .. bytes_parsed + crlf_idx];
            if (!isAscii(raw_header)) return error.NotAscii;

            if (std.mem.indexOf(u8, raw_header, ":")) |colon_idx| {
                const key = raw_header[0..colon_idx];
                if (key.len == 0) return error.MissingHeaderKey;

                const value_idx = blk: {
                    const after_colon_idx = colon_idx + ":".len;
                    for (raw_header[after_colon_idx..], 0..) |c, i| {
                        if (c != ' ' and c != '\t') {
                            break :blk after_colon_idx + i;
                        }
                    }
                    break :blk raw_header.len; // all whitespace, empty value
                };
                const value = raw_header[value_idx..];

                try request.headers.append(model.Header{ .key = key, .value = value });

                // TODO: consider handling body afterwards
                if (std.ascii.eqlIgnoreCase(key, "content-length")) {
                    // if (content_length != null) return error.InvalidContentLength; // TODO: chunked_transfer_encoding ovverides? (initially false)
                    content_length = std.fmt.parseInt(usize, value, 10) catch return error.InvalidContentLength;
                }
            }

            bytes_parsed += crlf_idx + "\r\n".len;
            continue;
        }

        const n = try std.posix.read(socket, buffer[bytes_read..]);
        if (n == 0) return error.EOF;
        bytes_read += n;
    }

    if (content_length) |len| {
        // TODO: otherwise assume zero length?
        while (bytes_read < bytes_parsed + len) {
            const n = try std.posix.read(socket, buffer[bytes_read..]);
            if (n == 0) return error.EOF;
            bytes_read += n;
        }

        request.body = buffer[bytes_parsed .. bytes_parsed + len];
    }
}

fn isAscii(string: []const u8) bool {
    for (string) |c| {
        if (!std.ascii.isAscii(c)) return false;
    }
    return true;
}

fn writeInto(socket: std.posix.fd_t, response: *const model.Response) !void {
    {
        const http_version = "HTTP/1.1 ";
        const n = try std.posix.write(socket, http_version);
        std.debug.assert(n == http_version.len);
    }
    {
        var buffer: [20]u8 = undefined;
        const status = std.fmt.bufPrintIntToSlice(&buffer, @intFromEnum(response.status), 10, .lower, .{});

        const n = try std.posix.write(socket, status);
        std.debug.assert(n == status.len);
    }

    const reason_phrase = response.reason_phrase orelse response.status.defaultReasonPhrase();
    if (reason_phrase) |reason| {
        if (reason.len > 0) {
            {
                const space = " ";
                const n = try std.posix.write(socket, space);
                std.debug.assert(n == space.len);
            }

            const n = try std.posix.write(socket, reason);
            std.debug.assert(n == reason.len);
        }
    }
    {
        const newline = "\r\n";
        const n = try std.posix.write(socket, newline);
        std.debug.assert(n == newline.len);
    }
    for (response.headers.items) |header| {
        {
            const n = try std.posix.write(socket, header.key);
            std.debug.assert(n == header.key.len);
        }

        {
            const n = try std.posix.write(socket, ": ");
            std.debug.assert(n == ": ".len);
        }

        {
            const n = try std.posix.write(socket, header.value);
            std.debug.assert(n == header.value.len);
        }

        {
            const newline = "\r\n";
            const n = try std.posix.write(socket, newline);
            std.debug.assert(n == newline.len);
        }
    }
    {
        const newline = "\r\n";
        const n = try std.posix.write(socket, newline);
        std.debug.assert(n == newline.len);
    }

    const n = try std.posix.write(socket, response.body);
    std.debug.assert(n == response.body.len);

    std.posix.close(socket);
}

// for tests
fn socketPair() ![2]i32 {
    var fds: [2]i32 = undefined;
    const result = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    try std.testing.expectEqual(result, 0);
    return .{ fds[0], fds[1] };
}

// for tests
fn writeSlowly(socket: std.posix.fd_t, request: []const u8) !void {
    var rng = std.Random.DefaultPrng.init(@intCast(std.time.timestamp()));
    var random = rng.random();

    var bytes_wrote: usize = 0;

    while (bytes_wrote < request.len) {
        const n = random.uintAtMost(usize, request.len - bytes_wrote);
        bytes_wrote += try std.posix.write(socket, request[bytes_wrote .. bytes_wrote + n]);

        std.log.warn("wrote {d} bytes", .{n});
        std.Thread.sleep(random.uintAtMost(u64, 100) * std.time.ns_per_us);
    }

    std.posix.close(socket);
}

test "receives request - GET method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    try readInto(b, &request);

    // then
    try std.testing.expectEqualDeep(request.method, .get);
}

test "receives request - HEAD method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "HEAD / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    try readInto(b, &request);

    // then
    try std.testing.expectEqualDeep(request.method, .head);
}

test "receives request - non-standard method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "BOOP / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    try readInto(b, &request);

    // then
    try std.testing.expectEqualDeep(request.method, model.Method{ .other = "BOOP" });
}

test "receives request - fails on empty method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, " / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.MissingMethod, result);
}

test "receives request - fails on non-ascii method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "über / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.NotAscii, result);
}

test "receives request - index path" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    try readInto(b, &request);

    // then
    try std.testing.expectEqualStrings(request.path, "/");
    try std.testing.expectEqual(request.query.items.len, 0);
}

test "receives request - non-index path with query parameters" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{
        a,
        "GET /foo/bar?foo=bar&duplicate=1&duplicate=2&empty=&flag& HTTP/1.1\r\nHost: example.com\r\n\r\n",
    });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    try readInto(b, &request);

    // then
    try std.testing.expectEqualStrings(request.path, "/foo/bar");
    try std.testing.expectEqual(request.query.items.len, 6);
    try std.testing.expectEqualDeep(request.query.items[0], model.QueryParameter{ .key = "foo", .value = "bar" });
    try std.testing.expectEqualDeep(request.query.items[1], model.QueryParameter{ .key = "duplicate", .value = "1" });
    try std.testing.expectEqualDeep(request.query.items[2], model.QueryParameter{ .key = "duplicate", .value = "2" });
    try std.testing.expectEqualDeep(request.query.items[3], model.QueryParameter{ .key = "empty", .value = "" });
    try std.testing.expectEqualDeep(request.query.items[4], model.QueryParameter{ .key = "flag", .value = null });
    try std.testing.expectEqualDeep(request.query.items[5], model.QueryParameter{ .key = "", .value = null });
}

test "receives request - fails on missing path" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET  HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.MissingPath, result);
}

test "receives request - fails on missing path with query parameters" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET ?foo=bar HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.MissingPath, result);
}

test "receives request - fails on non-ascii path" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET /über HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.NotAscii, result);
}

test "receives request - fails on non-v1.1" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/0.9\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.UnsupportedHttpVersion, result);
}

test "receives request - headers" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{
        a,
        "GET / HTTP/1.1\r\nHost: example.com\r\nwithout:space\r\nwith: \t space\r\nduplicate: 1\r\nduplicate: 2\r\nempty:    \r\n\r\n",
    });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    try readInto(b, &request);

    // then
    try std.testing.expectEqual(request.headers.items.len, 6);
    try std.testing.expectEqualDeep(request.headers.items[0], model.Header{ .key = "Host", .value = "example.com" });
    try std.testing.expectEqualDeep(request.headers.items[1], model.Header{ .key = "without", .value = "space" });
    try std.testing.expectEqualDeep(request.headers.items[2], model.Header{ .key = "with", .value = "space" });
    try std.testing.expectEqualDeep(request.headers.items[3], model.Header{ .key = "duplicate", .value = "1" });
    try std.testing.expectEqualDeep(request.headers.items[4], model.Header{ .key = "duplicate", .value = "2" });
    try std.testing.expectEqualDeep(request.headers.items[5], model.Header{ .key = "empty", .value = "" });
}

test "receives request - fails on missing header key" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/1.1\r\nHost: example.com\r\n:foo\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.MissingHeaderKey, result);
}

test "receives request - fails on non-ascii header" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/1.1\r\nHost: über.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.NotAscii, result);
}

test "receives request - empty body" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    try readInto(b, &request);

    // then
    try std.testing.expectEqualStrings(request.body, "");
}

test "receives request - non-empty body" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "POST /greeting HTTP/1.1\r\nHost: example.com\r\ncontent-length: 5\r\n\r\nhello" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    try readInto(b, &request);

    // then
    try std.testing.expectEqualStrings(request.body, "hello");
}

test "receives request - fails on negative content-length" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "POST /greeting HTTP/1.1\r\nHost: example.com\r\ncontent-length: -5\r\n\r\nhello" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.InvalidContentLength, result);
}

test "receives request - fails on non-base-10 content-length" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "POST /greeting HTTP/1.1\r\nHost: example.com\r\ncontent-length: 0xAA\r\n\r\nhello" });
    defer handle.join();

    var request = try model.Request.init(std.testing.allocator);
    defer request.deinit();

    // when
    const result = readInto(b, &request);

    // then
    try std.testing.expectError(error.InvalidContentLength, result);
}

// for tests
fn readToEnd(socket: std.posix.fd_t, buffer: []u8) ![]u8 {
    var bytes_read: usize = 0;
    while (true) {
        const n = try std.posix.read(socket, buffer[bytes_read..]);
        if (n == 0) break;
        bytes_read += n;
    }
    return buffer[0..bytes_read];
}

test "sends response - 200 status" {
    // given
    const a, const b = try socketPair();

    var response = try model.Response.init(std.testing.allocator);
    defer response.deinit();

    try response.headers.append(model.Header{ .key = "content-length", .value = "0" });

    // when
    try writeInto(a, &response);

    // then
    var buffer: [1024]u8 = undefined;
    const serialized = try readToEnd(b, &buffer);

    try std.testing.expectEqualStrings(serialized, "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n");
}

test "sends response - 204 status" {
    // given
    const a, const b = try socketPair();

    var response = try model.Response.init(std.testing.allocator);
    defer response.deinit();

    response.status = .no_content;
    // no content length

    // when
    try writeInto(a, &response);

    // then
    var buffer: [1024]u8 = undefined;
    const serialized = try readToEnd(b, &buffer);

    try std.testing.expectEqualStrings(serialized, "HTTP/1.1 204 No Content\r\n\r\n");
}

test "sends response - non-standard status" {
    // given
    const a, const b = try socketPair();

    var response = try model.Response.init(std.testing.allocator);
    defer response.deinit();

    response.status = @enumFromInt(599);
    try response.headers.append(model.Header{ .key = "content-length", .value = "0" });

    // when
    try writeInto(a, &response);

    // then
    var buffer: [1024]u8 = undefined;
    const serialized = try readToEnd(b, &buffer);

    try std.testing.expectEqualStrings(serialized, "HTTP/1.1 599\r\ncontent-length: 0\r\n\r\n");
}

test "sends response - custom reason phrase" {
    // given
    const a, const b = try socketPair();

    var response = try model.Response.init(std.testing.allocator);
    defer response.deinit();

    response.reason_phrase = "Well Done";
    try response.headers.append(model.Header{ .key = "content-length", .value = "0" });

    // when
    try writeInto(a, &response);

    // then
    var buffer: [1024]u8 = undefined;
    const serialized = try readToEnd(b, &buffer);

    try std.testing.expectEqualStrings(serialized, "HTTP/1.1 200 Well Done\r\ncontent-length: 0\r\n\r\n");
}

test "sends response - with body" {
    // given
    const a, const b = try socketPair();

    var response = try model.Response.init(std.testing.allocator);
    defer response.deinit();

    try response.headers.append(model.Header{ .key = "content-length", .value = "5" });
    response.body = "hello";

    // when
    try writeInto(a, &response);

    // then
    var buffer: [1024]u8 = undefined;
    const serialized = try readToEnd(b, &buffer);

    try std.testing.expectEqualStrings(serialized, "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello");
}
