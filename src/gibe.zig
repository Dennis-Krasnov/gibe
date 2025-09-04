const std = @import("std");

const model = @import("model.zig");
const server = @import("server.zig");

pub const Request = model.Request;
pub const Method = model.Method;
pub const QueryParameter = model.QueryParameter;
pub const Header = model.Header;
pub const Response = model.Response;
pub const StatusCode = model.StatusCode;

pub const Server = server.Server;

/// Convenience function for testing.
/// Leaks memory, as tests don't need to clean up after themselves.
///
/// Usage:
/// const arena, var request, var response = gibe.leakyInit();
/// request.body = "hello";
/// try handle(arena, &request, &response);
/// try std.testing.expectEqual(response.status, .ok);
/// try std.testing.expectEqualStrings(response.body, "");
pub fn leakyInit() struct { std.mem.Allocator, Request, Response } {
    const request = Request{
        .method = .get,
        .path = "/",
        .query = std.array_list.Managed(QueryParameter).init(std.heap.smp_allocator),
        .headers = std.array_list.Managed(Header).init(std.heap.smp_allocator),
        .body = "",
    };

    const response = Response{
        .status = .ok,
        .reason_phrase = null,
        .headers = std.array_list.Managed(Header).init(std.heap.smp_allocator),
        .body = "",
    };

    return .{ std.heap.smp_allocator, request, response };
}
