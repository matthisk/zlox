const std = @import("std");
const VM = @import("vm.zig").VM;

pub const Value = union(enum) {
    bool: bool,
    number: f64,
    nil: void,
    obj: *Obj,
};

pub const Obj = struct {
    next: ?*Obj,
    data: ObjData,

    pub fn destroy(self: *Obj, allocator: std.mem.Allocator) void {
        switch (self.data) {
            .str => |s| if (s.owner) allocator.free(s.chars),
        }
        allocator.destroy(self);
    }

    pub fn create(allocator: std.mem.Allocator, str: []const u8) !*Obj {
        // Alligned alloc allows us to perform a single allocation to alloc both object and string.
        const mem = try allocator.alignedAlloc(u8, .of(Obj), @sizeOf(Obj) + str.len);
        const obj: *Obj = @ptrCast(mem.ptr);
        const string = mem[@sizeOf(Obj)..];
        @memcpy(string, str);

        obj.*.data = ObjData{ .str = ObjStr{ .owner = true, .chars = string } };

        return obj;
    }
};

pub const ObjData = union(enum) {
    str: ObjStr,
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

pub inline fn strValue(allocator: std.mem.Allocator, chars: []const u8) !Value {
    const o = try allocator.create(Obj);
    o.data = ObjData{ .str = ObjStr{ .owner = false, .chars = chars } };
    return objValue(o);
}

pub inline fn copyString(allocator: std.mem.Allocator, vm: *VM, chars: []const u8) !*Obj {
    const interned = vm.strings.get(chars);
    if (interned != null) {
        return interned.?;
    }
    return try allocateString(allocator, vm, chars);
}

pub inline fn takeString(allocator: std.mem.Allocator, vm: *VM, chars: []const u8) !*Obj {
    const interned = vm.strings.get(chars);
    if (interned != null) {
        // Since we are taking ownership of the string, we need to free the duplicate string.
        allocator.free(chars);
        return interned.?;
    }
    return try allocateString(allocator, vm, chars);
}

pub inline fn allocateString(allocator: std.mem.Allocator, vm: *VM, chars: []const u8) !*Obj {
    const o = try Obj.create(allocator, chars);

    // Memory management. Intern the string and then register the new object with the vm.
    try vm.strings.put(chars, o);
    o.next = vm.objects;
    vm.objects = o;

    return o;
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
        },
        else => false,
    };
}

pub fn print(v: Value) void {
    switch (v) {
        .number => |n| std.debug.print("{d}", .{n}),
        .bool => |b| std.debug.print("{}", .{b}),
        .nil => std.debug.print("<nil>", .{}),
        .obj => |o| switch (o.data) {
            .str => |s| std.debug.print("\"{s}\" @ 0x{x}", .{ s.chars, @intFromPtr(o) }),
        },
    }
}
