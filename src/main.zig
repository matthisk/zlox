const std = @import("std");
const _ = @import("scanner.zig");

const Value = f64;

const DEBUG_TRACE_EXECUTION = true;

const OpCode = enum(u8) {
    OP_RETURN,
    OP_CONSTANT,
    OP_NEGATE,
    OP_ADD,
    OP_SUBTRACT,
    OP_MULTIPLY,
    OP_DIVIDE,
    ILLEGAL,
};

const Chunk = struct {
    code: std.ArrayList(u8),
    data: std.ArrayList(Value),
    lines: std.ArrayList(usize),

    fn writeChunk(self: *Chunk, b: u8, l: usize) !void {
        try self.code.append(b);
        try self.lines.append(l);
    }

    fn addValue(self: *Chunk, v: Value) !u8 {
        try self.data.append(v);
        return @truncate(self.data.items.len - 1);
    }

    fn disassemble(self: *Chunk, name: []const u8) void {
        std.debug.print("== {s} ==\n", .{name});

        var offset: usize = 0;
        while (offset < self.code.items.len) {
            offset = self.disassembleInstruction(offset);
        }
    }

    fn disassembleInstruction(self: *Chunk, offset: usize) usize {
        std.debug.print("{:0>4} ", .{offset});
        if (offset > 0 and self.lines.items[offset] == self.lines.items[offset - 1]) {
            std.debug.print("   | ", .{});
        } else {
            std.debug.print("{:>4} ", .{self.lines.items[offset]});
        }

        const op: OpCode = std.meta.intToEnum(OpCode, self.code.items[offset]) catch OpCode.ILLEGAL;
        switch (op) {
            OpCode.OP_RETURN => {
                std.debug.print("OP_RETURN\n", .{});
                return offset + 1;
            },
            OpCode.OP_CONSTANT => {
                const loc: u8 = self.code.items[offset + 1];
                const value: Value = self.data.items[loc];
                std.debug.print("OP_CONSTANT {d}\n", .{value});
                return offset + 2;
            },
            OpCode.OP_NEGATE => {
                std.debug.print("OP_NEGATE\n", .{});
                return offset + 1;
            },
            OpCode.OP_ADD => {
                std.debug.print("OP_ADD\n", .{});
                return offset + 1;
            },
            OpCode.OP_MULTIPLY => {
                std.debug.print("OP_MULTIPLY\n", .{});
                return offset + 1;
            },
            OpCode.OP_SUBTRACT => {
                std.debug.print("OP_SUBTRACT\n", .{});
                return offset + 1;
            },
            OpCode.OP_DIVIDE => {
                std.debug.print("OP_SUBTRACT\n", .{});
                return offset + 1;
            },
            OpCode.ILLEGAL => {
                std.debug.print("ILLEGAL\n", .{});
                return offset + 1;
            },
        }
    }
};

const InterpretResult = enum {
    OK,
    COMPILE_ERROR,
    RUNTIME_ERROR,
};

const VM = struct {
    chunk: *Chunk,
    stack: std.ArrayList(Value),
    ip: [*]u8,

    fn run(self: *VM) !InterpretResult {
        self.ip = self.chunk.code.items.ptr;

        while (true) {
            if (comptime DEBUG_TRACE_EXECUTION) {
                _ = self.chunk.disassembleInstruction(@intFromPtr(self.ip) - @intFromPtr(self.chunk.code.items.ptr));
            }

            const instruction: OpCode = std.meta.intToEnum(OpCode, self.readByte()) catch OpCode.ILLEGAL;
            switch (instruction) {
                OpCode.OP_RETURN => {
                    return InterpretResult.OK;
                },
                OpCode.OP_CONSTANT => {
                    const constant = self.readConstant();
                    try self.stack.append(constant);
                },
                OpCode.OP_NEGATE => {
                    const a = self.stack.pop() orelse unreachable;
                    try self.stack.append(-a);
                },
                OpCode.OP_ADD => {
                    try self.binaryOp(BinaryOperator.PLUS);
                },
                OpCode.OP_SUBTRACT => {
                    try self.binaryOp(BinaryOperator.SUBTRACT);
                },
                OpCode.OP_MULTIPLY => {
                    try self.binaryOp(BinaryOperator.MULTIPLY);
                },
                OpCode.OP_DIVIDE => {
                    try self.binaryOp(BinaryOperator.DIVIDE);
                },
                OpCode.ILLEGAL => {
                    return InterpretResult.RUNTIME_ERROR;
                },
            }
        }

        return InterpretResult.OK;
    }

    inline fn readByte(self: *VM) u8 {
        const b = self.ip[0];
        self.ip += 1;
        return b;
    }

    inline fn readConstant(self: *VM) Value {
        const pos = self.readByte();
        return self.chunk.data.items[pos];
    }

    inline fn binaryOp(self: *VM, comptime op: BinaryOperator) !void {
        const b = self.stack.pop() orelse unreachable;
        const a = self.stack.pop() orelse unreachable;
        const result = switch (op) {
            .PLUS => a + b,
            .MULTIPLY => a * b,
            .SUBTRACT => a - b,
            .DIVIDE => a / b,
        };
        try self.stack.append(result);
    }
};

const BinaryOperator = enum { PLUS, MULTIPLY, DIVIDE, SUBTRACT };

fn initVM(allocator: std.mem.Allocator, chunk: *Chunk) VM {
    return VM{ .chunk = chunk, .ip = chunk.code.items.ptr, .stack = std.ArrayList(Value).init(allocator) };
}

pub fn main() !void {
    var chunk = Chunk{
        .code = std.ArrayList(u8).init(std.heap.page_allocator),
        .data = std.ArrayList(Value).init(std.heap.page_allocator),
        .lines = std.ArrayList(usize).init(std.heap.page_allocator),
    };
    // Initialize static data.
    const c1 = try chunk.addValue(1.2);
    const c2 = try chunk.addValue(3.8);

    // Initialize the bytecode.
    try chunk.writeChunk(@intFromEnum(OpCode.OP_CONSTANT), 1);
    try chunk.writeChunk(c1, 1);
    try chunk.writeChunk(@intFromEnum(OpCode.OP_CONSTANT), 1);
    try chunk.writeChunk(c2, 1);
    try chunk.writeChunk(@intFromEnum(OpCode.OP_ADD), 1);
    try chunk.writeChunk(@intFromEnum(OpCode.OP_RETURN), 1);

    chunk.disassemble("test chunk");

    std.debug.print("\n== VM trace ==\n", .{});

    var vm = initVM(std.heap.page_allocator, &chunk);
    const result = try vm.run();

    std.debug.print("run result {}", .{result});
}
