const std = @import("std");

const c = @cImport(@cInclude("multipart_parser.h"));

const model = @import("model.zig");

/// Creates with request.multipartFormData(allocator);
pub const MultipartFormData = struct {
    parts: std.ArrayList(Part),

    /// Consumes self.
    pub fn deinit(self: MultipartFormData) void {
        for (self.parts.items) |part| {
            part.headers.deinit();
        }

        self.parts.deinit();
    }

    /// Finds the first occurrence of part by name, if any.
    pub fn findPart(self: MultipartFormData, name: []const u8) ?Part {
        for (self.parts.items) |part| {
            if (std.mem.eql(u8, part.name, name)) {
                return part;
            }
        }

        return null;
    }
};

pub fn parseBoundary(content_type: []const u8) ![]const u8 {
    const mime_type_prefix = "multipart/form-data;";
    if (!std.mem.startsWith(u8, content_type, mime_type_prefix)) {
        return error.InvalidContentType;
    }
    const raw_boundary = content_type[mime_type_prefix.len..];

    const boundary_prefix = "boundary=";
    if (std.mem.indexOf(u8, raw_boundary, boundary_prefix)) |prefix_idx| {
        const boundary = raw_boundary[prefix_idx + boundary_prefix.len ..];
        if (boundary[0] == '"' and boundary[boundary.len - 1] == '"') {
            return boundary[1 .. boundary.len - 1];
        }
        return boundary;
    } else {
        return error.MissingBoundary;
    }
}

// parse shouldn't need dependency of request. take content-type header value and body.
pub fn parseBody(allocator: std.mem.Allocator, boundary: []const u8, body: []const u8) !MultipartFormData {
    var parts = try std.ArrayList(Part).initCapacity(allocator, 8);
    errdefer {
        for (parts.items) |part| {
            part.headers.deinit();
        }
        parts.deinit();
    }

    var callbacks = std.mem.zeroes(c.multipart_parser_settings);
    callbacks.on_header_field = onHeaderField;
    callbacks.on_header_value = onHeaderValue;
    callbacks.on_part_data = onPartData;
    callbacks.on_part_data_begin = onPartDataBegin;
    callbacks.on_part_data_end = onPartDataEnd;
    callbacks.on_body_end = onBodyEnd;

    const c_boundary = try extendBoundaryZ(allocator, boundary);
    defer allocator.free(c_boundary);

    const multipart_parser = c.multipart_parser_init(c_boundary, &callbacks);
    std.debug.assert(multipart_parser != null);
    defer c.multipart_parser_free(multipart_parser);

    var parser = Parser{
        .allocator = allocator,
        .parts = &parts,
        ._temp_headers = null,
        ._temp_header_field = null,
        ._body_finished = false,
    };

    c.multipart_parser_set_data(multipart_parser, @ptrCast(&parser));

    const bytes_parsed = c.multipart_parser_execute(multipart_parser, @ptrCast(body), body.len);
    if (bytes_parsed != body.len) return error.InvalidBody;
    if (!parser._body_finished) return error.InvalidBody;

    return MultipartFormData{ .parts = parts };
}

fn extendBoundaryZ(allocator: std.mem.Allocator, boundary: []const u8) ![:0]const u8 {
    const c_boundary = try allocator.alloc(u8, boundary.len + 3);

    c_boundary[0] = '-';
    c_boundary[1] = '-';
    @memcpy(c_boundary[2 .. 2 + boundary.len], boundary);
    c_boundary[2 + boundary.len] = 0; // null terminated

    return c_boundary[0 .. boundary.len + 2 :0];
}

const Parser = struct {
    allocator: std.mem.Allocator,
    parts: *std.ArrayList(Part),
    _temp_headers: ?std.ArrayList(model.Header),
    _temp_header_field: ?[]const u8,
    _body_finished: bool,
};

