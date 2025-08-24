const std = @import("std");
const string = []const u8;

pub fn HandlerFn(comptime T: type) type {
    return if (T == void)
        fn (*Request, *Response) anyerror!void
    else
        fn (*T, *Request, *Response) anyerror!void;
}

pub const Request = struct {
    req: *std.http.Server.Request,
    params: ?std.StringHashMap(string),
    body: string,
    target: string,
    method: std.http.Method,
};

pub const Response = struct {
    req: *std.http.Server.Request,
    arena: std.mem.Allocator,
    headers: std.ArrayList(std.http.Header),

    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        const h = std.http.Header{ .name = name, .value = value };
        try self.headers.append(self.arena, h);
    }

    pub fn write(self: *Response, status: std.http.Status, body: []const u8) !void {
        try self.req.respond(body, .{
            .status = status,
            .extra_headers = self.headers.items,
        });
    }
};
