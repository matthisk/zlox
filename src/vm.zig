const std = @import("std");
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const Value = chunk_mod.Value;
const OpCode = chunk_mod.OpCode;

pub const InterpretResult = enum {
    OK,
    COMPILE_ERROR,
    RUNTIME_ERROR,
};

const BinaryOperator = enum { PLUS, MULTIPLY, DIVIDE, SUBTRACT };

const DEBUG_TRACE_EXECUTION = true;

pub const VM = struct {
    chunk: *Chunk,
    stack: std.ArrayList(Value),
    ip: [*]u8,

    pub fn init(allocator: std.mem.Allocator, chunk: *Chunk) VM {
        return VM{
            .chunk = chunk,
            .stack = std.ArrayList(Value).init(allocator),
            .ip = chunk.code.items.ptr,
        };
    }

    pub fn deinit(self: *VM) void {
        self.stack.deinit();
    }

    pub fn run(self: *VM) !InterpretResult {
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
