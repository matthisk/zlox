const std = @import("std");
const VM = @import("vm.zig").VM;
const Chunk = @import("chunk.zig").Chunk;

const DEBUG_STRING_LIMIT = 40;
const DEBUG_GC = @import("config").debug_gc;

/// `args[0]` is stack slot 0 of the call: the receiver (`this`) for a method call,
/// or the native function itself for a plain call. The arguments follow at `args[1..]`.
pub const NativeFn = *const fn (vm: *VM, argCount: usize, args: []const Value) anyerror!Value;

pub const Value = union(enum) {
    bool: bool,
    number: f64,
    nil: void,
    string: *ObjStr,
    function: *ObjFunction,
    native: *ObjNative,
    closure: *ObjClosure,
    array: *ObjArray,
    class: *ObjClass,
    instance: *ObjInstance,
    bound_method: *ObjBoundMethod,
};

pub const ObjArray = struct {
    obj: Obj = .{ .kind = .array },
    values: std.ArrayList(Value) = .empty,
};

pub const ObjClass = struct {
    obj: Obj = .{ .kind = .class },
    name: *ObjStr,
    /// Either a `.closure` (methods written in Lox) or a `.native` (methods written in Zig).
    methods: std.AutoHashMap(*ObjStr, Value),
};

pub const ObjInstance = struct {
    obj: Obj = .{ .kind = .instance },
    class: *ObjClass,
    fields: std.AutoHashMap(*ObjStr, Value),
};

pub const ObjBoundMethod = struct {
    obj: Obj = .{ .kind = .bound_method },
    receiver: Value,
    /// Either a `.closure` or a `.native`, see `ObjClass.methods`.
    method: Value,
};

pub const ObjClosure = struct {
    obj: Obj = .{ .kind = .closure },
    function: *ObjFunction,
    upvalues: []*ObjUpvalue,
    initializedUpvalueCount: usize = 0,

    pub fn setUpvalue(self: *ObjClosure, index: usize, upvalue: *ObjUpvalue) void {
        std.debug.assert(index == self.initializedUpvalueCount);
        self.upvalues[index] = upvalue;
        self.initializedUpvalueCount += 1;
    }
};

pub const ObjUpvalue = struct {
    obj: Obj = .{ .kind = .upvalue },
    location: *Value,
    closed: Value = .nil,
    next: ?*ObjUpvalue = null,
};

/// Tells OP_CLOSURE where to find one captured variable.
pub const UpvalueDescriptor = struct {
    /// true: `index` is a local slot in the enclosing function's frame.
    /// false: `index` is an upvalue index in the enclosing closure.
    isLocal: bool,
    index: u24,
};

pub const ObjFunction = struct {
    obj: Obj = .{ .kind = .function },
    arity: usize,
    chunk: Chunk,
    upvalueCount: u8 = 0,
    /// One descriptor per upvalue, filled in by the compiler once the function body
    /// is compiled. These used to be encoded in the bytecode after OP_CLOSURE.
    upvalues: []UpvalueDescriptor = &.{},
    name: *ObjStr = undefined,

    pub fn create(allocator: std.mem.Allocator) !*ObjFunction {
        var objFn = try allocator.create(ObjFunction);
        objFn.obj = .{ .kind = .function };
        objFn.arity = 0;
        objFn.upvalueCount = 0;
        objFn.upvalues = &.{};
        objFn.chunk = Chunk.init(allocator);
        return objFn;
    }

    pub fn destroy(self: *ObjFunction, allocator: std.mem.Allocator) void {
        allocator.free(self.upvalues);
        self.chunk.deinit();
        allocator.destroy(self);
    }
};

pub const ObjNative = struct {
    obj: Obj = .{ .kind = .native },
    arity: usize,
    function: NativeFn,
};

