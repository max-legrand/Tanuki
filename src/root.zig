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
        pointer: *anyopaque,
        deinit_fn: *const fn (pointer: *anyopaque) void,
        execute_fn: *const fn (
            pointer: *anyopaque,
            request: *Request,
            response: *Response,
            executor: *Server(T).Executor,
        ) anyerror!void,

        const Self = @This();

        pub fn init(pointer: anytype) Self {
            const Pointer = @TypeOf(pointer);
            const pointer_info = @typeInfo(Pointer);
            const generated = struct {
                pub fn deinit(pointer_opaque: *anyopaque) void {
                    const self: Pointer = @ptrCast(@alignCast(pointer_opaque));
                    if (std.meta.hasMethod(Pointer, "deinit")) {
                        return pointer_info.pointer.child.deinit(self);
                    }
                }

                pub fn execute(
                    pointer_opaque: *anyopaque,
                    request: *Request,
                    response: *Response,
                    executor: *Server(T).Executor,
                ) !void {
                    const self: Pointer = @ptrCast(@alignCast(pointer_opaque));
                    return pointer_info.pointer.child.execute(
                        self,
                        request,
                        response,
                        executor,
                    );
                }
            };
            return .{
                .pointer = pointer,
                .deinit_fn = generated.deinit,
                .execute_fn = generated.execute,
            };
        }

        pub fn deinit(self: Self) void {
            self.deinit_fn(self.pointer);
        }

        pub fn execute(
            self: Self,
            request: *Request,
            response: *Response,
            executor: *Server(T).Executor,
        ) !void {
            return self.execute_fn(self.pointer, request, response, executor);
        }
    };
}

pub const ServerConfigArgs = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 5882,
    max_concurrency: u16 = 16,
    request_body_bytes_max: u32 = 256 * 1024,
    request_head_bytes_max: u32 = 16 * 1024,
    request_memory_bytes_max: u32 = 1024 * 1024,
    request_target_bytes_max: u32 = 8 * 1024,
};

fn request_body_size(content_length: ?u64, bytes_max: u32) !usize {
    std.debug.assert(bytes_max > 0);
    const size_u64 = content_length orelse return 0;
    if (size_u64 > bytes_max) return error.RequestBodyTooLarge;
    const size = std.math.cast(usize, size_u64) orelse return error.RequestBodyTooLarge;
    std.debug.assert(size <= bytes_max);
    return size;
}

