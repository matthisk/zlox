const std = @import("std");
const config = @import("config");
const chunk_mod = @import("chunk.zig");
const Heap = @import("heap.zig").Heap;
const value = @import("value.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = value.Value;
const ObjStr = value.ObjStr;
const ObjFunction = value.ObjFunction;
const ObjClosure = value.ObjClosure;
const ObjUpvalue = value.ObjUpvalue;

pub const InterpretResult = enum {
    OK,
    COMPILE_ERROR,
    RUNTIME_ERROR,
};

const BinaryOperator = enum { PLUS, MULTIPLY, DIVIDE, SUBTRACT, LESS, GREATER };

const Errors = error{RuntimeError};

const CallFrame = struct {
    closure: *ObjClosure,
    ip: [*]u8,
    slots: usize,
};

const RuntimeFault = union(enum) {
    operand_must_be_number,
    operands_must_be_numbers,
    operands_must_be_numbers_or_strings,
    undefined_variable: []const u8,
    expected_arguments: struct {
        expected: usize,
        actual: u8,
    },
    stack_overflow,
    not_callable,
    illegal_opcode: u8,

    pub fn format(self: RuntimeFault, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .operand_must_be_number => try writer.writeAll("Operand must be a number."),
            .operands_must_be_numbers => try writer.writeAll("Operands must be numbers."),
            .operands_must_be_numbers_or_strings => try writer.writeAll("Operands must be two numbers or two strings."),
            .undefined_variable => |name| try writer.print("Undefined variable '{s}'", .{name}),
            .expected_arguments => |arguments| try writer.print(
                "Expected {d} arguments but got {d}",
                .{ arguments.expected, arguments.actual },
            ),
            .stack_overflow => try writer.writeAll("Stack overflow"),
            .not_callable => try writer.writeAll("Can only call functions."),
            .illegal_opcode => |opcode| try writer.print("Unknown opcode 0x{x:0>2}.", .{opcode}),
        }
    }
};

const FRAMES_MAX = 64;
const STACK_MAX = FRAMES_MAX * 0xFF;
const DEBUG_VM = config.debug_vm;
const DEBUG_STACK_LIMIT = 8;
const DEBUG_INSTRUCTION_LIMIT = 200;

const Stack = struct {
    // Open upvalues point into this storage. Do not move the VM while it is running.
    values: [STACK_MAX]Value = undefined,
    len: usize = 0,

    fn append(self: *Stack, v: Value) error{StackOverflow}!void {
        if (self.len == STACK_MAX) return error.StackOverflow;
        self.values[self.len] = v;
        self.len += 1;
    }

    fn pop(self: *Stack) ?Value {
        if (self.len == 0) return null;
        self.len -= 1;
        return self.values[self.len];
    }

    fn getLast(self: *const Stack) Value {
        return self.values[self.len - 1];
    }

    fn clearRetainingCapacity(self: *Stack) void {
        self.len = 0;
    }

    fn shrinkRetainingCapacity(self: *Stack, len: usize) void {
        std.debug.assert(len <= self.len);
        self.len = len;
    }
};

test "fixed stack preserves captured slots and rejects overflow" {
    var stack: Stack = .{};
    try stack.append(value.numberValue(42));
    const captured = &stack.values[0];

    while (stack.len < STACK_MAX) {
        try stack.append(value.nilValue());
    }
    try std.testing.expectError(error.StackOverflow, stack.append(value.nilValue()));
    try std.testing.expectEqual(@as(usize, STACK_MAX), stack.len);
    try std.testing.expect(captured == &stack.values[0]);
    try std.testing.expectEqual(@as(f64, 42), captured.number);

    stack.shrinkRetainingCapacity(1);
    try std.testing.expectEqual(@as(f64, 42), stack.pop().?.number);
    try std.testing.expectEqual(@as(?Value, null), stack.pop());
    try stack.append(value.boolValue(true));
    stack.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), stack.len);
}

