const std = @import("std");
const VM = @import("vm.zig").VM;
const Chunk = @import("chunk.zig").Chunk;

const DEBUG_STRING_LIMIT = 40;
const DEBUG_GC = @import("config").debug_gc;
const NAN_BOXING = @import("config").nan_boxing;

// NaN boxing constants:
const QNAN: u64 = 0x7ffc000000000000;
const SIGN_BIT: u64 = 0x8000000000000000;

const TAG_NIL = 1; // 01
const TAG_FALSE = 2; // 10
const TAG_TRUE = 3; // 11

const NIL_VAL = QNAN | TAG_NIL;
const TRUE_VAL = QNAN | TAG_TRUE;
const FALSE_VAL = QNAN | TAG_FALSE;

const ObjStrContext = struct {
    pub fn hash(_: ObjStrContext, key: *ObjStr) u64 {
        return key.hash;
    }
    pub fn eql(_: ObjStrContext, a: *ObjStr, b: *ObjStr) bool {
        return a == b;
    }
};

pub const HashMap = std.HashMap(*ObjStr, Value, ObjStrContext, std.hash_map.default_max_load_percentage);

/// `args[0]` is stack slot 0 of the call: the receiver (`this`) for a method call,
/// or the native function itself for a plain call. The arguments follow at `args[1..]`.
pub const NativeFn = *const fn (vm: *VM, argCount: usize, args: []const Value) anyerror!Value;

pub const Value = if (NAN_BOXING) u64 else union(enum) {
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
    methods: HashMap,
};

pub const ObjInstance = struct {
    obj: Obj = .{ .kind = .instance },
    class: *ObjClass,
    fields: HashMap,
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
    closed: Value = nilValue(),
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
                try writer.print("{f}", .{Formatter{ .value = stringValue(s) }});
            },
            .function => {
                const f: *ObjFunction = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = functionValue(f) }});
            },
            .native => {
                const n: *ObjNative = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = nativeValue(n) }});
            },
            .closure => {
                const o: *ObjClosure = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = closureValue(o) }});
            },
            .upvalue => {
                const u: *ObjUpvalue = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = u.closed }});
            },
            .array => {
                const a: *ObjArray = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = arrayValue(a) }});
            },
            .class => {
                const c: *ObjClass = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = classValue(c) }});
            },
            .instance => {
                const i: *ObjInstance = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = instanceValue(i) }});
            },
            .bound_method => {
                const b: *ObjBoundMethod = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = boundMethodValue(b) }});
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
    hash: u64, // pre computed hash.
};

pub inline fn boolValue(b: bool) Value {
    if (comptime NAN_BOXING) {
        return if (b) TRUE_VAL else FALSE_VAL;
    } else {
        return Value{ .bool = b };
    }
}

pub inline fn numberValue(n: f64) Value {
    if (comptime NAN_BOXING) {
        return @bitCast(n);
    } else {
        return Value{ .number = n };
    }
}

pub inline fn nilValue() Value {
    if (comptime NAN_BOXING) {
        return NIL_VAL;
    } else {
        return Value{ .nil = {} };
    }
}

pub inline fn stringValue(s: *ObjStr) Value {
    if (comptime NAN_BOXING) {
        return asValue(&s.obj);
    } else {
        return Value{ .string = s };
    }
}

pub inline fn functionValue(f: *ObjFunction) Value {
    if (comptime NAN_BOXING) {
        return asValue(&f.obj);
    } else {
        return Value{ .function = f };
    }
}

pub inline fn nativeValue(n: *ObjNative) Value {
    if (comptime NAN_BOXING) {
        return asValue(&n.obj);
    } else {
        return Value{ .native = n };
    }
}

pub inline fn closureValue(c: *ObjClosure) Value {
    if (comptime NAN_BOXING) {
        return asValue(&c.obj);
    } else {
        return Value{ .closure = c };
    }
}

pub inline fn arrayValue(a: *ObjArray) Value {
    if (comptime NAN_BOXING) {
        return asValue(&a.obj);
    } else {
        return Value{ .array = a };
    }
}

pub inline fn classValue(c: *ObjClass) Value {
    if (comptime NAN_BOXING) {
        return asValue(&c.obj);
    } else {
        return Value{ .class = c };
    }
}

pub inline fn instanceValue(i: *ObjInstance) Value {
    if (comptime NAN_BOXING) {
        return asValue(&i.obj);
    } else {
        return Value{ .instance = i };
    }
}

pub inline fn boundMethodValue(b: *ObjBoundMethod) Value {
    if (comptime NAN_BOXING) {
        return asValue(&b.obj);
    } else {
        return Value{ .bound_method = b };
    }
}

pub inline fn asNumber(v: Value) f64 {
    if (comptime NAN_BOXING) {
        return @bitCast(v);
    } else {
        return v.number;
    }
}

