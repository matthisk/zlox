const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const ObjFunction = value_mod.ObjFunction;
const ObjStr = value_mod.ObjStr;

pub const OpCode = enum(u8) {
    OP_EXTRA_ARG,
    OP_METHOD,
    OP_GET_PROPERTY,
    OP_SET_PROPERTY,
    OP_CLASS,
    OP_INHERIT,
    OP_ARRAY,
    OP_RETURN,
    OP_TRUE,
    OP_FALSE,
    OP_NIL,
    OP_CONSTANT,
    OP_NEGATE,
    OP_NOT,
    OP_ADD,
    OP_SUBTRACT,
    OP_MULTIPLY,
    OP_DIVIDE,
    OP_EQUALS,
    OP_LESS,
    OP_GREATER,
    OP_PRINT,
    OP_CALL,
    OP_INVOKE,
    OP_SUPER_INVOKE,
    OP_CLOSURE,
    OP_POP,
    OP_POPN,
    OP_DEFINE_GLOBAL,
    OP_GET_SUPER,
    OP_GET_GLOBAL,
    OP_SET_GLOBAL,
    OP_GET_LOCAL,
    OP_SET_LOCAL,
    OP_GET_UPVALUE,
    OP_SET_UPVALUE,
    OP_CLOSE_UPVALUE,
    OP_JUMP_IF_FALSE,
    OP_JUMP,
    OP_LOOP,
    OP_DUP,
    ILLEGAL,
};

pub const ChunkErrors = error{OutOfConstantDataSlots};

