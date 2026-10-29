const std = @import("std");
const value_mod = @import("value.zig");

const Value = value_mod.Value;
const Obj = value_mod.Obj;
const ObjData = value_mod.ObjData;
const ObjFunction = value_mod.ObjFunction;
const ObjNative = value_mod.ObjNative;
const ObjClosure = value_mod.ObjClosure;
const ObjUpvalue = value_mod.ObjUpvalue;
const ObjStr = value_mod.ObjStr;

/// Owns heap allocated runtime objects and their linked list.
///
/// The current object representation keeps the list link on `Obj`. As object
/// kinds move to an intrusive header, `register` remains the single place
/// responsible for linking allocations into the heap.
pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: ?*Obj = null,
    strings: std.StringHashMap(*Obj),

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{
            .allocator = allocator,
            .strings = std.StringHashMap(*Obj).init(allocator),
        };
    }

    /// Register an already allocated object with this heap.
    pub fn register(self: *Heap, object: *Obj) void {
        object.next = self.objects;
        self.objects = object;
    }

    /// Allocate and register an object using the heap's allocator.
    pub fn createObject(self: *Heap, data: ObjData) !*Obj {
        const object = try self.allocator.create(Obj);
        object.* = .{ .next = null, .data = data };
        self.register(object);

        switch (data) {
            .closure => |c| c.obj = object,
            .function => |f| f.obj = object,
            .native => |n| n.obj = object,
            .upvalue => |u| u.obj = object,
            else => {},
        }

        return object;
    }

    /// Allocate a function and return its registered heap object.
    ///
    /// `name` remains caller-owned in the current object model; callers must
    /// keep it alive for as long as the function is used. The compiler's
    /// existing name allocation is still separate and will be folded into
    /// heap ownership as the object representation is migrated.
    pub fn createFunction(self: *Heap, name: *ObjStr) !*Obj {
        const function = try ObjFunction.create(self.allocator);
        errdefer function.destroy(self.allocator);
        function.name = name;
        function.arity = 0;

        return try self.createObject(.{ .function = function });
    }

    pub fn createNative(self: *Heap, arity: u8, fun: value_mod.NativeFn) !*Obj {
        const native = try self.allocator.create(ObjNative);
        errdefer self.allocator.destroy(native);
        native.function = fun;
        native.arity = arity;

        return try self.createObject(.{ .native = native });
    }

    pub fn createClosure(self: *Heap, fun: *ObjFunction) !*Obj {
        const closure = try self.allocator.create(ObjClosure);
        errdefer self.allocator.destroy(closure);
        closure.function = fun;
        closure.upvalues = try self.allocator.alloc(*ObjUpvalue, fun.upvalueCount);
        errdefer self.allocator.free(closure.upvalues);

        return try self.createObject(.{ .closure = closure });
    }

    pub fn createUpvalue(self: *Heap, value: *Value) !*ObjUpvalue {
        const upvalue = try self.allocator.create(ObjUpvalue);
        errdefer self.allocator.destroy(upvalue);
        upvalue.location = value;
        upvalue.next = null;
        upvalue.closed = .nil;
        upvalue.obj = null;

        return upvalue;
    }

    /// Return an interned string, copying `chars` into heap-owned storage when
    /// it is not already present.
    pub fn copyString(self: *Heap, chars: []const u8) !*Obj {
        if (self.strings.get(chars)) |interned| return interned;

        const owned_chars = try self.allocator.dupe(u8, chars);
        return self.takeString(owned_chars);
    }

    /// Return an interned string, adopting the caller's allocator-owned buffer.
    /// Ownership transfers on entry: the buffer is freed on a duplicate or
    /// any error, and is otherwise released by `deinit`.
    pub fn takeString(self: *Heap, chars: []u8) !*Obj {
        if (self.strings.get(chars)) |interned| {
            self.allocator.free(chars);
            return interned;
        }

        const object = self.allocator.create(Obj) catch |err| {
            self.allocator.free(chars);
            return err;
        };
        object.* = .{
            .next = null,
            .data = .{ .str = .{ .owner = true, .chars = chars } },
        };
        errdefer object.destroy(self.allocator);

        try self.strings.put(chars, object);
        self.register(object);
        return object;
    }

    pub fn deinit(self: *Heap) void {
        self.strings.deinit();
        var object = self.objects;
        while (object) |current| {
            const next = current.next;
            current.destroy(self.allocator);
            object = next;
        }
        self.objects = null;
    }
};

test "heap registers and destroys allocated objects" {
    var heap = Heap.init(std.testing.allocator);
    const object = try heap.createObject(.{ .str = .{ .owner = false, .chars = "test" } });
    try std.testing.expect(heap.objects == object);
    try std.testing.expect(object.next == null);
    heap.deinit();
    try std.testing.expect(heap.objects == null);
}

test "heap creates and owns function objects" {
    var heap = Heap.init(std.testing.allocator);
    var name = ObjStr{ .owner = false, .chars = "<script>" };
    const object = try heap.createFunction(&name);
    const function = object.data.function;

    try std.testing.expectEqual(@as(usize, 0), function.arity);
    try std.testing.expectEqualStrings("<script>", function.name.chars);
    try std.testing.expect(heap.objects.? == object);
    heap.deinit();
    try std.testing.expect(heap.objects == null);
}

test "heap copies and interns strings" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const first = try heap.copyString("hello");
    const second = try heap.copyString("hello");
    try std.testing.expect(first == second);
    try std.testing.expectEqualStrings("hello", first.data.str.chars);
    try std.testing.expect(first.data.str.owner);
}

test "heap adopts strings and frees duplicate buffers" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const adopted_chars = try std.testing.allocator.dupe(u8, "owned");
    const adopted = try heap.takeString(adopted_chars);
    try std.testing.expectEqualStrings("owned", adopted.data.str.chars);
    try std.testing.expect(adopted.data.str.owner);

    const duplicate_chars = try std.testing.allocator.dupe(u8, "owned");
    const duplicate = try heap.takeString(duplicate_chars);
    try std.testing.expect(adopted == duplicate);
}
