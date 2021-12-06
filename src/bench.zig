const std = @import("std");
const art = @import("art.zig");

/// 245.448 milliseconds
pub fn main() !void {
    const gpa = std.heap.c_allocator;

    var tree = art.Art(void).init(gpa);
    defer tree.deinit();

    var keys = try gpa.alloc([32:0]u8, 1_000_000);
    defer gpa.free(keys);

    var rng = std.rand.DefaultPrng.init(0);
    for (keys) |*key| {
        rng.random.bytes(key);
        key[32] = 0;
    }

    var timer = try std.time.Timer.start();

    for (keys) |*key| {
        _ = try tree.insert(key, {});
    }

    std.debug.print("{}\n", .{std.fmt.fmtDuration(timer.read())});
}