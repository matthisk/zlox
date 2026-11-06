const std = @import("std");
const VM = @import("vm.zig").VM;
const Chunk = @import("chunk.zig").Chunk;

const DEBUG_STRING_LIMIT = 40;
const DEBUG_GC = @import("config").debug_gc;
const NAN_BOXING = @import("config").nan_boxing;

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

/// A Lox value. There are two interchangeable representations, picked at
/// compile time with `-Dnan-boxing`. Both only distinguish four cases:
/// number, bool, nil and obj. Which kind of object an obj is lives in
/// `Obj.kind`, so the object helpers (`from`, `is`, `as`) are shared.
pub const Value = if (NAN_BOXING) NanBoxed else Tagged;

/// Every value is packed into a single 64 bit word. Numbers are stored as
/// plain doubles. Everything else hides inside the unused bits of a quiet NaN:
///
///   nil/bool: QNAN | tag           (tag in the lowest two bits)
///   obj:      SIGN_BIT | QNAN | ptr (pointer in the lower 48 bits)
pub const NanBoxed = struct {
    bits: u64,

    const QNAN: u64 = 0x7ffc000000000000;
    const SIGN_BIT: u64 = 0x8000000000000000;

    const TAG_NIL = 1; // 01
    const TAG_FALSE = 2; // 10
    const TAG_TRUE = 3; // 11

    const NIL_BITS = QNAN | TAG_NIL;
    const FALSE_BITS = QNAN | TAG_FALSE;
    const TRUE_BITS = QNAN | TAG_TRUE;

    pub const nil: NanBoxed = .{ .bits = NIL_BITS };

    pub inline fn number(n: f64) NanBoxed {
        return .{ .bits = @bitCast(n) };
    }

    pub inline fn boolean(b: bool) NanBoxed {
        return .{ .bits = if (b) TRUE_BITS else FALSE_BITS };
    }

    pub inline fn fromObj(o: *Obj) NanBoxed {
        return .{ .bits = @intFromPtr(o) | SIGN_BIT | QNAN };
    }

    pub inline fn isNumber(v: NanBoxed) bool {
        return (v.bits & QNAN) != QNAN;
    }

    pub inline fn isBool(v: NanBoxed) bool {
        // FALSE_BITS and TRUE_BITS only differ in the lowest bit.
        return (v.bits | 1) == TRUE_BITS;
    }

    pub inline fn isNil(v: NanBoxed) bool {
        return v.bits == NIL_BITS;
    }

    pub inline fn isObj(v: NanBoxed) bool {
        return (v.bits & (SIGN_BIT | QNAN)) == (SIGN_BIT | QNAN);
    }

    pub inline fn asNumber(v: NanBoxed) f64 {
        return @bitCast(v.bits);
    }

    pub inline fn asBool(v: NanBoxed) bool {
        return v.bits == TRUE_BITS;
    }

    pub inline fn asObj(v: NanBoxed) *Obj {
        return @ptrFromInt(v.bits & ~(SIGN_BIT | QNAN));
    }

    pub const from = ObjMethods(NanBoxed).from;
    pub const is = ObjMethods(NanBoxed).is;
    pub const as = ObjMethods(NanBoxed).as;
};

/// The straightforward representation: a tagged union (16 bytes).
pub const Tagged = struct {
    raw: union(enum) {
        number: f64,
        bool: bool,
        nil: void,
        obj: *Obj,
    },

    pub const nil: Tagged = .{ .raw = .nil };

    pub inline fn number(n: f64) Tagged {
        return .{ .raw = .{ .number = n } };
    }

    pub inline fn boolean(b: bool) Tagged {
        return .{ .raw = .{ .bool = b } };
    }

    pub inline fn fromObj(o: *Obj) Tagged {
        return .{ .raw = .{ .obj = o } };
    }

    pub inline fn isNumber(v: Tagged) bool {
        return v.raw == .number;
    }

    pub inline fn isBool(v: Tagged) bool {
        return v.raw == .bool;
    }

    pub inline fn isNil(v: Tagged) bool {
        return v.raw == .nil;
    }

    pub inline fn isObj(v: Tagged) bool {
        return v.raw == .obj;
    }

    pub inline fn asNumber(v: Tagged) f64 {
        return v.raw.number;
    }

    pub inline fn asBool(v: Tagged) bool {
        return v.raw.bool;
    }

    pub inline fn asObj(v: Tagged) *Obj {
        return v.raw.obj;
    }

    pub const from = ObjMethods(Tagged).from;
    pub const is = ObjMethods(Tagged).is;
    pub const as = ObjMethods(Tagged).as;
};

