const std = @import("std");
const config = @import("config");
const value_mod = @import("value.zig");
const VM = @import("vm.zig").VM;
const Compiler = @import("compiler.zig").Compiler;
const TrackingAllocator = @import("tracking_allocator.zig").TrackingAllocator;

const Value = value_mod.Value;
const HashMap = value_mod.HashMap;
const Obj = value_mod.Obj;
const ObjFunction = value_mod.ObjFunction;
const ObjNative = value_mod.ObjNative;
const ObjClosure = value_mod.ObjClosure;
const ObjUpvalue = value_mod.ObjUpvalue;
const ObjStr = value_mod.ObjStr;
const ObjArray = value_mod.ObjArray;
const ObjClass = value_mod.ObjClass;
const ObjInstance = value_mod.ObjInstance;
const ObjBoundMethod = value_mod.ObjBoundMethod;

const DEBUG_GC = config.debug_gc;
const INITIAL_GC_THRESHOLD = 1024 * 1024;

/// Owns heap allocated runtime objects and their linked list.
///
/// Each allocation embeds an Obj header for registration and destruction.
pub const Heap = struct {
    trackingAllocator: *TrackingAllocator,
    allocator: std.mem.Allocator,
    objects: ?*Obj = null,
    strings: std.StringHashMap(*ObjStr),
    grayStack: std.ArrayList(*Obj),
    nextGC: usize = INITIAL_GC_THRESHOLD,
    compiler: ?*Compiler = null,
    garbageCollectionEnabled: bool = false,

    pub fn init(childAllocator: std.mem.Allocator) !Heap {
        // Allocator interfaces point at their implementation state. Keeping
        // that state separately allocated lets Heap move without invalidating
        // the interface stored by objects and collections.
        const trackingAllocator = try childAllocator.create(TrackingAllocator);
        trackingAllocator.* = TrackingAllocator.init(childAllocator);
        const allocator = trackingAllocator.allocator();

        return .{
            .trackingAllocator = trackingAllocator,
            .allocator = allocator,
            .strings = std.StringHashMap(*ObjStr).init(allocator),
            .grayStack = .empty,
        };
    }

    pub fn shouldCollectGarbage(self: *const Heap) bool {
        return self.trackingAllocator.bytesAllocated > self.nextGC;
    }

    pub fn checkAndCollect(self: *Heap) !void {
        // TODO: Now we collect once the heap is already larger than nextGC.
        // Instead we should collect when the upcoming allocation would surpass the max heap threshold.
        if (self.garbageCollectionEnabled and self.shouldCollectGarbage()) {
            const vm: *VM = @fieldParentPtr("heap", self);
            try self.collectGarbage(vm);
        }
    }

    /// Core garbage collection loop.
    pub fn collectGarbage(self: *Heap, vm: *VM) !void {
        const bytesBefore = self.trackingAllocator.bytesAllocated;

        if (comptime DEBUG_GC) {
            std.debug.print("-- gc begin\n", .{});
        }

        try self.markRoots(vm);
        try self.markObj(&vm.initString.obj);
        try self.markObj(&vm.arrayClass.obj);
        try self.traceReferences();
        self.removeWhiteInternedStrings();
        self.sweep();
        self.nextGC = std.math.mul(usize, self.trackingAllocator.bytesAllocated, 2) catch std.math.maxInt(usize);

        if (comptime DEBUG_GC) {
            const bytesAfter = self.trackingAllocator.bytesAllocated;
            const bytesFreed = bytesBefore -| bytesAfter;
            const bytesUntilNextGC = self.nextGC -| bytesAfter;
            std.debug.print("-- gc end: freed {d} bytes, {d} bytes until next collection\n", .{ bytesFreed, bytesUntilNextGC });
        }
    }

    pub fn removeWhiteInternedStrings(self: *Heap) void {
        var object = self.objects;
        while (object) |current| : (object = current.next) {
            if (current.kind == .str and !current.marked) {
                const string: *ObjStr = @fieldParentPtr("obj", current);
                _ = self.strings.remove(string.chars);
            }
        }

        // Removing entries leaves tombstones behind. Lookups for strings that
        // are not interned yet must probe past them, so without a rehash every
        // concatenation gets slower after each collection.
        self.strings.rehash();
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

        // 5) mark active compiler function objects
        var compiler = self.compiler;
        while (compiler) |current| {
            try self.markObj(&current.functionObject.obj);
            compiler = current.enclosing;
        }
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
                for (closure.upvalues[0..closure.initializedUpvalueCount]) |upvalue| {
                    try self.markObj(&upvalue.obj);
                }
            },
            .upvalue => {
                const upvalue: *ObjUpvalue = @fieldParentPtr("obj", obj);
                try self.markValue(upvalue.closed);
            },
            .array => {
                const array: *ObjArray = @fieldParentPtr("obj", obj);
                for (array.values.items) |value| {
                    try self.markValue(value);
                }
            },
            .class => {
                const class: *ObjClass = @fieldParentPtr("obj", obj);
                try self.markObj(&class.name.obj);
                var it = class.methods.iterator();
                while (it.next()) |entry| {
                    try self.markObj(&entry.key_ptr.*.obj);
                    try self.markValue(entry.value_ptr.*);
                }
            },
            .instance => {
                const instance: *ObjInstance = @fieldParentPtr("obj", obj);
                try self.markObj(&instance.class.obj);
                var fields = instance.fields.iterator();
                while (fields.next()) |entry| {
                    try self.markObj(&entry.key_ptr.*.obj);
                    try self.markValue(entry.value_ptr.*);
                }
            },
            .bound_method => {
                const bound: *ObjBoundMethod = @fieldParentPtr("obj", obj);
                try self.markValue(bound.receiver);
                try self.markValue(bound.method);
            },
            else => {},
        }
    }

    pub fn markValue(self: *Heap, value: Value) !void {
        if (value.isObj()) {
            try self.markObj(value.asObj());
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

    pub fn createArray(self: *Heap, len: usize) !*ObjArray {
        try self.checkAndCollect();

        const array = try self.allocator.create(ObjArray);
        errdefer self.allocator.destroy(array);
        array.* = .{};
        try array.values.ensureTotalCapacity(self.allocator, len);
        errdefer array.values.deinit(self.allocator);

        self.register(&array.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ array, @sizeOf(ObjArray) + @sizeOf(Value) * len, "<array>" });
        }

        return array;
    }

    /// The name must remain alive for the lifetime of the class.
    pub fn createClass(self: *Heap, name: *ObjStr) !*ObjClass {
        try self.checkAndCollect();

        const class = try self.allocator.create(ObjClass);
        errdefer self.allocator.destroy(class);
        const methods = HashMap.init(self.allocator);
        errdefer methods.deinit();

        class.* = .{ .name = name, .methods = methods };

        self.register(&class.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ class, @sizeOf(ObjClass), "<class>" });
        }

        return class;
    }

    /// The class must remain alive for the lifetime of the instance.
    pub fn createInstance(self: *Heap, class: *ObjClass) !*ObjInstance {
        try self.checkAndCollect();

        const instance = try self.allocator.create(ObjInstance);
        instance.* = .{
            .class = class,
            .fields = HashMap.init(self.allocator),
        };

        self.register(&instance.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ instance, @sizeOf(ObjInstance), "<instance>" });
        }

        return instance;
    }

    /// The receiver and the method must remain alive for the lifetime of the
    /// bound method.
    pub fn createBoundMethod(self: *Heap, receiver: Value, method: Value) !*ObjBoundMethod {
        try self.checkAndCollect();

        const bound = try self.allocator.create(ObjBoundMethod);
        bound.* = .{ .receiver = receiver, .method = method };

        self.register(&bound.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ bound, @sizeOf(ObjBoundMethod), "<bound method>" });
        }

        return bound;
    }

    /// The name must remain alive for the lifetime of the function.
    pub fn createFunction(self: *Heap, name: *ObjStr) !*ObjFunction {
        try self.checkAndCollect();

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
        try self.checkAndCollect();

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
        try self.checkAndCollect();

        const closure = try self.allocator.create(ObjClosure);
        errdefer self.allocator.destroy(closure);
        closure.* = .{
            .function = fun,
            .upvalues = try self.allocator.alloc(*ObjUpvalue, fun.upvalueCount),
            .initializedUpvalueCount = 0,
        };
        errdefer self.allocator.free(closure.upvalues);

        self.register(&closure.obj);

        if (comptime DEBUG_GC) {
            std.debug.print("{*} allocate {d} for {s}\n", .{ closure, @sizeOf(ObjClosure) + @sizeOf(*ObjUpvalue) * fun.upvalueCount, "<closure>" });
        }
        return closure;
    }

    pub fn createUpvalue(self: *Heap, value: *Value) !*ObjUpvalue {
        try self.checkAndCollect();

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
        try self.checkAndCollect();

        const owned_chars = try self.allocator.dupe(u8, chars);
        return self.takeString(owned_chars);
    }

    /// Return an interned string, adopting a buffer owned by this heap's allocator.
    /// Ownership transfers on entry: the buffer is freed on a duplicate or
    /// any error, and is otherwise released by `deinit`.
    pub fn takeString(self: *Heap, chars: []u8) !*ObjStr {
        if (self.strings.get(chars)) |interned| {
            self.allocator.free(chars);
            return interned;
        }

        try self.checkAndCollect();
        const object = self.allocator.create(ObjStr) catch |err| {
            self.allocator.free(chars);
            return err;
        };
        object.* = .{
            .chars = chars,
            .hash = std.hash.Wyhash.hash(0, chars),
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

        const childAllocator = self.trackingAllocator.childAllocator;
        childAllocator.destroy(self.trackingAllocator);
    }
};

