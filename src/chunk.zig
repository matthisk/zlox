const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const OpCode = enum(u8) {
    OP_RETURN,
    OP_TRUE,
    OP_FALSE,
    OP_NIL,
    OP_CONSTANT,
    OP_CONSTANT_LONG,
    OP_NEGATE,
    OP_NOT,
    OP_ADD,
    OP_SUBTRACT,
    OP_MULTIPLY,
    OP_DIVIDE,
    OP_AND,
    OP_OR,
    OP_EQUALS,
    OP_LESS,
    OP_GREATER,
    OP_PRINT,
    OP_CALL,
    OP_POP,
    OP_POPN,
    OP_POPN_LONG,
    OP_DEFINE_GLOBAL,
    OP_GET_GLOBAL,
    OP_SET_GLOBAL,
    OP_GET_LOCAL,
    OP_SET_LOCAL,
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
            const byte = self.chunk.code.items[self.offset];
            const op = std.enums.fromInt(OpCode, byte) orelse OpCode.ILLEGAL;
            const tag_name = @tagName(op);
            const name = if (!self.show_opcode_prefix and std.mem.startsWith(u8, tag_name, "OP_"))
                tag_name["OP_".len..]
            else
                tag_name;

            switch (op) {
                .OP_POPN, .OP_CALL => {
                    const n = self.chunk.code.items[self.offset + 1];
                    try writer.print("{s} [{d}]", .{ name, n });
                },
                .OP_POPN_LONG => {
                    const bytes = self.chunk.code.items[self.offset + 1 ..][0..3];
                    const n = std.mem.readInt(u24, bytes, .big);
                    try writer.print("{s} [{d}]", .{ name, n });
                },
                .OP_CONSTANT => {
                    const index = self.chunk.code.items[self.offset + 1];
                    try writer.print("{s} [{d}] {f}", .{ name, index, value_mod.format(self.chunk.data.items[index]) });
                },
                .OP_CONSTANT_LONG, .OP_DEFINE_GLOBAL, .OP_GET_GLOBAL, .OP_SET_GLOBAL => {
                    const bytes = self.chunk.code.items[self.offset + 1 ..][0..3];
                    const index = std.mem.readInt(u24, bytes, .big);
                    try writer.print("{s} [{d}] {f}", .{ name, index, value_mod.format(self.chunk.data.items[index]) });
                },
                .OP_GET_LOCAL, .OP_SET_LOCAL => {
                    const slot = self.chunk.code.items[self.offset + 1];
                    try writer.print("{s} slot {d}", .{ name, slot });
                },
                .OP_JUMP_IF_FALSE, .OP_JUMP, .OP_LOOP => {
                    const high = self.chunk.code.items[self.offset + 1];
                    const low = self.chunk.code.items[self.offset + 2];
                    const distance = (@as(u16, high) << 8) | low;
                    const next = self.offset + 3;
                    const target = if (op == .OP_LOOP) next - distance else next + distance;
                    try writer.print("{s} -> {d:0>4}", .{ name, target });
                },
                .ILLEGAL => try writer.print("ILLEGAL 0x{x:0>2}", .{byte}),
                else => try writer.writeAll(name),
            }
        }
    };

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

    pub fn addValue(self: *Chunk, v: Value) (std.mem.Allocator.Error || ChunkErrors)!u24 {
        try self.data.append(self.allocator, v);

        const index = self.data.items.len - 1;
        // We only have 2^24 data slots available in our VM.
        if (index > std.math.maxInt(u24)) {
            return ChunkErrors.OutOfConstantDataSlots;
        }

        return @intCast(index);
    }

    pub fn findValue(self: *Chunk, v: []const u8) ?u24 {
        for (self.data.items, 0..) |value, i| {
            if (value_mod.isString(value)) {
                const chars = value.obj.data.str.chars;
                if (chars.ptr == v.ptr and chars.len == v.len) {
                    // Impossible to fina a dataslot that doesn't fit a u24, as it cannot be stored.
                    return std.math.cast(u24, i) orelse unreachable;
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

    pub fn instructionLength(self: *const Chunk, offset: usize) usize {
        const op = std.enums.fromInt(OpCode, self.code.items[offset]) orelse return 1;
        return switch (op) {
            .OP_CONSTANT, .OP_CALL => 2,
            .OP_CONSTANT_LONG, .OP_DEFINE_GLOBAL, .OP_GET_LOCAL, .OP_SET_LOCAL, .OP_GET_GLOBAL, .OP_SET_GLOBAL => 4,
            .OP_JUMP_IF_FALSE, .OP_JUMP, .OP_LOOP => 3,
            else => 1,
        };
    }
};

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
