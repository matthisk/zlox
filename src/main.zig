const std = @import("std");
const Engine = @import("engine.zig").Engine;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const args = try init.minimal.args.toSlice(allocator);

    var engine = try Engine.init(init.io, allocator);
    defer engine.deinit();

    if (args.len > 1) {
        const file_path = args[1];
        const file = std.Io.Dir.cwd().openFile(init.io, file_path, .{}) catch |err| {
            std.debug.print("Error opening file '{s}': {}\n", .{ file_path, err });
            return;
        };
        defer file.close(init.io);

        const file_size = try file.length(init.io);
        const source = try allocator.alloc(u8, file_size + 1);
        _ = try file.readPositionalAll(init.io, source[0..file_size], 0);
        source[file_size] = 0;

        defer allocator.free(source);

        engine.execute(source) catch |err| {
            std.debug.print("Error: {}\n", .{err});
        };
    } else {
        var buffer = std.ArrayList(u8).empty;
        defer buffer.deinit(allocator);

        var stdin_buffer: [1024]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buffer);
        const stdin = &reader.interface;

        while (true) {
            std.debug.print("> ", .{});

            buffer.clearAndFree(allocator);

            const line = stdin.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    std.debug.print("\nGoodbye!\n", .{});
                    return;
                },
                else => return err,
            };

            try buffer.appendSlice(allocator, line);
            try buffer.append(allocator, 0);

            engine.execute(buffer.items) catch |err| {
                std.debug.print("Error: {}\n", .{err});
            };
        }
    }
}
