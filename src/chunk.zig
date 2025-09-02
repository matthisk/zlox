const std = @import("std");

pub const Value = f64;

pub const OpCode = enum(u8) {
    OP_RETURN,
    OP_CONSTANT,
    OP_NEGATE,
    OP_ADD,
    OP_SUBTRACT,
    OP_MULTIPLY,
    OP_DIVIDE,
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
                std.debug.print("OP_RETURN\n", .{});
                return offset + 1;
            },
            OpCode.OP_CONSTANT => {
                const loc: u8 = self.code.items[offset + 1];
                const value: Value = self.data.items[loc];
                std.debug.print("OP_CONSTANT {d}\n", .{value});
                return offset + 2;
            },
            OpCode.OP_NEGATE => {
                std.debug.print("OP_NEGATE\n", .{});
                return offset + 1;
            },
            OpCode.OP_ADD => {
                std.debug.print("OP_ADD\n", .{});
                return offset + 1;
            },
            OpCode.OP_MULTIPLY => {
                std.debug.print("OP_MULTIPLY\n", .{});
                return offset + 1;
            },
            OpCode.OP_SUBTRACT => {
                std.debug.print("OP_SUBTRACT\n", .{});
                return offset + 1;
            },
            OpCode.OP_DIVIDE => {
                std.debug.print("OP_DIVIDE\n", .{});
                return offset + 1;
            },
            OpCode.ILLEGAL => {
                std.debug.print("ILLEGAL\n", .{});
                return offset + 1;
            },
        }
    }
};