// Obj: sizeOf = 16 bytes
pub const Obj = struct {
    next: ?*Obj = null,
    marked: bool = false,
    kind: enum { str, function, native, closure, upvalue, array, class, instance, bound_method },

    pub fn mark(self: *Obj) void {
        self.marked = true;
    }

    pub fn format(self: *Obj, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .str => {
                const s: *ObjStr = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = Value{ .string = s } }});
            },
            .function => {
                const f: *ObjFunction = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = Value{ .function = f } }});
            },
            .native => {
                const n: *ObjNative = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = Value{ .native = n } }});
            },
            .closure => {
                const o: *ObjClosure = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = Value{ .closure = o } }});
            },
            .upvalue => {
                const u: *ObjUpvalue = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = u.closed }});
            },
            .array => {
                const a: *ObjArray = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = Value{ .array = a } }});
            },
            .class => {
                const c: *ObjClass = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = Value{ .class = c } }});
            },
            .instance => {
                const i: *ObjInstance = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = Value{ .instance = i } }});
            },
            .bound_method => {
                const b: *ObjBoundMethod = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = Value{ .bound_method = b } }});
            },
        }
    }

    pub fn destroy(self: *Obj, allocator: std.mem.Allocator) void {
        if (comptime DEBUG_GC) {
            std.debug.print("{*} free type {s}\n", .{ self, @tagName(self.kind) });
        }
        switch (self.kind) {
            .str => {
                const s: *ObjStr = @fieldParentPtr("obj", self);
                allocator.free(s.chars);
                allocator.destroy(s);
            },
            .function => {
                const f: *ObjFunction = @fieldParentPtr("obj", self);
                f.destroy(allocator);
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
            .array => {
                const a: *ObjArray = @fieldParentPtr("obj", self);
                a.values.deinit(allocator);
                allocator.destroy(a);
            },
            .class => {
                const c: *ObjClass = @fieldParentPtr("obj", self);
                c.methods.deinit();
                allocator.destroy(c);
            },
            .instance => {
                const i: *ObjInstance = @fieldParentPtr("obj", self);
                i.fields.deinit();
                allocator.destroy(i);
            },
            .bound_method => {
                const b: *ObjBoundMethod = @fieldParentPtr("obj", self);
                allocator.destroy(b);
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

pub inline fn isArray(v: Value) bool {
    return switch (v) {
        .array => true,
        else => false,
    };
}

pub inline fn isClass(v: Value) bool {
    return v == .class;
}

pub inline fn isInstance(v: Value) bool {
    return v == .instance;
}

pub inline fn isBoundMethod(v: Value) bool {
    return v == .bound_method;
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

pub inline fn asClass(v: Value) *ObjClass {
    return v.class;
}

pub inline fn asInstance(v: Value) *ObjInstance {
    return v.instance;
}

pub inline fn asBoundMethod(v: Value) *ObjBoundMethod {
    return v.bound_method;
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
    enclosing: ?*const Formatter = null,

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
                    try writer.print("<c script>", .{});
                } else {
                    try writer.print("<cl {s}>", .{c.function.name.chars});
                }
            },
            .function => |f| {
                if (std.mem.eql(u8, f.name.chars, "<script>")) {
                    try writer.print("<f script>", .{});
                } else {
                    try writer.print("<fn {s}>", .{f.name.chars});
                }
            },
            .native => {
                try writer.print("<native>", .{});
            },
            .array => {
                const items = self.value.array.values.items;
                const len = items.len;
                const truncated = len > 8;

                try writer.writeAll("[");

                for (0..@min(len, 8)) |i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (truncated and i == 4) try writer.writeAll("..., ");

                    const index = if (truncated and i >= 4)
                        len - 8 + i
                    else
                        i;

                    const value = items[index];

                    // To prevent infinite recursion we need to check for cycles in an array.
                    // I.e. var a = [1]; a.push(a); should print [1, [...]]
                    if (isArray(value)) {
                        var parent = self.enclosing;
                        while (parent != null) {
                            if (isArray(parent.?.value) and parent.?.value.array == value.array) {
                                try writer.writeAll("[...]");
                                return;
                            }
                            parent = parent.?.enclosing;
                        }
                    }

                    try writer.print("{f}", .{Formatter{ .value = value, .enclosing = &self }});
                }

                try writer.writeAll("]");
            },
            .class => |class| try writer.print("<class {s}>", .{class.name.chars}),
            .instance => |instance| try writer.print("<{s} instance>", .{instance.class.name.chars}),
            .bound_method => |bound| switch (bound.method) {
                .closure => |c| try writer.print("<bound {s}>", .{c.function.name.chars}),
                else => try writer.writeAll("<bound native>"),
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
        .array => try writer.print("{f}", .{Formatter{ .value = v }}),
        .class => |class| try writer.writeAll(class.name.chars),
        .instance => |instance| try writer.print("{s} instance", .{instance.class.name.chars}),
        .bound_method => |bound| switch (bound.method) {
            .closure => |c| try writer.writeAll(c.function.name.chars),
            else => try writer.writeAll("<native_fn>"),
        },
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
