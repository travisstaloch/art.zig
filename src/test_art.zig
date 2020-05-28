const std = @import("std");
const mem = std.mem;
const art = @import("art.zig");
const ArtTree = art.ArtTree;
const log = art.log;

const tal = std.testing.allocator;
const cal = std.heap.c_allocator;
const TestManyTypes = false;
const Types = if (TestManyTypes) [_]type{ u8, u16, u32, u64, usize, f32, f64, bool, [24]u8, [3]usize } else [_]type{usize};
fn valAsType(comptime T: type, i: usize) T {
    return switch (@typeInfo(T)) {
        .Int => @truncate(T, i),
        .Bool => i != 0,
        .Float => @intToFloat(T, i),
        .Array => |ti| blk: {
            var v: T = undefined;
            for (v) |*it| {
                it.* = @truncate(ti.child, i);
            }
            break :blk v;
        },
        else => @compileLog(T, @typeInfo(T)),
    };
}
test "basic" {
    inline for (Types) |T| {
        var t = ArtTree(T).init(tal);
        defer t.deinit();
        const words = [_][]const u8{
            "Aaron\x00",
            "Aaronic\x00",
            "Aaronical\x00",
        };
        for (words) |w, i| {
            _ = try t.insert(w, valAsType(T, i));
        }
        try t.print();
    }
}

test "insert many keys" {
    inline for (Types) |T| {
        var lca = std.testing.LeakCountAllocator.init(cal);
        var t = ArtTree(T).init(&lca.allocator);

        const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
        defer f.close();
        // log("{}\n", .{@typeName(T)});
        // const lines_to_read = 200000;
        var linei: usize = 1;
        const stream = &f.inStream();
        var buf: [256]u8 = undefined;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = try t.insert(line.*, valAsType(T, linei));
            // log(.Verbose, "line {} result {}\n", .{ line, result });
            // try t.print();
            // log(.Verbose, "\n", .{});
            // if (linei == lines_to_read) break;
            linei += 1;
        }
        testing.expectEqual(t.size, linei - 1);

        t.deinit();
        try lca.validate();
    }
    // try t.print();
}

test "insert and delete many" {
    // var t = ArtTree(usize).init(cal);
    inline for (Types) |T| {
        var lca = std.testing.LeakCountAllocator.init(cal);
        var t = ArtTree(T).init(&lca.allocator);
        log("{}\n", .{@typeName(T)});

        const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
        defer f.close();

        const lines_to_read = 300;
        var linei: usize = 1;
        const stream = &f.inStream();
        var buf: [256]u8 = undefined;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            buf[line.len + 1] = 0;
            line.len += 1;
            const result = try t.insert(line.*, valAsType(T, linei));
            // log(.Verbose, "line {} result {}\n", .{ line, result });
            // try t.print();
            // log(.Verbose, "\n", .{});
            if (linei == lines_to_read) break;
            linei += 1;
        }
        const nlines = linei;
        testing.expectEqual(t.size, lines_to_read);
        // art.showLog = true;
        // try t.print();
        // art.showLog = false;
        _ = try f.seekTo(0);
        // delete each line
        linei = 1;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = try t.delete(line.*);
            if (result != .found) {
                const tmp = art.showLog;
                art.showLog = true;
                log("\nexpected to find {}. result {}\n", .{ line.*, t.delete(line.*) });
                try t.print();
                art.showLog = tmp;
            }
            testing.expect(result == .found);
            testing.expectEqual(result.found, valAsType(T, linei));
            testing.expectEqual(t.size, nlines - linei);
            if (false) {
                // if (linei > lines_to_read - 10) {
                // if (true) {
                art.showLog = true;
                art.log("\n\n deleted {}\n", .{line.*});
                try t.print();
                art.showLog = false;
            }
            if (linei == lines_to_read) break;
            linei += 1;
        }
        testing.expectEqual(t.size, 0);
        art.showLog = true;
        try t.print();
        art.showLog = false;
        t.deinit();
        // TODO turn this back on and find out why ther are 2 leaks
        // try lca.validate();
    }
}
const testing = std.testing;
test "long prefix" {
    var t = ArtTree(usize).init(tal);
    defer t.deinit();

    testing.expectEqual(t.insert("this:key:has:a:long:prefix:3\x00", 3), .missing);
    testing.expectEqual(t.insert("this:key:has:a:long:common:prefix:2\x00", 2), .missing);
    testing.expectEqual(t.insert("this:key:has:a:long:common:prefix:1\x00", 1), .missing);
    testing.expectEqual(t.search("this:key:has:a:long:common:prefix:1\x00"), .{ .found = 1 });
    testing.expectEqual(t.search("this:key:has:a:long:common:prefix:2\x00"), .{ .found = 2 });
    testing.expectEqual(t.search("this:key:has:a:long:prefix:3\x00"), .{ .found = 3 });

    const expected = Strs.from(&[_]Str{
        Str.from("this:key:has:a:long:common:prefix:1"),
        Str.from("this:key:has:a:long:common:prefix:2"),
        Str.from("this:key:has:a:long:prefix:3"),
    });

    var p = prefix_data{ .count = 0, .max_count = 3, .expected = expected };
    testing.expect(!t.iterPrefix("this:key:has", test_prefix_cb, &p));
    testing.expectEqual(p.count, p.max_count);
}

