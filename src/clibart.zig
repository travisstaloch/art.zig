const std = @import("std");

const art = @cImport({
    @cInclude("art.h");
});

// const MAX_PREFIX_LEN = 10;
// const art_node = extern struct {
//     @"type": u8,
//     num_children: u8,
//     partial_len: u32,
//     partial: [MAX_PREFIX_LEN]u8,
// };

fn cb(data: ?*c_void, key: [*c]const u8, key_len: u32, value: ?*c_void, depth: c_int, n: [*c]art.art_node) callconv(.C) c_int {
    //fn cb(data: ?*c_void, key: [*c]const u8, key_len: u32, value: ?*c_void, depth: c_int, n: [*c]art.art_node) callconv(.C) c_int {
    // std.debug.warn("{}\n", .{n[0]});
    const nd = n[0];
    // const nd4 = @ptrCast(*art.art_node4, @alignCast(8, &n[0]));
    std.debug.warn("{}\n", .{nd4.*});
    std.debug.warn("{}-{} {} {} {}\n", .{ key[0..key_len], key_len, depth, nd.partial, nd.partial_len });
    return 0;
}

fn cb2(data: ?*c_void, key: [*c]const u8, key_len: u32, value: ?*c_void, depth: c_int, node: [*c]art.art_node) callconv(.C) c_int {
    const n = node[0];
    const nodeType = switch (n.type) {
        art.NODE4 => "4   ",
        art.NODE16 => "16  ",
        art.NODE48 => "48  ",
        art.NODE256 => "256 ",
        else => "LEAF",
    };
    std.debug.warn("Node {}: {}-{} {} {}\n", .{ nodeType, if (key_len > 0) key[0..key_len] else "(null)", key_len, depth, n.partial });
    // std.debug.warn("n {}\n", .{n});
    return 0;
}

test "basic insert" {
    var t: art.art_tree = undefined;
    _ = art.art_tree_init(&t);
    defer _ = art.art_tree_destroy(&t);
    const words = [_][]const u8{
        "car",
        "truck",
        "bike",
        "trucker",
        "cars",
        "bikes",
    };
    for (words) |w, _i| {
        var i = _i;
        // std.debug.warn("{}-{}\n", .{ w, art.art_insert(&t, w.ptr, @intCast(c_int, w.len), @as(*c_void, &i)) });
        _ = art.art_insert(&t, w.ptr, @intCast(c_int, w.len), @as(*c_void, &i));
        std.debug.warn("\n", .{});
    }
    var data: usize = 0;
    _ = art.art_iter(&t, cb2, @as(*c_void, &data));
}
