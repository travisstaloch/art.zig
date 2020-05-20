const std = @import("std");
const art = @cImport({
    @cInclude("art.h");
});
const clibart = @cImport({
    @cInclude("src/clibart.c");
});
extern var show_debug: c_int;

const Art = @import("art5.zig");
const ArtTree = Art.ArtTree;
const a = std.testing.allocator;

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
    var node = try a.create(art.art_node);
    var nodea = try a.create(UTree.Node);
    // const stopLine = 15;
    const stopLine = 20;
    // show_debug = 1;
    // Art.logLevel = .Verbose;
    var i: usize = 0;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        defer i += 1;
        if (i > stopLine) break;
        buf[line.len] = 0;
        line.len += 1;
        // buf[line.len] = 0;
        if (lines == stopLine) {
            // show_debug = 1;
            // Art.logLevel = .Verbose;
        }
        // std.debug.warn("line {} lines {}\n", .{ line.*, lines });
        if (lang == .c or lang == .both) {
            // art.debug("--- c code ----\n");
            // art.debug("line %s lines %d\n", line, lines);
            const result = art.art_insert(&t, line.ptr, @intCast(c_int, line.len), @as(*c_void, &lines));
            // Art.log(.Verbose, "result {}\n", .{result});
            // _ = art.art_iter2(&t, showCb_art, @as(*c_void, node));
        } else if (lang == .z or lang == .both) {
            // Art.log(.Verbose, "--- zig code ---\n", .{});
            // Art.log(.Verbose, "line {} lines {}\n", .{ line, lines });
            const result = try ta.insert(line.*, lines);
            if (result == .created) {
                // Art.log(.Verbose, "result null\n", .{});
            } else {
                // Art.log(.Verbose, "result {}\n", .{result.Found});
            }
            // _ = ta.iter(Art.showCb, @as(*c_void, nodea));
        }

        // if (lines % 1000 == 0) {
        // if (lines >= problemLine) {

        // std.debug.warn("--- c code ----\n", .{});

        // std.debug.warn("---\n", .{});
        // Art.log(.Verbose, "### {} {}\n", .{ line.*, i });
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
    if (lang == .c or lang == .both) {
        art.art_print(&t);
    }
    if (lang == .z or lang == .both) {
        try ta.print();
    }
}