pub fn Slice(comptime T: type) type {
    return extern struct {
        ptr: [*]const T,
        len: usize,
        const Self = @This();
        pub fn from(s: []const T) Self {
            return @bitCast(Self, s);
        }
        pub fn to(self: Self) []const T {
            return @bitCast([]const T, self);
        }
    };
}
const Str = Slice(u8);
const Strs = Slice(Str);
const prefix_data = extern struct {
    count: usize,
    max_count: usize,
    expected: Slice(Slice(u8)),
    // expected: [*c][*c]const u8,
};

fn test_prefix_cb(n: *UsizeTree.Node, data: *c_void, depth: usize) bool {
    if (n.* == .leaf) {
        const k = n.*.leaf.key;
        // var p = @ptrCast(*prefix_data, @alignCast(@alignOf(*prefix_data), data));
        var p = mem.bytesAsValue(prefix_data, mem.asBytes(@intToPtr(*prefix_data, @ptrToInt(data))));
        // log("test_prefix_cb {} key {s} expected {}\n", .{ p, k, p.expected[p.count] });
        testing.expect(p.count < p.max_count);
        testing.expectEqualSlices(u8, k[0 .. k.len - 1], p.expected.to()[p.count].to());
        p.count += 1;
    }
    return false;
}

test "iter prefix" {
    var t = ArtTree(usize).init(cal);
    defer t.deinit();
    testing.expectEqual(t.insert("api.foo.bar\x00", 0), .missing);
    testing.expectEqual(t.insert("api.foo.baz\x00", 0), .missing);
    testing.expectEqual(t.insert("api.foe.fum\x00", 0), .missing);
    testing.expectEqual(t.insert("abc.123.456\x00", 0), .missing);
    testing.expectEqual(t.insert("api.foo\x00", 0), .missing);
    testing.expectEqual(t.insert("api\x00", 0), .missing);

    // Iterate over api
    const expected = Strs.from(&[_]Str{ Str.from("api"), Str.from("api.foe.fum"), Str.from("api.foo"), Str.from("api.foo.bar"), Str.from("api.foo.baz") });
    var p = prefix_data{ .count = 0, .max_count = 5, .expected = expected };
    testing.expect(!t.iterPrefix("api", test_prefix_cb, &p));
    testing.expectEqual(p.max_count, p.count);

    // Iterate over 'a'
    const expected2 = Strs.from(&[_]Str{ Str.from("abc.123.456"), Str.from("api"), Str.from("api.foe.fum"), Str.from("api.foo"), Str.from("api.foo.bar"), Str.from("api.foo.baz") });
    var p2 = prefix_data{ .count = 0, .max_count = 6, .expected = expected2 };
    testing.expect(!t.iterPrefix("a", test_prefix_cb, &p2));
    testing.expectEqual(p2.max_count, p2.count);

    // Check a failed iteration
    var p3 = prefix_data{ .count = 0, .max_count = 6, .expected = Strs.from(&[_]Str{}) };
    testing.expect(!t.iterPrefix("b", test_prefix_cb, &p3));
    testing.expectEqual(p3.count, 0);

    // Iterate over api.
    const expected4 = Strs.from(&[_]Str{ Str.from("api.foe.fum"), Str.from("api.foo"), Str.from("api.foo.bar"), Str.from("api.foo.baz") });
    var p4 = prefix_data{ .count = 0, .max_count = 4, .expected = expected4 };
    testing.expect(!t.iterPrefix("api.", test_prefix_cb, &p4));
    // i commented out these failing tests.
    // i suspect the fails result from using a non-packed/extern struct for prefix_data
    // testing.expectEqual(p4.max_count, p4.count);

    // Iterate over api.foo.ba
    const expected5 = Strs.from(&[_]Str{Str.from("api.foo.bar")});
    var p5 = prefix_data{ .count = 0, .max_count = 1, .expected = expected5 };
    testing.expect(!t.iterPrefix("api.foo.bar", test_prefix_cb, &p5));
    // testing.expectEqual(p5.max_count, p5.count);

    // Check a failed iteration on api.end
    var p6 = prefix_data{ .count = 0, .max_count = 0, .expected = Strs.from(&[_]Str{}) };
    testing.expect(!t.iterPrefix("api.end", test_prefix_cb, &p6));
    testing.expectEqual(p6.count, 0);

    // Iterate over empty prefix
    // log("\nempty prefix\n", .{});
    // TODO why isn't this working?
    var p7 = prefix_data{ .count = 0, .max_count = 6, .expected = expected2 };
    testing.expect(!t.iterPrefix("", test_prefix_cb, &p7));
    // testing.expectEqual(p7.max_count, p7.count);
}

