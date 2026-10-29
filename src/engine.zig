const std = @import("std");
const vm_mod = @import("vm.zig");
const compiler_mod = @import("compiler.zig");
const scanner_mod = @import("scanner.zig");
const chunk_mod = @import("chunk.zig");

const Scanner = scanner_mod.Scanner;
const Compiler = compiler_mod.Compiler;
const VM = vm_mod.VM;
const FunctionType = compiler_mod.FunctionType;

pub const Engine = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    vm: VM,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !Engine {
        const vm = try VM.init(io, allocator);
        return Engine{
            .io = io,
            .allocator = allocator,
            .vm = vm,
        };
    }

    pub fn deinit(self: *Engine) void {
        self.vm.deinit();
    }

    pub fn execute(self: *Engine, source: []const u8) !void {
        var scanner = Scanner.init(source.ptr);
        var compiler = try Compiler.init(self.io, self.allocator, &scanner, &self.vm, null, FunctionType.SCRIPT);
        defer compiler.deinit();

        const functionObject = compiler.compile() catch |err| switch (err) {
            std.mem.Allocator.Error.OutOfMemory => {
                std.debug.print("Not enough memory.", .{});
                return;
            },
            chunk_mod.ChunkErrors.OutOfConstantDataSlots => {
                std.debug.print("Ran out of constant data slots (currently limited to 255).", .{});
                return;
            },
            else => {
                std.debug.print("Compile error.", .{});
                return;
            },
        };

        if (try self.vm.startScript(functionObject)) |_| {
            return;
        }

        _ = try self.vm.run();
    }
};

const InterpretResult = @import("vm.zig").InterpretResult;

fn loadTestFile(allocator: std.mem.Allocator, filename: []const u8) ![]u8 {
    const samples_dir = "samples";
    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ samples_dir, filename });
    defer allocator.free(full_path);

    const file = std.Io.Dir.cwd().openFile(std.testing.io, full_path, .{}) catch |err| {
        std.debug.print("Error opening test file '{s}': {}\n", .{ full_path, err });
        return err;
    };
    defer file.close(std.testing.io);

    const file_size = try file.length(std.testing.io);
    const source = try allocator.alloc(u8, file_size + 1);
    errdefer allocator.free(source);
    const bytes_read = try file.readPositionalAll(std.testing.io, source[0..file_size], 0);
    try std.testing.expectEqual(file_size, bytes_read);
    source[file_size] = 0;

    return source;
}

fn executeTestFile(allocator: std.mem.Allocator, filename: []const u8) !InterpretResult {
    const source = try loadTestFile(allocator, filename);
    defer allocator.free(source);

    var scanner = Scanner.init(source.ptr);
    var vm = try VM.init(std.testing.io, allocator);
    defer vm.deinit();
    var compiler = try Compiler.init(std.testing.io, allocator, &scanner, &vm, null, FunctionType.SCRIPT);
    defer compiler.deinit();

    const function = try compiler.compile();
    try std.testing.expectEqual(null, try vm.startScript(function));
    return try vm.run();
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

test "018 illegal assignment target" {
    const source = try loadTestFile(std.testing.allocator, "018_illegal_assignment_target.lox");
    defer std.testing.allocator.free(source);

    var scanner = Scanner.init(source.ptr);
    var vm = try VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();
    var compiler = try Compiler.init(std.testing.io, std.testing.allocator, &scanner, &vm, null, FunctionType.SCRIPT);
    defer compiler.deinit();

    // This should fail to compile
    try std.testing.expectError(error.ParseError, compiler.compile());
}

test "019 assignments" {
    const result = try executeTestFile(std.testing.allocator, "019_assignments.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "020 local variables" {
    const result = try executeTestFile(std.testing.allocator, "020_local_variables.lox");
    try std.testing.expect(result == InterpretResult.OK);
}

test "025 runtime error" {
    const result = try executeTestFile(std.testing.allocator, "025_runtime_error.lox");
    try std.testing.expect(result == InterpretResult.RUNTIME_ERROR);
}
