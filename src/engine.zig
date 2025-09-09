const std = @import("std");
const vm_mod = @import("vm.zig");
const compiler_mod = @import("compiler.zig");
const scanner_mod = @import("scanner.zig");
const chunk_mod = @import("chunk.zig");

const Chunk = chunk_mod.Chunk;
const Scanner = scanner_mod.Scanner;
const Compiler = compiler_mod.Compiler;
const VM = vm_mod.VM;

pub fn execute(allocator: std.mem.Allocator, source: []const u8) !void {
    var chunk = Chunk.init(allocator);
    var scanner = Scanner.init(source.ptr);
    var vm = VM.init(allocator, &chunk);
    var compiler = Compiler.init(allocator, &scanner, &vm);
    defer chunk.deinit();
    defer vm.deinit();

    try compiler.compile(&chunk);
    const result = try vm.run();

    std.debug.print("RESULT {s}\n", .{@tagName(result)});
}

test "engine execute" {
    try execute(std.testing.allocator, "1 + 1");
}
