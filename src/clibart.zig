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
    // const words = [_][]const u8{
    //     "car",
    //     "truck",
    //     "bike",
    //     "trucker",
    //     "cars",
    //     "bikes",
    // };
    show_debug = 1;
    const words = [_][]const u8{
        "Aaron\x00",
        "Aaronic\x00",
        "Aaronical\x00",
    };
    for (words) |w, _i| {
        var i = _i;
        // std.debug.warn("{}-{}\n", .{ w, art.art_insert(&t, w.ptr, @intCast(c_int, w.len), @as(*c_void, &i)) });
        _ = art.art_insert(&t, w.ptr, @intCast(c_int, w.len), @as(*c_void, &i));
        std.debug.warn("\n", .{});
    }
    var data: usize = 0;
    _ = art.art_iter2(&t, showCb_art, @as(*c_void, &data));
}

test "49 insert search" {
    var t: art.art_tree = undefined;
    _ = art.art_tree_init(&t);
    defer _ = art.art_tree_destroy(&t);
    const words = [_][]const u8{ "A", "A's", "AMD", "AMD's", "AOL", "AOL's", "AWS", "AWS's", "Aachen", "Aachen's", "Aaliyah", "Aaliyah's", "Aaron", "Aaron's", "Abbas", "Abbas's", "Abbasid", "Abbasid's", "Abbott", "Abbott's", "Abby", "Abby's", "Abdul", "Abdul's", "Abe", "Abe's", "Abel", "Abel's", "Abelard", "Abelard's", "Abelson", "Abelson's", "Aberdeen", "Aberdeen's", "Abernathy", "Abernathy's", "Abidjan", "Abidjan's", "Abigail", "Abigail's", "Abilene", "Abilene's", "Abner", "Abner's", "Abraham", "Abraham's", "Abram", "Abram's" };
    for (words) |w, _i| {
        var i = _i;
        // std.debug.warn("{}-{}\n", .{ w, art.art_insert(&t, w.ptr, @intCast(c_int, w.len), @as(*c_void, &i)) });
        _ = art.art_insert(&t, w.ptr, @intCast(c_int, w.len), @as(*c_void, &i));
    }
    var line = "A"[0..];
    const result = art.art_search(&t, line, @intCast(c_int, line.len));
    std.debug.warn("search result {} {}\n", .{ line, result });
    // var data: usize = 0;
    // _ = art.art_iter(&t, cb2, @as(*c_void, &data));
}

extern fn art_minimum(t: *art.art_tree) *art_leaf;
extern fn art_maximum(t: *art.art_tree) *art_leaf;
const art_leaf = extern struct {
    value: *c_void,
    key_len: c_uint,
    key: [*]u8,
    fn bytes(self: *art_leaf) [*]u8 {
        comptime std.debug.assert(@alignOf(u8) < @alignOf(art_leaf));
        const p = @ptrCast([*]u8, self) + @sizeOf(art_leaf) - 12; // why - 12 ???
        return p;
    }
};

const testing = std.testing;
extern var show_debug: c_int;
test "insert search" {
    var t: art.art_tree = undefined;
    _ = art.art_tree_init(&t);
    defer _ = art.art_tree_destroy(&t);

    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;
        const result = art.art_insert(&t, line.ptr, @intCast(c_int, line.len), @as(*c_void, &lines));
        lines += 1;
    }

    _ = try f.seekTo(0);

    // Search for each line
    lines = 1;
    // var line: [128]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;

        const result = art.art_search(&t, line.ptr, @intCast(c_int, line.len));
        // std.debug.warn("{} {}\n", .{ line, result });
        // testing.expect(result != null);
        const data = @ptrCast(*usize, @alignCast(@alignOf(*usize), result.?));
        if (lines != data.*) {
            show_debug = 1;
            std.debug.warn("{} {} != {} {}\n", .{ line, lines, data, art.art_search(&t, line.ptr, @intCast(c_int, line.len)) });
        }
        testing.expectEqual(data.*, lines);
        lines += 1;
        // break;
    }

    // Check the minimum
    var l = art_minimum(&t);
    std.debug.warn("l {c}\n", .{l.bytes()[0]});
    testing.expectEqual(l.bytes()[0], 'A');

    // Check the maximum
    l = art_maximum(&t);
    // std.debug.warn("l {}\n", .{l});
    const vla = l.bytes()[0..l.key_len];
    // std.debug.warn("vla {}\n", .{vla});
    testing.expectEqualSlices(u8, vla, "zythum");
}

const UTree = ArtTree(usize);

fn sizeCb(data: ?*c_void, key: [*c]const u8, key_len: u32, value: ?*c_void) callconv(.C) c_int {
    var size = @ptrCast(*usize, @alignCast(@alignOf(*usize), data.?));
    size.* += 1;
    return 0;
}
fn sizeCba(t: *UTree, n: *UTree.Node, data: *c_void, depth: usize) bool {
    if (n.* == .Leaf) {
        var size = @ptrCast(*usize, @alignCast(@alignOf(*usize), data));
        size.* += 1;
    }
    return false;
}
const Art = @import("art2.zig");
const ArtTree = Art.ArtTree;
const a = std.heap.c_allocator;
test "iter path length" {
    var t: art.art_tree = undefined;
    _ = art.art_tree_init(&t);
    defer _ = art.art_tree_destroy(&t);
    var ta = ArtTree(usize).init(a);
    defer ta.deinit();

    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    // @import("art2.zig").logLevel = .Warn;
    const problemLine = 15;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        buf[line.len] = 0;
        if (lines >= problemLine) {
            show_debug = 1;
            Art.logLevel = .Info;
            Art.log(.Warning, "line {} lines {}\n", .{ line.*, lines });
        }
        art.debug("--- c code ----\n");
        _ = art.art_insert(&t, line.ptr, @intCast(c_int, line.len), @as(*c_void, &lines));
        Art.log(.Verbose, "--- zig code ---\n", .{});
        _ = try ta.insert(line.*, lines);

        // if (lines % 1000 == 0) {
        if (lines >= problemLine) break;
        lines += 1;
    }
    var size: usize = 0;
    _ = art.art_iter(&t, sizeCb, @as(*c_void, &size));
    var sizea: usize = 0;
    _ = ta.iter(sizeCba, @as(*c_void, &sizea));
    if (size != sizea) {
        std.debug.warn("size differs. expecting size {} actual size {}\n", .{ size, sizea });
        testing.expectEqual(size, sizea);
    }
}

