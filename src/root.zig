const std = @import("std");
const router = @import("router.zig");
const types = @import("types.zig");

pub const Request = types.Request;
pub const Response = types.Response;
pub const HandlerFn = types.HandlerFn;
const string = []const u8;

pub fn Middleware(comptime T: type) type {
    return struct {
        ptr: *anyopaque,
        deinitFn: *const fn (ptr: *anyopaque) void,
        executeFn: *const fn (
            ptr: *anyopaque,
            req: *Request,
            res: *Response,
            executor: *Server(T).Executor,
        ) anyerror!void,

        const Self = @This();

        pub fn init(ptr: anytype) Self {
            const P = @TypeOf(ptr);
            const info = @typeInfo(P);

            const gen = struct {
                pub fn deinit(p: *anyopaque) void {
                    const self: P = @ptrCast(@alignCast(p));
                    if (std.meta.hasMethod(P, "deinit")) {
                        return info.pointer.child.deinit(self);
                    }
                }

                pub fn execute(
                    p: *anyopaque,
                    req: *Request,
                    res: *Response,
                    executor: *Server(T).Executor,
                ) !void {
                    const self: P = @ptrCast(@alignCast(p));
                    return info.pointer.child.execute(self, req, res, executor);
                }
            };

            return .{
                .ptr = ptr,
                .deinitFn = gen.deinit,
                .executeFn = gen.execute,
            };
        }

        pub fn deinit(self: Self) void {
            self.deinitFn(self.ptr);
        }

        pub fn execute(
            self: Self,
            req: *Request,
            res: *Response,
            executor: *Server(T).Executor,
        ) !void {
            return self.executeFn(self.ptr, req, res, executor);
        }
    };
}

pub const ServerConfigArgs = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 5882,
};

