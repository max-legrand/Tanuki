const std = @import("std");
const tanuki = @import("tanuki");

const Logger = struct {
    pub const Config = struct {};

    pub fn init(_: Config, _: anytype) !Logger {
        return .{};
    }

    pub fn execute(_: *const Logger, req: *tanuki.Request, _: *tanuki.Response, executor: anytype) !void {
        const clock = std.Io.Clock.real;
        const start_time = clock.now(req.io);
        const start = start_time.toMilliseconds();
        try executor.next();
        const end_time = clock.now(req.io);
        const end = end_time.toMilliseconds();
        std.debug.print("Request {s} {s} took {d}ms\n", .{ @tagName(req.req.head.method), req.req.head.target, end - start });
    }
};

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var server = try tanuki.Server(void).init(
        allocator,
        init.io,
        {},
        .{ .address = "0.0.0.0", .port = 8081 },
    );
    defer server.deinit();

    try server.addMiddleware(allocator, Logger, .{});

    try server.router.get("/test", testfn);
    try server.router.get("/stream", testStreaming);
    try server.router.get("/file/:name", serveFile);

    try server.start();
}

fn testfn(_: *tanuki.Request, res: *tanuki.Response) anyerror!void {
    try res.write(.ok, "hello world");
}

const State = struct {
    fn handle(_: State, writer: *tanuki.StreamWriter) !void {
        for (0..100_000) |i| {
            const msg = try std.fmt.allocPrint(std.heap.smp_allocator, "hello world {d}\n", .{i});
            try writer.write(msg);
            std.heap.smp_allocator.free(msg);
        }
    }
};

fn testStreaming(_: *tanuki.Request, res: *tanuki.Response) anyerror!void {
    try res.streamResponse(State{}, State.handle);
}

fn serveFile(req: *tanuki.Request, res: *tanuki.Response) anyerror!void {
    if (req.params == null) return error.ParamsNotFound;
    const name = req.params.?.get("name");
    if (name == null) return error.ParamsNotFound;
    const file_name = req.params.?.get("name").?;
    const dir = std.Io.Dir.cwd();
    const file = try dir.openFile(
        req.io,
        file_name,
        .{ .mode = .read_only },
    );

    const size = try file.stat(req.io);
    const data = try res.arena.alloc(u8, size.size);
    _ = try file.readPositionalAll(req.io, data, 0);

    try res.write(.ok, data);
}
