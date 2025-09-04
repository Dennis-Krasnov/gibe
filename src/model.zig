const std = @import("std");
const multipart_form_data = @import("multipart_form_data.zig");

pub const MultipartFormData = multipart_form_data.MultipartFormData;
pub const Part = multipart_form_data.Part;

/// Created and destroyed by the library.
/// Use gibe.leakyInit() to create an instance for testing.
pub const Request = struct {
    method: Method,
    /// Part of URI.
    path: []const u8,
    /// Part of URI.
    query: std.array_list.Managed(QueryParameter),
    headers: std.array_list.Managed(Header),
    body: []const u8,

    /// Finds the first occurrence of query pameter by key, if any, returning the value.
    pub fn findQuery(self: Request, key: []const u8) ?[]const u8 {
        for (self.query.items) |param| {
            if (std.ascii.eqlIgnoreCase(param.key, key)) {
                return param.value;
            }
        }

        return null;
    }

    /// Finds the first occurrence of header by key, if any, returning the value.
    pub fn findHeader(self: Request, key: []const u8) ?[]const u8 {
        for (self.headers.items) |header| {
            if (std.ascii.eqlIgnoreCase(header.key, key)) {
                return header.value;
            }
        }

        return null;
    }

    /// ...
    // TODO: error should be union of the two parses and missing
    pub fn multipartFormData(self: Request, allocator: std.mem.Allocator) !MultipartFormData {
        const content_type = self.findHeader("content-type") orelse return error.MissingContentType;
        const boundary = try multipart_form_data.parseBoundary(content_type);
        return multipart_form_data.parseBody(allocator, boundary, self.body);
    }
};

/// Request methods.
pub const Method = union(enum) {
    /// The GET method requests a representation of the specified resource.
    /// Requests using GET should only retrieve data and should not contain a request content.
    /// Safe, idempotent, cacheable.
    get,
    /// The HEAD method asks for a response identical to a GET request, but without a response body.
    /// Safe, idempotent, cacheable.
    head,
    /// The OPTIONS method describes the communication options for the target resource.
    /// Safe, idempotent, NOT cacheable.
    options,
    /// The TRACE method performs a message loop-back test along the path to the target resource.
    /// Safe, idempotent, NOT cacheable.
    trace,
    /// The PUT method replaces all current representations of the target resource with the request content.
    /// NOT safe, idempotent, NOT cacheable.
    put,
    /// The DELETE method deletes the specified resource.
    /// NOT safe, idempotent, NOT cacheable.
    delete,
    /// The POST method submits an entity to the specified resource, often causing a change in state or side effects on the server.
    /// NOT safe, NOT idempotent, cacheable if response explicitly include freshness information and a matching Content-Location header.
    post,
    /// The PATCH method applies partial modifications to a resource.
    /// NOT safe, NOT idempotent, cacheable if response explicitly include freshness information and a matching Content-Location header.
    patch,
    /// The CONNECT method establishes a tunnel to the server identified by the target resource.
    /// NOT safe, NOT idempotent, NOT cacheable.
    connect,
    /// Unofficial methods.
    other: []const u8,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .get => "GET",
            .head => "HEAD",
            .options => "OPTIONS",
            .trace => "TRACE",
            .put => "PUT",
            .delete => "DELETE",
            .post => "POST",
            .patch => "PATCH",
            .connect => "CONNECT",
            .other => |string| string,
        };
    }
};

pub const QueryParameter = struct {
    key: []const u8,
    value: ?[]const u8,
};

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

/// Created and destroyed by the library.
/// Use gibe.leakyInit() to create an instance for testing.
pub const Response = struct {
    status: StatusCode,
    reason_phrase: ?[]const u8,
    headers: std.array_list.Managed(Header),
    body: []const u8,
};

