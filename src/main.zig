const std = @import("std");
const Engine = @import("engine.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var source: []u8 = undefined;

    if (args.len > 1) {
        const file_path = args[1];
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            std.debug.print("Error opening file '{s}': {}\n", .{ file_path, err });
            return;
        };
        defer file.close();

        const file_size = try file.getEndPos();
        source = try allocator.alloc(u8, file_size);
        _ = try file.readAll(source);

        std.debug.print("Read from file '{s}':\n", .{file_path});
    } else {
        const stdin = std.io.getStdIn().reader();

        std.debug.print("> ", .{});

        var buffer: [1024]u8 = undefined;
        if (try stdin.readUntilDelimiterOrEof(buffer[0..], '\n')) |input| {
            source = try allocator.dupe(u8, input);
            std.debug.print("Read from stdin:\n", .{});
        } else {
            std.debug.print("No input received\n", .{});
            return;
        }
    }

    defer allocator.free(source);

    try Engine.execute(allocator, source);
}