/// Object helpers shared by both representations. They only rely on
/// `fromObj`, `isObj` and `asObj`, plus the `kind` declared on each object type.
fn ObjMethods(comptime V: type) type {
    return struct {
        /// Wrap a pointer to any object type, e.g. `Value.from(closure)`.
        pub inline fn from(ptr: anytype) V {
            return V.fromObj(&ptr.obj);
        }

        /// `v.is(ObjArray)` is true when `v` holds an array.
        pub inline fn is(v: V, comptime T: type) bool {
            return v.isObj() and v.asObj().kind == T.kind;
        }

        /// `v.as(ObjArray)` returns the array held by `v`.
        pub inline fn as(v: V, comptime T: type) *T {
            std.debug.assert(v.is(T));
            return @fieldParentPtr("obj", v.asObj());
        }
    };
}

pub const ObjArray = struct {
    pub const kind: Obj.Kind = .array;
    obj: Obj = .{ .kind = kind },
    values: std.ArrayList(Value) = .empty,
};

pub const ObjClass = struct {
    pub const kind: Obj.Kind = .class;
    obj: Obj = .{ .kind = kind },
    name: *ObjStr,
    /// Either an `ObjClosure` (methods written in Lox) or an `ObjNative` (methods written in Zig).
    methods: HashMap,
};

pub const ObjInstance = struct {
    pub const kind: Obj.Kind = .instance;
    obj: Obj = .{ .kind = kind },
    class: *ObjClass,
    fields: HashMap,
};

pub const ObjBoundMethod = struct {
    pub const kind: Obj.Kind = .bound_method;
    obj: Obj = .{ .kind = kind },
    receiver: Value,
    /// Either an `ObjClosure` or an `ObjNative`, see `ObjClass.methods`.
    method: Value,
};

