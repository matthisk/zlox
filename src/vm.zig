const std = @import("std");
const chunk_mod = @import("chunk.zig");
const value = @import("value.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = value.Value;
const Obj = value.Obj;

pub const InterpretResult = enum {
    OK,
    COMPILE_ERROR,
    RUNTIME_ERROR,
};

const BinaryOperator = enum { PLUS, MULTIPLY, DIVIDE, SUBTRACT, LESS, GREATER };

const Errors = error{RuntimeError};

const DEBUG_TRACE_EXECUTION = true;

pub const VM = struct {
    allocator: std.mem.Allocator,
    chunk: *Chunk,
    stack: std.ArrayList(Value),
    objects: ?*Obj,
    ip: [*]u8,
    strings: std.StringHashMap(*Obj),
    globals: std.StringHashMap(Value),

    pub fn init(allocator: std.mem.Allocator, chunk: *Chunk) VM {
        return VM{
            .allocator = allocator,
            .chunk = chunk,
            .stack = std.ArrayList(Value).init(allocator),
            .strings = std.StringHashMap(*Obj).init(allocator),
            .globals = std.StringHashMap(Value).init(allocator),
            .objects = null,
            .ip = chunk.code.items.ptr,
        };
    }

    pub fn deinit(self: *VM) void {
        self.stack.deinit();
        self.strings.deinit();
        self.globals.deinit();
        var object = self.objects;
        while (object != null) {
            const next = object.?.next;
            object.?.destroy(self.allocator);
            object = next;
        }
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
                            .obj => {
                                std.debug.print("[ ", .{});
                                value.print(item);
                                std.debug.print(" ]", .{});
                            },
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
                    try self.stack.append(value.boolValue(isFalsey(self.stack.pop().?)));
                },
                OpCode.OP_NEGATE => {
                    switch (self.stack.getLast()) {
                        .number => {
                            const a = self.stack.pop().?.number;
                            try self.stack.append(value.numberValue(-a));
                        },
                        else => {
                            self.runtimeError("Operand must be a number.", .{});
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
                OpCode.OP_AND => {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    try self.stack.append(value.boolValue(isTruthy(a) and isTruthy(b)));
                },
                OpCode.OP_OR => {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    try self.stack.append(value.boolValue(isTruthy(a) or isTruthy(b)));
                },
                OpCode.OP_EQUALS => {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    try self.stack.append(value.boolValue(self.valuesEqual(a, b)));
                },
                OpCode.OP_LESS => {
                    self.binaryOp(BinaryOperator.LESS) catch {
                        return InterpretResult.RUNTIME_ERROR;
                    };
                },
                OpCode.OP_GREATER => {
                    self.binaryOp(BinaryOperator.GREATER) catch {
                        return InterpretResult.RUNTIME_ERROR;
                    };
                },
                OpCode.OP_POP => {
                    _ = self.stack.pop();
                },
                OpCode.OP_PRINT => {
                    const v = self.stack.pop().?;
                    value.print(v);
                },
                OpCode.OP_DEFINE_GLOBAL => {
                    const identifier = self.readConstant();
                    try self.globals.put(identifier.obj.data.str.chars, self.stack.pop().?);
                },
                OpCode.OP_GET_GLOBAL => {
                    const identfier = self.readConstant();
                    const v = self.globals.get(identfier.obj.data.str.chars);

                    if (v == null) {
                        self.runtimeError("Undefined variable '{s}'", .{identfier.obj.data.str.chars});
                        return InterpretResult.RUNTIME_ERROR;
                    } else {
                        try self.stack.append(v.?);
                    }
                },
                OpCode.OP_SET_GLOBAL => {
                    const identifier = self.readConstant();
                    const name = identifier.obj.data.str.chars;
                    if (self.globals.contains(name)) {
                        try self.globals.put(name, self.peekStack(0));
                    } else {
                        self.runtimeError("Undefined variable '{s}'", .{name});
                        return InterpretResult.RUNTIME_ERROR;
                    }
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
        if (self.checkStringOperands()) {
            try self.concatenate();
        } else if (self.checkNumberOperands()) {
            // Safe to expect both entries to be numbers.
            const b = self.stack.pop().?.number;
            const a = self.stack.pop().?.number;

            const result = switch (op) {
                .PLUS => value.numberValue(a + b),
                .MULTIPLY => value.numberValue(a * b),
                .SUBTRACT => value.numberValue(a - b),
                .DIVIDE => value.numberValue(a / b),
                .LESS => value.boolValue(a < b),
                .GREATER => value.boolValue(a > b),
            };
            try self.stack.append(result);
        } else {
            self.runtimeError("Operands must be numbers.", .{});
            return Errors.RuntimeError;
        }
    }

    inline fn concatenate(self: *VM) !void {
        const b = self.stack.pop().?.obj.data.str.chars;
        const a = self.stack.pop().?.obj.data.str.chars;

        const chars = try std.mem.concat(self.allocator, u8, &[_][]const u8{ a, b });
        const v = value.objValue(try value.takeString(self.allocator, self, chars));

        try self.stack.append(v);
    }

    inline fn valuesEqual(_: *VM, a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
            return false;
        }

        return switch (a) {
            .number => a.number == b.number,
            .bool => a.bool == b.bool,
            .nil => true,
            .obj => {
                if (std.meta.activeTag(a.obj.data) != std.meta.activeTag(b.obj.data)) {
                    return false;
                }

                return std.mem.eql(u8, a.obj.data.str.chars, b.obj.data.str.chars);
            },
        };
    }

    fn checkStringOperands(self: *VM) bool {
        return value.isString(self.peekStack(0)) and value.isString(self.peekStack(1));
    }

    fn checkNumberOperands(self: *VM) bool {
        return value.isNumber(self.peekStack(0)) and value.isNumber(self.peekStack(1));
    }

    fn peekStack(self: *VM, i: usize) Value {
        return self.stack.items[self.stack.items.len - 1 - i];
    }

    fn runtimeError(self: *VM, comptime msg: []const u8, args: anytype) void {
        const instruction = @intFromPtr(self.ip) - @intFromPtr(self.chunk.code.items.ptr) - 1;
        const line = self.chunk.lines.items[instruction];

        std.debug.print(msg, args);
        std.debug.print("\n", .{});
        std.debug.print("[line {d}] in script\n", .{line});
    }
};

inline fn isTruthy(v: Value) bool {
    return switch (v) {
        .bool => v.bool,
        .number => false,
        .nil => false,
        .obj => false,
    };
}

inline fn isFalsey(v: Value) bool {
    return switch (v) {
        .bool => !v.bool,
        .number => false,
        .nil => true,
        .obj => true,
    };
}
