const std = @import("std");
const tanuki = @import("tanuki");

const Logger = struct {
    pub const Config = struct {};

    pub fn init(_: Config, _: anytype) !Logger {
        return .{};
    }

    pub fn execute(
        _: *const Logger,
        request: *tanuki.Request,
        _: *tanuki.Response,
        executor: anytype,
    ) !void {
        const clock = std.Io.Clock.real;
        const started_at = clock.now(request.io).toMilliseconds();
        try executor.next();
        const finished_at = clock.now(request.io).toMilliseconds();
        std.debug.print("Request {s} {s} took {d}ms\n", .{
            @tagName(request.method),
            request.target,
            finished_at - started_at,
        });
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
    try server.router.get("/stream", test_streaming);
    try server.router.get("/file/:name", serve_file);

    try server.start();
}

fn testfn(_: *tanuki.Request, res: *tanuki.Response) anyerror!void {
    try res.write(.ok, "hello world");
}

const State = struct {
    fn handle(_: State, writer: *tanuki.StreamWriter) !void {
        for (0..100_000) |index| {
            var message_buffer: [64]u8 = undefined;
            const message = try std.fmt.bufPrint(
                &message_buffer,
                "hello world {d}\n",
                .{index},
            );
            try writer.write(message);
        }
    }
};

fn test_streaming(_: *tanuki.Request, response: *tanuki.Response) anyerror!void {
    try response.streamResponse(State{}, State.handle);
}

fn serve_file(request: *tanuki.Request, response: *tanuki.Response) anyerror!void {
    const params = request.params orelse return error.ParamsNotFound;
    const file_name = params.get("name") orelse return error.ParamsNotFound;
    const directory = std.Io.Dir.cwd();
    const file = try directory.openFile(
        request.io,
        file_name,
        .{ .mode = .read_only },
    );
    defer file.close(request.io);

    const size = try file.stat(request.io);
    const data = try response.arena.alloc(u8, size.size);
    _ = try file.readPositionalAll(request.io, data, 0);
    try response.write(.ok, data);
}