pub inline fn asBool(v: Value) bool {
    if (comptime NAN_BOXING) {
        return v == TRUE_VAL;
    } else {
        return v.bool;
    }
}

pub inline fn asString(v: Value) *ObjStr {
    if (comptime NAN_BOXING) {
        return @fieldParentPtr("obj", asObj(v));
    } else {
        return v.string;
    }
}

pub inline fn asArray(v: Value) *ObjArray {
    if (comptime NAN_BOXING) {
        return @fieldParentPtr("obj", asObj(v));
    } else {
        return v.array;
    }
}

pub inline fn asFunction(v: Value) *ObjFunction {
    if (comptime NAN_BOXING) {
        return @fieldParentPtr("obj", asObj(v));
    } else {
        return v.function;
    }
}

pub inline fn asNative(v: Value) *ObjNative {
    if (comptime NAN_BOXING) {
        return @fieldParentPtr("obj", asObj(v));
    } else {
        return v.native;
    }
}

pub inline fn asClosure(v: Value) *ObjClosure {
    if (comptime NAN_BOXING) {
        return @fieldParentPtr("obj", asObj(v));
    } else {
        return v.closure;
    }
}

pub inline fn asClass(v: Value) *ObjClass {
    if (comptime NAN_BOXING) {
        return @fieldParentPtr("obj", asObj(v));
    } else {
        return v.class;
    }
}

pub inline fn asInstance(v: Value) *ObjInstance {
    if (comptime NAN_BOXING) {
        return @fieldParentPtr("obj", asObj(v));
    } else {
        return v.instance;
    }
}

pub inline fn asBoundMethod(v: Value) *ObjBoundMethod {
    if (comptime NAN_BOXING) {
        return @fieldParentPtr("obj", asObj(v));
    } else {
        return v.bound_method;
    }
}

pub inline fn asStr(v: Value) []const u8 {
    if (comptime NAN_BOXING) {
        return asString(v).chars;
    } else {
        return v.string.chars;
    }
}

/// The `Obj` header of a heap allocated value. Switch on its `kind` to find out
/// which object type it is.
pub inline fn asObj(v: Value) *Obj {
    if (comptime NAN_BOXING) {
        return @ptrFromInt(v & ~(SIGN_BIT | QNAN));
    } else {
        return switch (v) {
            .string => |o| &o.obj,
            .function => |o| &o.obj,
            .native => |o| &o.obj,
            .closure => |o| &o.obj,
            .array => |o| &o.obj,
            .class => |o| &o.obj,
            .instance => |o| &o.obj,
            .bound_method => |o| &o.obj,
            .bool, .number, .nil => unreachable,
        };
    }
}

pub inline fn asValue(obj: *Obj) Value {
    if (comptime NAN_BOXING) {
        return @intFromPtr(obj) | SIGN_BIT | QNAN;
    } else {
        return switch (obj.kind) {
            .str => stringValue(@fieldParentPtr("obj", obj)),
            .function => functionValue(@fieldParentPtr("obj", obj)),
            .native => nativeValue(@fieldParentPtr("obj", obj)),
            .closure => closureValue(@fieldParentPtr("obj", obj)),
            .array => arrayValue(@fieldParentPtr("obj", obj)),
            .class => classValue(@fieldParentPtr("obj", obj)),
            .instance => instanceValue(@fieldParentPtr("obj", obj)),
            .bound_method => boundMethodValue(@fieldParentPtr("obj", obj)),
            .upvalue => unreachable,
        };
    }
}

/// True for every heap allocated value, i.e. anything that is not a bool, number or nil.
pub inline fn isObj(v: Value) bool {
    if (comptime NAN_BOXING) {
        return (v & (SIGN_BIT | QNAN)) == (SIGN_BIT | QNAN);
    } else {
        return switch (v) {
            .bool, .number, .nil => false,
            else => true,
        };
    }
}

pub inline fn isNumber(v: Value) bool {
    if (comptime NAN_BOXING) {
        return (v & QNAN) != QNAN;
    } else {
        return switch (v) {
            .number => true,
            else => false,
        };
    }
}

pub inline fn isArray(v: Value) bool {
    if (comptime NAN_BOXING) {
        return isObj(v) and asObj(v).kind == .array;
    } else {
        return switch (v) {
            .array => true,
            else => false,
        };
    }
}

pub inline fn isClass(v: Value) bool {
    if (comptime NAN_BOXING) {
        return isObj(v) and asObj(v).kind == .class;
    } else {
        return v == .class;
    }
}

pub inline fn isInstance(v: Value) bool {
    if (comptime NAN_BOXING) {
        return isObj(v) and asObj(v).kind == .instance;
    } else {
        return v == .instance;
    }
}