pub const ObjClosure = struct {
    pub const kind: Obj.Kind = .closure;
    obj: Obj = .{ .kind = kind },
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
    pub const kind: Obj.Kind = .upvalue;
    obj: Obj = .{ .kind = kind },
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
    pub const kind: Obj.Kind = .function;
    obj: Obj = .{ .kind = kind },
    arity: usize,
    chunk: Chunk,
    upvalueCount: u8 = 0,
    /// One descriptor per upvalue, filled in by the compiler once the function body
    /// is compiled. These used to be encoded in the bytecode after OP_CLOSURE.
    upvalues: []UpvalueDescriptor = &.{},
    name: *ObjStr = undefined,

    pub fn create(allocator: std.mem.Allocator) !*ObjFunction {
        var objFn = try allocator.create(ObjFunction);
        objFn.obj = .{ .kind = kind };
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
    pub const kind: Obj.Kind = .native;
    obj: Obj = .{ .kind = kind },
    arity: usize,
    function: NativeFn,
};

// Obj: sizeOf = 16 bytes
pub const Obj = struct {
    next: ?*Obj = null,
    marked: bool = false,
    kind: Kind,

    pub const Kind = enum { str, function, native, closure, upvalue, array, class, instance, bound_method };

    pub fn as(self: *Obj, T: type) T {
        return @fieldParentPtr("obj", self);
    }

    pub fn mark(self: *Obj) void {
        self.marked = true;
    }

    pub fn format(self: *Obj, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self.kind) {
            .upvalue => {
                const u: *ObjUpvalue = @fieldParentPtr("obj", self);
                try writer.print("{f}", .{Formatter{ .value = u.closed }});
            },
            else => try writer.print("{f}", .{Formatter{ .value = .fromObj(self) }}),
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
    pub const kind: Obj.Kind = .str;
    obj: Obj = .{ .kind = kind },
    chars: []const u8,
    hash: u64, // pre computed hash.
};

pub const Formatter = struct {
    value: Value,
    enclosing: ?*const Formatter = null,

    pub fn format(self: Formatter, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const v = self.value;
        if (v.isNumber()) return writer.print("{d}", .{v.asNumber()});
        if (v.isBool()) return writer.print("{}", .{v.asBool()});
        if (v.isNil()) return writer.writeAll("nil");

        switch (v.asObj().kind) {
            .str => {
                const string = v.as(ObjStr);
                const preview_length = @min(string.chars.len, DEBUG_STRING_LIMIT);
                const preview = string.chars[0..preview_length];
                const ellipsis: []const u8 = if (preview_length < string.chars.len) "..." else "";
                try writer.print("\"{f}\"{s}", .{ std.zig.fmtString(preview), ellipsis });
            },
            .closure => {
                const c = v.as(ObjClosure);
                if (std.mem.eql(u8, c.function.name.chars, "<script>")) {
                    try writer.print("<c script>", .{});
                } else {
                    try writer.print("<cl {s}>", .{c.function.name.chars});
                }
            },
            .function => {
                const f = v.as(ObjFunction);
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
                const items = v.as(ObjArray).values.items;
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

                    const item = items[index];

                    // To prevent infinite recursion we need to check for cycles in an array.
                    // I.e. var a = [1]; a.push(a); should print [1, [...]]
                    if (item.is(ObjArray)) {
                        var parent = self.enclosing;
                        while (parent != null) {
                            if (parent.?.value.is(ObjArray) and parent.?.value.as(ObjArray) == item.as(ObjArray)) {
                                try writer.writeAll("[...]");
                                return;
                            }
                            parent = parent.?.enclosing;
                        }
                    }

                    try writer.print("{f}", .{Formatter{ .value = item, .enclosing = &self }});
                }

                try writer.writeAll("]");
            },
            .class => try writer.print("<class {s}>", .{v.as(ObjClass).name.chars}),
            .instance => try writer.print("<{s} instance>", .{v.as(ObjInstance).class.name.chars}),
            .bound_method => {
                const method = v.as(ObjBoundMethod).method;
                if (method.is(ObjClosure)) {
                    try writer.print("<bound {s}>", .{method.as(ObjClosure).function.name.chars});
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
    if (v.isNumber()) return writer.print("{d}", .{v.asNumber()});
    if (v.isBool()) return writer.print("{}", .{v.asBool()});
    if (v.isNil()) return writer.writeAll("nil");

    switch (v.asObj().kind) {
        .str => try writer.writeAll(v.as(ObjStr).chars),
        .function => try writer.writeAll(v.as(ObjFunction).name.chars),
        .native => try writer.writeAll("<native_fn>"),
        .closure => try writer.writeAll(v.as(ObjClosure).function.name.chars),
        .array => try writer.print("{f}", .{Formatter{ .value = v }}),
        .class => try writer.writeAll(v.as(ObjClass).name.chars),
        .instance => try writer.print("{s} instance", .{v.as(ObjInstance).class.name.chars}),
        .bound_method => {
            const method = v.as(ObjBoundMethod).method;
            if (method.is(ObjClosure)) {
                try writer.writeAll(method.as(ObjClosure).function.name.chars);
            } else {
                try writer.writeAll("<native_fn>");
            }
        },
        .upvalue => unreachable,
    }
}

// Both representations are always compiled, so they can be tested side by side
// no matter which one the build selected.
fn expectRepresentation(comptime V: type) !void {
    try std.testing.expect(V.nil.isNil());
    try std.testing.expect(!V.nil.isBool());
    try std.testing.expect(!V.nil.isNumber());
    try std.testing.expect(!V.nil.isObj());

    const t = V.boolean(true);
    const f = V.boolean(false);
    try std.testing.expect(t.isBool() and f.isBool());
    try std.testing.expect(t.asBool() and !f.asBool());
    try std.testing.expect(!t.isNil() and !t.isNumber() and !t.isObj());

    const n = V.number(-1.5);
    try std.testing.expect(n.isNumber());
    try std.testing.expectEqual(@as(f64, -1.5), n.asNumber());
    try std.testing.expect(!n.isBool() and !n.isNil() and !n.isObj());

    var s = ObjStr{ .chars = "hi", .hash = 0 };
    const sv = V.from(&s);
    try std.testing.expect(sv.isObj());
    try std.testing.expect(!sv.isNumber() and !sv.isBool() and !sv.isNil());
    try std.testing.expect(sv.is(ObjStr));
    try std.testing.expect(!sv.is(ObjArray));
    try std.testing.expectEqual(&s, sv.as(ObjStr));
}

test "nan boxed representation" {
    try expectRepresentation(NanBoxed);
}

test "tagged representation" {
    try expectRepresentation(Tagged);
}

test "debug formatter escapes and truncates strings" {
    var short = ObjStr{
        .chars = "hello\nworld",
        .hash = 0,
    };
    try std.testing.expectFmt("\"hello\\nworld\"", "{f}", .{format(.from(&short))});

    var long = ObjStr{
        .chars = "1234567890123456789012345678901234567890tail",
        .hash = 0,
    };
    try std.testing.expectFmt(
        "\"1234567890123456789012345678901234567890\"...",
        "{f}",
        .{format(.from(&long))},
    );
}
