const std = @import("std");
const config = @import("config");
const chunk_mod = @import("chunk.zig");
const Heap = @import("heap.zig").Heap;
const value = @import("value.zig");
const Chunk = chunk_mod.Chunk;
const OpCode = chunk_mod.OpCode;
const Value = value.Value;
const HashMap = value.HashMap;
const ObjStr = value.ObjStr;
const ObjFunction = value.ObjFunction;
const ObjClosure = value.ObjClosure;
const ObjUpvalue = value.ObjUpvalue;
const ObjArray = value.ObjArray;
const ObjClass = value.ObjClass;

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
    super_class_must_be_class,
    native_error,
    undefined_variable: []const u8,
    expected_arguments: struct {
        expected: usize,
        actual: u8,
    },
    stack_overflow,
    not_callable,
    not_assignable,
    not_an_object,
    unknown_property: struct { name: []const u8 },
    illegal_opcode: u8,

    pub fn format(self: RuntimeFault, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .operand_must_be_number => try writer.writeAll("Operand must be a number."),
            .operands_must_be_numbers => try writer.writeAll("Operands must be numbers."),
            .operands_must_be_numbers_or_strings => try writer.writeAll("Operands must be two numbers or two strings."),
            .super_class_must_be_class => try writer.writeAll("Superclass must be a class."),
            .undefined_variable => |name| try writer.print("Undefined variable '{s}'", .{name}),
            .expected_arguments => |arguments| try writer.print(
                "Expected {d} arguments but got {d}",
                .{ arguments.expected, arguments.actual },
            ),
            .stack_overflow => try writer.writeAll("Stack overflow"),
            .not_callable => try writer.writeAll("Can only call functions."),
            .illegal_opcode => |opcode| try writer.print("Unknown opcode 0x{x:0>2}.", .{opcode}),
            .not_assignable => try writer.writeAll("Can only assign to class instances."),
            .unknown_property => |e| try writer.print("Unknown property '{s}'", .{e.name}),
            .native_error => try writer.writeAll("Error in native method."),
            .not_an_object => try writer.writeAll("Can only get properties of an object"),
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
    try std.testing.expectEqual(@as(f64, 42), value.asNumber(captured.*));

    stack.shrinkRetainingCapacity(1);
    try std.testing.expectEqual(@as(f64, 42), value.asNumber(stack.pop().?));
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
    globals: HashMap,
    frames: [FRAMES_MAX]CallFrame = undefined,
    frameCount: usize,
    openUpvalues: ?*ObjUpvalue = null,
    initString: *ObjStr = undefined,
    /// The class of every `.array` value, see `getClass`. Its methods are natives.
    arrayClass: *ObjClass = undefined,
    stdoutIsTty: bool = true,
    stdoutBuffer: [4096]u8 = undefined,
    stdoutWriter: std.Io.File.Writer = undefined,
    stdinBuffer: [4096]u8 = undefined,
    /// Created on the first `readLine()` call. It must outlive a single call,
    /// because the reader may buffer more than one line at a time.
    stdinReader: ?std.Io.File.Reader = null,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) !VM {
        var vm = VM{
            .io = io,
            .allocator = allocator,
            .stack = .{},
            .heap = try Heap.init(allocator),
            .globals = HashMap.init(allocator),
            .frameCount = 0,
        };
        errdefer vm.deinit();

        vm.initString = try vm.heap.copyString("init");
        // Build the array class before enabling the GC, so we don't have to keep
        // the half-built class and its method names rooted on the stack.
        vm.arrayClass = try vm.heap.createClass(try vm.heap.copyString("Array"));
        try vm.defineNativeMethod(vm.arrayClass, "push", 1, arrayPushNative);
        try vm.defineNativeMethod(vm.arrayClass, "pop", 0, arrayPopNative);
        try vm.defineNativeMethod(vm.arrayClass, "len", 0, arrayLenNative);
        try vm.defineNativeMethod(vm.arrayClass, "get", 1, arrayGetNative);
        try vm.defineNativeMethod(vm.arrayClass, "set", 2, arraySetNative);
        try vm.defineNativeMethod(vm.arrayClass, "join", 1, arrayJoinNative);
        vm.heap.garbageCollectionEnabled = true;

        try vm.defineNative("clock", 0, clockNative);
        try vm.defineNative("random", 0, randomNative);
        try vm.defineNative("sqrt", 1, sqrtNative);
        try vm.defineNative("floor", 1, floorNative);
        try vm.defineNative("str", 1, strNative);
        try vm.defineNative("readLine", 0, readLineNative);
        try vm.defineNative("writeFile", 2, writeFileNative);
        try vm.defineNative("appendFile", 2, appendFileNative);

        return vm;
    }

    pub fn deinit(self: *VM) void {
        self.globals.deinit();
        self.heap.deinit();
    }

    pub fn resetStack(self: *VM) void {
        self.closeUpvalues(&self.stack.values[0]);
        self.stack.clearRetainingCapacity();
        self.frameCount = 0;
    }

    pub fn pushRoot(self: *VM, root: Value) !void {
        try self.stack.append(root);
    }

    pub fn popRoot(self: *VM) void {
        _ = self.stack.pop();
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
        try self.stack.append(value.functionValue(function));
        errdefer _ = self.stack.pop();

        const closure = try self.heap.createClosure(function);
        self.stack.values[self.stack.len - 1] = value.closureValue(closure);
        return self.call(closure, 0);
    }

    pub fn run(self: *VM) !InterpretResult {
        self.stdoutWriter = std.Io.File.stdout().writerStreaming(self.io, &self.stdoutBuffer);
        self.stdoutIsTty = try std.Io.File.stdout().isTty(self.io);
        defer self.stdoutWriter.flush() catch {};

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
        // High operand bytes collected by OP_EXTRA_ARG prefixes. `readOperand` folds
        // them into the next operand and resets this to 0. A local (rather than a VM
        // field) so it can live in a register; a prefix and its opcode always run
        // back-to-back in the same frame, so it never has to survive a call.
        var extra: u32 = 0;

        if (comptime DEBUG_VM) {
            std.debug.print("== VM execution ==\n", .{});
        }

        var instruction_count: usize = 0;
        while (true) {
            const instruction_offset = @intFromPtr(ip) - @intFromPtr(code);
            // Only trace at an instruction start. The compiler's encoding is minimal (the
            // first prefix byte is never 0), so `extra != 0` means we're in the middle
            // of a wide instruction that has already been traced as one folded line.
            if (comptime DEBUG_VM) if (extra == 0) {
                if (instruction_count < DEBUG_INSTRUCTION_LIMIT) {
                    std.debug.print("{f}", .{ExecutionTrace{ .vm = self, .offset = instruction_offset }});
                } else if (instruction_count == DEBUG_INSTRUCTION_LIMIT) {
                    std.debug.print(
                        "[vm] trace limit reached | suppressing instructions after {d}\n",
                        .{DEBUG_INSTRUCTION_LIMIT},
                    );
                }
            };
            instruction_count += 1;

            const instruction_byte = self.readByte(&ip);
            const instruction: OpCode = std.enums.fromInt(OpCode, instruction_byte) orelse OpCode.ILLEGAL;
            switch (instruction) {
                OpCode.OP_EXTRA_ARG => {
                    extra = (extra << 8) | self.readByte(&ip);
                },
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
                    const constant = self.readConstant(&ip, &extra, constants);
                    try self.stack.append(constant);
                },
                OpCode.OP_NOT => {
                    try self.stack.append(value.boolValue(isFalsey(self.stack.pop().?)));
                },
                OpCode.OP_NEGATE => {
                    const v = self.stack.getLast();
                    if (!value.isNumber(v)) {
                        return .operand_must_be_number;
                    }
                    self.stack.values[self.stack.len - 1] = value.numberValue(-value.asNumber(v));
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
                    var n = self.readOperand(&ip, &extra);
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
                OpCode.OP_CLOSURE => {
                    const functionValue = self.readConstant(&ip, &extra, constants);
                    const f = value.asFunction(functionValue);
                    const c = try self.heap.createClosure(f);
                    try self.stack.append(value.closureValue(c));

                    var initialized = false;
                    defer {
                        if (!initialized) _ = self.stack.pop();
                    }

                    for (f.upvalues, 0..) |desc, i| {
                        const upvalue = if (desc.isLocal)
                            try self.captureUpvalue(&self.stack.values[frame.slots + desc.index])
                        else
                            frame.closure.upvalues[desc.index];
                        c.setUpvalue(i, upvalue);
                    }
                    initialized = true;
                },
                OpCode.OP_GET_UPVALUE => {
                    const slot = self.readOperand(&ip, &extra);
                    try self.stack.append(frame.closure.upvalues[slot].location.*);
                },
                OpCode.OP_SET_UPVALUE => {
                    const slot = self.readOperand(&ip, &extra);
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
                OpCode.OP_INVOKE => {
                    const name = self.readConstant(&ip, &extra, constants);
                    const argCount = self.readByte(&ip);

                    // Safe the caller's ip address.
                    frame.ip = ip;

                    if (try self.invoke(value.asString(name), argCount)) |err| {
                        return err;
                    }
                    frame = &self.frames[self.frameCount - 1];
                    constants = frame.closure.function.chunk.data.items;
                    code = frame.closure.function.chunk.code.items.ptr;
                    ip = frame.ip;
                },
                OpCode.OP_SUPER_INVOKE => {
                    const name = value.asString(self.readConstant(&ip, &extra, constants));
                    const argCount = self.readByte(&ip);
                    const super = value.asClass(self.stack.pop().?);

                    frame.ip = ip;

                    if (try self.invokeFromClass(super, name, argCount)) |err| {
                        return err;
                    }
                    frame = &self.frames[self.frameCount - 1];
                    constants = frame.closure.function.chunk.data.items;
                    code = frame.closure.function.chunk.code.items.ptr;
                    ip = frame.ip;
                },
                OpCode.OP_CLASS => {
                    const name = self.readConstant(&ip, &extra, constants);

                    try self.stack.append(value.classValue(try self.heap.createClass(value.asString(name))));
                },
                OpCode.OP_INHERIT => {
                    const superClass = self.peekStack(1);
                    const class = value.asClass(self.peekStack(0));

                    if (!value.isClass(superClass)) {
                        return .super_class_must_be_class;
                    }

                    var it = value.asClass(superClass).methods.iterator();
                    while (it.next()) |entry| {
                        try class.methods.put(entry.key_ptr.*, entry.value_ptr.*);
                    }
                    // Subclass. Keep the super on the stack, it is a local or upvalue referenced by children scopes.
                    _ = self.stack.pop();
                },
                OpCode.OP_METHOD => {
                    const name = self.readConstant(&ip, &extra, constants);

                    try self.defineMethod(value.asString(name));
                },
                OpCode.OP_GET_SUPER => {
                    const name = value.asString(self.readConstant(&ip, &extra, constants));
                    const super = value.asClass(self.stack.pop().?);

                    if (try self.bindMethod(super, name)) |err| {
                        return err;
                    }
                },
                OpCode.OP_GET_PROPERTY => {
                    const name = self.readConstant(&ip, &extra, constants);

                    // Leave the receiver on the stack: bindMethod needs it and
                    // replaces it with the bound method itself.
                    const v = self.peekStack(0);
                    if (value.isInstance(v)) {
                        if (value.asInstance(v).fields.get(value.asString(name))) |val| {
                            _ = self.stack.pop();
                            try self.stack.append(val);
                            continue;
                        }
                    }
                    if (self.getClass(v)) |class| {
                        if (try self.bindMethod(class, value.asString(name))) |err| {
                            return err;
                        }
                    } else {
                        return .not_an_object;
                    }
                },
                OpCode.OP_SET_PROPERTY => {
                    const name = self.readConstant(&ip, &extra, constants);

                    const v = self.stack.pop().?;
                    const instance = self.stack.pop().?;
                    if (value.isInstance(instance)) {
                        try value.asInstance(instance).fields.put(value.asString(name), v);
                        try self.stack.append(v);
                    } else {
                        return .not_assignable;
                    }
                },
                OpCode.OP_DEFINE_GLOBAL => {
                    const identifier = self.readConstant(&ip, &extra, constants);
                    try self.globals.put(value.asString(identifier), self.stack.pop().?);
                },
                OpCode.OP_GET_GLOBAL => {
                    const identfier = self.readConstant(&ip, &extra, constants);
                    const v = self.globals.get(value.asString(identfier));

                    if (v == null) {
                        return .{ .undefined_variable = value.asString(identfier).chars };
                    } else {
                        try self.stack.append(v.?);
                    }
                },
                OpCode.OP_SET_GLOBAL => {
                    const identifier = self.readConstant(&ip, &extra, constants);
                    const name = value.asString(identifier);
                    if (self.globals.contains(name)) {
                        try self.globals.put(name, self.peekStack(0));
                    } else {
                        return .{ .undefined_variable = name.chars };
                    }
                },
                OpCode.OP_GET_LOCAL => {
                    const slot = self.readOperand(&ip, &extra);
                    try self.stack.append(self.stack.values[frame.slots + slot]);
                },
                OpCode.OP_SET_LOCAL => {
                    const slot = self.readOperand(&ip, &extra);
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
                OpCode.OP_ARRAY => {
                    const len = self.readOperand(&ip, &extra);
                    const array: *ObjArray = try self.heap.createArray(len);
                    const items = self.stack.values[self.stack.len - len .. self.stack.len];
                    try array.values.appendSlice(self.heap.allocator, items);

                    self.stack.shrinkRetainingCapacity(self.stack.len - len);
                    try self.stack.append(value.arrayValue(array));
                },
                OpCode.ILLEGAL => {
                    return .{ .illegal_opcode = instruction_byte };
                },
            }
        }
    }

    inline fn defineMethod(self: *VM, name: *ObjStr) !void {
        const method = self.peekStack(0);
        const class = value.asClass(self.peekStack(1));
        try class.methods.put(name, method);
        _ = self.stack.pop();
    }

    inline fn bindMethod(self: *VM, class: *ObjClass, name: *ObjStr) !?RuntimeFault {
        const method = class.methods.get(name) orelse return .{ .unknown_property = .{ .name = name.chars } };

        const bound = try self.heap.createBoundMethod(self.peekStack(0), method);
        _ = self.stack.pop();
        try self.stack.append(value.boundMethodValue(bound));

        return null;
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

    /// Read an instruction's one-byte operand and fold in the high bytes collected
    /// by any preceding OP_EXTRA_ARG prefixes. Resetting `extra` here is what makes
    /// prefixes belong only to the next operand-carrying instruction, so every case
    /// that takes a (prefixable) operand must go through this function.
    inline fn readOperand(self: *VM, ip: *[*]u8, extra: *u32) u32 {
        const operand = (extra.* << 8) | self.readByte(ip);
        extra.* = 0;
        return operand;
    }

    inline fn readConstant(self: *VM, ip: *[*]u8, extra: *u32, constants: []Value) Value {
        return constants[self.readOperand(ip, extra)];
    }

    inline fn binaryOp(self: *VM, comptime op: BinaryOperator) !?RuntimeFault {
        if (op == BinaryOperator.PLUS) {
            if (self.checkStringOperands()) {
                try self.concatenate();
            } else if (self.checkNumberOperands()) {
                const result = value.numberValue(value.asNumber(self.stack.pop().?) + value.asNumber(self.stack.pop().?));
                try self.stack.append(result);
            } else if (self.checkArrayOperands()) {
                try self.concatArrays();
            } else {
                return .operands_must_be_numbers_or_strings;
            }
        } else if (self.checkNumberOperands()) {
            // Safe to expect both entries to be numbers.
            const b = value.asNumber(self.stack.pop().?);
            const a = value.asNumber(self.stack.pop().?);

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
        const b = value.asString(self.peekStack(0)).chars;
        const a = value.asString(self.peekStack(1)).chars;

        // Perform a garbage collection run (if needed) before we allocate the new string buffer.
        try self.heap.checkAndCollect();

        const chars = try std.mem.concat(self.heap.allocator, u8, &[_][]const u8{ a, b });
        const v: Value = value.stringValue(try self.heap.takeString(chars));

        _ = self.stack.pop();
        _ = self.stack.pop();

        try self.stack.append(v);
    }

    inline fn concatArrays(self: *VM) !void {
        const b = value.asArray(self.peekStack(0));
        const a = value.asArray(self.peekStack(1));

        try self.heap.checkAndCollect();

        const combined = try self.heap.createArray(a.values.items.len + b.values.items.len);

        try combined.values.appendSlice(self.heap.allocator, a.values.items);
        try combined.values.appendSlice(self.heap.allocator, b.values.items);

        _ = self.stack.pop();
        _ = self.stack.pop();

        try self.stack.append(value.arrayValue(combined));
    }

    fn valuesEqual(self: *VM, a: Value, b: Value) bool {
        if (value.isNumber(a) and value.isNumber(b)) return value.asNumber(a) == value.asNumber(b);
        if (value.isBool(a) and value.isBool(b)) return value.asBool(a) == value.asBool(b);
        if (value.isNil(a) and value.isNil(b)) return true;
        if (value.isString(a) and value.isString(b)) {
            return std.mem.eql(u8, value.asStr(a), value.asStr(b));
        }
        if (value.isArray(a) and value.isArray(b)) {
            const arrayA = value.asArray(a);
            const arrayB = value.asArray(b);
            if (arrayA.values.items.len != arrayB.values.items.len) return false;
            if (arrayA == arrayB) return true;
            for (arrayA.values.items, arrayB.values.items) |itemA, itemB| {
                if (!self.valuesEqual(itemA, itemB)) return false;
            }
            return true;
        }
        // All other objects (functions, classes, instances, ...) compare by identity.
        if (value.isObj(a) and value.isObj(b)) return value.asObj(a) == value.asObj(b);
        return false;
    }

    inline fn invoke(self: *VM, name: *ObjStr, argCount: u8) !?RuntimeFault {
        const receiver = self.peekStack(argCount);

        // A field shadows a method of the same name. Only instances have fields.
        if (value.isInstance(receiver)) {
            if (value.asInstance(receiver).fields.get(name)) |f| {
                self.stack.values[self.stack.len - argCount - 1] = f;
                return try self.callValue(f, argCount);
            }
        }

        const class = self.getClass(receiver) orelse return .not_callable;
        return self.invokeFromClass(class, name, argCount);
    }

    /// Every value that can have methods has a class. Instances carry a pointer to
    /// theirs; built-in types like arrays share a class owned by the VM.
    inline fn getClass(self: *VM, v: Value) ?*ObjClass {
        if (value.isInstance(v)) return value.asInstance(v).class;
        if (value.isArray(v)) return self.arrayClass;
        return null;
    }

    inline fn invokeFromClass(self: *VM, receiver: *ObjClass, name: *ObjStr, argCount: u8) !?RuntimeFault {
        if (receiver.methods.get(name)) |m| {
            return try self.callMethod(m, argCount);
        } else {
            return .{ .unknown_property = .{ .name = name.chars } };
        }
    }

    inline fn callValue(self: *VM, callee: Value, argCount: u8) !?RuntimeFault {
        if (value.isClass(callee)) {
            const class = value.asClass(callee);
            // The class sits below the arguments; replace it with the new
            // instance so it becomes slot 0 of the callee's frame.
            const instance = try self.heap.createInstance(class);
            self.stack.values[self.stack.len - argCount - 1] = value.instanceValue(instance);
            if (class.methods.get(self.initString)) |initMethod| {
                return try self.callMethod(initMethod, argCount);
            } else if (argCount != 0) {
                return .{ .expected_arguments = .{ .expected = 0, .actual = argCount } };
            }
            return null;
        }
        if (value.isBoundMethod(callee)) {
            const bound = value.asBoundMethod(callee);
            // Slot 0 holds `this`, so overwrite the bound method with its receiver.
            self.stack.values[self.stack.len - argCount - 1] = bound.receiver;
            return try self.callMethod(bound.method, argCount);
        }
        if (value.isClosure(callee)) return try self.callClosure(value.asClosure(callee), argCount);
        if (value.isNative(callee)) return try self.callNative(value.asNative(callee), argCount);
        return .not_callable;
    }

    /// Calls a method from `ObjClass.methods`. The receiver must already be in slot 0.
    inline fn callMethod(self: *VM, method: Value, argCount: u8) !?RuntimeFault {
        if (value.isClosure(method)) return try self.callClosure(value.asClosure(method), argCount);
        if (value.isNative(method)) return try self.callNative(value.asNative(method), argCount);
        unreachable; // classes only hold closures and natives
    }

    inline fn callClosure(self: *VM, closure: *ObjClosure, argCount: u8) !?RuntimeFault {
        if (argCount != closure.function.arity) {
            return .{ .expected_arguments = .{
                .expected = closure.function.arity,
                .actual = argCount,
            } };
        }
        return try self.call(closure, argCount);
    }

    inline fn callNative(self: *VM, native: *value.ObjNative, argCount: u8) !?RuntimeFault {
        if (argCount != native.arity) {
            return .{ .expected_arguments = .{
                .expected = native.arity,
                .actual = argCount,
            } };
        }
        // Like a closure's frame, the native sees slot 0 (the receiver or the
        // native itself) followed by the arguments.
        const slot0 = self.stack.len - argCount - 1;
        const result = native.function(self, argCount, self.stack.values[slot0..self.stack.len]) catch {
            return .native_error;
        };
        self.stack.shrinkRetainingCapacity(slot0);
        try self.stack.append(result);
        return null;
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

    fn defineNativeMethod(self: *VM, class: *ObjClass, name: []const u8, arity: u8, native: value.NativeFn) !void {
        const method = try self.heap.createNative(arity, native);
        try class.methods.put(try self.heap.copyString(name), value.nativeValue(method));
    }

    fn defineNative(self: *VM, name: []const u8, arity: u8, native: value.NativeFn) !void {
        try self.stack.append(value.stringValue(try self.heap.copyString(name)));
        try self.stack.append(value.nativeValue(try self.heap.createNative(arity, native)));
        try self.globals.put(value.asString(self.stack.values[0]), self.stack.values[1]);
        _ = self.stack.pop();
        _ = self.stack.pop();
    }

    fn checkStringOperands(self: *VM) bool {
        return value.isString(self.peekStack(0)) and value.isString(self.peekStack(1));
    }

    fn checkNumberOperands(self: *VM) bool {
        return value.isNumber(self.peekStack(0)) and value.isNumber(self.peekStack(1));
    }

    fn checkArrayOperands(self: *VM) bool {
        return value.isArray(self.peekStack(0)) and value.isArray(self.peekStack(1));
    }

    fn peekStack(self: *VM, i: usize) Value {
        return self.stack.values[self.stack.len - 1 - i];
    }

    fn printProgramValue(self: *VM, v: Value) !void {
        const stdout = &self.stdoutWriter.interface;
        try value.write(v, stdout);
        try stdout.writeByte('\n');
        if (self.stdoutIsTty) try stdout.flush();
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
        self.stdoutWriter.flush() catch {};

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
    // Make sure a prompt printed with `print` is visible before we block.
    try vm.stdoutWriter.flush();

    if (vm.stdinReader == null) {
        vm.stdinReader = std.Io.File.stdin().readerStreaming(vm.io, &vm.stdinBuffer);
    }
    return readLineFrom(vm, &vm.stdinReader.?.interface);
}

/// Returns the next line without its line ending, or `nil` at end of input.
fn readLineFrom(vm: *VM, reader: *std.Io.Reader) !Value {
    const line = try reader.takeDelimiter('\n') orelse return value.nilValue();
    // The slice points into the reader's buffer, so the string must copy it.
    return value.stringValue(try vm.heap.copyString(std.mem.trimEnd(u8, line, "\r")));
}

pub fn writeFileNative(vm: *VM, argCount: usize, args: []const Value) !Value {
    if (argCount != 2) {
        return Errors.RuntimeError;
    }
    if (!value.isString(args[1]) or !value.isString(args[2])) {
        return Errors.RuntimeError;
    }

    try std.Io.Dir.cwd().writeFile(vm.io, .{
        .sub_path = value.asString(args[1]).chars,
        .data = value.asString(args[2]).chars,
    });

    return value.nilValue();
}

pub fn appendFileNative(vm: *VM, argCount: usize, args: []const Value) !Value {
    if (argCount != 2) {
        return Errors.RuntimeError;
    }
    if (!value.isString(args[1]) or !value.isString(args[2])) {
        return Errors.RuntimeError;
    }

    // std.Io has no append mode, so open without truncating and write at the end.
    const file = try std.Io.Dir.cwd().createFile(vm.io, value.asString(args[1]).chars, .{ .truncate = false });
    defer file.close(vm.io);
    try file.writePositionalAll(vm.io, value.asString(args[2]).chars, try file.length(vm.io));

    return value.nilValue();
}

pub fn strNative(vm: *VM, argCount: usize, args: []const Value) !Value {
    if (argCount != 1) {
        return Errors.RuntimeError;
    }
    const v = args[1];
    const str = if (value.isBool(v))
        try vm.heap.copyString(if (value.asBool(v)) "true" else "false")
    else if (value.isNumber(v))
        try vm.heap.takeString(try std.fmt.allocPrint(vm.heap.allocator, "{d}", .{value.asNumber(v)}))
    else if (value.isNil(v))
        try vm.heap.copyString("nil")
    else switch (value.asObj(v).kind) {
        .str => value.asString(v),
        .function, .closure, .bound_method => try vm.heap.copyString("function"),
        .native => try vm.heap.copyString("native"),
        .array => try vm.heap.copyString("array"),
        .class => try vm.heap.copyString("class"),
        .instance => try vm.heap.copyString("instance"),
        .upvalue => unreachable, // upvalues are never stored in a Value
    };

    return value.stringValue(str);
}

pub fn sqrtNative(_: *VM, argCount: usize, args: []const Value) !Value {
    if (argCount != 1) {
        return Errors.RuntimeError;
    }
    if (!value.isNumber(args[1])) {
        return Errors.RuntimeError;
    }
    return value.numberValue(std.math.sqrt(value.asNumber(args[1])));
}

pub fn floorNative(_: *VM, argCount: usize, args: []const Value) !Value {
    if (argCount != 1) {
        return Errors.RuntimeError;
    }
    if (!value.isNumber(args[1])) {
        return Errors.RuntimeError;
    }
    return value.numberValue(@floor(value.asNumber(args[1])));
}

// Array methods. `args[0]` is the receiver: `getClass` only dispatches to these
// for `.array` values, so it is always an array.

pub fn arrayPushNative(vm: *VM, _: usize, args: []const Value) !Value {
    try value.asArray(args[0]).values.append(vm.heap.allocator, args[1]);
    return value.nilValue();
}

pub fn arrayPopNative(_: *VM, _: usize, args: []const Value) !Value {
    return value.asArray(args[0]).values.pop() orelse Errors.RuntimeError;
}

pub fn arrayLenNative(_: *VM, _: usize, args: []const Value) !Value {
    return value.numberValue(@floatFromInt(value.asArray(args[0]).values.items.len));
}

pub fn arrayGetNative(_: *VM, _: usize, args: []const Value) !Value {
    const items = value.asArray(args[0]).values.items;
    return items[try arrayIndex(items.len, args[1])];
}

pub fn arraySetNative(_: *VM, _: usize, args: []const Value) !Value {
    const items = value.asArray(args[0]).values.items;
    items[try arrayIndex(items.len, args[1])] = args[2];
    return args[2];
}

/// Joins the items into a new string, with the separator `args[1]` between them.
/// Items are converted like `print` does, so strings are included as-is.
pub fn arrayJoinNative(vm: *VM, _: usize, args: []const Value) !Value {
    if (!value.isString(args[1])) return Errors.RuntimeError;
    const separator = value.asString(args[1]).chars;

    var out: std.Io.Writer.Allocating = .init(vm.heap.allocator);
    defer out.deinit();
    for (value.asArray(args[0]).values.items, 0..) |item, i| {
        if (i > 0) try out.writer.writeAll(separator);
        try value.write(item, &out.writer);
    }

    // `takeString` adopts the buffer, so `out.deinit()` has nothing left to free.
    return value.stringValue(try vm.heap.takeString(try out.toOwnedSlice()));
}

/// Indices must be whole numbers in `0..len`.
fn arrayIndex(len: usize, index: Value) !usize {
    if (!value.isNumber(index)) return Errors.RuntimeError;
    const n = value.asNumber(index);
    if (n < 0 or n != @floor(n) or n >= @as(f64, @floatFromInt(len))) return Errors.RuntimeError;
    return @intFromFloat(n);
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

        const op = frame.closure.function.chunk.decode(self.offset).op;
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
    try std.testing.expect(vm.valuesEqual(value.stringValue(&a), value.stringValue(&b)));
    b.chars = "different";
    try std.testing.expect(!vm.valuesEqual(value.stringValue(&a), value.stringValue(&b)));

    const name = try vm.heap.copyString("test");
    const function = try vm.heap.createFunction(name);
    const otherFunction = try vm.heap.createFunction(name);
    const closure = try vm.heap.createClosure(function);
    const otherClosure = try vm.heap.createClosure(function);
    const native = try vm.heap.createNative(0, readLineNative);
    const otherNative = try vm.heap.createNative(0, readLineNative);
    try std.testing.expect(vm.valuesEqual(value.functionValue(function), value.functionValue(function)));
    try std.testing.expect(!vm.valuesEqual(value.functionValue(function), value.functionValue(otherFunction)));
    try std.testing.expect(vm.valuesEqual(value.closureValue(closure), value.closureValue(closure)));
    try std.testing.expect(!vm.valuesEqual(value.closureValue(closure), value.closureValue(otherClosure)));
    try std.testing.expect(vm.valuesEqual(value.nativeValue(native), value.nativeValue(native)));
    try std.testing.expect(!vm.valuesEqual(value.nativeValue(native), value.nativeValue(otherNative)));
    try std.testing.expect(!vm.valuesEqual(value.closureValue(closure), value.functionValue(function)));
    try std.testing.expect(!vm.valuesEqual(value.stringValue(&a), value.nilValue()));
}

test "readLine returns lines without line endings and nil at end of input" {
    var vm = try VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();

    var reader: std.Io.Reader = .fixed("first\nsecond\r\nlast");
    try std.testing.expectEqualStrings("first", value.asString(try readLineFrom(&vm, &reader)).chars);
    try std.testing.expectEqualStrings("second", value.asString(try readLineFrom(&vm, &reader)).chars);
    try std.testing.expectEqualStrings("last", value.asString(try readLineFrom(&vm, &reader)).chars);
    try std.testing.expect(value.isNil(try readLineFrom(&vm, &reader)));
}

test "writeFile native requires a path and contents string" {
    var vm = try VM.init(std.testing.io, std.testing.allocator);
    defer vm.deinit();

    const contents = try vm.heap.copyString("contents");
    const args = [_]Value{
        value.nilValue(), // slot 0: the native itself, unused here
        value.numberValue(1),
        value.stringValue(contents),
    };

    try std.testing.expectError(error.RuntimeError, writeFileNative(&vm, args.len - 1, &args));
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

inline fn isFalsey(v: Value) bool {
    if (value.isBool(v)) return !value.asBool(v);
    if (value.isNil(v)) return true;
    // Empty arrays are falsey, all other numbers and objects are truthy.
    if (value.isArray(v)) return value.asArray(v).values.items.len == 0;
    return false;
}
