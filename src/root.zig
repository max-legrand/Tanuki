const std = @import("std");
const router = @import("router.zig");
const types = @import("types.zig");
pub const utils = @import("utils.zig");

pub const Request = types.Request;
pub const Response = types.Response;
pub const HandlerFn = types.HandlerFn;
pub const StreamWriter = types.StreamWriter;

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
    max_concurrency: usize = 1024,
};

pub fn Server(comptime T: type) type {
    return struct {
        handler: if (T == void) void else *T,
        router: router.Router(T),
        middlewares: []Middleware(T),
        address: string,
        port: u16,
        semaphore: std.Io.Semaphore = .{},
        max_concurrency: usize,
        running: bool = true,
        listener: ?std.Io.net.Server = null,
        io: std.Io,

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

        pub fn init(allocator: std.mem.Allocator, io: std.Io, handler: if (T == void) void else *T, config: ServerConfigArgs) !Self {
            return .{
                .handler = handler,
                .router = try router.Router(T).init(allocator),
                .middlewares = &.{},
                .address = config.address,
                .port = config.port,
                .semaphore = std.Io.Semaphore{ .permits = config.max_concurrency },
                .max_concurrency = config.max_concurrency,
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            // Connection handlers run on detached threads. Drain every permit
            // (acquiring one blocks until whichever in-flight handler holding
            // it calls semaphore.post()) so all of them - including the
            // connection stop() opened to unblock accept() - have finished
            // before we tear down the router/listener/io they still reference.
            for (0..self.max_concurrency) |_| {
                self.semaphore.wait(self.io) catch break;
            }

            for (self.middlewares) |mw| mw.deinit();
            self.router.deinit();
            if (self.listener) |*l| {
                l.deinit(self.io);
            }
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
            var address = try std.Io.net.IpAddress.parse(self.address, self.port);
            self.listener = try address.listen(self.io, .{
                .reuse_address = true,
            });

            while (self.running) {
                const conn = self.listener.?.accept(self.io) catch |err| {
                    // If we're not running anymore, just return gracefully
                    if (!self.running) return;
                    return err;
                };
                try self.semaphore.wait(self.io);
                const thread = try std.Thread.spawn(.{}, connectionWrapper, .{ self, conn });
                thread.detach();
            }
        }

        pub fn stop(self: *Self) void {
            self.running = false;
            // Connect to ourselves to unblock accept()
            const addr = std.Io.net.IpAddress.parse(self.address, self.port) catch return;
            const socket = std.Io.net.IpAddress.connect(&addr, self.io, .{
                .mode = .stream,
                .timeout = .none,
            }) catch return;
            socket.close(self.io);
        }

        fn connectionWrapper(self: *Server(T), stream: std.Io.net.Stream) void {
            defer self.semaphore.post(self.io);
            handleConnection(self, stream) catch |err| {
                std.debug.print("Connection error: {s}\n", .{@errorName(err)});
            };
        }

        fn handleConnection(self: *Server(T), stream: std.Io.net.Stream) !void {
            defer stream.close(self.io);

            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const allocator = arena.allocator();

            var recv_buffer: [4000]u8 = undefined;
            var send_buffer: [4000]u8 = undefined;
            var conn_reader = std.Io.net.Stream.reader(stream, self.io, &recv_buffer);
            var conn_writer = std.Io.net.Stream.writer(stream, self.io, &send_buffer);

            var http_server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

            var req = http_server.receiveHead() catch return;
            const res = try allocator.create(Response);
            res.* = Response{
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
            var headers = std.ArrayList(std.http.Header).empty;
            var header_iter = req.iterateHeaders();
            while (header_iter.next()) |header| {
                try headers.append(allocator, header);
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
                .io = self.io,
                .params = null,
                .body = body,
                .target = path,
                .method = method,
                .query = query,
                .headers = headers,
            };

            // Try exact match first
            if (self.router.route_map.get(.{ .method = method, .path = path })) |handler_fn| {
                var executor = Executor{
                    .index = 0,
                    .req = &request,
                    .res = res,
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
                    var seg_idx: usize = 0;
                    var is_valid = true;
                    var params = std.StringHashMap(string).init(allocator);
                    for (route.segments, 0..) |route_segment, route_idx| {
                        switch (route_segment) {
                            .Static => |s| {
                                if (seg_idx >= segments.items.len or !std.mem.eql(u8, segments.items[seg_idx], s)) {
                                    is_valid = false;
                                    break;
                                }
                                seg_idx += 1;
                            },
                            .Param => |p| {
                                // A param requires at least one path segment to bind to.
                                if (seg_idx >= segments.items.len) {
                                    is_valid = false;
                                    break;
                                }
                                if (route_idx == route.segments.len - 1) {
                                    // Trailing param absorbs the remaining segments.
                                    const rest = try std.mem.join(allocator, "/", segments.items[seg_idx..]);
                                    try params.put(p, rest);
                                    seg_idx = segments.items.len;
                                } else {
                                    try params.put(p, segments.items[seg_idx]);
                                    seg_idx += 1;
                                }
                            },
                            .Wildcard => {
                                // Wildcard absorbs all remaining segments (possibly none).
                                const rest = try std.mem.join(allocator, "/", segments.items[seg_idx..]);
                                try params.put("*", rest);
                                seg_idx = segments.items.len;
                                break;
                            },
                        }
                    }
                    // Every request segment must have been consumed, otherwise the
                    // path is longer than the route and is not a match.
                    if (is_valid and seg_idx != segments.items.len) {
                        is_valid = false;
                    }
                    if (!is_valid) {
                        params.deinit();
                        continue;
                    } else {
                        request.params = params;
                        var executor = Executor{
                            .index = 0,
                            .req = &request,
                            .res = res,
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

            // No match: run the middleware chain around a default 404 handler
            // so middleware (logging, etc.) still observes unmatched requests.
            const not_found_action: *const HandlerFn(T) = if (T == void)
                &struct {
                    fn f(_: *Request, response: *Response) anyerror!void {
                        try response.write(.not_found, "Not Found");
                    }
                }.f
            else
                &struct {
                    fn f(_: *T, _: *Request, response: *Response) anyerror!void {
                        try response.write(.not_found, "Not Found");
                    }
                }.f;

            var not_found_executor = Executor{
                .index = 0,
                .req = &request,
                .res = res,
                .handler = self.handler,
                .middlewares = self.middlewares,
                .action = not_found_action,
            };
            not_found_executor.next() catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "Internal Server Error: {s}", .{@errorName(err)});
                req.respond(msg, .{ .status = .internal_server_error }) catch {};
            };
        }
    };
}
