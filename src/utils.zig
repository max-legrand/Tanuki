const std = @import("std");
const brotli = @cImport({
    @cInclude("brotli/encode.h");
});

pub fn compressData(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Estimate max compressed size (Brotli doc: worst case is input + 600 bytes)
    const max_compressed_size = data.len + 600;
    var compressed = try allocator.alloc(u8, max_compressed_size);

    var out_size: usize = max_compressed_size;

    const ok = brotli.BrotliEncoderCompress(
        brotli.BROTLI_DEFAULT_QUALITY, // quality: 0..11 (default 11 is slowest/best)
        brotli.BROTLI_DEFAULT_WINDOW, // window: 10..24 (default 22)
        brotli.BROTLI_MODE_GENERIC, // mode: GENERIC, TEXT, FONT
        data.len, // input size
        data.ptr, // input buffer
        &out_size, // in/out: output size
        compressed.ptr, // output buffer
    );

    if (ok != 1) {
        allocator.free(compressed);
        return error.CompressionFailed;
    }

    // Shrink to actual size
    const result = try allocator.alloc(u8, out_size);
    @memcpy(result.ptr, compressed[0..out_size]);
    allocator.free(compressed);

    return result;
}

pub fn getMimeType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".html")) return "text/html";
    if (std.mem.eql(u8, ext, ".css")) return "text/css";
    if (std.mem.eql(u8, ext, ".js")) return "application/javascript";
    if (std.mem.eql(u8, ext, ".json")) return "application/json";
    if (std.mem.eql(u8, ext, ".png")) return "image/png";
    if (std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (std.mem.eql(u8, ext, ".gif")) return "image/gif";
    if (std.mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (std.mem.eql(u8, ext, ".txt")) return "text/plain";
    if (std.mem.eql(u8, ext, ".xml")) return "application/xml";
    if (std.mem.eql(u8, ext, ".pdf")) return "application/pdf";
    if (std.mem.eql(u8, ext, ".zip")) return "application/zip";
    return "application/octet-stream";
}
