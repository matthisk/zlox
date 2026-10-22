const std = @import("std");
const VM = @import("vm.zig").VM;
const Chunk = @import("chunk.zig").Chunk;

const DEBUG_STRING_LIMIT = 40;

pub const Value = union(enum) {
    bool: bool,
    number: f64,
    nil: void,
    obj: *Obj,
};

pub const ObjFunction = struct {
    obj: Obj,
    arity: usize,
    chunk: Chunk,
    name: *ObjStr = undefined,

    pub fn create(allocator: std.mem.Allocator) !*ObjFunction {
        var objFn = try allocator.create(ObjFunction);
        objFn.arity = 0;
        objFn.chunk = Chunk.init(allocator);
        return objFn;
    }

    pub fn destroy(self: *ObjFunction, allocator: std.mem.Allocator) void {
        self.chunk.deinit();
        allocator.destroy(self);
    }
};

pub const Obj = struct {
    next: ?*Obj,
    data: ObjData,

    pub fn destroy(self: *Obj, allocator: std.mem.Allocator) void {
        switch (self.data) {
            .str => |s| if (s.owner) allocator.free(s.chars),
            .function => |f| {
                f.chunk.deinit();
                allocator.destroy(f);
            },
        }
        allocator.destroy(self);
    }
};

pub const ObjData = union(enum) {
    str: ObjStr,
    function: *ObjFunction,
};

pub const ObjStr = struct {
    owner: bool,
    chars: []const u8,
};

pub inline fn boolValue(b: bool) Value {
    return Value{ .bool = b };
}

pub inline fn numberValue(n: f64) Value {
    return Value{ .number = n };
}

pub inline fn nilValue() Value {
    return Value{ .nil = {} };
}

pub inline fn objValue(o: *Obj) Value {
    return Value{ .obj = o };
}

pub inline fn strObj(chars: []const u8) ObjStr {
    return ObjStr{ .chars = chars };
}

pub inline fn isNumber(v: Value) bool {
    return switch (v) {
        .number => true,
        else => false,
    };
}

pub inline fn isBool(v: Value) bool {
    return switch (v) {
        .bool => true,
        else => false,
    };
}

pub inline fn isNil(v: Value) bool {
    return switch (v) {
        .nil => true,
        else => false,
    };
}

pub inline fn isString(v: Value) bool {
    return switch (v) {
        .obj => |o| switch (o.data) {
            .str => true,
            else => false,
        },
        else => false,
    };
}

pub inline fn isFunction(v: Value) bool {
    return switch (v) {
        .obj => |o| switch (o.data) {
            .function => true,
            else => false,
        },
        else => false,
    };
}

pub const Formatter = struct {
    value: Value,

    pub fn format(self: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.value) {
            .number => |number| try writer.print("{d}", .{number}),
            .bool => |boolean| try writer.print("{}", .{boolean}),
            .nil => try writer.writeAll("nil"),
            .obj => |object| switch (object.data) {
                .str => |string| {
                    const preview_length = @min(string.chars.len, DEBUG_STRING_LIMIT);
                    const preview = string.chars[0..preview_length];
                    const ellipsis: []const u8 = if (preview_length < string.chars.len) "..." else "";
                    try writer.print("\"{f}\"{s}", .{ std.zig.fmtString(preview), ellipsis });
                },
                .function => |f| {
                    if (f.name.chars.len > 0) {
                        try writer.print("<fn {s}>", .{f.name.chars});
                    } else {
                        try writer.print("<script>", .{});
                    }
                },
            },
        }
    }
};

pub fn format(v: Value) Formatter {
    return .{ .value = v };
}

pub fn write(v: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    switch (v) {
        .number => |number| try writer.print("{d}", .{number}),
        .bool => |boolean| try writer.print("{}", .{boolean}),
        .nil => try writer.writeAll("nil"),
        .obj => |object| switch (object.data) {
            .str => |string| try writer.writeAll(string.chars),
            .function => |f| try writer.writeAll(f.name.chars),
        },
    }
}

test "debug formatter escapes and truncates strings" {
    var short = Obj{
        .next = null,
        .data = .{ .str = .{ .owner = false, .chars = "hello\nworld" } },
    };
    try std.testing.expectFmt("\"hello\\nworld\"", "{f}", .{format(objValue(&short))});

    var long = Obj{
        .next = null,
        .data = .{ .str = .{ .owner = false, .chars = "1234567890123456789012345678901234567890tail" } },
    };
    try std.testing.expectFmt(
        "\"1234567890123456789012345678901234567890\"...",
        "{f}",
        .{format(objValue(&long))},
    );
}
