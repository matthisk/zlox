const std = @import("std");
const config = @import("config");
const chunk_mod = @import("chunk.zig");
const Heap = @import("heap.zig").Heap;
const value = @import("value.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = value.Value;
const Obj = value.Obj;
const ObjFunction = value.ObjFunction;

pub const InterpretResult = enum {
    OK,
    COMPILE_ERROR,
    RUNTIME_ERROR,
};

const BinaryOperator = enum { PLUS, MULTIPLY, DIVIDE, SUBTRACT, LESS, GREATER };

const Errors = error{RuntimeError};

const CallFrame = struct {
    function: *ObjFunction,
    ip: [*]u8,
    slots: usize,
};

const FRAMES_MAX = 64;
const STACK_MAX = FRAMES_MAX * 0xFF;
const DEBUG_VM = config.debug_vm;
const DEBUG_STACK_LIMIT = 8;
const DEBUG_INSTRUCTION_LIMIT = 200;

pub const VM = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stack: std.ArrayList(Value),
    heap: Heap,
    globals: std.StringHashMap(Value),
    frames: [FRAMES_MAX]CallFrame = undefined,
    frameCount: usize,
    frame: *CallFrame = undefined,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !VM {
        var vm = VM{
            .io = io,
            .allocator = allocator,
            .stack = std.ArrayList(Value).empty,
            .heap = Heap.init(allocator),
            .globals = std.StringHashMap(Value).init(allocator),
            .frameCount = 0,
        };

        try vm.defineNative("clock", 0, clockNative);
        try vm.defineNative("random", 0, randomNative);
        try vm.defineNative("sqrt", 1, sqrtNative);
        try vm.defineNative("str", 1, strNative);
        try vm.defineNative("readLine", 0, readLineNative);

        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.stack.deinit(self.allocator);
        self.globals.deinit();
        self.heap.deinit();
    }

    pub fn resetStack(self: *VM) void {
        self.stack.clearRetainingCapacity();
        self.frameCount = 0;
    }

    pub fn appendFrame(self: *VM, function: *ObjFunction) void {
        var frame = &self.frames[self.frameCount];
        frame.function = function;
        frame.ip = function.chunk.code.items.ptr;
        frame.slots = self.stack.items.len;
        self.frameCount += 1;
    }

    pub fn startScript(self: *VM, functionObject: *Obj) !bool {
        try self.stack.append(self.allocator, value.objValue(functionObject));
        return self.call(functionObject.data.function, 0);
    }

    pub fn run(self: *VM) !InterpretResult {
        self.frame = &self.frames[self.frameCount - 1];

        if (comptime DEBUG_VM) {
            std.debug.print("== VM execution ==\n", .{});
        }

        var instruction_count: usize = 0;
        while (true) {
            const instruction_offset = @intFromPtr(self.frame.ip) - @intFromPtr(self.frame.function.chunk.code.items.ptr);
            if (comptime DEBUG_VM) {
                if (instruction_count < DEBUG_INSTRUCTION_LIMIT) {
                    std.debug.print("{f}", .{ExecutionTrace{ .vm = self, .offset = instruction_offset }});
                } else if (instruction_count == DEBUG_INSTRUCTION_LIMIT) {
                    std.debug.print(
                        "[vm] trace limit reached | suppressing instructions after {d}\n",
                        .{DEBUG_INSTRUCTION_LIMIT},
                    );
                }
            }
            instruction_count += 1;

            const instruction_byte = self.readByte();
            const instruction: OpCode = std.enums.fromInt(OpCode, instruction_byte) orelse OpCode.ILLEGAL;
            switch (instruction) {
                OpCode.OP_RETURN => {
                    const result = self.stack.pop().?;
                    self.frameCount -= 1;
                    if (self.frameCount == 0) {
                        _ = self.stack.pop().?;
                        return InterpretResult.OK;
                    }

                    self.stack.shrinkRetainingCapacity(self.frame.slots);
                    try self.stack.append(self.allocator, result);
                    self.frame = &self.frames[self.frameCount - 1];
                },
                OpCode.OP_TRUE => {
                    try self.stack.append(self.allocator, value.boolValue(true));
                },
                OpCode.OP_FALSE => {
                    try self.stack.append(self.allocator, value.boolValue(false));
                },
                OpCode.OP_NIL => {
                    try self.stack.append(self.allocator, value.nilValue());
                },
                OpCode.OP_CONSTANT => {
                    const constant = self.readConstant();
                    try self.stack.append(self.allocator, constant);
                },
                OpCode.OP_CONSTANT_LONG => {
                    const constant = self.readLongConstant();
                    try self.stack.append(self.allocator, constant);
                },
                OpCode.OP_NOT => {
                    try self.stack.append(self.allocator, value.boolValue(isFalsey(self.stack.pop().?)));
                },
                OpCode.OP_NEGATE => {
                    switch (self.stack.getLast()) {
                        .number => {
                            self.stack.items[self.stack.items.len - 1].number *= -1;
                        },
                        else => {
                            self.runtimeError("Operand must be a number.", .{});
                            return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                        },
                    }
                },
                OpCode.OP_ADD => {
                    self.binaryOp(BinaryOperator.PLUS) catch {
                        return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                    };
                },
                OpCode.OP_SUBTRACT => {
                    self.binaryOp(BinaryOperator.SUBTRACT) catch {
                        return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                    };
                },
                OpCode.OP_MULTIPLY => {
                    self.binaryOp(BinaryOperator.MULTIPLY) catch {
                        return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                    };
                },
                OpCode.OP_DIVIDE => {
                    self.binaryOp(BinaryOperator.DIVIDE) catch {
                        return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                    };
                },
                OpCode.OP_AND => {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    try self.stack.append(self.allocator, value.boolValue(isTruthy(a) and isTruthy(b)));
                },
                OpCode.OP_OR => {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    try self.stack.append(self.allocator, value.boolValue(isTruthy(a) or isTruthy(b)));
                },
                OpCode.OP_EQUALS => {
                    const b = self.stack.pop().?;
                    const a = self.stack.pop().?;
                    try self.stack.append(self.allocator, value.boolValue(self.valuesEqual(a, b)));
                },
                OpCode.OP_LESS => {
                    self.binaryOp(BinaryOperator.LESS) catch {
                        return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                    };
                },
                OpCode.OP_GREATER => {
                    self.binaryOp(BinaryOperator.GREATER) catch {
                        return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                    };
                },
                OpCode.OP_POP => {
                    _ = self.stack.pop();
                },
                OpCode.OP_POPN => {
                    var n = self.readByte();
                    while (n > 0) : (n -= 1) {
                        _ = self.stack.pop();
                    }
                },
                OpCode.OP_POPN_LONG => {
                    var n = self.readMedium();
                    while (n > 0) : (n -= 1) {
                        _ = self.stack.pop();
                    }
                },
                OpCode.OP_DUP => {
                    const v = self.peekStack(0);
                    try self.stack.append(self.allocator, v);
                },
                OpCode.OP_PRINT => {
                    const v = self.stack.pop().?;
                    try self.printProgramValue(v);
                },
                OpCode.OP_CALL => {
                    const argCount = self.readByte();
                    if (!try self.callValue(self.peekStack(argCount), argCount)) {
                        return InterpretResult.RUNTIME_ERROR;
                    }
                    self.frame = &self.frames[self.frameCount - 1];
                },
                OpCode.OP_DEFINE_GLOBAL => {
                    // TODO: We globals shouldn't always require a long constant slot.
                    const identifier = self.readLongConstant();
                    try self.globals.put(identifier.obj.data.str.chars, self.stack.pop().?);
                },
                OpCode.OP_GET_GLOBAL => {
                    const identfier = self.readLongConstant();
                    const v = self.globals.get(identfier.obj.data.str.chars);

                    if (v == null) {
                        self.runtimeError("Undefined variable '{s}'", .{identfier.obj.data.str.chars});
                        return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                    } else {
                        try self.stack.append(self.allocator, v.?);
                    }
                },
                OpCode.OP_SET_GLOBAL => {
                    const identifier = self.readLongConstant();
                    const name = identifier.obj.data.str.chars;
                    if (self.globals.contains(name)) {
                        try self.globals.put(name, self.peekStack(0));
                    } else {
                        self.runtimeError("Undefined variable '{s}'", .{name});
                        return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                    }
                },
                OpCode.OP_GET_LOCAL => {
                    const slot = self.readMedium();
                    try self.stack.append(self.allocator, self.stack.items[self.frame.slots + slot]);
                },
                OpCode.OP_SET_LOCAL => {
                    const slot = self.readMedium();
                    self.stack.items[self.frame.slots + slot] = self.peekStack(0);
                },
                OpCode.OP_JUMP_IF_FALSE => {
                    const offset = self.readShort();
                    if (isFalsey(self.peekStack(0))) {
                        self.frame.ip += offset;
                    }
                },
                OpCode.OP_JUMP => {
                    const offset = self.readShort();
                    self.frame.ip += offset;
                },
                OpCode.OP_LOOP => {
                    const offset = self.readShort();
                    self.frame.ip -= offset;
                },
                OpCode.ILLEGAL => {
                    self.runtimeError("Unknown opcode 0x{x:0>2}.", .{instruction_byte});
                    return self.finish(InterpretResult.RUNTIME_ERROR, instruction_count);
                },
            }
        }
    }

    inline fn readByte(self: *VM) u8 {
        const b = self.frame.ip[0];
        self.frame.ip += 1;
        return b;
    }

    inline fn readShort(self: *VM) u16 {
        const high = self.frame.ip[0];
        const low = self.frame.ip[1];
        self.frame.ip += 2;
        return (@as(u16, high) << 8) | low;
    }

    inline fn readMedium(self: *VM) u24 {
        const high = self.frame.ip[0];
        const mid = self.frame.ip[1];
        const low = self.frame.ip[2];
        self.frame.ip += 3;
        return (@as(u24, high) << 16) | (@as(u24, mid) << 8) | low;
    }

    inline fn readConstant(self: *VM) Value {
        const pos = self.readByte();
        return self.frame.function.chunk.data.items[pos];
    }

    inline fn readLongConstant(self: *VM) Value {
        const pos = self.readMedium();
        return self.frame.function.chunk.data.items[pos];
    }

    inline fn binaryOp(self: *VM, comptime op: BinaryOperator) !void {
        if (op == BinaryOperator.PLUS) {
            if (self.checkStringOperands()) {
                try self.concatenate();
            } else if (self.checkNumberOperands()) {
                const result = value.numberValue(self.stack.pop().?.number + self.stack.pop().?.number);
                try self.stack.append(self.allocator, result);
            } else {
                self.runtimeError("Operands must be two numbers or two strings.", .{});
                return Errors.RuntimeError;
            }
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
            try self.stack.append(self.allocator, result);
        } else {
            self.runtimeError("Operands must be numbers.", .{});
            return Errors.RuntimeError;
        }
    }

    inline fn concatenate(self: *VM) !void {
        const b = self.stack.pop().?.obj.data.str.chars;
        const a = self.stack.pop().?.obj.data.str.chars;

        const chars = try std.mem.concat(self.allocator, u8, &[_][]const u8{ a, b });
        const v = value.objValue(try self.heap.takeString(chars));

        try self.stack.append(self.allocator, v);
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

    inline fn callValue(self: *VM, callee: Value, argCount: u8) !bool {
        if (value.isFunction(callee)) {
            if (argCount != callee.obj.data.function.arity) {
                self.runtimeError("Expected {d} arguments but got {d}", .{ callee.obj.data.function.arity, argCount });
                return false;
            }
            return try self.call(callee.obj.data.function, argCount);
        }
        if (value.isNative(callee)) {
            const native = value.asNative(callee);
            if (argCount != native.arity) {
                self.runtimeError("Expected {d} arguments but got {d}", .{ native.arity, argCount });
                return false;
            }
            const firstArgumentOnStackOffset = self.stack.items.len - argCount;
            const result = try native.function(self, argCount, self.stack.items[firstArgumentOnStackOffset..]);
            self.stack.shrinkRetainingCapacity(firstArgumentOnStackOffset - 1);
            try self.stack.append(self.allocator, result);
            return true;
        }

        self.runtimeError("Can only call functions.", .{});
        return false;
    }

    fn call(self: *VM, func: *ObjFunction, argCount: u8) !bool {
        if (self.frameCount == FRAMES_MAX) {
            self.runtimeError("Stack overflow", .{});
            return false;
        }

        var frame = &self.frames[self.frameCount];
        self.frameCount += 1;
        frame.function = func;
        frame.ip = func.chunk.code.items.ptr;
        frame.slots = self.stack.items.len - argCount - 1;
        return true;
    }

    fn defineNative(self: *VM, name: []const u8, arity: u8, native: value.NativeFn) !void {
        try self.stack.append(self.allocator, value.objValue(try self.heap.copyString(name)));
        try self.stack.append(self.allocator, value.objValue(try self.heap.createNative(arity, native)));
        try self.globals.put(value.asStr(self.stack.items[0]), self.stack.items[1]);
        _ = self.stack.pop();
        _ = self.stack.pop();
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

    fn printProgramValue(self: *VM, v: Value) !void {
        var buffer: [256]u8 = undefined;
        var stdout_writer = std.Io.File.stdout().writerStreaming(self.io, &buffer);
        const stdout = &stdout_writer.interface;
        try value.write(v, stdout);
        try stdout.writeByte('\n');
        try stdout.flush();
    }

    fn finish(_: *VM, result: InterpretResult, instruction_count: usize) InterpretResult {
        if (comptime DEBUG_VM) {
            std.debug.print(
                "[vm] finished | {s} | {d} instructions\n",
                .{ @tagName(result), instruction_count },
            );
        }
        return result;
    }

    fn runtimeError(self: *VM, comptime msg: []const u8, args: anytype) void {
        const instruction = @intFromPtr(self.frame.ip) - @intFromPtr(self.frame.function.chunk.code.items.ptr) - 1;
        const line = self.frame.function.chunk.getLine(instruction);

        std.debug.print("[vm] runtime error | line {d} | ", .{line});
        std.debug.print(msg ++ "\n", args);

        for (1..self.frameCount + 1) |incIndex| {
            const i = self.frameCount - incIndex;
            const frame = &self.frames[i];
            const func = frame.function;
            const index = @intFromPtr(frame.ip) - @intFromPtr(func.chunk.code.items.ptr) - 1;
            std.debug.print("[vm] runtime error | line {d} | ", .{func.chunk.getLine(index)});
            std.debug.print("{s}()\n", .{func.name.chars});
        }

        self.resetStack();
    }
};

pub fn readLineNative(vm: *VM, _: usize, _: []const Value) !Value {
    return value.objValue(try vm.heap.copyString("hello world"));
}

pub fn strNative(vm: *VM, argCount: usize, args: []const Value) !Value {
    if (argCount != 1) {
        return Errors.RuntimeError;
    }
    const v = args[0];
    const str = switch (v) {
        .bool => |b| try vm.heap.copyString(if (b) "true" else "false"),
        .number => |n| try vm.heap.takeString(try std.fmt.allocPrint(vm.allocator, "{d}", .{n})),
        .nil => try vm.heap.copyString("nil"),
        .obj => |o| switch (o.data) {
            .str => o,
            .function => try vm.heap.copyString("function"),
            .native => try vm.heap.copyString("native"),
        },
    };

    return value.objValue(str);
}

pub fn sqrtNative(_: *VM, argCount: usize, args: []const Value) !Value {
    if (argCount != 1) {
        return Errors.RuntimeError;
    }
    if (!value.isNumber(args[0])) {
        return Errors.RuntimeError;
    }
    return value.numberValue(std.math.sqrt(args[0].number));
}

pub fn clockNative(vm: *VM, _: usize, _: []const Value) !Value {
    return value.numberValue(@floatFromInt(std.Io.Timestamp.now(vm.io, .real).toMilliseconds()));
}

var prng = std.Random.DefaultPrng.init(12345);
const random = prng.random();

pub fn randomNative(_: *VM, _: usize, _: []const Value) !Value {
    return value.numberValue(random.float(f64));
}

const ExecutionTrace = struct {
    vm: *const VM,
    offset: usize,

    pub fn format(self: ExecutionTrace, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const line = self.vm.frame.function.chunk.getLine(self.offset);
        var instruction_buffer: [256]u8 = undefined;
        var instruction_writer: std.Io.Writer = .fixed(&instruction_buffer);
        try instruction_writer.print("{f}", .{self.vm.frame.function.chunk.formatInstruction(self.offset, false)});

        try writer.print("[vm] {d:0>4} line {d: >4} | {s: <32} | stack [", .{
            self.offset,
            line,
            instruction_writer.buffered(),
        });

        const stack = self.vm.stack.items;
        if (stack.len <= DEBUG_STACK_LIMIT) {
            try writeStackValues(writer, stack);
        } else {
            const visible_each_side = DEBUG_STACK_LIMIT / 2;
            try writeStackValues(writer, stack[0..visible_each_side]);
            try writer.print(", ... {d} hidden ..., ", .{stack.len - DEBUG_STACK_LIMIT});
            try writeStackValues(writer, stack[stack.len - visible_each_side ..]);
        }
        try writer.writeByte(']');

        if (stack.len > 0) try writer.writeAll(" <- top");

        const byte = self.vm.frame.function.chunk.code.items[self.offset];
        const op = std.enums.fromInt(OpCode, byte) orelse OpCode.ILLEGAL;
        if (op == OpCode.OP_JUMP_IF_FALSE and stack.len > 0) {
            try writer.writeAll(if (isFalsey(stack[stack.len - 1])) " | taken" else " | not taken");
        }
        try writer.writeByte('\n');
    }

    fn writeStackValues(writer: *std.Io.Writer, values: []const Value) std.Io.Writer.Error!void {
        for (values, 0..) |item, index| {
            if (index > 0) try writer.writeAll(", ");
            try writer.print("{f}", .{value.format(item)});
        }
    }
};

test "execution trace labels instruction and pre-execution stack" {
    const function = try ObjFunction.create(std.testing.allocator);
    defer function.destroy(std.testing.allocator);

    try function.chunk.writeChunk(@intFromEnum(OpCode.OP_ADD), 4);

    var vm = VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();
    vm.appendFrame(function);
    vm.frame = &vm.frames[vm.frameCount - 1];
    try vm.stack.append(std.testing.allocator, value.numberValue(1));
    try vm.stack.append(std.testing.allocator, value.numberValue(2));

    try std.testing.expectFmt(
        "[vm] 0000 line    4 | ADD                              | stack [1, 2] <- top\n",
        "{f}",
        .{ExecutionTrace{ .vm = &vm, .offset = 0 }},
    );
}

test "execution trace shows branch destination and decision" {
    const function = try ObjFunction.create(std.testing.allocator);
    defer function.destroy(std.testing.allocator);

    try function.chunk.writeChunk(@intFromEnum(OpCode.OP_JUMP_IF_FALSE), 3);
    try function.chunk.writeChunk(0, 3);
    try function.chunk.writeChunk(2, 3);

    var vm = VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();
    vm.appendFrame(function);
    vm.frame = &vm.frames[vm.frameCount - 1];
    try vm.stack.append(std.testing.allocator, value.boolValue(false));

    try std.testing.expectFmt(
        "[vm] 0000 line    3 | JUMP_IF_FALSE -> 0005            | stack [false] <- top | taken\n",
        "{f}",
        .{ExecutionTrace{ .vm = &vm, .offset = 0 }},
    );
}

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
