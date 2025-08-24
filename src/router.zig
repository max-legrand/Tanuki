const std = @import("std");
const types = @import("types.zig");
const Request = types.Request;
const Response = types.Response;
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

fn routeHash(_: void, key: RouteKey) u64 {
    var h = std.hash.Wyhash.init(0);
    // method as small integer
    std.hash.autoHash(&h, @intFromEnum(key.method));
    // path bytes
    h.update(key.path);
    return h.final();
}

fn routeEql(_: void, a: RouteKey, b: RouteKey) bool {
    return a.method == b.method and std.mem.eql(u8, a.path, b.path);
}

const RouteCtx = struct {
    pub fn hash(_: @This(), key: RouteKey) u64 {
        return routeHash({}, key);
    }
    pub fn eql(_: @This(), a: RouteKey, b: RouteKey) bool {
        return routeEql({}, a, b);
    }
};

const MethodCtx = struct {
    pub fn hash(_: @This(), key: std.http.Method) u64 {
        return @intFromEnum(key);
    }
    pub fn eql(_: @This(), a: std.http.Method, b: std.http.Method) bool {
        return a == b;
    }
};

pub fn Router(comptime T: type) type {
    const Route = struct {
        raw_path: string,
        segments: []Segment,
        handler: *const HandlerFn(T),
    };

    const router = struct {
        const Self = @This();
        allocator: std.mem.Allocator,

        // Use const function pointers in map
        route_map: std.HashMap(RouteKey, *const HandlerFn(T), RouteCtx, 80),
        routes: std.HashMap(std.http.Method, std.ArrayList(Route), MethodCtx, 80),

        pub fn init(allocator: std.mem.Allocator) !Self {
            var routes = std.HashMap(std.http.Method, std.ArrayList(Route), MethodCtx, 80).init(allocator);
            // Pre-load with empty routes
            const tags = std.meta.tags(std.http.Method);
            for (tags) |tag| {
                try routes.put(tag, std.ArrayList(Route).empty);
            }

            return .{
                .route_map = std.HashMap(RouteKey, *const HandlerFn(T), RouteCtx, 80).init(allocator),
                .allocator = allocator,
                .routes = routes,
            };
        }

        pub fn deinit(self: *Self) void {
            self.route_map.deinit();
            self.routes.deinit();
        }

        pub fn get(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.processRoute(.GET, path, handler);
        }
        pub fn post(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.processRoute(.POST, path, handler);
        }
        pub fn put(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.processRoute(.PUT, path, handler);
        }
        pub fn delete(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.processRoute(.DELETE, path, handler);
        }
        pub fn head(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.processRoute(.HEAD, path, handler);
        }
        pub fn connect(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.processRoute(.CONNECT, path, handler);
        }
        pub fn options(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.processRoute(.OPTIONS, path, handler);
        }
        pub fn trace(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.processRoute(.TRACE, path, handler);
        }
        pub fn patch(self: *Self, path: string, handler: *const HandlerFn(T)) !void {
            try self.processRoute(.PATCH, path, handler);
        }
        fn processRoute(self: *Self, method: std.http.Method, path: string, handler: *const HandlerFn(T)) !void {
            const segments = try parsePathToSegments(self.allocator, path);
            if (segments) |s| {
                // dynamic route
                var method_routes = self.routes.get(method) orelse return error.MethodNotInitialized;
                const r = Route{
                    .raw_path = path,
                    .segments = s,
                    .handler = handler,
                };
                try method_routes.append(self.allocator, r);
                try self.routes.put(method, method_routes);
            } else {
                // exact match
                try self.route_map.put(.{ .method = method, .path = path }, handler);
            }
        }
    };

    return router;
}

fn parsePathToSegments(allocator: std.mem.Allocator, path: string) !?[]Segment {
    var segments = std.ArrayList(Segment).empty;
    var pieces = std.mem.splitScalar(u8, path, '/');
    var has_dynamic = false;
    while (pieces.next()) |piece| {
        if (piece.len == 0) continue;
        if (std.mem.eql(u8, piece, "*")) {
            try segments.append(allocator, .{ .Wildcard = {} });
            has_dynamic = true;
            break;
        } else if (piece[0] == ':') {
            try segments.append(allocator, .{ .Param = piece[1..] });
            has_dynamic = true;
        } else {
            try segments.append(allocator, .{ .Static = piece });
        }
    }
    if (!has_dynamic) {
        segments.deinit(allocator);
        return null;
    }
    return try segments.toOwnedSlice(allocator);
}