test "heap registers and destroys allocated objects" {
    var heap = try Heap.init(std.testing.allocator);
    const object = try heap.copyString("test");
    try std.testing.expect(heap.objects == &object.obj);
    try std.testing.expect(object.obj.next == null);
    heap.deinit();
    try std.testing.expect(heap.objects == null);
}

test "heap creates and owns function objects" {
    var heap = try Heap.init(std.testing.allocator);
    var name = ObjStr{ .chars = "<script>", .hash = 0 };
    const object = try heap.createFunction(&name);
    const function = object;

    try std.testing.expectEqual(@as(usize, 0), function.arity);
    try std.testing.expectEqualStrings("<script>", function.name.chars);
    try std.testing.expect(heap.objects.? == &object.obj);
    heap.deinit();
    try std.testing.expect(heap.objects == null);
}

test "heap copies and interns strings" {
    var heap = try Heap.init(std.testing.allocator);
    defer heap.deinit();

    const first = try heap.copyString("hello");
    const second = try heap.copyString("hello");
    try std.testing.expect(first == second);
    try std.testing.expectEqualStrings("hello", first.chars);
}

test "heap adopts strings and frees duplicate buffers" {
    var heap = try Heap.init(std.testing.allocator);
    defer heap.deinit();

    const adopted_chars = try heap.allocator.dupe(u8, "owned");
    const adopted = try heap.takeString(adopted_chars);
    try std.testing.expectEqualStrings("owned", adopted.chars);

    const duplicate_chars = try heap.allocator.dupe(u8, "owned");
    const duplicate = try heap.takeString(duplicate_chars);
    try std.testing.expect(adopted == duplicate);
}

