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

const InterpretResult = @import("vm.zig").InterpretResult;

fn loadTestFile(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const samples_dir = "samples";
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ samples_dir, filename });
    defer allocator.free(full_path);

    const file = std.fs.cwd().openFile(full_path, .{}) catch |err| {
        std.debug.print("Error opening test file '{s}': {}\n", .{ full_path, err });
        return err;
    };
    defer file.close();

    const file_size = try file.getEndPos();
    const source = try allocator.alloc(u8, file_size);
    _ = try file.readAll(source);

    return source;
}

fn executeTestFile(allocator: std.mem.Allocator, filename: []const u8) !InterpretResult {
    const source = try loadTestFile(allocator, filename);
    defer allocator.free(source);

    var chunk = Chunk.init(allocator);
    var scanner = Scanner.init(source.ptr);
    var vm = VM.init(allocator, &chunk);
    var compiler = Compiler.init(allocator, &scanner, &vm);
    defer chunk.deinit();
    defer vm.deinit();

    try compiler.compile(&chunk);
    return try vm.run();
}

test "engine execute" {
    try execute(std.testing.allocator, "1 + 1");
}

test "001 simple expression" {
    const result = try executeTestFile(std.testing.allocator, "001_simple_expression.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "002 boolean literals" {
    const result = try executeTestFile(std.testing.allocator, "002_boolean_literals.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "003 boolean operations" {
    const result = try executeTestFile(std.testing.allocator, "003_boolean_operations.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "004 boolean or" {
    const result = try executeTestFile(std.testing.allocator, "004_boolean_or.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "005 nil value" {
    const result = try executeTestFile(std.testing.allocator, "005_nil_value.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "006 string literal" {
    const result = try executeTestFile(std.testing.allocator, "006_string_literal.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "007 string concatenation" {
    const result = try executeTestFile(std.testing.allocator, "007_string_concatenation.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "008 empty string" {
    const result = try executeTestFile(std.testing.allocator, "008_empty_string.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "009 number comparison" {
    const result = try executeTestFile(std.testing.allocator, "009_number_comparison.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "010 number equality" {
    const result = try executeTestFile(std.testing.allocator, "010_number_equality.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "011 less equal" {
    const result = try executeTestFile(std.testing.allocator, "011_less_equal.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "012 not equal" {
    const result = try executeTestFile(std.testing.allocator, "012_not_equal.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "013 string equality" {
    const result = try executeTestFile(std.testing.allocator, "013_string_equality.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "014 negation precedence" {
    const result = try executeTestFile(std.testing.allocator, "014_negation_precedence.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "015 complex boolean" {
    const result = try executeTestFile(std.testing.allocator, "015_complex_boolean.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "016 arithmetic negation" {
    const result = try executeTestFile(std.testing.allocator, "016_arithmetic_negation.lox");
    try std.testing.expect(result == InterpretResult.OK);
}