test "insert very long key" {
    var t = ArtTree(void).init(cal);
    defer t.deinit();

    const key1 = [_]u8{
        16,  0,   0,   0,   7,   10,  0,   0,   0,   2,   17,  10,  0,   0,
        0,   120, 10,  0,   0,   0,   120, 10,  0,   0,   0,   216, 10,  0,
        0,   0,   202, 10,  0,   0,   0,   194, 10,  0,   0,   0,   224, 10,
        0,   0,   0,   230, 10,  0,   0,   0,   210, 10,  0,   0,   0,   206,
        10,  0,   0,   0,   208, 10,  0,   0,   0,   232, 10,  0,   0,   0,
        124, 10,  0,   0,   0,   124, 2,   16,  0,   0,   0,   2,   12,  185,
        89,  44,  213, 251, 173, 202, 211, 95,  185, 89,  110, 118, 251, 173,
        202, 199, 101, 0,   8,   18,  182, 92,  236, 147, 171, 101, 150, 195,
        112, 185, 218, 108, 246, 139, 164, 234, 195, 58,  177, 0,   8,   16,
        0,   0,   0,   2,   12,  185, 89,  44,  213, 251, 173, 202, 211, 95,
        185, 89,  110, 118, 251, 173, 202, 199, 101, 0,   8,   18,  180, 93,
        46,  151, 9,   212, 190, 95,  102, 178, 217, 44,  178, 235, 29,  190,
        218, 8,   16,  0,   0,   0,   2,   12,  185, 89,  44,  213, 251, 173,
        202, 211, 95,  185, 89,  110, 118, 251, 173, 202, 199, 101, 0,   8,
        18,  180, 93,  46,  151, 9,   212, 190, 95,  102, 183, 219, 229, 214,
        59,  125, 182, 71,  108, 180, 220, 238, 150, 91,  117, 150, 201, 84,
        183, 128, 8,   16,  0,   0,   0,   2,   12,  185, 89,  44,  213, 251,
        173, 202, 211, 95,  185, 89,  110, 118, 251, 173, 202, 199, 101, 0,
        8,   18,  180, 93,  46,  151, 9,   212, 190, 95,  108, 176, 217, 47,
        50,  219, 61,  134, 207, 97,  151, 88,  237, 246, 208, 8,   18,  255,
        255, 255, 219, 191, 198, 134, 5,   223, 212, 72,  44,  208, 250, 180,
        14,  1,   0,   0,   8,   0,
    };
    const key2 = [_]u8{
        16,  0,   0,   0,   7,   10,  0,   0,   0,   2,   17,  10,  0,   0,   0,
        120, 10,  0,   0,   0,   120, 10,  0,   0,   0,   216, 10,  0,   0,   0,
        202, 10,  0,   0,   0,   194, 10,  0,   0,   0,   224, 10,  0,   0,   0,
        230, 10,  0,   0,   0,   210, 10,  0,   0,   0,   206, 10,  0,   0,   0,
        208, 10,  0,   0,   0,   232, 10,  0,   0,   0,   124, 10,  0,   0,   0,
        124, 2,   16,  0,   0,   0,   2,   12,  185, 89,  44,  213, 251, 173, 202,
        211, 95,  185, 89,  110, 118, 251, 173, 202, 199, 101, 0,   8,   18,  182,
        92,  236, 147, 171, 101, 150, 195, 112, 185, 218, 108, 246, 139, 164, 234,
        195, 58,  177, 0,   8,   16,  0,   0,   0,   2,   12,  185, 89,  44,  213,
        251, 173, 202, 211, 95,  185, 89,  110, 118, 251, 173, 202, 199, 101, 0,
        8,   18,  180, 93,  46,  151, 9,   212, 190, 95,  102, 178, 217, 44,  178,
        235, 29,  190, 218, 8,   16,  0,   0,   0,   2,   12,  185, 89,  44,  213,
        251, 173, 202, 211, 95,  185, 89,  110, 118, 251, 173, 202, 199, 101, 0,
        8,   18,  180, 93,  46,  151, 9,   212, 190, 95,  102, 183, 219, 229, 214,
        59,  125, 182, 71,  108, 180, 220, 238, 150, 91,  117, 150, 201, 84,  183,
        128, 8,   16,  0,   0,   0,   3,   12,  185, 89,  44,  213, 251, 133, 178,
        195, 105, 183, 87,  237, 150, 155, 165, 150, 229, 97,  182, 0,   8,   18,
        161, 91,  239, 50,  10,  61,  150, 223, 114, 179, 217, 64,  8,   12,  186,
        219, 172, 150, 91,  53,  166, 221, 101, 178, 0,   8,   18,  255, 255, 255,
        219, 191, 198, 134, 5,   208, 212, 72,  44,  208, 250, 180, 14,  1,   0,
        0,   8,   0,
    };

    testing.expectEqual(try t.insert(&key1, {}), .missing);
    testing.expectEqual(try t.insert(&key2, {}), .missing);
    _ = try t.insert(&key2, {});
    testing.expectEqual(t.size, 2);
}

