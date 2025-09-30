const std = @import("std");
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const OpCode = enum(u8) {
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
    ILLEGAL,
};

pub const ChunkErrors = error{OutOfConstantDataSlots};

pub const Chunk = struct {
    code: std.ArrayList(u8) = undefined,
    data: std.ArrayList(Value) = undefined,
    lines: std.ArrayList(usize) = undefined,

    pub fn init(allocator: std.mem.Allocator) Chunk {
        return Chunk{
            .code = std.ArrayList(u8).init(allocator),
            .data = std.ArrayList(Value).init(allocator),
            .lines = std.ArrayList(usize).init(allocator),
        };
    }

    pub fn deinit(self: *Chunk) void {
        self.code.deinit();
        self.data.deinit();
        self.lines.deinit();
    }

    pub fn writeChunk(self: *Chunk, b: u8, l: usize) std.mem.Allocator.Error!void {
        try self.code.append(b);
        try self.lines.append(l);
    }

    pub fn addValue(self: *Chunk, v: Value) (std.mem.Allocator.Error || ChunkErrors)!u8 {
        try self.data.append(v);
        return std.math.cast(u8, self.data.items.len - 1) orelse return ChunkErrors.OutOfConstantDataSlots;
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
        if (offset > 0 and self.lines.items[offset] == self.lines.items[offset - 1]) {
            std.debug.print("   | ", .{});
        } else {
            std.debug.print("{:>4} ", .{self.lines.items[offset]});
        }

        const op: OpCode = std.meta.intToEnum(OpCode, self.code.items[offset]) catch OpCode.ILLEGAL;
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
        std.debug.print(name, .{});
        value_mod.print(v);
        std.debug.print("\n", .{});
        return offset + 2;
    }
};