pub fn Server(comptime T: type) type {
    return struct {
        handler: if (T == void) void else *T,
        router: router.Router(T),
        middlewares: []Middleware(T),
        address: string,
        port: u16,
        max_concurrency: u16,
        request_body_bytes_max: u32,
        request_head_bytes_max: u32,
        request_memory: []u8,
        request_memory_bytes_max: u32,
        request_target_bytes_max: u32,
        connection_queue: std.Io.Queue(std.Io.net.Stream),
        connection_queue_storage: []std.Io.net.Stream,
        worker_threads: []?std.Thread,
        allocator: std.mem.Allocator,
        running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        listener: ?std.Io.net.Server = null,
        io: std.Io,

        const Self = @This();

        const ParsedTarget = struct {
            path: []u8,
            query: std.StringHashMap(string),
        };

        const ParsedRequest = struct {
            request: Request,
            response: *Response,
        };

        pub const Executor = struct {
            index: u16,
            request: *Request,
            response: *Response,
            handler: if (T == void) void else *T,
            middlewares: []const Middleware(T),
            action: *const HandlerFn(T),

            pub fn next(self: *Executor) !void {
                if (self.index < self.middlewares.len) {
                    const middleware = self.middlewares[self.index];
                    self.index += 1;
                    return middleware.execute(self.request, self.response, self);
                }
                if (T == void) {
                    return self.action(self.request, self.response);
                }
                return self.action(self.handler, self.request, self.response);
            }
        };

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            handler: if (T == void) void else *T,
            config: ServerConfigArgs,
        ) !Self {
            try validate_config(config);
            const worker_count: usize = config.max_concurrency;
            const request_memory_bytes_max: usize = config.request_memory_bytes_max;
            const request_memory_len = try std.math.mul(
                usize,
                worker_count,
                request_memory_bytes_max,
            );
            const request_memory = try allocator.alloc(u8, request_memory_len);
            errdefer allocator.free(request_memory);
            const queue_storage = try allocator.alloc(std.Io.net.Stream, worker_count);
            errdefer allocator.free(queue_storage);
            const worker_threads = try allocator.alloc(?std.Thread, worker_count);
            errdefer allocator.free(worker_threads);
            @memset(worker_threads, null);

            return init_result(
                allocator,
                io,
                handler,
                config,
                request_memory,
                queue_storage,
                worker_threads,
            );
        }

        fn init_result(
            allocator: std.mem.Allocator,
            io: std.Io,
            handler: if (T == void) void else *T,
            config: ServerConfigArgs,
            request_memory: []u8,
            queue_storage: []std.Io.net.Stream,
            worker_threads: []?std.Thread,
        ) !Self {
            return .{
                .handler = handler,
                .router = try router.Router(T).init(allocator),
                .middlewares = &.{},
                .address = config.address,
                .port = config.port,
                .max_concurrency = config.max_concurrency,
                .request_body_bytes_max = config.request_body_bytes_max,
                .request_head_bytes_max = config.request_head_bytes_max,
                .request_memory = request_memory,
                .request_memory_bytes_max = config.request_memory_bytes_max,
                .request_target_bytes_max = config.request_target_bytes_max,
                .connection_queue = .init(queue_storage),
                .connection_queue_storage = queue_storage,
                .worker_threads = worker_threads,
                .allocator = allocator,
                .io = io,
            };
        }

        pub fn deinit(self: *Self) void {
            std.debug.assert(!self.running.load(.acquire));
            for (self.worker_threads) |worker_thread| {
                std.debug.assert(worker_thread == null);
            }
            for (self.middlewares) |middleware| middleware.deinit();
            self.router.deinit();
            if (self.listener) |*listener| listener.deinit(self.io);
            self.allocator.free(self.worker_threads);
            self.allocator.free(self.connection_queue_storage);
            self.allocator.free(self.request_memory);
            self.* = undefined;
        }

        pub fn addMiddleware(
            self: *Self,
            allocator: std.mem.Allocator,
            MiddlewareType: type,
            config: ?MiddlewareType.Config,
        ) !void {
            const middleware = try allocator.create(MiddlewareType);
            middleware.* = try middleware_init(MiddlewareType, allocator, config);
            const interface = Middleware(T).init(middleware);
            const list = try allocator.alloc(Middleware(T), self.middlewares.len + 1);
            @memcpy(list[0..self.middlewares.len], self.middlewares);
            list[self.middlewares.len] = interface;
            self.middlewares = list;
        }

        pub fn start(self: *Self) !void {
            std.debug.assert(self.listener == null);
            std.debug.assert(!self.running.load(.acquire));
            try self.worker_pool_start();
            defer self.worker_pool_stop();

            var address = try std.Io.net.IpAddress.parse(self.address, self.port);
            self.listener = try address.listen(self.io, .{ .reuse_address = true });
            self.running.store(true, .release);
            defer self.running.store(false, .release);

            while (self.running.load(.acquire)) {
                const stream = self.listener.?.accept(self.io) catch |accept_error| {
                    if (!self.running.load(.acquire)) break;
                    return accept_error;
                };
                if (!self.running.load(.acquire)) {
                    stream.close(self.io);
                    break;
                }
                self.connection_queue.putOne(self.io, stream) catch |queue_error| {
                    stream.close(self.io);
                    return queue_error;
                };
            }
        }

        pub fn stop(self: *Self) !void {
            self.running.store(false, .release);
            const address = try std.Io.net.IpAddress.parse(self.address, self.port);
            const stream = try std.Io.net.IpAddress.connect(&address, self.io, .{
                .mode = .stream,
                .timeout = .none,
            });
            stream.close(self.io);
        }

        fn worker_pool_start(self: *Self) !void {
            for (self.worker_threads, 0..) |*worker_thread, worker_index| {
                std.debug.assert(worker_thread.* == null);
                worker_thread.* = std.Thread.spawn(
                    .{},
                    worker_run,
                    .{ self, worker_index },
                ) catch |spawn_error| {
                    self.connection_queue.close(self.io);
                    self.worker_pool_join();
                    return spawn_error;
                };
            }
        }

        fn worker_pool_stop(self: *Self) void {
            self.connection_queue.close(self.io);
            self.worker_pool_join();
        }

        fn worker_pool_join(self: *Self) void {
            for (self.worker_threads) |*worker_thread| {
                if (worker_thread.*) |thread| thread.join();
                worker_thread.* = null;
            }
        }

        fn worker_run(self: *Self, worker_index: usize) void {
            std.debug.assert(worker_index < self.worker_threads.len);
            while (true) {
                const stream = self.connection_queue.getOneUncancelable(self.io) catch break;
                self.handle_connection(stream, worker_index) catch |connection_error| {
                    std.debug.print("Connection error: {s}\n", .{@errorName(connection_error)});
                };
            }
        }

        fn handle_connection(
            self: *Self,
            stream: std.Io.net.Stream,
            worker_index: usize,
        ) !void {
            defer stream.close(self.io);
            std.debug.assert(worker_index < self.worker_threads.len);
            const memory_bytes_max: usize = self.request_memory_bytes_max;
            const memory_offset = worker_index * memory_bytes_max;
            const memory = self.request_memory[memory_offset..][0..memory_bytes_max];
            var fixed_buffer = std.heap.FixedBufferAllocator.init(memory);
            const allocator = fixed_buffer.allocator();

            const head_bytes_max: usize = self.request_head_bytes_max;
            const receive_buffer = try allocator.alloc(u8, head_bytes_max);
            var send_buffer: [4000]u8 = undefined;
            var connection_reader = std.Io.net.Stream.reader(
                stream,
                self.io,
                receive_buffer,
            );
            var connection_writer = std.Io.net.Stream.writer(stream, self.io, &send_buffer);
            var http_server = std.http.Server.init(
                &connection_reader.interface,
                &connection_writer.interface,
            );
            var raw_request = try http_server.receiveHead();
            if (!try self.request_validate(&raw_request)) return;
            var parsed = self.request_parse(&raw_request, allocator) catch |parse_error| {
                if (parse_error == error.StreamTooLong) {
                    try raw_request.respond("Payload Too Large", .{
                        .status = .payload_too_large,
                    });
                    return;
                }
                return parse_error;
            };
            try self.request_dispatch(&parsed.request, parsed.response, allocator);
        }

        fn request_validate(self: *Self, request: *std.http.Server.Request) !bool {
            const target_bytes_max: usize = self.request_target_bytes_max;
            if (request.head.target.len > target_bytes_max) {
                try request.respond("URI Too Long", .{ .status = .uri_too_long });
                return false;
            }
            _ = request_body_size(
                request.head.content_length,
                self.request_body_bytes_max,
            ) catch {
                try request.respond("Payload Too Large", .{
                    .status = .payload_too_large,
                });
                return false;
            };
            return true;
        }

        fn request_parse(
            self: *Self,
            raw_request: *std.http.Server.Request,
            allocator: std.mem.Allocator,
        ) !ParsedRequest {
            const method = raw_request.head.method;
            const target = try parse_target(allocator, raw_request.head.target);
            const headers = try parse_headers(allocator, raw_request);
            const body = try self.request_read_body(raw_request, allocator);
            const response = try allocator.create(Response);
            response.* = .{
                .req = raw_request,
                .arena = allocator,
                .headers = .empty,
                .status = .ok,
            };
            return .{
                .request = .{
                    .req = raw_request,
                    .params = null,
                    .body = body,
                    .target = target.path,
                    .method = method,
                    .query = target.query,
                    .headers = headers,
                    .io = self.io,
                },
                .response = response,
            };
        }

        fn request_read_body(
            self: *Self,
            request: *std.http.Server.Request,
            allocator: std.mem.Allocator,
        ) ![]const u8 {
            const body_size = try request_body_size(
                request.head.content_length,
                self.request_body_bytes_max,
            );
            const transfer_encoding = request.head.transfer_encoding;
            if (body_size == 0 and transfer_encoding == .none) return "";

            var reader_buffer: [4000]u8 = undefined;
            const body_reader = try request.readerExpectContinue(&reader_buffer);
            if (transfer_encoding == .chunked) {
                return body_reader.allocRemaining(
                    allocator,
                    .limited(self.request_body_bytes_max),
                );
            }
            const body = try allocator.alloc(u8, body_size);
            try body_reader.readSliceAll(body);
            std.debug.assert(body.len <= self.request_body_bytes_max);
            return body;
        }

        fn request_dispatch(
            self: *Self,
            request: *Request,
            response: *Response,
            allocator: std.mem.Allocator,
        ) !void {
            if (self.router.route_map.get(.{
                .method = request.method,
                .path = request.target,
            })) |action| {
                return self.request_execute(request, response, action);
            }
            if (try self.request_dynamic_action(request, allocator)) |action| {
                return self.request_execute(request, response, action);
            }
            return self.request_execute(request, response, not_found_action());
        }

        fn request_execute(
            self: *Self,
            request: *Request,
            response: *Response,
            action: *const HandlerFn(T),
        ) !void {
            var executor: Executor = .{
                .index = 0,
                .request = request,
                .response = response,
                .handler = self.handler,
                .middlewares = self.middlewares,
                .action = action,
            };
            executor.next() catch |handler_error| {
                return respond_internal_error(request.req, handler_error);
            };
        }

        fn request_dynamic_action(
            self: *Self,
            request: *Request,
            allocator: std.mem.Allocator,
        ) !?*const HandlerFn(T) {
            const routes = self.router.routes.get(request.method) orelse return null;
            var sections = std.mem.splitScalar(u8, request.target, '/');
            var segments = std.ArrayList(string).empty;
            while (sections.next()) |segment| {
                if (segment.len > 0) try segments.append(allocator, segment);
            }
            for (routes.items) |route| {
                if (try route_match(allocator, request, segments.items, route.segments)) {
                    return route.handler;
                }
            }
            return null;
        }

        fn route_match(
            allocator: std.mem.Allocator,
            request: *Request,
            segments: []const string,
            route_segments: []const router.Segment,
        ) !bool {
            var segment_index: u16 = 0;
            var params = std.StringHashMap(string).init(allocator);
            for (route_segments, 0..) |route_segment, route_index| {
                const matches = try route_segment_match(
                    allocator,
                    &params,
                    segments,
                    &segment_index,
                    route_segment,
                    route_index == route_segments.len - 1,
                );
                if (!matches) {
                    params.deinit();
                    return false;
                }
            }
            if (segment_index != segments.len) {
                params.deinit();
                return false;
            }
            request.params = params;
            return true;
        }

        fn route_segment_match(
            allocator: std.mem.Allocator,
            params: *std.StringHashMap(string),
            segments: []const string,
            segment_index: *u16,
            route_segment: router.Segment,
            is_last: bool,
        ) !bool {
            return switch (route_segment) {
                .Static => |expected| route_static_match(
                    expected,
                    segments,
                    segment_index,
                ),
                .Param => |name| route_param_match(
                    allocator,
                    params,
                    name,
                    segments,
                    segment_index,
                    is_last,
                ),
                .Wildcard => route_wildcard_match(
                    allocator,
                    params,
                    segments,
                    segment_index,
                ),
            };
        }

        fn not_found_action() *const HandlerFn(T) {
            return if (T == void)
                &struct {
                    fn run(_: *Request, response: *Response) anyerror!void {
                        try response.write(.not_found, "Not Found");
                    }
                }.run
            else
                &struct {
                    fn run(_: *T, _: *Request, response: *Response) anyerror!void {
                        try response.write(.not_found, "Not Found");
                    }
                }.run;
        }
    };
}