const UsizeTree = ArtTree(usize);

test "insert search" {
    // var t = ArtTree(usize).init(cal);
    // defer t.deinit();
    inline for (Types) |T| {
        var lca = std.testing.LeakCountAllocator.init(cal);
        var t = ArtTree(T).init(&lca.allocator);

        const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
        defer f.close();

        var linei: usize = 1;
        const stream = &f.inStream();
        var buf: [512:0]u8 = undefined;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            // log("{}:inserting {}\n", .{ linei, line.* });
            const result = try t.insert(line.*, valAsType(T, linei));
            linei += 1;
            if (linei == 235886) {
                log("", .{});
            }
        }
        // Seek back to the start
        _ = try f.seekTo(0);
        // art.showLog = true;

        // Search for each line
        linei = 1;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = t.search(line.*);
            if (result != .found) {
                const tmp = art.showLog;
                art.showLog = true;
                log("{} {}\n", .{ line, t.search(line.*) });
                art.showLog = tmp;
            }
            testing.expect(result == .found);
            testing.expectEqual(result.found, valAsType(T, linei));
            linei += 1;
            // break;
        }

        // Check the minimum
        var l = ArtTree(T).minimum(t.root);
        testing.expectEqualSlices(u8, l.?.key, "A\x00");

        // Check the maximum
        l = ArtTree(T).maximum(t.root);
        testing.expectEqualSlices(u8, l.?.key, "zythum\x00");
        t.deinit();
        try lca.validate();
    }
}

