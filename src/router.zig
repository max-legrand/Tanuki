const std = @import("std");
const types = @import("types.zig");
const HandlerFn = types.HandlerFn;
const string = []const u8;

pub const Segment = union(enum) {
    Static: string,
    Param: string,
    Wildcard: void,
};

const RouteKey = struct {
    method: std.http.Method,
    path: string,
};

fn route_hash(_: void, key: RouteKey) u64 {
    var hash = std.hash.Wyhash.init(0);
    std.hash.autoHash(&hash, @intFromEnum(key.method));
    hash.update(key.path);
    return hash.final();
}

fn route_equal(_: void, left: RouteKey, right: RouteKey) bool {
    if (left.method != right.method) return false;
    return std.mem.eql(u8, left.path, right.path);
}

const RouteContext = struct {
    pub fn hash(_: @This(), key: RouteKey) u64 {
        return route_hash({}, key);
    }

    pub fn eql(_: @This(), left: RouteKey, right: RouteKey) bool {
        return route_equal({}, left, right);
    }
};

const MethodContext = struct {
    pub fn hash(_: @This(), key: std.http.Method) u64 {
        return @intFromEnum(key);
    }

    pub fn eql(_: @This(), left: std.http.Method, right: std.http.Method) bool {
        return left == right;
    }
};

pub fn Router(comptime T: type) type {
    const Route = struct {
        raw_path: string,
        segments: []Segment,
        handler: *const HandlerFn(T),
    };
    return struct {
        allocator: std.mem.Allocator,
        route_map: std.HashMap(RouteKey, *const HandlerFn(T), RouteContext, 80),
        routes: std.HashMap(
            std.http.Method,
            std.ArrayList(Route),
            MethodContext,
            80,
        ),

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) !Self {
            var routes = std.HashMap(
                std.http.Method,
                std.ArrayList(Route),
                MethodContext,
                80,
            ).init(allocator);
            for (std.meta.tags(std.http.Method)) |method| {
                try routes.put(method, .empty);
            }
            return .{
                .route_map = .init(allocator),
                .allocator = allocator,
                .routes = routes,
            };
        }

        pub fn deinit(self: *Self) void {
            var route_lists = self.routes.valueIterator();
            while (route_lists.next()) |route_list| {
                for (route_list.items) |route| self.allocator.free(route.segments);
                route_list.deinit(self.allocator);
            }
            self.route_map.deinit();
            self.routes.deinit();
            self.* = undefined;
        }

        pub fn get(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.process_route(.GET, path, handler);
        }

        pub fn post(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.process_route(.POST, path, handler);
        }

        pub fn put(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.process_route(.PUT, path, handler);
        }

        pub fn delete(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.process_route(.DELETE, path, handler);
        }

        pub fn head(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.process_route(.HEAD, path, handler);
        }

        pub fn connect(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.process_route(.CONNECT, path, handler);
        }

        pub fn options(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.process_route(.OPTIONS, path, handler);
        }

        pub fn trace(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.process_route(.TRACE, path, handler);
        }

        pub fn patch(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.process_route(.PATCH, path, handler);
        }

        fn process_route(
            self: *Self,
            method: std.http.Method,
            path: string,
            handler: *const HandlerFn(T),
        ) !void {
            const segments = try parse_path_segments(self.allocator, path);
            if (segments == null) {
                try self.route_map.put(.{ .method = method, .path = path }, handler);
                return;
            }
            const route_segments = segments.?;
            errdefer self.allocator.free(route_segments);
            const method_routes = self.routes.getPtr(method) orelse {
                return error.MethodNotInitialized;
            };
            try method_routes.append(self.allocator, .{
                .raw_path = path,
                .segments = route_segments,
                .handler = handler,
            });
        }
    };
}

fn parse_path_segments(allocator: std.mem.Allocator, path: string) !?[]Segment {
    var segments = std.ArrayList(Segment).empty;
    errdefer segments.deinit(allocator);
    var pieces = std.mem.splitScalar(u8, path, '/');
    var has_dynamic = false;
    while (pieces.next()) |piece| {
        if (piece.len == 0) continue;
        if (std.mem.eql(u8, piece, "*")) {
            try segments.append(allocator, .{ .Wildcard = {} });
            has_dynamic = true;
            break;
        }
        if (piece[0] == ':') {
            try segments.append(allocator, .{ .Param = piece[1..] });
            has_dynamic = true;
            continue;
        }
        try segments.append(allocator, .{ .Static = piece });
    }
    if (!has_dynamic) {
        segments.deinit(allocator);
        return null;
    }
    return @as(?[]Segment, try segments.toOwnedSlice(allocator));
}