fn validate_config(config: ServerConfigArgs) !void {
    if (config.max_concurrency == 0) return error.InvalidMaxConcurrency;
    if (config.request_body_bytes_max == 0) return error.InvalidRequestBodyLimit;
    if (config.request_head_bytes_max == 0) return error.InvalidRequestHeadLimit;
    if (config.request_memory_bytes_max == 0) return error.InvalidRequestMemoryLimit;
    if (config.request_target_bytes_max == 0) return error.InvalidRequestTargetLimit;
    if (config.request_body_bytes_max > config.request_memory_bytes_max) {
        return error.RequestBodyLimitExceedsMemoryLimit;
    }
    if (config.request_head_bytes_max > config.request_memory_bytes_max) {
        return error.RequestHeadLimitExceedsMemoryLimit;
    }
    if (config.request_target_bytes_max > config.request_head_bytes_max) {
        return error.RequestTargetLimitExceedsHeadLimit;
    }
}

fn middleware_init(
    comptime MiddlewareType: type,
    allocator: std.mem.Allocator,
    config: ?MiddlewareType.Config,
) !MiddlewareType {
    if (!@hasDecl(MiddlewareType, "init")) {
        @compileError("Middleware " ++ @typeName(MiddlewareType) ++ " must define init");
    }
    const init_info = @typeInfo(@TypeOf(MiddlewareType.init));
    if (init_info != .@"fn") @compileError("Middleware init must be a function");
    return switch (init_info.@"fn".params.len) {
        0 => MiddlewareType.init(),
        1 => MiddlewareType.init(config.?),
        2 => MiddlewareType.init(config.?, .{
            .arena = allocator,
            .allocator = allocator,
        }),
        else => @compileError("Unsupported middleware init signature"),
    };
}

