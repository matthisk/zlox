const std = @import("std");
const VM = @import("vm.zig").VM;
const Chunk = @import("chunk.zig").Chunk;

const DEBUG_STRING_LIMIT = 40;

pub const NativeFn = *const fn (vm: *VM, argCount: usize, args: []const Value) anyerror!Value;

pub const Value = union(enum) {
    bool: bool,
    number: f64,
    nil: void,
    string: *ObjStr,
    function: *ObjFunction,
    native: *ObjNative,
    closure: *ObjClosure,
};

pub const ObjClosure = struct {
    obj: Obj = .{ .kind = .closure },
    function: *ObjFunction,
    upvalues: []*ObjUpvalue,
};

pub const ObjUpvalue = struct {
    obj: Obj = .{ .kind = .upvalue },
    location: *Value,
    closed: Value = .nil,
    next: ?*ObjUpvalue = null,
};

pub const ObjFunction = struct {
    obj: Obj = .{ .kind = .function },
    arity: usize,
    chunk: Chunk,
    upvalueCount: u8 = 0,
    name: *ObjStr = undefined,

    pub fn create(allocator: std.mem.Allocator) !*ObjFunction {
        var objFn = try allocator.create(ObjFunction);
        objFn.obj = .{ .kind = .function };
        objFn.arity = 0;
        objFn.upvalueCount = 0;
        objFn.chunk = Chunk.init(allocator);
        return objFn;
    }

    pub fn destroy(self: *ObjFunction, allocator: std.mem.Allocator) void {
        self.chunk.deinit();
        allocator.destroy(self);
    }
};

pub const ObjNative = struct {
    obj: Obj = .{ .kind = .native },
    arity: usize,
    function: NativeFn,
};

pub const Obj = struct {
    next: ?*Obj = null,
    kind: enum { str, function, native, closure, upvalue },

    pub fn destroy(self: *Obj, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .str => {
                const s: *ObjStr = @fieldParentPtr("obj", self);
                allocator.free(s.chars);
                allocator.destroy(s);
            },
            .function => {
                const f: *ObjFunction = @fieldParentPtr("obj", self);
                f.chunk.deinit();
                allocator.destroy(f);
            },
            .native => {
                const n: *ObjNative = @fieldParentPtr("obj", self);
                allocator.destroy(n);
            },
            .closure => {
                const o: *ObjClosure = @fieldParentPtr("obj", self);
                allocator.free(o.upvalues);
                allocator.destroy(o);
            },
            .upvalue => {
                const u: *ObjUpvalue = @fieldParentPtr("obj", self);
                allocator.destroy(u);
            },
        }
    }
};

pub const ObjStr = struct {
    obj: Obj = .{ .kind = .str },
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
    return v == .string;
}

pub inline fn asFunction(v: Value) *ObjFunction {
    return v.function;
}

pub inline fn asNative(v: Value) *ObjNative {
    return v.native;
}

pub inline fn asClosure(v: Value) *ObjClosure {
    return v.closure;
}

pub inline fn asStr(v: Value) []const u8 {
    return v.string.chars;
}

pub inline fn isFunction(v: Value) bool {
    return v == .function;
}

pub inline fn isNative(v: Value) bool {
    return v == .native;
}

pub inline fn isClosure(v: Value) bool {
    return v == .closure;
}

pub const Formatter = struct {
    value: Value,

    pub fn format(self: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.value) {
            .number => |number| try writer.print("{d}", .{number}),
            .bool => |boolean| try writer.print("{}", .{boolean}),
            .nil => try writer.writeAll("nil"),
            .string => |string| {
                const preview_length = @min(string.chars.len, DEBUG_STRING_LIMIT);
                const preview = string.chars[0..preview_length];
                const ellipsis: []const u8 = if (preview_length < string.chars.len) "..." else "";
                try writer.print("\"{f}\"{s}", .{ std.zig.fmtString(preview), ellipsis });
            },
            .closure => |c| {
                if (std.mem.eql(u8, c.function.name.chars, "<script>")) {
                    try writer.print("<script>", .{});
                } else {
                    try writer.print("<fn {s}>", .{c.function.name.chars});
                }
            },
            .function => |f| {
                if (std.mem.eql(u8, f.name.chars, "<script>")) {
                    try writer.print("<script>", .{});
                } else {
                    try writer.print("<fn {s}>", .{f.name.chars});
                }
            },
            .native => {
                try writer.print("<native>", .{});
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
        .string => |string| try writer.writeAll(string.chars),
        .function => |f| try writer.writeAll(f.name.chars),
        .native => try writer.writeAll("<native_fn>"),
        .closure => |c| try writer.writeAll(c.function.name.chars),
    }
}

test "debug formatter escapes and truncates strings" {
    var short = ObjStr{
        .chars = "hello\nworld",
    };
    try std.testing.expectFmt("\"hello\\nworld\"", "{f}", .{format(.{ .string = &short })});

    var long = ObjStr{
        .chars = "1234567890123456789012345678901234567890tail",
    };
    try std.testing.expectFmt(
        "\"1234567890123456789012345678901234567890\"...",
        "{f}",
        .{format(.{ .string = &long })},
    );
}
