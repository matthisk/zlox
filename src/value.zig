const std = @import("std");

pub const Value = union(enum) {
    bool: bool,
    number: f64,
    nil: void,
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

pub fn print(v: Value) void {
    switch (v) {
        .number => |n| std.debug.print("{d}", .{n}),
        .bool => |b| std.debug.print("{}", .{b}),
        .nil => std.debug.print("<nil>", .{}),
    }
}
