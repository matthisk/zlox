const std = @import("std");
const config = @import("config");
const value_mod = @import("value.zig");
const VM = @import("vm.zig").VM;
const Compiler = @import("compiler.zig").Compiler;

const Value = value_mod.Value;
const Obj = value_mod.Obj;
const ObjFunction = value_mod.ObjFunction;
const ObjNative = value_mod.ObjNative;
const ObjClosure = value_mod.ObjClosure;
const ObjUpvalue = value_mod.ObjUpvalue;
const ObjStr = value_mod.ObjStr;

const DEBUG_GC = config.debug_gc;

/// Owns heap allocated runtime objects and their linked list.
///
/// Each allocation embeds an Obj header for registration and destruction.
pub const Heap = struct {
    allocator: std.mem.Allocator,
    objects: ?*Obj = null,
    strings: std.StringHashMap(*ObjStr),
    grayStack: std.ArrayList(*Obj),

    pub fn init(allocator: std.mem.Allocator) Heap {
        return .{
            .allocator = allocator,
            .strings = std.StringHashMap(*ObjStr).init(allocator),
            .grayStack = .empty,
        };
    }

    /// Core garbage collection loop.
    pub fn collectGarbage(self: *Heap, vm: *VM) !void {
        if (comptime DEBUG_GC) {
            std.debug.print("-- gc begin\n", .{});
        }

        try self.markRoots(vm);
        try self.traceReferences();
        self.sweep();

        if (comptime DEBUG_GC) {
            std.debug.print("-- gc end\n", .{});
        }
    }

    pub fn sweep(self: *Heap) void {
        var previous: ?*Obj = null;
        var object = self.objects;
        while (object != null) {
            if (object.?.marked) {
                object.?.marked = false;
                previous = object;
                object = object.?.next;
            } else {
                const unreached = object;
                object = object.?.next;

                if (previous == null) {
                    self.objects = object;
                } else {
                    previous.?.next = object;
                }

                unreached.?.destroy(self.allocator);
            }
        }
    }

    pub fn traceReferences(self: *Heap) !void {
        while (self.grayStack.pop()) |obj| {
            try self.blackenObj(obj);
        }
    }

    pub fn markRoots(self: *Heap, vm: *VM) !void {
        // 1) mark the stack
        for (0..vm.stack.len) |i| {
            try self.markValue(vm.stack.values[i]);
        }

        // 2) mark all globals
        var it = vm.globals.iterator();
        while (it.next()) |entry| {
            try self.markObj(&entry.key_ptr.*.obj);
            try self.markValue(entry.value_ptr.*);
        }

        // 3) mark active frames
        for (0..vm.frameCount) |i| {
            try self.markObj(&vm.frames[i].closure.obj);
        }

        // 4) mark open upvalues
        var upvalue = vm.openUpvalues;
        while (upvalue != null) {
            try self.markObj(&upvalue.?.obj);
            upvalue = upvalue.?.next;
        }

        // TODO: Currently there is no active compiler when GC runs.
        // 5) mark active compiler function objects
        // var currentCompiler = compiler;
        // while (currentCompiler != null) {
        //     self.markObj(currentCompiler.functionObject);
        //    currentCompiler = currentCompiler.enclosing;
        // }
    }

    pub fn blackenObj(self: *Heap, obj: *Obj) !void {
        if (comptime DEBUG_GC) {
            std.debug.print("{*} blacken {f}\n", .{ obj, obj });
        }

        switch (obj.kind) {
            .function => {
                const function: *ObjFunction = @fieldParentPtr("obj", obj);
                try self.markObj(&function.name.obj);
                for (function.chunk.data.items) |constant| {
                    try self.markValue(constant);
                }
            },
            .closure => {
                const closure: *ObjClosure = @fieldParentPtr("obj", obj);
                try self.markObj(&closure.function.obj);
                for (closure.upvalues) |upvalue| {
                    try self.markObj(&upvalue.obj);
                }
            },
            .upvalue => {
                const upvalue: *ObjUpvalue = @fieldParentPtr("obj", obj);
                try self.markValue(upvalue.closed);
            },
            else => {},
        }
    }

    pub fn markValue(self: *Heap, value: Value) !void {
        switch (value) {
            .function => |f| try self.markObj(&f.obj),
            .closure => |c| try self.markObj(&c.obj),
            .native => |n| try self.markObj(&n.obj),
            .string => |s| try self.markObj(&s.obj),
            else => {},
        }
    }

    pub fn markObj(self: *Heap, obj: *Obj) !void {
        if (obj.marked) return;

        if (comptime DEBUG_GC) {
            std.debug.print("{*} mark {f}\n", .{ obj, obj });
        }

        obj.mark();
        try self.grayStack.append(self.allocator, obj);
    }

    /// Register an already allocated object with this heap.
    pub fn register(self: *Heap, object: *Obj) void {
        object.next = self.objects;
        self.objects = object;
    }

    /// The name must remain alive for the lifetime of the function.
    pub fn createFunction(self: *Heap, name: *ObjStr) !*ObjFunction {
        const function = try ObjFunction.create(self.allocator);
        errdefer function.destroy(self.allocator);
        function.name = name;
        function.arity = 0;

        self.register(&function.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ function, @sizeOf(ObjFunction), "<function>" });
        }

        return function;
    }

    pub fn createNative(self: *Heap, arity: u8, fun: value_mod.NativeFn) !*ObjNative {
        const native = try self.allocator.create(ObjNative);
        errdefer self.allocator.destroy(native);
        native.* = .{ .function = fun, .arity = arity };

        self.register(&native.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ native, @sizeOf(ObjNative), "<native>" });
        }

        return native;
    }

    pub fn createClosure(self: *Heap, fun: *ObjFunction) !*ObjClosure {
        const closure = try self.allocator.create(ObjClosure);
        errdefer self.allocator.destroy(closure);
        closure.* = .{
            .function = fun,
            .upvalues = try self.allocator.alloc(*ObjUpvalue, fun.upvalueCount),
        };
        errdefer self.allocator.free(closure.upvalues);

        self.register(&closure.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ closure, @sizeOf(ObjClosure) + @sizeOf(*ObjUpvalue) * fun.upvalueCount, "<closure>" });
        }
        return closure;
    }

    pub fn createUpvalue(self: *Heap, value: *Value) !*ObjUpvalue {
        const upvalue = try self.allocator.create(ObjUpvalue);
        errdefer self.allocator.destroy(upvalue);
        upvalue.* = .{ .location = value };
        self.register(&upvalue.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ upvalue, @sizeOf(ObjUpvalue), "<upvalue>" });
        }

        return upvalue;
    }

    /// Return an interned string, copying `chars` into heap-owned storage when
    /// it is not already present.
    pub fn copyString(self: *Heap, chars: []const u8) !*ObjStr {
        if (self.strings.get(chars)) |interned| return interned;

        const owned_chars = try self.allocator.dupe(u8, chars);
        return self.takeString(owned_chars);
    }

    /// Return an interned string, adopting the caller's allocator-owned buffer.
    /// Ownership transfers on entry: the buffer is freed on a duplicate or
    /// any error, and is otherwise released by `deinit`.
    pub fn takeString(self: *Heap, chars: []u8) !*ObjStr {
        if (self.strings.get(chars)) |interned| {
            self.allocator.free(chars);
            return interned;
        }

        const object = self.allocator.create(ObjStr) catch |err| {
            self.allocator.free(chars);
            return err;
        };
        object.* = .{
            .chars = chars,
        };
        errdefer object.obj.destroy(self.allocator);

        try self.strings.put(chars, object);
        self.register(&object.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ object, @sizeOf(ObjStr) + @sizeOf(u8) * chars.len, "<str>" });
        }

        return object;
    }

    pub fn deinit(self: *Heap) void {
        self.strings.deinit();
        self.grayStack.deinit(self.allocator);
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
    const object = try heap.copyString("test");
    try std.testing.expect(heap.objects == &object.obj);
    try std.testing.expect(object.obj.next == null);
    heap.deinit();
    try std.testing.expect(heap.objects == null);
}