/// Response status codes.
/// Create a custom status with @enumFromInt(n).
pub const StatusCode = enum(u10) {
    /// This interim response indicates that the client should continue the request or ignore the response if the request is already finished.
    @"continue" = 100,
    /// This code is sent in response to an Upgrade request header from the client and indicates the protocol the server is switching to.
    switching_protocols = 101,
    /// This code was used in WebDAV contexts to indicate that a request has been received by the server, but no status was available at the time of the response.
    processing = 102,
    /// This status code is primarily intended to be used with the Link header,
    /// letting the user agent start preloading resources while the server prepares a response or preconnect to an origin from which the page will need resources.
    early_hints = 103,
    /// The request succeeded.
    /// The result and meaning of "success" depends on the HTTP method:
    /// - GET: The resource has been fetched and transmitted in the message body.
    /// - HEAD: Representation headers are included in the response without any message body.
    /// - PUT or POST: The resource describing the result of the action is transmitted in the message body.
    /// - TRACE: The message body contains the request as received by the server.
    ok = 200,
    /// The request succeeded, and a new resource was created as a result. This is typically the response sent after POST requests, or some PUT requests.
    created = 201,
    /// The request has been received but not yet acted upon.
    /// It is noncommittal, since there is no way in HTTP to later send an asynchronous response indicating the outcome of the request.
    /// It is intended for cases where another process or server handles the request, or for batch processing.
    accepted = 202,
    /// This response code means the returned metadata is not exactly the same as is available from the origin server, but is collected from a local or a third-party copy.
    /// This is mostly used for mirrors or backups of another resource.
    /// Except for that specific case, the 200 OK response is preferred to this status.
    non_authoritative_information = 203,
    /// There is no content to send for this request, but the headers are useful.
    /// The user agent may update its cached headers for this resource with the new ones.
    no_content = 204,
    /// Tells the user agent to reset the document which sent this request.
    reset_content = 205,
    /// This response code is used in response to a range request when the client has requested a part or parts of a resource.
    partial_content = 206,
    /// Conveys information about multiple resources, for situations where multiple status codes might be appropriate.
    multi_status = 207,
    /// Used inside a <dav:propstat> response element to avoid repeatedly enumerating the internal members of multiple bindings to the same collection.
    already_reported = 208,
    /// The server has fulfilled a GET request for the resource,
    /// and the response is a representation of the result of one or more instance-manipulations applied to the current instance.
    im_used = 226,
    /// In agent-driven content negotiation, the request has more than one possible response and the user agent or user should choose one of them.
    /// There is no standardized way for clients to automatically choose one of the responses, so this is rarely used.
    multiple_choices = 300,
    /// The URL of the requested resource has been changed permanently. The new URL is given in the response.
    moved_permanently = 301,
    /// This response code means that the URI of requested resource has been changed temporarily.
    /// Further changes in the URI might be made in the future, so the same URI should be used by the client in future requests.
    found = 302,
    /// The server sent this response to direct the client to get the requested resource at another URI with a GET request.
    see_other = 303,
    /// This is used for caching purposes.
    /// It tells the client that the response has not been modified, so the client can continue to use the same cached version of the response.
    not_modified = 304,
    /// The server sends this response to direct the client to get the requested resource at another URI with the same method that was used in the prior request.
    /// This has the same semantics as the 302 Found response code, with the exception that the user agent must not change the HTTP method used:
    /// if a POST was used in the first request, a POST must be used in the redirected request.
    temporary_redirect = 307,
    /// This means that the resource is now permanently located at another URI, specified by the Location response header.
    /// This has the same semantics as the 301 Moved Permanently HTTP response code, with the exception that the user agent must not change the HTTP method used:
    /// if a POST was used in the first request, a POST must be used in the second request.
    permanent_redirect = 308,
    /// The server cannot or will not process the request due to something that is perceived to be a client error
    /// (e.g., malformed request syntax, invalid request message framing, or deceptive request routing).
    bad_request = 400,
    /// Although the HTTP standard specifies "unauthorized", semantically this response means "unauthenticated".
    /// That is, the client must authenticate itself to get the requested response.
    unauthorized = 401,
    /// The initial purpose of this code was for digital payment systems, however this status code is rarely used and no standard convention exists.
    payment_required = 402,
    /// The client does not have access rights to the content; that is, it is unauthorized, so the server is refusing to give the requested resource.
    /// Unlike 401 Unauthorized, the client's identity is known to the server.
    forbidden = 403,
    /// The server cannot find the requested resource.
    /// In the browser, this means the URL is not recognized.
    /// In an API, this can also mean that the endpoint is valid but the resource itself does not exist.
    /// Servers may also send this response instead of 403 Forbidden to hide the existence of a resource from an unauthorized client.
    /// This response code is probably the most well known due to its frequent occurrence on the web.
    not_found = 404,
    /// The request method is known by the server but is not supported by the target resource.
    /// For example, an API may not allow DELETE on a resource, or the TRACE method entirely.
    method_not_allowed = 405,
    /// This response is sent when the web server, after performing server-driven content negotiation,
    /// doesn't find any content that conforms to the criteria given by the user agent.
    not_acceptable = 406,
    /// This is similar to 401 Unauthorized but authentication is needed to be done by a proxy.
    proxy_authentication_required = 407,
    /// This response is sent on an idle connection by some servers, even without any previous request by the client.
    /// It means that the server would like to shut down this unused connection.
    /// This response is used much more since some browsers use HTTP pre-connection mechanisms to speed up browsing.
    /// Some servers may shut down a connection without sending this message.
    request_timeout = 408,
    /// This response is sent when a request conflicts with the current state of the server.
    /// In WebDAV remote web authoring, 409 responses are errors sent to the client so that a user might be able to resolve a conflict and resubmit the request.
    conflict = 409,
    /// This response is sent when the requested content has been permanently deleted from server, with no forwarding address.
    /// Clients are expected to remove their caches and links to the resource.
    /// The HTTP specification intends this status code to be used for "limited-time, promotional services".
    /// APIs should not feel compelled to indicate resources that have been deleted with this status code.
    gone = 410,
    /// Server rejected the request because the Content-Length header field is not defined and the server requires it.
    length_required = 411,
    /// In conditional requests, the client has indicated preconditions in its headers which the server does not meet.
    precondition_failed = 412,
    /// The request body is larger than limits defined by server. The server might close the connection or return an Retry-After header field.
    content_too_large = 413,
    /// The URI requested by the client is longer than the server is willing to interpret.
    uri_too_long = 414,
    /// The media format of the requested data is not supported by the server, so the server is rejecting the request.
    unsupported_media_type = 415,
    /// The ranges specified by the Range header field in the request cannot be fulfilled.
    /// It's possible that the range is outside the size of the target resource's data.
    range_not_satisfiable = 416,
    /// This response code means the expectation indicated by the Expect request header field cannot be met by the server.
    expectation_failed = 417,
    /// The server refuses the attempt to brew coffee with a teapot.
    im_a_teapot = 418,
    /// The request was directed at a server that is not able to produce a response.
    /// This can be sent by a server that is not configured to produce responses for the combination of scheme and authority that are included in the request URI.
    misdirected_request = 421,
    /// The request was well-formed but was unable to be followed due to semantic errors.
    unprocessable_content = 422,
    /// The resource that is being accessed is locked.
    locked = 423,
    /// The request failed due to failure of a previous request.
    failed_dependency = 424,
    /// Indicates that the server is unwilling to risk processing a request that might be replayed.
    too_early = 425,
    /// The server refuses to perform the request using the current protocol but might be willing to do so after the client upgrades to a different protocol.
    /// The server sends an Upgrade header in a 426 response to indicate the required protocol(s).
    upgrade_required = 426,
    /// The origin server requires the request to be conditional.
    /// This response is intended to prevent the 'lost update' problem, where a client GETs a resource's state,
    /// modifies it and PUTs it back to the server, when meanwhile a third party has modified the state on the server, leading to a conflict.
    precondition_required = 428,
    /// The user has sent too many requests in a given amount of time (rate limiting).
    too_many_requests = 429,
    /// The server is unwilling to process the request because its header fields are too large.
    /// The request may be resubmitted after reducing the size of the request header fields.
    request_header_fields_too_large = 431,
    /// The user agent requested a resource that cannot legally be provided, such as a web page censored by a government.
    unavailable_for_legal_reasons = 451,
    /// The server has encountered a situation it does not know how to handle.
    /// This error is generic, indicating that the server cannot find a more appropriate 5XX status code to respond with.
    internal_server_error = 500,
    /// The request method is not supported by the server and cannot be handled.
    /// The only methods that servers are required to support (and therefore that must not return this code) are GET and HEAD.
    not_implemented = 501,
    /// This error response means that the server, while working as a gateway to get a response needed to handle the request, got an invalid response.
    bad_gateway = 502,
    /// The server is not ready to handle the request.
    /// Common causes are a server that is down for maintenance or that is overloaded.
    /// Note that together with this response, a user-friendly page explaining the problem should be sent.
    /// This response should be used for temporary conditions and the Retry-After HTTP header should,
    /// if possible, contain the estimated time before the recovery of the service.
    /// The webmaster must also take care about the caching-related headers that are sent along with this response,
    /// as these temporary condition responses should usually not be cached.
    service_unavailable = 503,
    /// This error response is given when the server is acting as a gateway and cannot get a response in time.
    gateway_timeout = 504,
    /// The HTTP version used in the request is not supported by the server.
    http_version_not_supported = 505,
    /// The server has an internal configuration error: during content negotiation, the chosen variant is configured to engage in content negotiation itself,
    /// which results in circular references when creating responses.
    variant_also_negotiates = 506,
    /// The method could not be performed on the resource because the server is unable to store the representation needed to successfully complete the request.
    insufficient_storage = 507,
    /// The server detected an infinite loop while processing the request.
    loop_detected = 508,
    /// The client request declares an HTTP Extension (RFC 2774) that should be used to process the request, but the extension is not supported.
    not_extended = 510,
    /// Indicates that the client needs to authenticate to gain network access.
    network_authentication_required = 511,
    _, // non-exhaustive

    /// Customize by setting Response.reason_phrase.
    pub fn defaultReasonPhrase(self: StatusCode) ?[]const u8 {
        return switch (self) {
            .@"continue" => "Continue",
            .switching_protocols => "Switching Protocols",
            .processing => "Processing",
            .early_hints => "Early Hints",
            .ok => "OK",
            .created => "Created",
            .accepted => "Accepted",
            .non_authoritative_information => "Non-Authoritative Information",
            .no_content => "No Content",
            .reset_content => "Reset Content",
            .partial_content => "Partial Content",
            .multi_status => "Multi-Status",
            .already_reported => "Already Reported",
            .im_used => "IM Used",
            .multiple_choices => "Multiple Choices",
            .moved_permanently => "Moved Permanently",
            .found => "Found",
            .see_other => "See Other",
            .not_modified => "Not Modified",
            .temporary_redirect => "Temporary Redirect",
            .permanent_redirect => "Permanent Redirect",
            .bad_request => "Bad Request",
            .unauthorized => "Unauthorized",
            .payment_required => "Payment Required",
            .forbidden => "Forbidden",
            .not_found => "Not Found",
            .method_not_allowed => "Method Not Allowed",
            .not_acceptable => "Not Acceptable",
            .proxy_authentication_required => "Proxy Authentication Required",
            .request_timeout => "Request Timeout",
            .conflict => "Conflict",
            .gone => "Gone",
            .length_required => "Length Required",
            .precondition_failed => "Precondition Failed",
            .content_too_large => "Content Too Large",
            .uri_too_long => "URI Too Long",
            .unsupported_media_type => "Unsupported Media Type",
            .range_not_satisfiable => "Range Not Satisfiable",
            .expectation_failed => "Expectation Failed",
            .im_a_teapot => "I'm a teapot",
            .misdirected_request => "Misdirected Request",
            .unprocessable_content => "Unprocessable Content",
            .locked => "Locked",
            .failed_dependency => "Failed Dependency",
            .too_early => "Too Early",
            .upgrade_required => "Upgrade Required",
            .precondition_required => "Precondition Required",
            .too_many_requests => "Too Many Requests",
            .request_header_fields_too_large => "Request Header Fields Too Large",
            .unavailable_for_legal_reasons => "Unavailable For Legal Reasons",
            .internal_server_error => "Internal Server Error",
            .not_implemented => "Not Implemented",
            .bad_gateway => "Bad Gateway",
            .service_unavailable => "Service Unavailable",
            .gateway_timeout => "Gateway Timeout",
            .http_version_not_supported => "HTTP Version Not Supported",
            .variant_also_negotiates => "Variant Also Negotiates",
            .insufficient_storage => "Insufficient Storage",
            .loop_detected => "Loop Detected",
            .not_extended => "Not Extended",
            .network_authentication_required => "Network Authentication Required",
            _ => null,
        };
    }

    /// Status code is within the range 100-199.
    pub fn isInformational(self: StatusCode) bool {
        return 100 <= @intFromEnum(self) and @intFromEnum(self) <= 199;
    }

    /// Status code is within the range 200-299.
    pub fn isSuccessful(self: StatusCode) bool {
        return 200 <= @intFromEnum(self) and @intFromEnum(self) <= 299;
    }

    /// Status code is within the range 300-399.
    pub fn isRedirection(self: StatusCode) bool {
        return 300 <= @intFromEnum(self) and @intFromEnum(self) <= 399;
    }

    /// Status code is within the range 400-499.
    pub fn isClientError(self: StatusCode) bool {
        return 400 <= @intFromEnum(self) and @intFromEnum(self) <= 499;
    }

    /// Status code is within the range 500-599.
    pub fn isServerError(self: StatusCode) bool {
        return 500 <= @intFromEnum(self) and @intFromEnum(self) <= 599;
    }
};