fn parse_target(allocator: std.mem.Allocator, raw_target: []const u8) !struct {
    path: []u8,
    query: std.StringHashMap(string),
} {
    var target = try allocator.dupe(u8, raw_target);
    var query = std.StringHashMap(string).init(allocator);
    const query_index = std.mem.indexOfScalar(u8, target, '?') orelse {
        return .{ .path = target, .query = query };
    };
    if (query_index + 1 < target.len) {
        var parameters = std.mem.splitScalar(u8, target[query_index + 1 ..], '&');
        while (parameters.next()) |parameter| {
            var pair = std.mem.splitScalar(u8, parameter, '=');
            const name = pair.next() orelse continue;
            const value = pair.next() orelse "";
            try query.put(name, value);
        }
    }
    target = target[0..query_index];
    return .{ .path = target, .query = query };
}

fn parse_headers(
    allocator: std.mem.Allocator,
    request: *std.http.Server.Request,
) !std.ArrayList(std.http.Header) {
    var headers = std.ArrayList(std.http.Header).empty;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        try headers.append(allocator, .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
        });
    }
    return headers;
}

fn route_static_match(
    expected: string,
    segments: []const string,
    segment_index: *u16,
) bool {
    if (segment_index.* >= segments.len) return false;
    if (!std.mem.eql(u8, segments[segment_index.*], expected)) return false;
    segment_index.* += 1;
    return true;
}

