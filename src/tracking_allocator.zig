const std = @import("std");

const Allocator = std.mem.Allocator;

/// Wraps another allocator and tracks the number of currently allocated bytes.
///
/// This allocator is not thread-safe.
pub const TrackingAllocator = struct {
    childAllocator: Allocator,
    bytesAllocated: usize = 0,

    pub fn init(childAllocator: Allocator) TrackingAllocator {
        return .{ .childAllocator = childAllocator };
    }

    pub fn allocator(self: *TrackingAllocator) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, returnAddress: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const memory = self.childAllocator.rawAlloc(len, alignment, returnAddress) orelse return null;
        self.bytesAllocated += len;
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, newLen: usize, returnAddress: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (!self.childAllocator.rawResize(memory, alignment, newLen, returnAddress)) return false;

        self.recordResize(memory.len, newLen);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, newLen: usize, returnAddress: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const newMemory = self.childAllocator.rawRemap(memory, alignment, newLen, returnAddress) orelse return null;

        self.recordResize(memory.len, newLen);
        return newMemory;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, returnAddress: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.childAllocator.rawFree(memory, alignment, returnAddress);
        self.bytesAllocated -= memory.len;
    }

    fn recordResize(self: *TrackingAllocator, oldLen: usize, newLen: usize) void {
        if (newLen >= oldLen) {
            self.bytesAllocated += newLen - oldLen;
        } else {
            self.bytesAllocated -= oldLen - newLen;
        }
    }
};

test "tracks allocated and freed bytes" {
    var buffer: [64]u8 = undefined;
    var fixedBufferAllocator = std.heap.FixedBufferAllocator.init(&buffer);
    var trackingAllocator = TrackingAllocator.init(fixedBufferAllocator.allocator());
    const allocator = trackingAllocator.allocator();

    const bytes = try allocator.alloc(u8, 8);
    try std.testing.expectEqual(8, trackingAllocator.bytesAllocated);

    const words = try allocator.alloc(u32, 4);
    try std.testing.expectEqual(24, trackingAllocator.bytesAllocated);

    allocator.free(words);
    try std.testing.expectEqual(8, trackingAllocator.bytesAllocated);

    allocator.free(bytes);
    try std.testing.expectEqual(0, trackingAllocator.bytesAllocated);
}

test "updates tracked bytes only after successful resize operations" {
    var buffer: [32]u8 = undefined;
    var fixedBufferAllocator = std.heap.FixedBufferAllocator.init(&buffer);
    var trackingAllocator = TrackingAllocator.init(fixedBufferAllocator.allocator());
    const allocator = trackingAllocator.allocator();

    var memory = try allocator.alloc(u8, 8);

    try std.testing.expect(allocator.resize(memory, 12));
    memory = memory.ptr[0..12];
    try std.testing.expectEqual(12, trackingAllocator.bytesAllocated);

    memory = allocator.remap(memory, 16).?;
    try std.testing.expectEqual(16, trackingAllocator.bytesAllocated);

    try std.testing.expect(allocator.remap(memory, 64) == null);
    try std.testing.expectEqual(16, trackingAllocator.bytesAllocated);

    allocator.free(memory);
    try std.testing.expectEqual(0, trackingAllocator.bytesAllocated);
}

test "does not track failed allocations" {
    var buffer: [8]u8 = undefined;
    var fixedBufferAllocator = std.heap.FixedBufferAllocator.init(&buffer);
    var trackingAllocator = TrackingAllocator.init(fixedBufferAllocator.allocator());
    const allocator = trackingAllocator.allocator();

    try std.testing.expectError(error.OutOfMemory, allocator.alloc(u8, 9));
    try std.testing.expectEqual(0, trackingAllocator.bytesAllocated);
}