pub const Chunk = struct {
    pub const InstructionFormatter = struct {
        chunk: *const Chunk,
        offset: usize,
        show_opcode_prefix: bool,

        pub fn format(self: InstructionFormatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            // `decode` folds any OP_EXTRA_ARG prefixes into the operand, so a wide
            // instruction is printed as a single line.
            const d = self.chunk.decode(self.offset);
            const code = self.chunk.code.items;
            const data = self.chunk.data.items;
            const tag_name = @tagName(d.op);
            const name = if (!self.show_opcode_prefix and std.mem.startsWith(u8, tag_name, "OP_"))
                tag_name["OP_".len..]
            else
                tag_name;

            switch (d.op) {
                .OP_POPN, .OP_CALL, .OP_ARRAY, .OP_GET_UPVALUE, .OP_SET_UPVALUE, .OP_GET_LOCAL, .OP_SET_LOCAL => {
                    try writer.print("{s} [{d}]", .{ name, d.operand });
                },
                .OP_CONSTANT, .OP_DEFINE_GLOBAL, .OP_GET_GLOBAL, .OP_SET_GLOBAL, .OP_CLASS, .OP_GET_PROPERTY, .OP_SET_PROPERTY, .OP_METHOD, .OP_GET_SUPER => {
                    try writer.print("{s} [{d}] {f}", .{ name, d.operand, value_mod.format(data[d.operand]) });
                },
                .OP_INVOKE, .OP_SUPER_INVOKE => {
                    const argCount = code[d.op_offset + 2];
                    try writer.print("{s} [{d}] {f} (args = {d})", .{ name, d.operand, value_mod.format(data[d.operand]), argCount });
                },
                .OP_CLOSURE => {
                    try writer.print("{s} [{d}] {f}", .{ name, d.operand, value_mod.format(data[d.operand]) });
                    // The upvalue descriptors live on the function object, not in the bytecode.
                    for (data[d.operand].as(ObjFunction).upvalues) |desc| {
                        try writer.print(" ~ upvalue {s} [{d}]", .{ if (desc.isLocal) "<local>" else "", desc.index });
                    }
                },
                .OP_JUMP_IF_FALSE, .OP_JUMP, .OP_LOOP => {
                    const high = code[d.op_offset + 1];
                    const low = code[d.op_offset + 2];
                    const distance = (@as(u16, high) << 8) | low;
                    const next = d.op_offset + 3;
                    const target = if (d.op == .OP_LOOP) next - distance else next + distance;
                    try writer.print("{s} -> {d:0>4}", .{ name, target });
                },
                .ILLEGAL => try writer.print("ILLEGAL 0x{x:0>2}", .{code[d.op_offset]}),
                // `decode` always skips past prefixes, so OP_EXTRA_ARG never shows up here.
                else => try writer.writeAll(name),
            }
        }
    };

    /// An instruction with its OP_EXTRA_ARG prefixes folded into the operand.
    pub const Decoded = struct {
        op: OpCode,
        /// Prefix bytes folded in; 0 for operand-less ops.
        operand: u32,
        /// Where the real opcode byte sits (after any prefixes).
        op_offset: usize,
    };

    /// Does `op` take a one-byte operand that OP_EXTRA_ARG prefixes can widen?
    /// Jumps are not listed: they have a fixed 2-byte operand.
    pub fn hasOperand(op: OpCode) bool {
        return switch (op) {
            .OP_CONSTANT, .OP_DEFINE_GLOBAL, .OP_GET_GLOBAL, .OP_SET_GLOBAL, .OP_CLASS, .OP_METHOD, .OP_GET_PROPERTY, .OP_SET_PROPERTY, .OP_INVOKE, .OP_SUPER_INVOKE, .OP_CLOSURE, .OP_POPN, .OP_ARRAY, .OP_CALL, .OP_GET_LOCAL, .OP_SET_LOCAL, .OP_GET_UPVALUE, .OP_SET_UPVALUE, .OP_GET_SUPER => true,
            else => false,
        };
    }

    allocator: std.mem.Allocator,
    code: std.ArrayList(u8) = undefined,
    data: std.ArrayList(Value) = undefined,
    lines: std.ArrayList(usize) = undefined,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return Chunk{
            .allocator = allocator,
            .code = std.ArrayList(u8).empty,
            .data = std.ArrayList(Value).empty,
            .lines = std.ArrayList(usize).empty,
        };
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.lines.deinit(self.allocator);
    }

    pub fn writeChunk(self: *Chunk, b: u8, l: usize) std.mem.Allocator.Error!void {
        try self.code.append(self.allocator, b);

        const currentLine = self.lines.items.len;
        if (currentLine == 0) {
            var missing_lines = l;
            while (missing_lines > 0) : (missing_lines -= 1) {
                try self.lines.append(self.allocator, self.code.items.len - 1);
            }
        } else if (l > currentLine) {
            var d = l - currentLine;

            // Empty lines don't receive bytecode so we need to make sure we fill the lines array for those lines.
            while (d > 1) {
                try self.lines.append(self.allocator, self.code.items.len - 1);
                d -= 1;
            }

            try self.lines.append(self.allocator, self.code.items.len - 1);
        }
    }

    pub fn getLine(self: *Chunk, i: usize) usize {
        var line: usize = 1;
        for (self.lines.items, 0..) |code_index, line_index| {
            if (code_index > i) break;
            line = line_index + 1;
        }
        return line;
    }

    pub fn addValue(self: *Chunk, v: Value) (std.mem.Allocator.Error || ChunkErrors)!u32 {
        try self.data.append(self.allocator, v);

        const index = self.data.items.len - 1;
        // We only have 2^32 data slots available in our VM (three OP_EXTRA_ARG prefixes).
        if (index > std.math.maxInt(u32)) {
            return ChunkErrors.OutOfConstantDataSlots;
        }

        return @intCast(index);
    }

    pub fn findValue(self: *Chunk, v: []const u8) ?u32 {
        for (self.data.items, 0..) |value, i| {
            if (value.is(ObjStr)) {
                const chars = value.as(ObjStr).chars;
                if (chars.ptr == v.ptr and chars.len == v.len) {
                    // Impossible to find a dataslot that doesn't fit a u32, as it cannot be stored.
                    return std.math.cast(u32, i) orelse unreachable;
                }
            }
        }

        return null;
    }

    pub fn disassemble(self: *Chunk, name: []const u8) void {
        std.debug.print("== {s} ==\n", .{name});

        var offset: usize = 0;
        while (offset < self.code.items.len) {
            offset = self.disassembleInstruction(offset);
        }
    }

    pub fn disassembleInstruction(self: *Chunk, offset: usize) usize {
        std.debug.print("{d:0>4} ", .{offset});
        if (offset > 0 and self.getLine(offset) == self.getLine(offset - 1)) {
            std.debug.print("   | ", .{});
        } else {
            std.debug.print("{d: >4} ", .{self.getLine(offset)});
        }

        std.debug.print("{f}\n", .{self.formatInstruction(offset, true)});
        return offset + self.instructionLength(offset);
    }

    pub fn formatInstruction(self: *const Chunk, offset: usize, show_opcode_prefix: bool) InstructionFormatter {
        return .{
            .chunk = self,
            .offset = offset,
            .show_opcode_prefix = show_opcode_prefix,
        };
    }

    /// Decode the instruction at `offset`, folding in any OP_EXTRA_ARG prefixes.
    /// `offset` must be an instruction start (first prefix, or the opcode itself).
    /// We can't scan backwards from an opcode to find its prefixes, because an
    /// operand byte may have the same value as OP_EXTRA_ARG.
    pub fn decode(self: *const Chunk, offset: usize) Decoded {
        var extra: u32 = 0;
        var i = offset;
        while (self.code.items[i] == @intFromEnum(OpCode.OP_EXTRA_ARG)) : (i += 2) {
            extra = (extra << 8) | self.code.items[i + 1];
        }
        const op = std.enums.fromInt(OpCode, self.code.items[i]) orelse .ILLEGAL;
        const operand = if (hasOperand(op)) (extra << 8) | self.code.items[i + 1] else 0;
        return .{ .op = op, .operand = operand, .op_offset = i };
    }

    /// Length in bytes of the instruction at `offset`, including its prefixes.
    pub fn instructionLength(self: *const Chunk, offset: usize) usize {
        const d = self.decode(offset);
        const prefix = d.op_offset - offset;
        const base: usize = switch (d.op) {
            .OP_JUMP_IF_FALSE, .OP_JUMP, .OP_LOOP, .OP_INVOKE, .OP_SUPER_INVOKE => 3,
            else => if (hasOperand(d.op)) 2 else 1,
        };
        return prefix + base;
    }
};

