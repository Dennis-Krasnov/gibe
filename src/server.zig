const std = @import("std");

const model = @import("model.zig");
const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;

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
    pub fn run(self: *Server, socket: std.posix.socket_t, comptime State: type, handler: Handler(State), state: State) !void {
        defer _ = self.arena.reset(.retain_capacity);
        const arena_allocator = self.arena.allocator();

        var circular_buffer = try CircularBuffer.init(4096);
        defer circular_buffer.deinit();

        var request = try readInto(arena_allocator, socket, &circular_buffer);

        var response = model.Response{
            .status = .ok,
            .reason_phrase = null,
            .headers = try std.ArrayList(model.Header).initCapacity(arena_allocator, 32),
            .body = "",
        };

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

fn readInto(allocator: std.mem.Allocator, socket: std.posix.fd_t, circular_buffer: *CircularBuffer) !model.Request {
    var request = model.Request{
        .method = .get,
        .path = "/",
        .query = try std.ArrayList(model.QueryParameter).initCapacity(allocator, 8),
        .headers = try std.ArrayList(model.Header).initCapacity(allocator, 32),
        .body = "",
    };
    errdefer request.query.deinit();
    errdefer request.headers.deinit();

    var bytes_parsed: usize = 0;

    while (true) {
        // TODO: place after if for symmetry. do one unconditional before the loop?
        if (circular_buffer.data().len == circular_buffer.size) return error.RequestTooBig;
        const n = try std.posix.read(socket, circular_buffer.uninitialized());
        if (n == 0) return error.EOF; // TODO: more descriptive error
        circular_buffer.commit(n);

        if (std.mem.indexOf(u8, circular_buffer.data()[bytes_parsed..], " ")) |space_idx| {
            if (space_idx == 0) return error.MissingMethod;
            const raw_method = circular_buffer.data()[bytes_parsed .. bytes_parsed + space_idx];
            if (!isAscii(raw_method)) return error.NotAscii;

            request.method = stringToMethod.get(raw_method) orelse .{ .other = raw_method };

            bytes_parsed += space_idx + " ".len;
            break;
        }
    }

    while (true) {
        if (std.mem.indexOf(u8, circular_buffer.data()[bytes_parsed..], " ")) |space_idx| {
            if (space_idx == 0) return error.MissingPath;
            const raw_path = circular_buffer.data()[bytes_parsed .. bytes_parsed + space_idx];
            if (!isAscii(raw_path)) return error.NotAscii;

            if (std.mem.indexOf(u8, raw_path, "?")) |question_idx| {
                if (question_idx == 0) return error.MissingPath;
                request.path = raw_path[0..question_idx];

                var iter = std.mem.splitScalar(u8, raw_path[question_idx + "?".len ..], '&');
                while (iter.next()) |raw_param| {
                    const query_param = if (std.mem.indexOf(u8, raw_param, "=")) |equal_idx| blk: {
                        const key = percentToUrlEncoding(std.Uri.percentDecodeInPlace(@constCast(raw_param[0..equal_idx])));
                        const value = percentToUrlEncoding(std.Uri.percentDecodeInPlace(@constCast(raw_param[equal_idx + "=".len ..])));
                        break :blk model.QueryParameter{ .key = key, .value = value };
                    } else blk: {
                        const key = percentToUrlEncoding(std.Uri.percentDecodeInPlace(@constCast(raw_param)));
                        break :blk model.QueryParameter{ .key = key, .value = null };
                    };

                    try request.query.append(query_param);
                }
            } else {
                request.path = raw_path;
            }

            bytes_parsed += space_idx + " ".len;
            break;
        }

        if (circular_buffer.data().len == circular_buffer.size) return error.RequestTooBig;
        const n = try std.posix.read(socket, circular_buffer.uninitialized());
        if (n == 0) return error.EOF; // TODO: more descriptive error
        circular_buffer.commit(n);
    }

    while (true) {
        if (std.mem.indexOf(u8, circular_buffer.data()[bytes_parsed..], "\r\n")) |crlf_idx| {
            const raw_version = circular_buffer.data()[bytes_parsed .. bytes_parsed + crlf_idx];

            if (!std.mem.eql(u8, raw_version, "HTTP/1.1")) {
                return error.UnsupportedHttpVersion;
            }

            bytes_parsed += crlf_idx + "\r\n".len;
            break;
        }

        if (circular_buffer.data().len == circular_buffer.size) return error.RequestTooBig;
        const n = try std.posix.read(socket, circular_buffer.uninitialized());
        if (n == 0) return error.EOF; // TODO: more descriptive error
        circular_buffer.commit(n);
    }

    var content_length: ?usize = null;

    while (true) {
        if (std.mem.indexOf(u8, circular_buffer.data()[bytes_parsed..], "\r\n")) |crlf_idx| {
            if (crlf_idx == 0) {
                bytes_parsed += "\r\n".len;
                break;
            }

            const raw_header = circular_buffer.data()[bytes_parsed .. bytes_parsed + crlf_idx];
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

        if (circular_buffer.data().len == circular_buffer.size) return error.RequestTooBig;
        const n = try std.posix.read(socket, circular_buffer.uninitialized());
        if (n == 0) return error.EOF; // TODO: more descriptive error
        circular_buffer.commit(n);
    }

    if (content_length) |len| {
        // TODO: otherwise assume zero length?
        while (circular_buffer.data().len < bytes_parsed + len) {
            if (circular_buffer.data().len == circular_buffer.size) return error.RequestTooBig;
            const n = try std.posix.read(socket, circular_buffer.uninitialized());
            if (n == 0) return error.EOF; // TODO: more descriptive error
            circular_buffer.commit(n);
        }

        request.body = circular_buffer.data()[bytes_parsed .. bytes_parsed + len];
    }

    return request;
}

fn isAscii(string: []const u8) bool {
    for (string) |c| {
        if (!std.ascii.isAscii(c)) return false;
    }
    return true;
}

fn percentToUrlEncoding(string: []u8) []const u8 {
    for (string) |*c| {
        if (c.* == '+') {
            c.* = ' ';
        }
    }

    return string;
}

fn writeInto(socket: std.posix.fd_t, response: *const model.Response) !void {
    const stream = std.net.Stream{ .handle = socket };

    // TODO: ArrayList on the arena. then writev (stream.writevAll(.{});)

    var buffered = std.io.bufferedWriter(stream.writer());
    try buffered.writer().print("HTTP/1.1 {d}", .{@intFromEnum(response.status)});
    if (response.reason_phrase orelse response.status.defaultReasonPhrase()) |reason| {
        if (reason.len > 0) {
            try buffered.writer().writeAll(" ");
            try buffered.writer().writeAll(reason);
        }
    }
    try buffered.writer().writeAll("\r\n");
    for (response.headers.items) |header| {
        try buffered.writer().print("{s}: {s}\r\n", .{ header.key, header.value });
    }
    try buffered.writer().writeAll("\r\n");
    try buffered.flush();

    try stream.writeAll(response.body);

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

        std.Thread.sleep(random.uintAtMost(u64, 100) * std.time.ns_per_us);
    }

    std.posix.close(socket);
}

test "receives request - GET method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const request = try readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectEqualDeep(request.method, .get);
}

