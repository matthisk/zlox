const std = @import("std");
const chunk_mod = @import("chunk.zig");
const value = @import("value.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = value.Value;

pub const InterpretResult = enum {
    OK,
    COMPILE_ERROR,
    RUNTIME_ERROR,
};

const BinaryOperator = enum { PLUS, MULTIPLY, DIVIDE, SUBTRACT };

const Errors = error{RuntimeError};

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
                if (self.stack.items.len > 0) {
                    std.debug.print("          ", .{});
                    for (self.stack.items) |item| {
                        switch (item) {
                            .number => |n| std.debug.print("[ {d} ]", .{n}),
                            .bool => |b| std.debug.print("[ {} ]", .{b}),
                            .nil => std.debug.print("[ nil ]", .{}),
                        }
                    }
                    std.debug.print("\n", .{});
                }
            }

            const instruction: OpCode = std.meta.intToEnum(OpCode, self.readByte()) catch OpCode.ILLEGAL;
            switch (instruction) {
                OpCode.OP_RETURN => {
                    return InterpretResult.OK;
                },
                OpCode.OP_TRUE => {
                    try self.stack.append(value.boolValue(true));
                },
                OpCode.OP_FALSE => {
                    try self.stack.append(value.boolValue(false));
                },
                OpCode.OP_NIL => {
                    try self.stack.append(value.nilValue());
                },
                OpCode.OP_CONSTANT => {
                    const constant = self.readConstant();
                    try self.stack.append(constant);
                },
                OpCode.OP_NOT => {
                    switch (self.stack.getLast()) {
                        .bool => {
                            try self.stack.append(value.boolValue(!self.stack.pop().?.bool));
                        },
                        else => {
                            self.runtimeError("Operand must be a boolean.");
                            return InterpretResult.RUNTIME_ERROR;
                        },
                    }
                },
                OpCode.OP_NEGATE => {
                    switch (self.stack.getLast()) {
                        .number => {
                            const a = self.stack.pop().?.number;
                            try self.stack.append(value.numberValue(-a));
                        },
                        else => {
                            self.runtimeError("Operand must be a number.");
                            return InterpretResult.RUNTIME_ERROR;
                        },
                    }
                },
                OpCode.OP_ADD => {
                    self.binaryOp(BinaryOperator.PLUS) catch {
                        return InterpretResult.RUNTIME_ERROR;
                    };
                },
                OpCode.OP_SUBTRACT => {
                    self.binaryOp(BinaryOperator.SUBTRACT) catch {
                        return InterpretResult.RUNTIME_ERROR;
                    };
                },
                OpCode.OP_MULTIPLY => {
                    self.binaryOp(BinaryOperator.MULTIPLY) catch {
                        return InterpretResult.RUNTIME_ERROR;
                    };
                },
                OpCode.OP_DIVIDE => {
                    self.binaryOp(BinaryOperator.DIVIDE) catch {
                        return InterpretResult.RUNTIME_ERROR;
                    };
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
        if (!self.checkNumberOperands()) {
            self.runtimeError("Operands must be numbers.");
            return Errors.RuntimeError;
        }

        // Safe to expect both entries to be numbers.
        const b = self.stack.pop().?.number;
        const a = self.stack.pop().?.number;

        const result = switch (op) {
            .PLUS => a + b,
            .MULTIPLY => a * b,
            .SUBTRACT => a - b,
            .DIVIDE => a / b,
        };
        try self.stack.append(value.numberValue(result));
    }

    fn checkNumberOperands(self: *VM) bool {
        return value.isNumber(self.peekStack(0)) and value.isNumber(self.peekStack(1));
    }

    fn peekStack(self: *VM, i: usize) Value {
        return self.stack.items[self.stack.items.len - 1 - i];
    }

    fn runtimeError(self: *VM, msg: []const u8) void {
        const instruction = @intFromPtr(self.ip) - @intFromPtr(self.chunk.code.items.ptr) - 1;
        const line = self.chunk.lines.items[instruction];

        std.debug.print("{s}\n", .{msg});
        std.debug.print("[line {d}] in script\n", .{line});
    }
};