pub inline fn isBoundMethod(v: Value) bool {
    if (comptime NAN_BOXING) {
        return isObj(v) and asObj(v).kind == .bound_method;
    } else {
        return v == .bound_method;
    }
}

pub inline fn isBool(v: Value) bool {
    if (comptime NAN_BOXING) {
        return (v | 1) == TRUE_VAL;
    } else {
        return switch (v) {
            .bool => true,
            else => false,
        };
    }
}

pub inline fn isNil(v: Value) bool {
    if (comptime NAN_BOXING) {
        return v == NIL_VAL;
    } else {
        return switch (v) {
            .nil => true,
            else => false,
        };
    }
}

pub inline fn isString(v: Value) bool {
    if (comptime NAN_BOXING) {
        return isObj(v) and asObj(v).kind == .str;
    } else {
        return v == .string;
    }
}

pub inline fn isFunction(v: Value) bool {
    if (comptime NAN_BOXING) {
        return isObj(v) and asObj(v).kind == .function;
    } else {
        return v == .function;
    }
}

pub inline fn isNative(v: Value) bool {
    if (comptime NAN_BOXING) {
        return isObj(v) and asObj(v).kind == .native;
    } else {
        return v == .native;
    }
}

pub inline fn isClosure(v: Value) bool {
    if (comptime NAN_BOXING) {
        return isObj(v) and asObj(v).kind == .closure;
    } else {
        return v == .closure;
    }
}

pub const Formatter = struct {
    value: Value,
    enclosing: ?*const Formatter = null,

    pub fn format(self: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const v = self.value;
        if (isNumber(v)) return writer.print("{d}", .{asNumber(v)});
        if (isBool(v)) return writer.print("{}", .{asBool(v)});
        if (isNil(v)) return writer.writeAll("nil");

        switch (asObj(v).kind) {
            .str => {
                const string = asString(v);
                const preview_length = @min(string.chars.len, DEBUG_STRING_LIMIT);
                const preview = string.chars[0..preview_length];
                const ellipsis: []const u8 = if (preview_length < string.chars.len) "..." else "";
                try writer.print("\"{f}\"{s}", .{ std.zig.fmtString(preview), ellipsis });
            },
            .closure => {
                const c = asClosure(v);
                if (std.mem.eql(u8, c.function.name.chars, "<script>")) {
                    try writer.print("<c script>", .{});
                } else {
                    try writer.print("<cl {s}>", .{c.function.name.chars});
                }
            },
            .function => {
                const f = asFunction(v);
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
                const items = asArray(v).values.items;
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
                            if (isArray(parent.?.value) and asArray(parent.?.value) == asArray(value)) {
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
            .class => try writer.print("<class {s}>", .{asClass(v).name.chars}),
            .instance => try writer.print("<{s} instance>", .{asInstance(v).class.name.chars}),
            .bound_method => {
                const method = asBoundMethod(v).method;
                if (isClosure(method)) {
                    try writer.print("<bound {s}>", .{asClosure(method).function.name.chars});
                } else {
                    try writer.writeAll("<bound native>");
                }
            },
            // Upvalues are never stored in a Value, only referenced from closures.
            .upvalue => unreachable,
        }
    }
};

pub fn format(v: Value) Formatter {
    return .{ .value = v };
}

pub fn write(v: Value, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (isNumber(v)) return writer.print("{d}", .{asNumber(v)});
    if (isBool(v)) return writer.print("{}", .{asBool(v)});
    if (isNil(v)) return writer.writeAll("nil");

    switch (asObj(v).kind) {
        .str => try writer.writeAll(asString(v).chars),
        .function => try writer.writeAll(asFunction(v).name.chars),
        .native => try writer.writeAll("<native_fn>"),
        .closure => try writer.writeAll(asClosure(v).function.name.chars),
        .array => try writer.print("{f}", .{Formatter{ .value = v }}),
        .class => try writer.writeAll(asClass(v).name.chars),
        .instance => try writer.print("{s} instance", .{asInstance(v).class.name.chars}),
        .bound_method => {
            const method = asBoundMethod(v).method;
            if (isClosure(method)) {
                try writer.writeAll(asClosure(method).function.name.chars);
            } else {
                try writer.writeAll("<native_fn>");
            }
        },
        .upvalue => unreachable,
    }
}

test "debug formatter escapes and truncates strings" {
    var short = ObjStr{
        .chars = "hello\nworld",
        .hash = 0,
    };
    try std.testing.expectFmt("\"hello\\nworld\"", "{f}", .{format(stringValue(&short))});

    var long = ObjStr{
        .chars = "1234567890123456789012345678901234567890tail",
        .hash = 0,
    };
    try std.testing.expectFmt(
        "\"1234567890123456789012345678901234567890\"...",
        "{f}",
        .{format(stringValue(&long))},
    );
}