fn route_param_match(
    allocator: std.mem.Allocator,
    params: *std.StringHashMap(string),
    name: string,
    segments: []const string,
    segment_index: *u16,
    is_last: bool,
) !bool {
    if (segment_index.* >= segments.len) return false;
    if (is_last) {
        const rest = try std.mem.join(allocator, "/", segments[segment_index.*..]);
        try params.put(name, rest);
        segment_index.* = @intCast(segments.len);
        return true;
    }
    try params.put(name, segments[segment_index.*]);
    segment_index.* += 1;
    return true;
}

fn route_wildcard_match(
    allocator: std.mem.Allocator,
    params: *std.StringHashMap(string),
    segments: []const string,
    segment_index: *u16,
) !bool {
    const rest = try std.mem.join(allocator, "/", segments[segment_index.*..]);
    try params.put("*", rest);
    segment_index.* = @intCast(segments.len);
    return true;
}

fn respond_internal_error(
    request: *std.http.Server.Request,
    handler_error: anyerror,
) !void {
    std.debug.print("Handler error: {s}\n", .{@errorName(handler_error)});
    request.respond("Internal Server Error", .{
        .status = .internal_server_error,
    }) catch |response_error| {
        std.debug.print("Error response failed: {s}\n", .{@errorName(response_error)});
        return response_error;
    };
}

test "request body size is explicit and bounded" {
    try std.testing.expectEqual(0, try request_body_size(null, 1024));
    try std.testing.expectEqual(1024, try request_body_size(1024, 1024));
    try std.testing.expectError(
        error.RequestBodyTooLarge,
        request_body_size(1025, 1024),
    );
    try std.testing.expectError(
        error.RequestBodyTooLarge,
        request_body_size(std.math.maxInt(u64), 1024),
    );
}

test "server preallocates a bounded worker pool" {
    var server = try Server(void).init(
        std.testing.allocator,
        std.testing.io,
        {},
        .{
            .max_concurrency = 2,
            .request_body_bytes_max = 128,
            .request_head_bytes_max = 256,
            .request_memory_bytes_max = 1024,
            .request_target_bytes_max = 64,
        },
    );
    defer server.deinit();

    try std.testing.expectEqual(2, server.worker_threads.len);
    try std.testing.expectEqual(2, server.connection_queue.capacity());
    try std.testing.expectEqual(2048, server.request_memory.len);
}

test "server configuration rejects invalid bounds" {
    try std.testing.expectError(
        error.InvalidMaxConcurrency,
        validate_config(.{ .max_concurrency = 0 }),
    );
    try std.testing.expectError(
        error.RequestBodyLimitExceedsMemoryLimit,
        validate_config(.{
            .request_body_bytes_max = 2,
            .request_memory_bytes_max = 1,
        }),
    );
}