fn showCb_art(data: ?*c_void, n: [*c]art.art_node, value: ?*c_void, depth: c_uint) callconv(.C) c_int {
    // std.debug.warn("showCb_art {}\n", .{n[0]});
    switch (n[0].type) {
        art.NODE4 => {
            const nn = @ptrCast(*art.art_node4, @alignCast(@alignOf(*art.art_node4), &n[0]));
            std.debug.warn("{}4-{} ({})\n", .{ spaces[0 .. depth * 2], nn.keys[0..n[0].num_children], n[0].partial[0..n[0].partial_len] });
        },
        art.NODE16 => {
            const nn = @ptrCast(*art.art_node16, @alignCast(@alignOf(*art.art_node16), &n[0]));
            std.debug.warn("{}16-{} ({})\n", .{ spaces[0 .. depth * 2], nn.keys[0..n[0].num_children], n[0].partial[0..n[0].partial_len] });
        },
        art.NODE48 => {
            const nn = @ptrCast(*art.art_node48, @alignCast(@alignOf(*art.art_node48), &n[0]));
            std.debug.warn("{}48-{} ({})\n", .{ spaces[0 .. depth * 2], nn.keys[0..n[0].num_children], n[0].partial[0..n[0].partial_len] });
        },
        art.NODE256 => {
            const nn = @ptrCast(*art.art_node256, @alignCast(@alignOf(*art.art_node256), &n[0]));
            std.debug.warn("{}256-", .{spaces[0 .. depth * 2]});
            for (nn.children[0..256]) |c, i| {
                if (c != null) {
                    std.debug.warn("{c}", .{@truncate(u8, i)});
                }
            }
            std.debug.warn("{}\n", .{n[0].partial[0..n[0].partial_len]});
        },
        else => {
            std.debug.warn("{} -> ", .{spaces[0 .. depth * 2]});
            const nn = art.display_leaf(&n[0]);
            std.debug.warn("\n", .{});
        },
    }
    return 0;
}
const spaces = [1]u8{' '} ** 256;
test "compare node keys" {
    const Lang = enum { c, z, both };
    var t: art.art_tree = undefined;
    _ = art.art_tree_init(&t);
    defer _ = art.art_tree_destroy(&t);
    var ta = ArtTree(usize).init(a);
    defer ta.deinit();

    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    // @import("art2.zig").logLevel = .Warn;
    var node = try a.create(art.art_node);
    var nodea = try a.create(UTree.Node);
    const lang = .z;
    // const stopLine = 15;
    const stopLine = 10000000;
    // show_debug = 1;
    Art.logLevel = .Verbose;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        buf[line.len] = 0;
        if (lines == stopLine) {
            show_debug = 1;
            Art.logLevel = .Verbose;
        }
        // std.debug.warn("line {} lines {}\n", .{ line.*, lines });
        if (lang == .c or lang == .both) {
            // art.debug("--- c code ----\n");
            // art.debug("line %s lines %d\n", line, lines);
            _ = art.art_insert(&t, line.ptr, @intCast(c_int, line.len), @as(*c_void, &lines));
            // _ = art.art_iter2(&t, showCb_art, @as(*c_void, node));
        } else if (lang == .z or lang == .both) {
            // Art.log(.Verbose, "--- zig code ---\n", .{});
            // Art.log(.Verbose, "line {} lines {}\n", .{ line, lines });
            _ = try ta.insert(line.*, lines);
            // _ = ta.iter(Art.showCb, @as(*c_void, nodea));
        }

        // if (lines % 1000 == 0) {
        // if (lines >= problemLine) {

        // std.debug.warn("--- c code ----\n", .{});

        // std.debug.warn("---\n", .{});
        Art.log(.Verbose, "---\n", .{});
        // if (size != sizea) {
        //     std.debug.warn("size differs. expecting size {} actual size {}\n", .{ size, sizea });
        //     testing.expectEqual(size, sizea);
        // }
        // }
        if (lines == stopLine) break;
        lines += 1;
    }
    // _ = art.art_iter2(&t, showCb_art, @as(*c_void, node));
    // _ = ta.iter(showCb, @as(*c_void, nodea));
}

// test "node keys correctness" {
//     show_debug = 1;
//     var t: art.art_tree = undefined;
//     _ = art.art_tree_init(&t);
//     defer _ = art.art_tree_destroy(&t);
//     var lines: usize = 0;
//     _ = art.art_insert(&t, "A\x00", @intCast(c_int, 1), @as(*c_void, &lines));
//     _ = art.art_insert(&t, "a\x00", @intCast(c_int, 2), @as(*c_void, &lines));
// }
