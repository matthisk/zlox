const std = @import("std");
const Engine = @import("engine.zig").Engine;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var engine = Engine.init(allocator);
    defer engine.deinit();

    if (args.len > 1) {
        const file_path = args[1];
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            std.debug.print("Error opening file '{s}': {}\n", .{ file_path, err });
            return;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        const source = try allocator.alloc(u8, file_size);
        _ = try file.readAll(source);

        defer allocator.free(source);

        engine.execute(source) catch |err| {
            std.debug.print("Error: {}\n", .{err});
        };
    } else {
        var buffer = std.ArrayList(u8).init(allocator);
        defer buffer.deinit();

        while (true) {
            const stdin = std.io.getStdIn().reader();

            std.debug.print("> ", .{});

            buffer.clearRetainingCapacity();

            stdin.streamUntilDelimiter(buffer.writer(), '\n', null) catch |err| switch (err) {
                error.EndOfStream => {
                    std.debug.print("\nGoodbye!\n", .{});
                    return;
                },
                else => return err,
            };

            try buffer.append(0);

            engine.execute(buffer.items) catch |err| {
                std.debug.print("Error: {}\n", .{err});
            };
        }
    }
}
