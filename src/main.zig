const std = @import("std");
const tanuki = @import("tanuki");

const Logger = struct {
    pub const Config = struct {};

    pub fn init(_: Config, _: anytype) !Logger {
        return .{};
    }

    pub fn execute(_: *const Logger, req: *tanuki.Request, _: *tanuki.Response, executor: anytype) !void {
        const start = std.time.milliTimestamp();
        try executor.next();
        const end = std.time.milliTimestamp();
        std.debug.print("Request {s} {s} took {d}ms\n", .{ @tagName(req.req.head.method), req.req.head.target, end - start });
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try tanuki.Server(void).init(allocator, {}, .{ .address = "0.0.0.0", .port = 8081 });
    defer server.deinit();

    try server.addMiddleware(allocator, Logger, .{});

    try server.router.get("/test", testfn);
    try server.router.get("/file/:name", serveFile);

    try server.start();
}

fn testfn(_: *tanuki.Request, res: *tanuki.Response) anyerror!void {
    try res.write(.ok, "hello world");
}

fn serveFile(req: *tanuki.Request, res: *tanuki.Response) anyerror!void {
    if (req.params == null) return error.ParamsNotFound;
    const name = req.params.?.get("name");
    if (name == null) return error.ParamsNotFound;
    const file_name = req.params.?.get("name").?;
    const file = try std.fs.cwd().openFile(file_name, .{ .mode = .read_only });
    defer file.close();

    const data = try file.readToEndAlloc(res.arena, std.math.maxInt(u64));

    try res.write(.ok, data);
}
