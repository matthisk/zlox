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
const UpvalueDescriptor = value_mod.UpvalueDescriptor;

const DEBUG_GC = config.debug_gc;
const INITIAL_GC_THRESHOLD = 1024 * 1024;

/// Object counts per kind, used by the `debug-gc` report.
const KindCounts = std.EnumArray(Obj.Kind, usize);

/// Aggregated numbers for the `debug-gc` report. Printing one line per
/// allocation floods the console, so we count instead and print a single
/// summary per collection.
const GcStats = struct {
    collections: usize = 0,
    /// Objects registered since the previous collection ended.
    allocated: KindCounts = .initFill(0),
    /// Objects freed by the current collection's sweep.
    freed: KindCounts = .initFill(0),
};

/// Owns heap allocated runtime objects and their linked list.
///
/// Each allocation embeds an Obj header for registration and destruction.
pub const Heap = struct {
    childAllocator: std.mem.Allocator, // We use this allocator to ensure we don't trigger garbage collection on grayStack allocations.
    trackingAllocator: *TrackingAllocator,
    allocator: std.mem.Allocator,
    objects: ?*Obj = null,
    strings: std.StringHashMap(*ObjStr),
    grayStack: std.ArrayList(*Obj),
    compiler: ?*Compiler = null,
    gcStats: GcStats = .{},
    /// Collect before every allocation. Tests use this to surface objects
    /// that aren't rooted while the VM allocates.
    stressGc: bool = false,

    pub fn init(childAllocator: std.mem.Allocator) !Heap {
        // Allocator interfaces point at their implementation state. Keeping
        // that state separately allocated lets Heap move without invalidating
        // the interface stored by objects and collections.
        const trackingAllocator = try childAllocator.create(TrackingAllocator);
        trackingAllocator.* = TrackingAllocator.init(childAllocator);
        trackingAllocator.threshold = INITIAL_GC_THRESHOLD;
        const allocator = trackingAllocator.allocator();

        return .{
            .childAllocator = childAllocator,
            .trackingAllocator = trackingAllocator,
            .allocator = allocator,
            .strings = std.StringHashMap(*ObjStr).init(allocator),
            .grayStack = .empty,
        };
    }

    /// Let the tracking allocator run a collection before an allocation
    /// crosses the threshold.
    ///
    /// The hook stores a pointer to this heap, so call this only once the
    /// heap (and the VM that contains it) is at its final address. `Heap.init`
    /// returns by value, so `VM.init` calls this after the heap is in place.
    pub fn enableGarbageCollection(self: *Heap) void {
        self.trackingAllocator.onThresholdReached = .{
            .context = self,
            .call = collectGarbageHook,
        };
    }

    fn collectGarbageHook(context: *anyopaque) void {
        const self: *Heap = @ptrCast(@alignCast(context));
        const vm: *VM = @fieldParentPtr("heap", self);
        // The allocator interface can't return this error. Skipping the
        // collection is safe: the allocation goes ahead and the heap grows.
        self.collectGarbage(vm) catch {};
    }

    pub fn isGarbageCollectionEnabled(self: *const Heap) bool {
        return self.trackingAllocator.onThresholdReached != null;
    }

    pub fn shouldCollectGarbage(self: *const Heap) bool {
        return self.trackingAllocator.bytesAllocated > self.trackingAllocator.threshold;
    }

    /// Core garbage collection loop.
    pub fn collectGarbage(self: *Heap, vm: *VM) !void {
        const bytesBefore = self.trackingAllocator.bytesAllocated;

        try self.markRoots(vm);
        try self.markObj(&vm.initString.obj);
        try self.markObj(&vm.arrayClass.obj);
        try self.traceReferences();
        self.removeWhiteInternedStrings();
        self.sweep();
        self.trackingAllocator.threshold = if (self.stressGc)
            0
        else
            @max(std.math.mul(usize, self.trackingAllocator.bytesAllocated, 2) catch std.math.maxInt(usize), INITIAL_GC_THRESHOLD);

        if (comptime DEBUG_GC) {
            self.printGcReport(bytesBefore);
        }
    }

    /// Print one summary block for the collection that just finished.
    fn printGcReport(self: *Heap, bytesBefore: usize) void {
        const stats = &self.gcStats;
        stats.collections += 1;

        // After the sweep every object left in the list survived.
        var live: KindCounts = .initFill(0);
        var liveBytes: KindCounts = .initFill(0);
        var objectBytesTotal: usize = 0;
        var object = self.objects;
        while (object) |current| : (object = current.next) {
            const bytes = objectBytes(current);
            live.getPtr(current.kind).* += 1;
            liveBytes.getPtr(current.kind).* += bytes;
            objectBytesTotal += bytes;
        }

        const bytesAfter = self.trackingAllocator.bytesAllocated;
        const bytesFreed = bytesBefore -| bytesAfter;
        const percentFreed = if (bytesBefore == 0) 0 else @as(f64, @floatFromInt(bytesFreed)) * 100 / @as(f64, @floatFromInt(bytesBefore));

        std.debug.print("\n== gc #{d} ==========================================\n", .{stats.collections});
        std.debug.print("  heap before: {Bi:.1}\n", .{bytesBefore});
        std.debug.print("  freed:       {Bi:.1} ({d:.0}%)\n", .{ bytesFreed, percentFreed });
        std.debug.print("  heap after:  {Bi:.1}\n", .{bytesAfter});
        std.debug.print("  next gc at:  {Bi:.1}\n\n", .{self.trackingAllocator.threshold});
        std.debug.print("  {s:<14}{s:>12}{s:>12}{s:>12}{s:>14}\n", .{ "objects", "allocated", "freed", "live", "live bytes" });
        for (std.enums.values(Obj.Kind)) |kind| {
            const allocated = stats.allocated.get(kind);
            const freed = stats.freed.get(kind);
            if (allocated == 0 and freed == 0 and live.get(kind) == 0) continue;
            std.debug.print("  {s:<14}{d:>12}{d:>12}{d:>12}{Bi:>14.1}\n", .{ @tagName(kind), allocated, freed, live.get(kind), liveBytes.get(kind) });
        }
        // Memory the heap's allocator handed out that no object owns, such
        // as the string intern table.
        std.debug.print("  {s:<50}{Bi:>14.1}\n", .{ "not owned by an object (e.g. intern table)", bytesAfter -| objectBytesTotal });
        std.debug.print("====================================================\n\n", .{});

        stats.allocated = .initFill(0);
        stats.freed = .initFill(0);
    }

    /// Bytes an object owns: its own struct plus the buffers it points to.
    /// Used only by the `debug-gc` report.
    fn objectBytes(obj: *Obj) usize {
        const value = Value.fromObj(obj);
        return switch (obj.kind) {
            .str => @sizeOf(ObjStr) + value.as(ObjStr).chars.len,
            .function => blk: {
                const function = value.as(ObjFunction);
                break :blk @sizeOf(ObjFunction) +
                    function.chunk.code.capacity * @sizeOf(u8) +
                    function.chunk.data.capacity * @sizeOf(Value) +
                    function.chunk.lines.capacity * @sizeOf(usize) +
                    function.upvalues.len * @sizeOf(UpvalueDescriptor);
            },
            .native => @sizeOf(ObjNative),
            .closure => @sizeOf(ObjClosure) + value.as(ObjClosure).upvalues.len * @sizeOf(*ObjUpvalue),
            .upvalue => @sizeOf(ObjUpvalue),
            // Capacity, not length: the ArrayList reserves room to grow.
            .array => @sizeOf(ObjArray) + value.as(ObjArray).values.capacity * @sizeOf(Value),
            .class => @sizeOf(ObjClass) + hashMapBytes(value.as(ObjClass).methods),
            .instance => @sizeOf(ObjInstance) + hashMapBytes(value.as(ObjInstance).fields),
            .bound_method => @sizeOf(ObjBoundMethod),
        };
    }

    /// Approximate: each slot holds one metadata byte, a key and a value.
    /// The real allocation also has a small header and alignment padding.
    fn hashMapBytes(map: HashMap) usize {
        return map.capacity() * (1 + @sizeOf(*ObjStr) + @sizeOf(Value));
    }

    pub fn removeWhiteInternedStrings(self: *Heap) void {
        var object = self.objects;
        while (object) |current| : (object = current.next) {
            if (current.kind == .str and !current.marked) {
                _ = self.strings.remove(Value.fromObj(current).as(ObjStr).chars);
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

                if (comptime DEBUG_GC) self.gcStats.freed.getPtr(unreached.?.kind).* += 1;
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
        switch (obj.kind) {
            .function => {
                const function = Value.fromObj(obj).as(ObjFunction);
                try self.markObj(&function.name.obj);
                for (function.chunk.data.items) |constant| {
                    try self.markValue(constant);
                }
            },
            .closure => {
                const closure = Value.fromObj(obj).as(ObjClosure);
                try self.markObj(&closure.function.obj);
                for (closure.upvalues[0..closure.initializedUpvalueCount]) |upvalue| {
                    try self.markObj(&upvalue.obj);
                }
            },
            .upvalue => {
                const upvalue = Value.fromObj(obj).as(ObjUpvalue);
                try self.markValue(upvalue.closed);
            },
            .array => {
                const array = Value.fromObj(obj).as(ObjArray);
                for (array.values.items) |value| {
                    try self.markValue(value);
                }
            },
            .class => {
                const class = Value.fromObj(obj).as(ObjClass);
                try self.markObj(&class.name.obj);
                var it = class.methods.iterator();
                while (it.next()) |entry| {
                    try self.markObj(&entry.key_ptr.*.obj);
                    try self.markValue(entry.value_ptr.*);
                }
            },
            .instance => {
                const instance = Value.fromObj(obj).as(ObjInstance);
                try self.markObj(&instance.class.obj);
                var fields = instance.fields.iterator();
                while (fields.next()) |entry| {
                    try self.markObj(&entry.key_ptr.*.obj);
                    try self.markValue(entry.value_ptr.*);
                }
            },
            .bound_method => {
                const bound = Value.fromObj(obj).as(ObjBoundMethod);
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

        obj.mark();
        try self.grayStack.append(self.childAllocator, obj);
    }

    /// Register an already allocated object with this heap.
    pub fn register(self: *Heap, object: *Obj) void {
        object.next = self.objects;
        self.objects = object;
        if (comptime DEBUG_GC) self.gcStats.allocated.getPtr(object.kind).* += 1;
    }

    pub fn createArray(self: *Heap, len: usize) !*ObjArray {
        const array = try self.allocator.create(ObjArray);
        errdefer self.allocator.destroy(array);
        array.* = .{};
        try array.values.ensureTotalCapacity(self.allocator, len);
        errdefer array.values.deinit(self.allocator);

        self.register(&array.obj);

        return array;
    }

    /// The name must remain alive for the lifetime of the class.
    pub fn createClass(self: *Heap, name: *ObjStr) !*ObjClass {
        const class = try self.allocator.create(ObjClass);
        errdefer self.allocator.destroy(class);
        const methods = HashMap.init(self.allocator);
        errdefer methods.deinit();

        class.* = .{ .name = name, .methods = methods };

        self.register(&class.obj);

        return class;
    }

    /// The class must remain alive for the lifetime of the instance.
    pub fn createInstance(self: *Heap, class: *ObjClass) !*ObjInstance {
        const instance = try self.allocator.create(ObjInstance);
        instance.* = .{
            .class = class,
            .fields = HashMap.init(self.allocator),
        };

        self.register(&instance.obj);

        return instance;
    }

    /// The receiver and the method must remain alive for the lifetime of the
    /// bound method.
    pub fn createBoundMethod(self: *Heap, receiver: Value, method: Value) !*ObjBoundMethod {
        const bound = try self.allocator.create(ObjBoundMethod);
        bound.* = .{ .receiver = receiver, .method = method };

        self.register(&bound.obj);

        return bound;
    }

    /// The name must remain alive for the lifetime of the function.
    pub fn createFunction(self: *Heap, name: *ObjStr) !*ObjFunction {
        const function = try ObjFunction.create(self.allocator);
        errdefer function.destroy(self.allocator);
        function.name = name;
        function.arity = 0;

        self.register(&function.obj);

        return function;
    }

    pub fn createNative(self: *Heap, arity: u8, fun: value_mod.NativeFn) !*ObjNative {
        const native = try self.allocator.create(ObjNative);
        errdefer self.allocator.destroy(native);
        native.* = .{ .function = fun, .arity = arity };

        self.register(&native.obj);

        return native;
    }

    pub fn createClosure(self: *Heap, fun: *ObjFunction) !*ObjClosure {
        const closure = try self.allocator.create(ObjClosure);
        errdefer self.allocator.destroy(closure);
        closure.* = .{
            .function = fun,
            .upvalues = try self.allocator.alloc(*ObjUpvalue, fun.upvalueCount),
            .initializedUpvalueCount = 0,
        };
        errdefer self.allocator.free(closure.upvalues);

        self.register(&closure.obj);
        return closure;
    }

    pub fn createUpvalue(self: *Heap, value: *Value) !*ObjUpvalue {
        const upvalue = try self.allocator.create(ObjUpvalue);
        errdefer self.allocator.destroy(upvalue);
        upvalue.* = .{ .location = value };
        self.register(&upvalue.obj);

        return upvalue;
    }

    /// Return an interned string, copying `chars` into heap-owned storage when
    /// it is not already present.
    pub fn copyString(self: *Heap, chars: []const u8) !*ObjStr {
        if (self.strings.get(chars)) |interned| return interned;

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

        return object;
    }

    pub fn deinit(self: *Heap) void {
        self.strings.deinit();
        self.grayStack.deinit(self.childAllocator);
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