test "receives request - HEAD method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "HEAD / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const request = try readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectEqualDeep(request.method, .head);
}

test "receives request - non-standard method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "BOOP / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const request = try readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectEqualDeep(request.method, model.Method{ .other = "BOOP" });
}

test "receives request - fails on empty method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, " / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectError(error.MissingMethod, result);
}

test "receives request - fails on non-ascii method" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "über / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectError(error.NotAscii, result);
}

test "receives request - index path" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const request = try readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectEqualStrings(request.path, "/");
    try std.testing.expectEqual(request.query.items.len, 0);
}

test "receives request - non-index path with query parameters" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{
        a,
        "GET /foo/bar?foo=bar&per+cent=enc%20oded&duplicate=1&duplicate=2&empty=&flag& HTTP/1.1\r\nHost: example.com\r\n\r\n",
    });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const request = try readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectEqualStrings(request.path, "/foo/bar");
    try std.testing.expectEqual(request.query.items.len, 7);
    try std.testing.expectEqualDeep(request.query.items[0], model.QueryParameter{ .key = "foo", .value = "bar" });
    try std.testing.expectEqualDeep(request.query.items[1], model.QueryParameter{ .key = "per cent", .value = "enc oded" });
    try std.testing.expectEqualDeep(request.query.items[2], model.QueryParameter{ .key = "duplicate", .value = "1" });
    try std.testing.expectEqualDeep(request.query.items[3], model.QueryParameter{ .key = "duplicate", .value = "2" });
    try std.testing.expectEqualDeep(request.query.items[4], model.QueryParameter{ .key = "empty", .value = "" });
    try std.testing.expectEqualDeep(request.query.items[5], model.QueryParameter{ .key = "flag", .value = null });
    try std.testing.expectEqualDeep(request.query.items[6], model.QueryParameter{ .key = "", .value = null });
}

test "receives request - fails on missing path" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET  HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectError(error.MissingPath, result);
}

test "receives request - fails on missing path with query parameters" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET ?foo=bar HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectError(error.MissingPath, result);
}

test "receives request - fails on non-ascii path" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET /über HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectError(error.NotAscii, result);
}

test "receives request - fails on non-v1.1" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/0.9\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.heap.smp_allocator, b, &circular_buffer);

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

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const request = try readInto(std.heap.smp_allocator, b, &circular_buffer);

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

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectError(error.MissingHeaderKey, result);
}

