//! Generates a large Lox program for the compile_large benchmark. The program
//! defines many small functions and calls only the last one, so its run time
//! is dominated by scanning and compiling.

const std = @import("std");

const function_count = 10000;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.debug.print("usage: {s} <output-path>\n", .{args[0]});
        return error.InvalidArguments;
    }

    const file = try std.Io.Dir.cwd().createFile(init.io, args[1], .{});
    defer file.close(init.io);

    var buffer: [64 * 1024]u8 = undefined;
    var file_writer = file.writer(init.io, &buffer);
    const writer = &file_writer.interface;

    try writer.writeAll("var start = clock();\n");
    for (0..function_count) |i| {
        try writer.print(
            \\fun f{d}(a, b) {{
            \\  var x = a * {d} + b;
            \\  if (x > {d}) {{ x = x - 1; }} else {{ x = x + 1; }}
            \\  return x;
            \\}}
            \\
        , .{ i, i, i });
    }
    try writer.print("print f{d}(1, 2);\n", .{function_count - 1});
    try writer.writeAll("print clock() - start;\n");
    try writer.flush();
}
