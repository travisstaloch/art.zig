// zig test src/clibart.zig --c-source libartc/src/art.c -I/usr/include/ -I/usr/include/x86_64-linux-gnu/ -lc -I libartc/src -I. -DLANG="'z'"

const std = @import("std");
const artc = @cImport({
    @cInclude("art.h");
});

const clibart = @cImport({
    @cInclude("src/clibart.c");
});
extern var show_debug: c_int;

const art = @import("art.zig");
const Art = art.Art;
const testing = std.testing;
const a = std.heap.c_allocator;

const Lang = enum { c, z, both };

const lang = switch (clibart.LANG) {
    'c' => .c,
    'z' => .z,
    'b' => .both,
    else => unreachable,
};
const UTree = Art(usize);

test "compare node keys" {
    var t: artc.art_tree = undefined;
    _ = artc.art_tree_init(&t);
    defer _ = artc.art_tree_destroy(&t);
    var ta = Art(usize).init(a);
    defer ta.deinit();

    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var linei: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    const stop_line = 200;
    var i: usize = 0;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        defer i += 1;
        // if (i > stop_line) break;
        buf[line.len] = 0;
        if (lang == .c or lang == .both) {
            // this prevents all inserted values from pointing to the same value
            // TODO fix leak
            const temp = try a.create(usize);
            temp.* = linei;
            const result = artc.art_insert(&t, line.ptr, @intCast(c_int, line.len), temp);
        } else if (lang == .z or lang == .both) {
            const result = try ta.insert(buf[0..line.len :0], linei);
        }
        linei += 1;
    }

    if (lang == .c or lang == .both) {
        show_debug = 1;
        artc.art_print(&t);
    }
    if (lang == .z or lang == .both) {
        try ta.print();
    }
}

// this is used to compare against output from the original c version of libart
test "compare tree after delete" {
    var t: artc.art_tree = undefined;
    _ = artc.art_tree_init(&t);
    defer _ = artc.art_tree_destroy(&t);
    var ta = Art(usize).init(a);
    defer ta.deinit();

    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var linei: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    const stop_line = 197141;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;
        if (lang == .c or lang == .both) {
            // this prevents all inserted values from pointing to the same value
            // TODO fix leak
            const temp = try a.create(usize);
            temp.* = linei;
            const result = artc.art_insert(&t, line.ptr, @intCast(c_int, line.len), temp);
        } else if (lang == .z or lang == .both) {
            const result = try ta.insert(buf[0..line.len :0], linei);
        }
        // if (linei == stop_line) break;
        linei += 1;
    }

    _ = try f.seekTo(0);
    linei = 1;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;
        if (linei == stop_line) {
            if (lang == .c or lang == .both) {
                show_debug = 1;
                artc.art_print(&t);
                show_debug = 0;
            }
            if (lang == .z or lang == .both) {
                // var list = std.ArrayList(u8).init(a);
                // try ta.printToStream(&std.io.getStdOut().outStream());
                // try ta.printToStream(&list.outStream());
                try ta.print();
            }
        }
        if (lang == .c or lang == .both) {
            const result = artc.art_delete(&t, line.ptr, @intCast(c_int, line.len));
            testing.expect(result != null);
        } else if (lang == .z or lang == .both) {
            const result = try ta.delete(buf[0..line.len :0]);
            if (result != .found) {
                std.debug.warn("\nfailed on line {}:{}\n", .{ linei, line });
            }
            testing.expect(result == .found);
        }
        if (linei == stop_line) break;
        linei += 1;
    }
    if (lang == .c or lang == .both) {
        show_debug = 1;
        artc.art_print(&t);
        show_debug = 0;
    }
    if (lang == .z or lang == .both) {
        // var list = std.ArrayList(u8).init(a);
        // try ta.printToStream(&std.io.getStdOut().outStream());
        // try ta.printToStream(&list.outStream());
    }
}
// zig test src/clibart.zig --c-source libartc/src/art.c -I/usr/include/ -I/usr/include/x86_64-linux-gnu/ -lc -I libartc/src -I. -DLANG="'c'" --test-filter bench --release-fast
test "bench against libart" {
    var t: artc.art_tree = undefined;
    _ = artc.art_tree_init(&t);
    defer _ = artc.art_tree_destroy(&t);

    var ta = Art(usize).init(a);
    defer ta.deinit();

    const filename = "./testdata/words.txt";

    const f = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer f.close();

    var linei: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;

    var timer = try std.time.Timer.start();
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;
        if (lang == .z or lang == .both)
            _ = try ta.insert(buf[0..line.len :0], linei);
        if (lang == .c or lang == .both) {
            var tmp: usize = 0;
            const result = artc.art_insert(&t, line.ptr, @intCast(c_int, line.len), &tmp);
            testing.expect(result == null);
        }
    }
    const t1 = timer.read();

    timer.reset();
    try f.seekTo(0);
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;
        if (lang == .z or lang == .both)
            _ = ta.search(buf[0..line.len :0]);
        if (lang == .c or lang == .both) {
            _ = artc.art_search(&t, line.ptr, @intCast(c_int, line.len));
        }
    }
    const t2 = timer.read();

    timer.reset();
    try f.seekTo(0);
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;
        if (lang == .z or lang == .both)
            _ = try ta.delete(buf[0..line.len :0]);
        if (lang == .c or lang == .both) {
            _ = artc.art_delete(&t, line.ptr, @intCast(c_int, line.len));
        }
    }
    const t3 = timer.read();

    std.debug.warn("{: <7} insert {}ms, search {}ms, delete {}ms, combined {}ms\n", .{
        if (lang == .z) "art.zig" else "art.c",
        t1 / 1000000,
        t2 / 1000000,
        t3 / 1000000,
        (t1 + t2 + t3) / 1000000,
    });
}