pub const VM = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    stack: Stack,
    heap: Heap,
    globals: std.AutoHashMap(*ObjStr, Value),
    frames: [FRAMES_MAX]CallFrame = undefined,
    frameCount: usize,
    openUpvalues: ?*ObjUpvalue = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !VM {
        var vm = VM{
            .io = io,
            .allocator = allocator,
            .stack = .{},
            .heap = Heap.init(allocator),
            .globals = std.AutoHashMap(*ObjStr, Value).init(allocator),
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
        self.globals.deinit();
        self.heap.deinit();
    }

    pub fn resetStack(self: *VM) void {
        self.stack.clearRetainingCapacity();
        self.frameCount = 0;
    }

    pub fn getGlobal(self: *VM, name: []const u8) ?Value {
        const interned = self.heap.strings.get(name) orelse return null;
        return self.globals.get(interned);
    }

    pub fn appendFrame(self: *VM, function: *ObjFunction) void {
        var frame = &self.frames[self.frameCount];
        frame.ip = function.chunk.code.items.ptr;
        frame.slots = self.stack.len;
        self.frameCount += 1;
    }

    pub fn startScript(self: *VM, function: *ObjFunction) !?RuntimeFault {
        const closure = try self.heap.createClosure(function);
        try self.stack.append(.{ .closure = closure });
        return self.call(closure, 0);
    }

    pub fn run(self: *VM) !InterpretResult {
        const fault = self.runInstructions() catch |err| switch (err) {
            error.StackOverflow => RuntimeFault.stack_overflow,
            else => return err,
        };
        if (fault) |runtimeFault| {
            self.runtimeError(runtimeFault);
            return InterpretResult.RUNTIME_ERROR;
        }
        return InterpretResult.OK;
    }

    fn runInstructions(self: *VM) !?RuntimeFault {
        var frame = &self.frames[self.frameCount - 1];
        var constants = frame.closure.function.chunk.data.items;
        var code = frame.closure.function.chunk.code.items.ptr;
        var ip = frame.ip;
        defer frame.ip = ip;

        if (comptime DEBUG_VM) {
            std.debug.print("== VM execution ==\n", .{});
        }

        var instruction_count: usize = 0;
        while (true) {
            try self.heap.collectGarbage(self);

            const instruction_offset = @intFromPtr(ip) - @intFromPtr(code);
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

            const instruction_byte = self.readByte(&ip);
            const instruction: OpCode = std.enums.fromInt(OpCode, instruction_byte) orelse OpCode.ILLEGAL;
            switch (instruction) {
                OpCode.OP_RETURN => {
                    const result = self.stack.pop().?;
                    self.closeUpvalues(&self.stack.values[frame.slots]);
                    self.frameCount -= 1;
                    if (self.frameCount == 0) {
                        _ = self.stack.pop().?;
                        return null;
                    }

                    self.stack.shrinkRetainingCapacity(frame.slots);
                    try self.stack.append(result);
                    frame = &self.frames[self.frameCount - 1];
                    constants = frame.closure.function.chunk.data.items;
                    code = frame.closure.function.chunk.code.items.ptr;
                    ip = frame.ip;
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
                    const constant = self.readConstant(&ip, constants);
                    try self.stack.append(constant);
                },
                OpCode.OP_CONSTANT_LONG => {
                    const constant = self.readLongConstant(&ip, constants);
                    try self.stack.append(constant);
                },
                OpCode.OP_NOT => {
                    try self.stack.append(value.boolValue(isFalsey(self.stack.pop().?)));
                },
                OpCode.OP_NEGATE => {
                    switch (self.stack.getLast()) {
                        .number => {
                            self.stack.values[self.stack.len - 1].number *= -1;
                        },
                        else => {
                            return .operand_must_be_number;
                        },
                    }
                },
                OpCode.OP_ADD => {
                    if (try self.binaryOp(BinaryOperator.PLUS)) |err| {
                        return err;
                    }
                },
                OpCode.OP_SUBTRACT => {
                    if (try self.binaryOp(BinaryOperator.SUBTRACT)) |err| {
                        return err;
                    }
                },
                OpCode.OP_MULTIPLY => {
                    if (try self.binaryOp(BinaryOperator.MULTIPLY)) |err| {
                        return err;
                    }
                },
                OpCode.OP_DIVIDE => {
                    if (try self.binaryOp(BinaryOperator.DIVIDE)) |err| {
                        return err;
                    }
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
                    if (try self.binaryOp(BinaryOperator.LESS)) |err| {
                        return err;
                    }
                },
                OpCode.OP_GREATER => {
                    if (try self.binaryOp(BinaryOperator.GREATER)) |err| {
                        return err;
                    }
                },
                OpCode.OP_POP => {
                    _ = self.stack.pop();
                },
                OpCode.OP_POPN => {
                    var n = self.readByte(&ip);
                    while (n > 0) : (n -= 1) {
                        _ = self.stack.pop();
                    }
                },
                OpCode.OP_POPN_LONG => {
                    var n = self.readMedium(&ip);
                    while (n > 0) : (n -= 1) {
                        _ = self.stack.pop();
                    }
                },
                OpCode.OP_DUP => {
                    const v = self.peekStack(0);
                    try self.stack.append(v);
                },
                OpCode.OP_PRINT => {
                    const v = self.stack.pop().?;
                    try self.printProgramValue(v);
                },
                OpCode.OP_CLOSURE, OpCode.OP_CLOSURE_LONG => {
                    const functionValue = if (instruction == .OP_CLOSURE)
                        self.readConstant(&ip, constants)
                    else
                        constants[self.readMedium(&ip)];
                    const f = value.asFunction(functionValue);
                    const c = try self.heap.createClosure(f);

                    for (0..f.upvalueCount) |i| {
                        const isLocal = self.readByte(&ip);
                        const index = self.readMedium(&ip);

                        if (isLocal == 1) {
                            c.upvalues[i] = try self.captureUpvalue(&self.stack.values[frame.slots + index]);
                        } else {
                            c.upvalues[i] = frame.closure.upvalues[i];
                        }
                    }

                    try self.stack.append(.{ .closure = c });
                },
                OpCode.OP_GET_UPVALUE => {
                    const slot = self.readMedium(&ip);
                    try self.stack.append(frame.closure.upvalues[slot].location.*);
                },
                OpCode.OP_SET_UPVALUE => {
                    const slot = self.readMedium(&ip);
                    frame.closure.upvalues[slot].location.* = self.peekStack(0);
                },
                OpCode.OP_CLOSE_UPVALUE => {
                    self.closeUpvalues(&self.stack.values[self.stack.len - 1]);
                    _ = self.stack.pop();
                },
                OpCode.OP_CALL => {
                    const argCount = self.readByte(&ip);

                    // Safe the caller's ip address.
                    frame.ip = ip;

                    if (try self.callValue(self.peekStack(argCount), argCount)) |err| {
                        return err;
                    }
                    frame = &self.frames[self.frameCount - 1];
                    constants = frame.closure.function.chunk.data.items;
                    code = frame.closure.function.chunk.code.items.ptr;
                    ip = frame.ip;
                },
                OpCode.OP_DEFINE_GLOBAL, OpCode.OP_DEFINE_GLOBAL_LONG => {
                    const identifier = if (instruction == .OP_DEFINE_GLOBAL)
                        self.readConstant(&ip, constants)
                    else
                        self.readLongConstant(&ip, constants);
                    try self.globals.put(identifier.string, self.stack.pop().?);
                },
                OpCode.OP_GET_GLOBAL, OpCode.OP_GET_GLOBAL_LONG => {
                    const identfier = if (instruction == .OP_GET_GLOBAL)
                        self.readConstant(&ip, constants)
                    else
                        self.readLongConstant(&ip, constants);
                    const v = self.globals.get(identfier.string);

                    if (v == null) {
                        return .{ .undefined_variable = identfier.string.chars };
                    } else {
                        try self.stack.append(v.?);
                    }
                },
                OpCode.OP_SET_GLOBAL, OpCode.OP_SET_GLOBAL_LONG => {
                    const identifier = if (instruction == .OP_SET_GLOBAL)
                        self.readConstant(&ip, constants)
                    else
                        self.readLongConstant(&ip, constants);
                    const name = identifier.string;
                    if (self.globals.contains(name)) {
                        try self.globals.put(name, self.peekStack(0));
                    } else {
                        return .{ .undefined_variable = name.chars };
                    }
                },
                OpCode.OP_GET_LOCAL => {
                    const slot = self.readMedium(&ip);
                    try self.stack.append(self.stack.values[frame.slots + slot]);
                },
                OpCode.OP_SET_LOCAL => {
                    const slot = self.readMedium(&ip);
                    self.stack.values[frame.slots + slot] = self.peekStack(0);
                },
                OpCode.OP_JUMP_IF_FALSE => {
                    const offset = self.readShort(&ip);
                    if (isFalsey(self.peekStack(0))) {
                        ip += offset;
                    }
                },
                OpCode.OP_JUMP => {
                    const offset = self.readShort(&ip);
                    ip += offset;
                },
                OpCode.OP_LOOP => {
                    const offset = self.readShort(&ip);
                    ip -= offset;
                },
                OpCode.ILLEGAL => {
                    return .{ .illegal_opcode = instruction_byte };
                },
            }
        }
    }

    inline fn closeUpvalues(self: *VM, last: *Value) void {
        while (self.openUpvalues != null and @intFromPtr(self.openUpvalues.?.location) >= @intFromPtr(last)) {
            const upvalue = self.openUpvalues.?;
            upvalue.closed = upvalue.location.*;
            upvalue.location = &upvalue.closed;
            self.openUpvalues = upvalue.next;
        }
    }

    inline fn captureUpvalue(self: *VM, local: *Value) !*ObjUpvalue {
        var prevUpvalue: ?*ObjUpvalue = null;
        var upvalue = self.openUpvalues;

        while (upvalue != null and @intFromPtr(upvalue.?.location) > @intFromPtr(local)) {
            prevUpvalue = upvalue;
            upvalue = upvalue.?.next;
        }

        if (upvalue != null and upvalue.?.location == local) {
            return upvalue.?;
        }

        const createdUpvalue = try self.heap.createUpvalue(local);

        if (prevUpvalue == null) {
            self.openUpvalues = createdUpvalue;
        } else {
            prevUpvalue.?.next = createdUpvalue;
        }

        return createdUpvalue;
    }

    inline fn readByte(_: *VM, ip: *[*]u8) u8 {
        const b = ip.*[0];
        ip.* += 1;
        return b;
    }

    inline fn readShort(_: *VM, ip: *[*]u8) u16 {
        const high = ip.*[0];
        const low = ip.*[1];
        ip.* += 2;
        return (@as(u16, high) << 8) | low;
    }

    inline fn readMedium(_: *VM, ip: *[*]u8) u24 {
        const high = ip.*[0];
        const mid = ip.*[1];
        const low = ip.*[2];
        ip.* += 3;
        return (@as(u24, high) << 16) | (@as(u24, mid) << 8) | low;
    }

    inline fn readConstant(self: *VM, ip: *[*]u8, constants: []Value) Value {
        const pos = self.readByte(ip);
        return constants[pos];
    }

    inline fn readLongConstant(self: *VM, ip: *[*]u8, constants: []Value) Value {
        const pos = self.readMedium(ip);
        return constants[pos];
    }

    inline fn binaryOp(self: *VM, comptime op: BinaryOperator) !?RuntimeFault {
        if (op == BinaryOperator.PLUS) {
            if (self.checkStringOperands()) {
                try self.concatenate();
            } else if (self.checkNumberOperands()) {
                const result = value.numberValue(self.stack.pop().?.number + self.stack.pop().?.number);
                try self.stack.append(result);
            } else {
                return .operands_must_be_numbers_or_strings;
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
            try self.stack.append(result);
        } else {
            return .operands_must_be_numbers;
        }

        return null;
    }

    inline fn concatenate(self: *VM) !void {
        const b = self.stack.pop().?.string.chars;
        const a = self.stack.pop().?.string.chars;

        const chars = try std.mem.concat(self.allocator, u8, &[_][]const u8{ a, b });
        const v: Value = .{ .string = try self.heap.takeString(chars) };

        try self.stack.append(v);
    }

    fn valuesEqual(_: *VM, a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
            return false;
        }

        return switch (a) {
            .number => a.number == b.number,
            .bool => a.bool == b.bool,
            .nil => true,
            .string => |s| std.mem.eql(u8, s.chars, b.string.chars),
            .function => |f| f == b.function,
            .native => |n| n == b.native,
            .closure => |c| c == b.closure,
        };
    }

    inline fn callValue(self: *VM, callee: Value, argCount: u8) !?RuntimeFault {
        switch (callee) {
            .closure => |closure| {
                if (argCount != closure.function.arity) {
                    return .{ .expected_arguments = .{
                        .expected = closure.function.arity,
                        .actual = argCount,
                    } };
                }
                return try self.call(closure, argCount);
            },
            .native => |native| {
                if (argCount != native.arity) {
                    return .{ .expected_arguments = .{
                        .expected = native.arity,
                        .actual = argCount,
                    } };
                }
                const firstArgumentOnStackOffset = self.stack.len - argCount;
                const result = try native.function(self, argCount, self.stack.values[firstArgumentOnStackOffset..self.stack.len]);
                self.stack.shrinkRetainingCapacity(firstArgumentOnStackOffset - 1);
                try self.stack.append(result);
                return null;
            },
            else => return .not_callable,
        }
    }

    fn call(self: *VM, closure: *ObjClosure, argCount: u8) !?RuntimeFault {
        if (self.frameCount == FRAMES_MAX) {
            return .stack_overflow;
        }

        var frame = &self.frames[self.frameCount];
        self.frameCount += 1;
        frame.closure = closure;
        frame.ip = closure.function.chunk.code.items.ptr;
        frame.slots = self.stack.len - argCount - 1;
        return null;
    }

    fn defineNative(self: *VM, name: []const u8, arity: u8, native: value.NativeFn) !void {
        try self.stack.append(.{ .string = try self.heap.copyString(name) });
        try self.stack.append(.{ .native = try self.heap.createNative(arity, native) });
        try self.globals.put(self.stack.values[0].string, self.stack.values[1]);
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
        return self.stack.values[self.stack.len - 1 - i];
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

    fn runtimeError(self: *VM, runtimeFault: RuntimeFault) void {
        const frame = &self.frames[self.frameCount - 1];
        const instruction = @intFromPtr(frame.ip) - @intFromPtr(frame.closure.function.chunk.code.items.ptr) - 1;
        const line = frame.closure.function.chunk.getLine(instruction);

        std.debug.print("[vm] runtime error | line {d} | ", .{line});
        std.debug.print("{f}\n", .{runtimeFault});

        for (1..self.frameCount + 1) |incIndex| {
            const i = self.frameCount - incIndex;
            const nextFrame = &self.frames[i];
            const func = nextFrame.closure.function;
            const index = @intFromPtr(nextFrame.ip) - @intFromPtr(func.chunk.code.items.ptr) - 1;
            std.debug.print("[vm] runtime error | line {d} | ", .{func.chunk.getLine(index)});
            std.debug.print("{s}()\n", .{func.name.chars});
        }

        self.resetStack();
    }
};

pub fn readLineNative(vm: *VM, _: usize, _: []const Value) !Value {
    return .{ .string = try vm.heap.copyString("hello world") };
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
        .string => |s| s,
        .function => try vm.heap.copyString("function"),
        .native => try vm.heap.copyString("native"),
        .closure => try vm.heap.copyString("function"),
    };

    return .{ .string = str };
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
        const frame = self.vm.frames[self.vm.frameCount - 1];
        const line = frame.closure.function.chunk.getLine(self.offset);
        var instruction_buffer: [256]u8 = undefined;
        var instruction_writer: std.Io.Writer = .fixed(&instruction_buffer);
        try instruction_writer.print("{f}", .{frame.closure.function.chunk.formatInstruction(self.offset, false)});

        try writer.print("[vm] {d:0>4} line {d: >4} | {s: <32} | stack [", .{
            self.offset,
            line,
            instruction_writer.buffered(),
        });

        const stack = self.vm.stack.values[0..self.vm.stack.len];
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

        const byte = frame.closure.function.chunk.code.items[self.offset];
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

test "object equality compares strings by content and callables by identity" {
    var vm = try VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();

    var a = value.ObjStr{ .chars = "same" };
    var b = value.ObjStr{ .chars = "same" };
    try std.testing.expect(vm.valuesEqual(.{ .string = &a }, .{ .string = &b }));
    b.chars = "different";
    try std.testing.expect(!vm.valuesEqual(.{ .string = &a }, .{ .string = &b }));

    const name = try vm.heap.copyString("test");
    const function = try vm.heap.createFunction(name);
    const otherFunction = try vm.heap.createFunction(name);
    const closure = try vm.heap.createClosure(function);
    const otherClosure = try vm.heap.createClosure(function);
    const native = try vm.heap.createNative(0, readLineNative);
    const otherNative = try vm.heap.createNative(0, readLineNative);
    try std.testing.expect(vm.valuesEqual(.{ .function = function }, .{ .function = function }));
    try std.testing.expect(!vm.valuesEqual(.{ .function = function }, .{ .function = otherFunction }));
    try std.testing.expect(vm.valuesEqual(.{ .closure = closure }, .{ .closure = closure }));
    try std.testing.expect(!vm.valuesEqual(.{ .closure = closure }, .{ .closure = otherClosure }));
    try std.testing.expect(vm.valuesEqual(.{ .native = native }, .{ .native = native }));
    try std.testing.expect(!vm.valuesEqual(.{ .native = native }, .{ .native = otherNative }));
    try std.testing.expect(!vm.valuesEqual(.{ .closure = closure }, .{ .function = function }));
    try std.testing.expect(!vm.valuesEqual(.{ .string = &a }, .nil));
}

test "stack overflow is a runtime fault and resets the VM" {
    var vm = try VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();

    const name = try vm.heap.copyString("overflow");
    const function = try vm.heap.createFunction(name);
    try function.chunk.writeChunk(@intFromEnum(OpCode.OP_NIL), 7);
    try std.testing.expectEqual(@as(?RuntimeFault, null), try vm.startScript(function));
    while (vm.stack.len < STACK_MAX) {
        try vm.stack.append(value.nilValue());
    }

    try std.testing.expectEqual(InterpretResult.RUNTIME_ERROR, try vm.run());
    try std.testing.expectEqual(@as(usize, 0), vm.stack.len);
    try std.testing.expectEqual(@as(usize, 0), vm.frameCount);
}

test "execution trace labels instruction and pre-execution stack" {
    const function = try ObjFunction.create(std.testing.allocator);
    defer function.destroy(std.testing.allocator);

    try function.chunk.writeChunk(@intFromEnum(OpCode.OP_ADD), 4);

    var vm = try VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();
    const closure = try vm.heap.createClosure(function);
    vm.appendFrame(function);
    vm.frames[vm.frameCount - 1].closure = closure;
    try vm.stack.append(value.numberValue(1));
    try vm.stack.append(value.numberValue(2));

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

    var vm = try VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();
    const closure = try vm.heap.createClosure(function);
    vm.appendFrame(function);
    vm.frames[vm.frameCount - 1].closure = closure;
    try vm.stack.append(value.boolValue(false));

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
        .string, .function, .native, .closure => false,
    };
}

inline fn isFalsey(v: Value) bool {
    return switch (v) {
        .bool => !v.bool,
        .number => false,
        .nil => true,
        .string, .function, .native, .closure => true,
    };
}