test "heap creates and owns function objects" {
    var heap = Heap.init(std.testing.allocator);
    var name = ObjStr{ .chars = "<script>" };
    const object = try heap.createFunction(&name);
    const function = object;

    try std.testing.expectEqual(@as(usize, 0), function.arity);
    try std.testing.expectEqualStrings("<script>", function.name.chars);
    try std.testing.expect(heap.objects.? == &object.obj);
    heap.deinit();
    try std.testing.expect(heap.objects == null);
}

test "heap copies and interns strings" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const first = try heap.copyString("hello");
    const second = try heap.copyString("hello");
    try std.testing.expect(first == second);
    try std.testing.expectEqualStrings("hello", first.chars);
}

test "heap adopts strings and frees duplicate buffers" {
    var heap = Heap.init(std.testing.allocator);
    defer heap.deinit();

    const adopted_chars = try std.testing.allocator.dupe(u8, "owned");
    const adopted = try heap.takeString(adopted_chars);
    try std.testing.expectEqualStrings("owned", adopted.chars);

    const duplicate_chars = try std.testing.allocator.dupe(u8, "owned");
    const duplicate = try heap.takeString(duplicate_chars);
    try std.testing.expect(adopted == duplicate);
}

fn exerciseObjectAllocations(allocator: std.mem.Allocator) !void {
    var heap = Heap.init(allocator);
    defer heap.deinit();

    const name = try heap.copyString("function");
    const function = try heap.createFunction(name);
    function.upvalueCount = 1;
    const closure = try heap.createClosure(function);
    var local: Value = .{ .number = 42 };
    const upvalue = try heap.createUpvalue(&local);
    closure.upvalues[0] = upvalue;
    const native = try heap.createNative(0, testNative);

    try std.testing.expect(heap.objects == &native.obj);
    try std.testing.expect(native.obj.next == &upvalue.obj);
    try std.testing.expect(upvalue.obj.next == &closure.obj);
    try std.testing.expect(closure.obj.next == &function.obj);
    try std.testing.expect(function.obj.next == &name.obj);
    try std.testing.expect(closure.upvalues[0].location == &local);
}

fn testNative(_: *@import("vm.zig").VM, _: usize, _: []const Value) !Value {
    return .nil;
}

test "heap owns every object kind including on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseObjectAllocations, .{});
}