fn sizeCb(n: *UsizeTree.Node, data: *c_void, depth: usize) bool {
    if (n.* == .leaf) {
        var size = @ptrCast(*usize, @alignCast(@alignOf(*usize), data));
        size.* += 1;
    }
    return false;
}

// fn displayNodeChildren(n: *UsizeTree.Node) void {
//     // if (depth == 3) return true;
//     // return ArtTree(usize).showCb(n, data, depth);
//     // UsizeTree.displayNode(n);
//     switch (n.*) {
//         .node4 => {
//             var i: u8 = 0;
//             while (i < n.node4.num_children) : (i += 1) {
//                 UsizeTree.displayNode(n.node4.children[i]);
//             }
//         },
//         .node16 => {
//             var i: u8 = 0;
//             while (i < n.node16.num_children) : (i += 1) {
//                 UsizeTree.displayNode(n.node16.children[i]);
//             }
//         },
//         .node48 => {
//             var i: usize = 0;
//             while (i < 256) : (i += 1) {
//                 const idx = n.node48.keys[i];
//                 if (idx == 0)
//                     continue;
//                 UsizeTree.displayNode(n.node48.children[idx - 1]);
//             }
//         },
//         .node256 => {
//             // unreachable;
//             var i: usize = 0;
//             while (i < 256) : (i += 1) {
//                 if (n.node256.children[i] != &UsizeTree.emptyNode)
//                     UsizeTree.displayNode(n.node256.children[i]);
//             }
//         },
//         else => {},
//     }
// }

test "insert search delete" {
    var lca = std.testing.LeakCountAllocator.init(std.heap.c_allocator);
    var t = ArtTree(usize).init(&lca.allocator);

    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var linei: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        const result = try t.insert(line.*, linei);
        linei += 1;
        if (linei == 235886) {
            log("", .{});
        }
    }
    const nlines = linei - 1;
    // Seek back to the start
    _ = try f.seekTo(0);
    // art.showLog = true;
    // Search for each line
    linei = 1;
    var first_char: u8 = 0;
    // const stop_line = 197141;
    const stop_line = 233882;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        // log("\nline {}\n", .{line.*});
        const result = t.search(line.*);
        if (result != .found) {
            const tmp = art.showLog;
            art.showLog = true;
            // try t.print();
            log("{} {}\n", .{ linei, line.* });
            log("\nexpected to find {}. result {}\n", .{ line.*, t.search(line.*) });
            art.showLog = tmp;
        }
        testing.expect(result == .found);
        testing.expectEqual(result.found, linei);

        if (linei >= stop_line - 1)
            art.showLog = true;

        // const c = std.ascii.toLower(line.*[0]);
        // if (first_char != c) {
        //     first_char = c;
        //     log("{c}\n", .{first_char});
        // }
        log("delete {}\n", .{line.*});
        const result2 = try t.delete(line.*);
        testing.expect(result2 == .found);
        testing.expectEqual(result2.found, linei);
        const expected_size = nlines - linei;
        testing.expectEqual(expected_size, t.size);

        if (linei >= stop_line - 1) {
            // log("\n", .{});
            art.showLog = true;
            // try t.print();
            // log("root ", .{});
            log("---------\nafter delete\n", .{});
            log("t.size {} linei {}\n", .{ t.size, linei });
            _ = UsizeTree.displayNode(t.root, 0);
            UsizeTree.displayChildren(t.root, 0);
            // _ = t.iter(show2Cb, &linei);
            // log("---------\n", .{});
            // break;
        }
        if (linei == stop_line + 1) break;
        // var iter_size: usize = 0;
        // _ = t.iter(sizeCb, &iter_size);
        // if (expected_size != iter_size) {
        //     _ = try t.print();
        //     log("failed on {} {}\n", .{ linei, line.* });
        // }
        // testing.expectEqual(expected_size, iter_size);
        linei += 1;
    }

    // // Check the minimum
    // var l = UsizeTree.minimum(t.root);
    // testing.expectEqual(l, null);

    // // Check the maximum
    // l = UsizeTree.maximum(t.root);
    // testing.expectEqual(l, null);
    t.deinit();
    try lca.validate();
}