fn onPartDataBegin(p: ?*c.multipart_parser) callconv(.c) c_int {
    const parser: *Parser = @ptrCast(@alignCast(c.multipart_parser_get_data(p).?));
    std.debug.assert(parser._temp_headers == null);
    parser._temp_headers = std.ArrayList(model.Header).initCapacity(parser.allocator, 8) catch return 1;
    return 0;
}

fn onHeaderField(p: ?*c.multipart_parser, at: [*c]const u8, length: usize) callconv(.c) c_int {
    const parser: *Parser = @ptrCast(@alignCast(c.multipart_parser_get_data(p).?));
    std.debug.assert(parser._temp_header_field == null);
    parser._temp_header_field = at[0..length];
    return 0;
}

fn onHeaderValue(p: ?*c.multipart_parser, at: [*c]const u8, length: usize) callconv(.c) c_int {
    const parser: *Parser = @ptrCast(@alignCast(c.multipart_parser_get_data(p).?));
    const header = model.Header{ .key = parser._temp_header_field.?, .value = at[0..length] };
    parser._temp_headers.?.append(header) catch return 1;
    parser._temp_header_field = null;
    return 0;
}

fn onPartData(p: ?*c.multipart_parser, at: [*c]const u8, length: usize) callconv(.c) c_int {
    const parser: *Parser = @ptrCast(@alignCast(c.multipart_parser_get_data(p).?));

    var name: ?[]const u8 = null;
    var filename: ?[]const u8 = null;
    for (parser._temp_headers.?.items) |header| {
        if (std.ascii.eqlIgnoreCase(header.key, "content-disposition")) {
            const name_prefix = "name=\"";
            if (std.mem.indexOf(u8, header.value, name_prefix)) |name_prefix_idx| {
                if (std.mem.indexOfPos(u8, header.value, name_prefix_idx + name_prefix.len, "\"")) |name_postfix_idx| {
                    if (name != null) return -1;
                    name = header.value[name_prefix_idx + name_prefix.len .. name_postfix_idx];

                    // FIXME: in-place decode
                    // name = std.Uri.percentDecodeInPlace(@constCast(name.?));
                } else {
                    return -1;
                }
            } else {
                return -1;
            }

            const filename_prefix = "filename=\"";
            if (std.mem.indexOf(u8, header.value, filename_prefix)) |filename_prefix_idx| {
                if (std.mem.indexOfPos(u8, header.value, filename_prefix_idx + filename_prefix.len, "\"")) |filename_postfix_idx| {
                    if (filename != null) return -1;
                    filename = header.value[filename_prefix_idx + filename_prefix.len .. filename_postfix_idx];

                    // FIXME: in-place decode
                    // filename = std.Uri.percentDecodeInPlace(@constCast(filename.?));
                } else {
                    return -1;
                }
            }

            break;
        }
    } else {
        return -1;
    }

    if (name == null) return -1;

    const part = Part{
        .headers = parser._temp_headers.?,
        .name = name.?,
        .filename = filename,
        .data = at[0..length],
    };
    parser.parts.append(part) catch return 1;
    return 0;
}

fn onPartDataEnd(p: ?*c.multipart_parser) callconv(.c) c_int {
    const parser: *Parser = @ptrCast(@alignCast(c.multipart_parser_get_data(p).?));
    std.debug.assert(parser._temp_headers != null);
    parser._temp_headers = null;
    return 0;
}

fn onBodyEnd(p: ?*c.multipart_parser) callconv(.c) c_int {
    const parser: *Parser = @alignCast(@ptrCast(c.multipart_parser_get_data(p).?));
    parser._body_finished = true;
    return 0;
}

pub const Part = struct {
    headers: std.ArrayList(model.Header),
    name: []const u8,
    filename: ?[]const u8,
    data: []const u8,

    /// Finds the first occurrence of header by key, if any, returning the value.
    pub fn findHeader(self: Part, key: []const u8) ?[]const u8 {
        for (self.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.key, key)) {
                return header.value;
            }
        }

        return null;
    }

    /// Conforms to https://datatracker.ietf.org/doc/html/rfc7578#section-4.4.
    pub fn contentType(self: Part) []const u8 {
        return switch (self.filename) {
            _ => self.findHeader("content-type") orelse "application/octet-stream",
            null => self.findHeader("content-type") orelse "text/plain",
        };
    }
};