test "receives request - fails on non-ascii header" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/1.1\r\nHost: über.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectError(error.NotAscii, result);
}

test "receives request - empty body" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const request = try readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectEqualStrings(request.body, "");
}

test "receives request - non-empty body" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "POST /greeting HTTP/1.1\r\nHost: example.com\r\ncontent-length: 5\r\n\r\nhello" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const request = try readInto(std.heap.smp_allocator, b, &circular_buffer);

    // then
    try std.testing.expectEqualStrings(request.body, "hello");
}

test "receives request - fails on negative content-length" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "POST /greeting HTTP/1.1\r\nHost: example.com\r\ncontent-length: -5\r\n\r\nhello" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.testing.allocator, b, &circular_buffer);

    // then
    try std.testing.expectError(error.InvalidContentLength, result);
}

test "receives request - fails on non-base-10 content-length" {
    // given
    const a, const b = try socketPair();

    const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, "POST /greeting HTTP/1.1\r\nHost: example.com\r\ncontent-length: 0xAA\r\n\r\nhello" });
    defer handle.join();

    var circular_buffer = try CircularBuffer.init(4096);
    defer circular_buffer.deinit();

    // when
    const result = readInto(std.testing.allocator, b, &circular_buffer);

    // then
    try std.testing.expectError(error.InvalidContentLength, result);
}

test "receives request - fails when request too big" {
    const serialized = "POST /greeting HTTP/1.1\r\nHost: example.com\r\ncontent-length: 5\r\n\r\nhello";

    for (1..serialized.len) |buffer_size| {
        // given
        const a, const b = try socketPair();

        const handle = try std.Thread.spawn(.{}, writeSlowly, .{ a, serialized });
        defer handle.join();

        var circular_buffer = try CircularBuffer.init(buffer_size);
        defer circular_buffer.deinit();
        // TODO: artificially fill up with a commit once buffer size is page aligned

        // when
        const result = readInto(std.heap.smp_allocator, b, &circular_buffer);

        // then
        try std.testing.expectError(error.RequestTooBig, result);
    }
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

    var response = model.Response{
        .status = .ok,
        .reason_phrase = null,
        .headers = std.ArrayList(model.Header).init(std.heap.smp_allocator),
        .body = "",
    };

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

    var response = model.Response{
        .status = .no_content,
        .reason_phrase = null,
        .headers = std.ArrayList(model.Header).init(std.heap.smp_allocator),
        .body = "",
    };

    // when
    try writeInto(a, &response);

    // then
    var buffer: [1024]u8 = undefined;
    const serialized = try readToEnd(b, &buffer);

    // no content length
    try std.testing.expectEqualStrings(serialized, "HTTP/1.1 204 No Content\r\n\r\n");
}

test "sends response - non-standard status" {
    // given
    const a, const b = try socketPair();

    var response = model.Response{
        .status = @enumFromInt(599),
        .reason_phrase = null,
        .headers = std.ArrayList(model.Header).init(std.heap.smp_allocator),
        .body = "",
    };
    try response.headers.append(model.Header{ .key = "content-length", .value = "0" });

    // when
    try writeInto(a, &response);

    // then
    var buffer: [1024]u8 = undefined;
    const serialized = try readToEnd(b, &buffer);

    try std.testing.expectEqualStrings(serialized, "HTTP/1.1 599\r\ncontent-length: 0\r\n\r\n");
}

test "sends response - empty reason phrase" {
    // given
    const a, const b = try socketPair();

    var response = model.Response{
        .status = .ok,
        .reason_phrase = "",
        .headers = std.ArrayList(model.Header).init(std.heap.smp_allocator),
        .body = "",
    };
    try response.headers.append(model.Header{ .key = "content-length", .value = "0" });

    // when
    try writeInto(a, &response);

    // then
    var buffer: [1024]u8 = undefined;
    const serialized = try readToEnd(b, &buffer);

    try std.testing.expectEqualStrings(serialized, "HTTP/1.1 200\r\ncontent-length: 0\r\n\r\n");
}

test "sends response - custom reason phrase" {
    // given
    const a, const b = try socketPair();

    var response = model.Response{
        .status = .ok,
        .reason_phrase = "Well Done",
        .headers = std.ArrayList(model.Header).init(std.heap.smp_allocator),
        .body = "",
    };
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

    var response = model.Response{
        .status = .ok,
        .reason_phrase = null,
        .headers = std.ArrayList(model.Header).init(std.heap.smp_allocator),
        .body = "hello",
    };
    try response.headers.append(model.Header{ .key = "content-length", .value = "5" });

    // when
    try writeInto(a, &response);

    // then
    var buffer: [1024]u8 = undefined;
    const serialized = try readToEnd(b, &buffer);

    try std.testing.expectEqualStrings(serialized, "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhello");
}