pub fn Server(comptime T: type) type {
    return struct {
        handler: if (T == void) void else *T,
        router: router.Router(T),
        middlewares: []Middleware(T),
        address: string,
        port: u16,

        const Self = @This();

        pub const Executor = struct {
            index: usize,
            req: *Request,
            res: *Response,
            handler: if (T == void) void else *T,
            middlewares: []const Middleware(T),
            action: *const HandlerFn(T),

            pub fn next(self: *Executor) !void {
                if (self.index < self.middlewares.len) {
                    const mw = self.middlewares[self.index];
                    self.index += 1;
                    return mw.execute(self.req, self.res, self);
                }

                // No more middleware, call handler
                if (T == void) {
                    try self.action(self.req, self.res);
                } else {
                    try self.action(self.handler, self.req, self.res);
                }
            }
        };

        pub fn init(allocator: std.mem.Allocator, handler: if (T == void) void else *T, config: ServerConfigArgs) !Self {
            return .{
                .handler = handler,
                .router = try router.Router(T).init(allocator),
                .middlewares = &.{},
                .address = config.address,
                .port = config.port,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.middlewares) |mw| mw.deinit();
            self.router.deinit();
        }

        pub fn addMiddleware(
            self: *Self,
            allocator: std.mem.Allocator,
            M: type,
            config: ?M.Config,
        ) !void {
            const m = try allocator.create(M);

            if (@hasDecl(M, "init")) {
                const InitFn = @TypeOf(M.init);
                const info = @typeInfo(InitFn);

                if (info == .@"fn") {
                    const params = info.@"fn".params.len;

                    switch (params) {
                        // init()
                        0 => m.* = try M.init(),

                        // init(config)
                        1 => m.* = try M.init(config.?),

                        // init(config, opts)
                        2 => m.* = try M.init(config.?, .{
                            .arena = allocator,
                            .allocator = allocator,
                        }),

                        else => @compileError("Unsupported init signature for middleware " ++ @typeName(M)),
                    }
                } else {
                    @compileError("Middleware init must be a function");
                }
            } else {
                @compileError("Middleware " ++ @typeName(M) ++ " must define an init function");
            }

            const iface = Middleware(T).init(m);
            const new_list = try allocator.alloc(Middleware(T), self.middlewares.len + 1);
            @memcpy(new_list[0..self.middlewares.len], self.middlewares);
            new_list[self.middlewares.len] = iface;
            self.middlewares = new_list;
        }

        pub fn start(self: *Self) !void {
            var address = try std.net.Address.parseIp(self.address, self.port);
            var listener = try address.listen(.{
                .reuse_address = true,
            });
            defer listener.deinit();

            while (true) {
                const conn = try listener.accept();
                // Limit concurrency with a semaphore if you want
                const thread = try std.Thread.spawn(.{}, connectionWrapper, .{ self, conn });
                thread.detach();
            }
        }

        fn connectionWrapper(self: *Server(T), conn: std.net.Server.Connection) void {
            handleConnection(self, conn) catch |err| {
                std.debug.print("Connection error: {s}\n", .{@errorName(err)});
            };
        }

        fn handleConnection(self: *Server(T), conn: std.net.Server.Connection) !void {
            defer conn.stream.close();

            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            var recv_buffer: [4000]u8 = undefined;
            var send_buffer: [4000]u8 = undefined;
            var conn_reader = conn.stream.reader(&recv_buffer);
            var conn_writer = conn.stream.writer(&send_buffer);

            var http_server = std.http.Server.init(conn_reader.interface(), &conn_writer.interface);

            var req = http_server.receiveHead() catch return;
            var res = Response{
                .req = &req,
                .arena = allocator,
                .headers = std.ArrayList(std.http.Header).empty,
                .status = .ok,
            };

            var path = allocator.dupe(u8, req.head.target) catch return;
            const method = req.head.method;
            // Parse the URL query params
            const idx = std.mem.indexOf(u8, path, "?");
            var query = std.StringHashMap(string).init(res.arena);
            if (idx) |i| {
                if (i < path.len - 1) {
                    const slice = path[i + 1 ..];
                    var param_iter = std.mem.splitScalar(u8, slice, '&');
                    while (param_iter.next()) |item| {
                        var split = std.mem.splitScalar(u8, item, '=');
                        const key = split.next() orelse continue;
                        const value = split.next() orelse "";
                        try query.put(key, value);
                    }
                }
                path = path[0..i];
            }

            var body: []const u8 = "";
            const content_length = req.head.content_length;
            if (content_length) |len| {
                const buf = try allocator.alloc(u8, len);
                const reader = req.readerExpectNone(buf);
                body = try reader.readAlloc(allocator, len);
            }

            var request = Request{
                .req = &req,
                .params = null,
                .body = body,
                .target = path,
                .method = method,
                .query = query,
            };

            // Try exact match first
            if (self.router.route_map.get(.{ .method = method, .path = path })) |handler_fn| {
                var executor = Executor{
                    .index = 0,
                    .req = &request,
                    .res = &res,
                    .handler = self.handler,
                    .middlewares = self.middlewares,
                    .action = handler_fn,
                };
                executor.next() catch |err| {
                    // Respond with 500
                    const msg = try std.fmt.allocPrint(allocator, "Internal Server Error: {s}", .{@errorName(err)});
                    req.respond(msg, .{ .status = .internal_server_error }) catch {};
                };
                return;
            } else {
                const method_routes = self.router.routes.get(method) orelse return;

                var sections = std.mem.splitScalar(u8, path, '/');
                var segments = std.ArrayList(string).empty;
                defer segments.deinit(allocator);
                while (sections.next()) |segment| {
                    if (segment.len == 0) continue;
                    try segments.append(allocator, segment);
                }

                for (method_routes.items) |route| {
                    var route_segment_idx: usize = 0;
                    var is_valid = true;
                    var params = std.StringHashMap(string).init(allocator);
                    for (segments.items) |segment| {
                        switch (route.segments[route_segment_idx]) {
                            .Static => |s| {
                                if (!std.mem.eql(u8, segment, s)) {
                                    is_valid = false;
                                    break;
                                }
                            },
                            .Param => |p| {
                                if (route_segment_idx == route.segments.len - 1) {
                                    const rest = try std.mem.join(allocator, "/", segments.items[route_segment_idx..]);
                                    try params.put(p, rest);
                                    break;
                                } else {
                                    try params.put(p, segment);
                                }
                            },
                            .Wildcard => {
                                try params.put("*", segment);
                                break;
                            },
                        }
                        route_segment_idx += 1;
                    }
                    if (!is_valid) {
                        params.deinit();
                        continue;
                    } else {
                        request.params = params;
                        var executor = Executor{
                            .index = 0,
                            .req = &request,
                            .res = &res,
                            .handler = self.handler,
                            .middlewares = self.middlewares,
                            .action = route.handler,
                        };
                        executor.next() catch |err| {
                            // Respond with 500
                            const msg = try std.fmt.allocPrint(allocator, "Internal Server Error: {s}", .{@errorName(err)});
                            req.respond(msg, .{ .status = .internal_server_error }) catch {};
                        };
                        return;
                    }
                }
            }

            // No match
            try req.respond("Not Found", .{ .status = .not_found });
        }
    };
}