test "instruction length includes POPN operands" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    try chunk.writeChunk(@intFromEnum(OpCode.OP_POPN), 1);
    try chunk.writeChunk(1, 1);
    try chunk.writeChunk(@intFromEnum(OpCode.OP_EXTRA_ARG), 1);
    try chunk.writeChunk(1, 1);
    try chunk.writeChunk(@intFromEnum(OpCode.OP_POPN), 1);
    try chunk.writeChunk(0, 1);

    try std.testing.expectEqual(@as(usize, 2), chunk.instructionLength(0));
    try std.testing.expectEqual(@as(usize, 4), chunk.instructionLength(2));
}

test "decode folds OP_EXTRA_ARG prefixes into the operand" {
    const cases = [_]struct { bytes: []const u8, operand: u32 }{
        .{ .bytes = &.{ @intFromEnum(OpCode.OP_CONSTANT), 0x07 }, .operand = 7 },
        .{ .bytes = &.{ @intFromEnum(OpCode.OP_EXTRA_ARG), 0x01, @intFromEnum(OpCode.OP_CONSTANT), 0x2C }, .operand = 300 },
        .{ .bytes = &.{ @intFromEnum(OpCode.OP_EXTRA_ARG), 0x01, @intFromEnum(OpCode.OP_EXTRA_ARG), 0x11, @intFromEnum(OpCode.OP_CONSTANT), 0x70 }, .operand = 70_000 },
        // A middle prefix byte of 0 (and an operand byte equal to OP_EXTRA_ARG's value).
        .{ .bytes = &.{ @intFromEnum(OpCode.OP_EXTRA_ARG), 0x01, @intFromEnum(OpCode.OP_EXTRA_ARG), 0x00, @intFromEnum(OpCode.OP_EXTRA_ARG), 0x00, @intFromEnum(OpCode.OP_CONSTANT), @intFromEnum(OpCode.OP_EXTRA_ARG) }, .operand = 0x01_00_00_00 },
    };

    for (cases) |case| {
        var chunk = Chunk.init(std.testing.allocator);
        defer chunk.deinit();
        for (case.bytes) |b| try chunk.writeChunk(b, 1);

        const d = chunk.decode(0);
        try std.testing.expectEqual(OpCode.OP_CONSTANT, d.op);
        try std.testing.expectEqual(case.operand, d.operand);
        try std.testing.expectEqual(case.bytes.len - 2, d.op_offset);
        try std.testing.expectEqual(case.bytes.len, chunk.instructionLength(0));
    }
}

test "disassembler folds a wide instruction into one line" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    for ([_]u8{ @intFromEnum(OpCode.OP_EXTRA_ARG), 0x01, @intFromEnum(OpCode.OP_EXTRA_ARG), 0x11, @intFromEnum(OpCode.OP_POPN), 0x70 }) |b| {
        try chunk.writeChunk(b, 1);
    }

    var buffer: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{f}", .{chunk.formatInstruction(0, false)});
    try std.testing.expectEqualStrings("POPN [70000]", line);
}

test "compressed line table resolves instruction offsets" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    try chunk.writeChunk(0, 1);
    try chunk.writeChunk(0, 1);
    try chunk.writeChunk(0, 3);
    try chunk.writeChunk(0, 5);

    try std.testing.expectEqual(@as(usize, 1), chunk.getLine(0));
    try std.testing.expectEqual(@as(usize, 1), chunk.getLine(1));
    try std.testing.expectEqual(@as(usize, 3), chunk.getLine(2));
    try std.testing.expectEqual(@as(usize, 5), chunk.getLine(3));
}

test "compressed line table handles leading empty lines" {
    var chunk = Chunk.init(std.testing.allocator);
    defer chunk.deinit();

    try chunk.writeChunk(0, 3);
    try chunk.writeChunk(0, 3);

    try std.testing.expectEqual(@as(usize, 3), chunk.getLine(0));
    try std.testing.expectEqual(@as(usize, 3), chunk.getLine(1));
}
