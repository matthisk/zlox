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
    OP_POP,
    OP_DEFINE_GLOBAL,
    OP_GET_GLOBAL,
    OP_SET_GLOBAL,
    OP_GET_LOCAL,
    OP_SET_LOCAL,
    OP_JUMP_IF_FALSE,
    OP_JUMP,
    OP_LOOP,
    ILLEGAL,
};

pub const ChunkErrors = error{OutOfConstantDataSlots};

pub const Chunk = struct {
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
            try self.lines.append(self.allocator, 0);
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
        var prevCodeIndex: usize = 0;

        for (self.lines.items, 0..) |codeIndex, lineNumber| {
            if (i < codeIndex and i >= prevCodeIndex) {
                return lineNumber;
            }
            prevCodeIndex = codeIndex;
        }

        return self.lines.items.len - 1;
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

    pub fn findValue(self: *Chunk, v: []const u8) ?u8 {
        for (self.data.items, 0..) |value, i| {
            if (value_mod.isString(value)) {
                const chars = value.obj.data.str.chars;
                if (chars.ptr == v.ptr and chars.len == v.len) {
                    // Impossible to fina a dataslot that doesn't fit a u8, as it cannot be stored.
                    return std.math.cast(u8, i) orelse unreachable;
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
        std.debug.print("{:0>4} ", .{offset});
        if (offset > 0 and self.getLine(offset) == self.getLine(offset - 1)) {
            std.debug.print("   | ", .{});
        } else {
            std.debug.print("{:>4} ", .{self.getLine(offset)});
        }

        const op: OpCode = std.enums.fromInt(OpCode, self.code.items[offset]) orelse OpCode.ILLEGAL;
        switch (op) {
            OpCode.OP_RETURN => {
                return self.simpleInstruction("OP_RETURN", offset);
            },
            OpCode.OP_FALSE => {
                return self.simpleInstruction("OP_FALSE", offset);
            },
            OpCode.OP_TRUE => {
                return self.simpleInstruction("OP_TRUE", offset);
            },
            OpCode.OP_NIL => {
                return self.simpleInstruction("OP_NIL", offset);
            },
            OpCode.OP_NOT => {
                return self.simpleInstruction("OP_NOT", offset);
            },
            OpCode.OP_CONSTANT => {
                return self.constantInstruction("OP_CONSTANT", offset);
            },
            OpCode.OP_CONSTANT_LONG => {
                return self.longConstantInstruction("OP_CONSTANT_LONG", offset);
            },
            OpCode.OP_NEGATE => {
                return self.simpleInstruction("OP_NEGATE", offset);
            },
            OpCode.OP_ADD => {
                return self.simpleInstruction("OP_ADD", offset);
            },
            OpCode.OP_MULTIPLY => {
                return self.simpleInstruction("OP_MULTIPLY", offset);
            },
            OpCode.OP_SUBTRACT => {
                return self.simpleInstruction("OP_SUBTRACT", offset);
            },
            OpCode.OP_DIVIDE => {
                return self.simpleInstruction("OP_DIVIDE", offset);
            },
            OpCode.OP_AND => {
                return self.simpleInstruction("OP_AND", offset);
            },
            OpCode.OP_OR => {
                return self.simpleInstruction("OP_OR", offset);
            },
            OpCode.OP_EQUALS => {
                return self.simpleInstruction("OP_EQUALS", offset);
            },
            OpCode.OP_LESS => {
                return self.simpleInstruction("OP_LESS", offset);
            },
            OpCode.OP_GREATER => {
                return self.simpleInstruction("OP_GREATER", offset);
            },
            OpCode.OP_DEFINE_GLOBAL => {
                return self.constantInstruction("OP_DEFINE_GLOBAL", offset);
            },
            OpCode.OP_GET_GLOBAL => {
                return self.constantInstruction("OP_GET_GLOBAL", offset);
            },
            OpCode.OP_SET_GLOBAL => {
                return self.constantInstruction("OP_SET_GLOBAL", offset);
            },
            OpCode.OP_PRINT => {
                return self.simpleInstruction("OP_PRINT", offset);
            },
            OpCode.OP_POP => {
                return self.simpleInstruction("OP_POP", offset);
            },
            OpCode.OP_SET_LOCAL => {
                return self.constantInstruction("OP_SET_LOCAL", offset);
            },
            OpCode.OP_GET_LOCAL => {
                return self.constantInstruction("OP_GET_LOCAL", offset);
            },
            OpCode.OP_JUMP_IF_FALSE => {
                return self.jumpInstruction("OP_JUMP_IF_FALSE", offset);
            },
            OpCode.OP_JUMP => {
                return self.jumpInstruction("OP_JUMP", offset);
            },
            OpCode.OP_LOOP => {
                return self.jumpInstruction("OP_LOOP", offset);
            },
            OpCode.ILLEGAL => {
                return self.simpleInstruction("", offset);
            },
        }
    }

    fn simpleInstruction(_: *Chunk, comptime name: []const u8, offset: usize) usize {
        std.debug.print(name, .{});
        std.debug.print("\n", .{});
        return offset + 1;
    }

    fn constantInstruction(self: *Chunk, comptime name: []const u8, offset: usize) usize {
        const loc: u8 = self.code.items[offset + 1];
        const v: Value = self.data.items[loc];
        std.debug.print("{s} [{d}] ", .{ name, loc });
        value_mod.print(v);
        std.debug.print("\n", .{});
        return offset + 2;
    }

    fn longConstantInstruction(self: *Chunk, comptime name: []const u8, offset: usize) usize {
        const bs = self.code.items[offset + 1 ..][0..3];
        const loc: u24 = std.mem.readInt(u24, bs, .big);
        const v: Value = self.data.items[loc];
        std.debug.print("{s} [{d}] ", .{ name, loc });
        value_mod.print(v);
        std.debug.print("\n", .{});
        return offset + 4;
    }

    fn jumpInstruction(self: *Chunk, comptime name: []const u8, offset: usize) usize {
        const high = self.code.items[offset + 1];
        const low = self.code.items[offset + 2];
        const jumpOffset = (@as(u16, high) << 8) | low;

        std.debug.print("{s} [{d}]\n", .{ name, jumpOffset });

        return offset + 3;
    }
};
