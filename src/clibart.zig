const std = @import("std");
const art = @cImport({
    @cInclude("art.h");
});
const clibart = @cImport({
    @cInclude("src/clibart.c");
});
extern var show_debug: c_int;

const Art = @import("art2.zig");
const ArtTree = Art.ArtTree;
// const a = std.testing.allocator;
// var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
// var a = &arena.allocator;
const a = std.heap.c_allocator;

const Lang = enum { c, z, both };

const lang = switch (clibart.LANG) {
    'c' => .c,
    'z' => .z,
    'b' => .both,
    else => unreachable,
};
const UTree = ArtTree(usize);
test "compare node keys" {
    // @compileLog("lang", lang);
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
    // var node = try a.create(art.art_node);
    // var nodea = try a.create(UTree.Node);
    // const stopLine = 15;
    const stopLine = 200;
    // show_debug = 1;
    // Art.logLevel = .Verbose;
    var i: usize = 0;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        defer i += 1;
        // if (i > stopLine) break;
        buf[line.len] = 0;
        line.len += 1;
        // buf[line.len] = 0;
        // std.debug.warn("\nline {} {}\n", .{ lines, line.* });
        if (lines == stopLine) {
            // show_debug = 1;
            // Art.logLevel = .Verbose;
            std.debug.warn("", .{});
        }
        if (lang == .c or lang == .both) {
            // TODO leak
            const temp = try a.create(usize);
            temp.* = lines;
            const result = art.art_insert(&t, line.ptr, @intCast(c_int, line.len), temp);
        } else if (lang == .z or lang == .both) {
            const result = try ta.insert(line.*, lines);
            if (result == .missing) {
                // Art.log(.Verbose, "result null\n", .{});
            } else {
                // Art.log(.Verbose, "result {}\n", .{result.Found});
            }
            // _ = ta.iter(Art.showCb, @as(*c_void, nodea));
        }
        lines += 1;
    }

    if (lang == .c or lang == .both) {
        show_debug = 1;
        art.art_print(&t);
    }
    if (lang == .z or lang == .both) {
        Art.showLog = true;
        try ta.print();
    }
}
