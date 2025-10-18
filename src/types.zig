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
    query: std.StringHashMap(string),
    headers: std.ArrayList(std.http.Header),
};

pub const Response = struct {
    req: *std.http.Server.Request,
    arena: std.mem.Allocator,
    headers: std.ArrayList(std.http.Header),
    status: std.http.Status,

    pub const CookieOptions = struct {
        name: []const u8,
        value: []const u8,
        expires: ?i64,
        domain: ?[]const u8,
        secure: bool,
        http_only: bool,
    };

    pub fn setCookie(self: *Response, opts: CookieOptions) !void {
        var cookie = try std.fmt.allocPrint(self.arena, "{s}={s};", .{ opts.name, opts.value });
        if (opts.expires) |expires| {
            cookie = try std.fmt.allocPrint("{s} expires={d};", .{ cookie, expires });
        }
        if (opts.domain) |domain| {
            cookie = try std.fmt.allocPrint("{s} domain={s};", .{ cookie, domain });
        }
        if (opts.secure) {
            cookie = try std.fmt.allocPrint("{s} secure;", .{cookie});
        }
        if (opts.http_only) {
            cookie = try std.fmt.allocPrint("{s} httpOnly;", .{cookie});
        }
        try self.header("Set-Cookie", cookie);
    }

    pub fn header(self: *Response, name: []const u8, value: []const u8) !void {
        const h = std.http.Header{ .name = name, .value = value };
        try self.headers.append(self.arena, h);
    }

    pub fn write(self: *Response, status: std.http.Status, body: []const u8) !void {
        self.status = status;
        try self.req.respond(body, .{
            .status = status,
            .extra_headers = self.headers.items,
        });
    }

    pub fn streamResponse(self: *Response, ctx: anytype, comptime handler: fn (
        @TypeOf(ctx),
        *StreamWriter,
    ) anyerror!void) !void {
        const headers = [_]std.http.Header{
            .{
                .name = "Content-Type",
                .value = "text/event-stream",
            },
            .{
                .name = "Cache-Control",
                .value = "no-cache",
            },
            .{
                .name = "Connection",
                .value = "keep-alive",
            },
        };

        const buffer: []u8 = try self.arena.alloc(u8, 1024);
        var writer = try self.req.respondStreaming(buffer, .{ .respond_options = .{
            .status = .ok,
            .extra_headers = &headers,
        } });

        var thread_writer = StreamWriter{
            ._buffer = buffer,
            ._writer = &writer,
            ._allocator = self.arena,
        };

        try handler(ctx, &thread_writer);
        try writer.end();
        return;
    }
};

pub const StreamWriter = struct {
    _writer: *std.http.BodyWriter,
    _buffer: []u8,
    _allocator: std.mem.Allocator,
    pub fn write(self: *StreamWriter, bytes: []const u8) !void {
        try self._writer.writer.writeAll(bytes);
        try self._writer.writer.flush();
        try self._writer.http_protocol_output.flush();
    }
    pub fn end(self: *StreamWriter) !void {
        try self._writer.end();
        self._allocator.free(self._buffer);
    }
};