fn exerciseObjectAllocations(allocator: std.mem.Allocator) !void {
    var heap = try Heap.init(allocator);
    defer heap.deinit();

    const name = try heap.copyString("function");
    const function = try heap.createFunction(name);
    function.upvalueCount = 1;
    const closure = try heap.createClosure(function);
    var local: Value = Value.number(42);
    const upvalue = try heap.createUpvalue(&local);
    closure.setUpvalue(0, upvalue);
    const native = try heap.createNative(0, testNative);
    const className = try heap.copyString("Class");
    const class = try heap.createClass(className);
    const instance = try heap.createInstance(class);
    const fieldName = try heap.copyString("field");
    try instance.fields.put(fieldName, Value.number(42));
    const bound = try heap.createBoundMethod(Value.from(instance), Value.from(closure));

    try std.testing.expect(heap.objects == &bound.obj);
    try std.testing.expect(bound.obj.next == &fieldName.obj);
    try std.testing.expect(fieldName.obj.next == &instance.obj);
    try std.testing.expect(instance.obj.next == &class.obj);
    try std.testing.expect(class.obj.next == &className.obj);
    try std.testing.expect(className.obj.next == &native.obj);
    try std.testing.expect(native.obj.next == &upvalue.obj);
    try std.testing.expect(upvalue.obj.next == &closure.obj);
    try std.testing.expect(closure.obj.next == &function.obj);
    try std.testing.expect(function.obj.next == &name.obj);
    try std.testing.expect(closure.upvalues[0].location == &local);
    try std.testing.expectEqual(@as(f64, 42), instance.fields.get(fieldName).?.asNumber());
    try std.testing.expect(bound.method.as(ObjClosure) == closure);
    try std.testing.expect(bound.receiver.as(ObjInstance) == instance);
}

test "instance keeps its class and fields reachable" {
    var heap = try Heap.init(std.testing.allocator);
    defer heap.deinit();

    const className = try heap.copyString("Bag");
    const class = try heap.createClass(className);
    const instance = try heap.createInstance(class);
    const fieldName = try heap.copyString("contents");
    const fieldValue = try heap.copyString("value");
    try instance.fields.put(fieldName, Value.from(fieldValue));

    try heap.markObj(&instance.obj);
    try heap.traceReferences();

    try std.testing.expect(class.obj.marked);
    try std.testing.expect(className.obj.marked);
    try std.testing.expect(fieldName.obj.marked);
    try std.testing.expect(fieldValue.obj.marked);
}

test "bound method keeps its receiver and method reachable" {
    var heap = try Heap.init(std.testing.allocator);
    defer heap.deinit();

    const className = try heap.copyString("Bag");
    const class = try heap.createClass(className);
    const instance = try heap.createInstance(class);
    const functionName = try heap.copyString("get");
    const function = try heap.createFunction(functionName);
    const closure = try heap.createClosure(function);
    const bound = try heap.createBoundMethod(Value.from(instance), Value.from(closure));

    try heap.markObj(&bound.obj);
    try heap.traceReferences();

    try std.testing.expect(instance.obj.marked);
    try std.testing.expect(class.obj.marked);
    try std.testing.expect(closure.obj.marked);
    try std.testing.expect(function.obj.marked);
    try std.testing.expect(functionName.obj.marked);
}

fn testNative(_: *@import("vm.zig").VM, _: usize, _: []const Value) !Value {
    return Value.nil;
}

test "heap owns every object kind including on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseObjectAllocations, .{});
}