test "parses boundary - simple" {
    // given
    const header = "multipart/form-data; boundary=----WebKitFormBoundaryePkpFF7tjBAqx29L";

    // when
    const boundary = try parseBoundary(header);

    // then
    try std.testing.expectEqualStrings(boundary, "----WebKitFormBoundaryePkpFF7tjBAqx29L");
}

test "parses boundary - quotes" {
    // given
    const header = "multipart/form-data; boundary=\"--MyCustomBoundary123\"";

    // when
    const boundary = try parseBoundary(header);

    // then
    try std.testing.expectEqualStrings(boundary, "--MyCustomBoundary123");
}

test "parses boundary - not multipart form data" {
    // given
    const header = "application/x-www-form-urlencoded";

    // when
    const result = parseBoundary(header);

    // then
    try std.testing.expectError(error.InvalidContentType, result);
}

test "parses boundary - missing boundary" {
    // given
    const header = "multipart/form-data;";

    // when
    const result = parseBoundary(header);

    // then
    try std.testing.expectError(error.MissingBoundary, result);
}

test "parses body - simple" {
    // given
    const boundary = "--example-1";
    const body = "--example-1\r\n" ++
        "Content-Disposition: form-data; name=\"text1\"\r\n" ++
        "\r\n" ++
        "hello\r\n" ++
        "--example-1--";

    // when
    const multipart_form_data = try parseBody(std.testing.allocator, boundary, body);
    defer multipart_form_data.deinit();

    // then
    try std.testing.expectEqual(multipart_form_data.parts.items.len, 1);
    try std.testing.expectEqual(multipart_form_data.parts.items[0].headers.items.len, 1);
    try std.testing.expectEqualDeep(multipart_form_data.parts.items[0].headers.items[0], model.Header{ .key = "Content-Disposition", .value = "form-data; name=\"text1\"" });
    try std.testing.expectEqualStrings(multipart_form_data.parts.items[0].name, "text1");
    try std.testing.expectEqual(multipart_form_data.parts.items[0].filename, null);
    try std.testing.expectEqualStrings(multipart_form_data.parts.items[0].data, "hello");
}

// test "parses body - percent encoded" {
//     // given
//     const boundary = "--example-1";
//     const body = "--example-1\r\n" ++
//         "Content-Disposition: form-data; name=\"per%20cent\" filename=\"enc%20oded\"\r\n" ++
//         "\r\n" ++
//         "he%20llo\r\n" ++
//         "--example-1--";

//     // when
//     const multipart_form_data = try parseBody(std.testing.allocator, boundary, body);
//     defer multipart_form_data.deinit();

//     // then
//     try std.testing.expectEqual(multipart_form_data.parts.items.len, 1);
//     try std.testing.expectEqual(multipart_form_data.parts.items[0].headers.items.len, 1);
//     try std.testing.expectEqualDeep(multipart_form_data.parts.items[0].headers.items[0], model.Header{ .key = "Content-Disposition", .value = "form-data; name=\"per%20cent\" filename=\"enc%20oded\"" });
//     try std.testing.expectEqualStrings(multipart_form_data.parts.items[0].name, "per cent");
//     try std.testing.expectEqual(multipart_form_data.parts.items[0].filename, "enc oded");
//     try std.testing.expectEqualStrings(multipart_form_data.parts.items[0].data, "he%20llo");
// }

test "parses body - incomplete body" {
    // given
    const boundary = "--example-1";
    const body = "--example-1\r\n" ++
        "Content-Disposition: form-data; name=\"text1\"\r\n" ++
        "\r\n" ++
        "hello\r\n" ++
        "--exa";

    // when
    const result = parseBody(std.testing.allocator, boundary, body);

    // then
    try std.testing.expectError(error.InvalidBody, result);
}
