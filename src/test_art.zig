const std = @import("std");
const mem = std.mem;
const art = @import("art.zig");
const ArtTree = art.ArtTree;
const log = art.log;

const tal = std.testing.allocator;
const cal = std.heap.c_allocator;
const TestAllTypes = false;
const Types = if (TestAllTypes) [_]type{ u8, u16, u32, u64, usize, f32, f64, bool, [24]u8, [3]usize } else [_]type{usize};
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
        var t = ArtTree(T).init(lca.internal_allocator);
        defer t.deinit();

        const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
        defer f.close();
        var linei: usize = 1;
        const stream = &f.inStream();
        var buf: [256]u8 = undefined;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = try t.insert(line.*, valAsType(T, linei));
            linei += 1;
        }
        testing.expectEqual(t.size, linei - 1);

        try lca.validate();
    }
}

test "insert and delete many" {
    inline for (Types) |T| {
        var lca = std.testing.LeakCountAllocator.init(cal);
        var t = ArtTree(T).init(lca.internal_allocator);
        defer t.deinit();

        const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
        defer f.close();

        var linei: usize = 1;
        const stream = &f.inStream();
        var buf: [256]u8 = undefined;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = try t.insert(line.*, valAsType(T, linei));
            linei += 1;
        }
        const nlines = linei;
        testing.expectEqual(t.size, linei - 1);
        _ = try f.seekTo(0);

        linei = 1;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = try t.delete(line.*);

            testing.expect(result == .found);
            testing.expectEqual(result.found, valAsType(T, linei));
            testing.expectEqual(t.size, nlines - linei - 1);
            linei += 1;
        }
        testing.expectEqual(t.size, 0);
        try lca.validate();
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

    const expected = [_][]const u8{
        "this:key:has:a:long:common:prefix:1\x00",
        "this:key:has:a:long:common:prefix:2\x00",
        "this:key:has:a:long:prefix:3\x00",
    };

    var p = prefix_data{ .count = 0, .max_count = 3, .expected = &expected };
    testing.expect(!t.iterPrefix("this:key:has", test_prefix_cb, &p));
    testing.expectEqual(p.count, p.max_count);
}

test "insert search uuid" {
    inline for (Types) |T| {
        var lca = std.testing.LeakCountAllocator.init(cal);
        var t = ArtTree(T).init(lca.internal_allocator);
        defer t.deinit();

        const f = try std.fs.cwd().openFile("./testdata/uuid.txt", .{ .read = true });
        defer f.close();

        var linei: usize = 1;
        const stream = &f.inStream();
        var buf: [256]u8 = undefined;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = try t.insert(line.*, valAsType(T, linei));
            testing.expect(result == .missing);
            linei += 1;
        }

        try f.seekTo(0);
        linei = 1;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = t.search(line.*);
            testing.expect(result == .found);
            testing.expectEqual(result.found, linei);

            linei += 1;
        }

        // Check the minimum
        var l = UsizeTree.minimum(t.root);
        testing.expect(l != null);
        testing.expectEqualSlices(u8, l.?.key, "00026bda-e0ea-4cda-8245-522764e9f325\x00");

        // Check the maximum
        l = UsizeTree.maximum(t.root);
        testing.expect(l != null);
        testing.expectEqualSlices(u8, l.?.key, "ffffcb46-a92e-4822-82af-a7190f9c1ec5\x00");

        try lca.validate();
    }
}

const prefix_data = struct {
    count: usize,
    max_count: usize,
    expected: []const []const u8,
};

fn test_prefix_cb(n: *UsizeTree.Node, data: *c_void, depth: usize) bool {
    // std.debug.warn("test_prefix_cb {}\n", .{n});
    if (n.* == .leaf) {
        const k = n.*.leaf.key;
        // var p = @ptrCast(*prefix_data, @alignCast(@alignOf(*prefix_data), data));
        var p = mem.bytesAsValue(prefix_data, mem.asBytes(@intToPtr(*prefix_data, @ptrToInt(data))));
        // std.debug.warn("test_prefix_cb {} key {s} expected {}\n", .{ p, k, p.expected[p.count] });
        testing.expect(p.count < p.max_count);
        const expected = p.expected[p.count];
        testing.expectEqualSlices(u8, k, expected);
        p.count += 1;
    }
    return false;
}

test "iter prefix" {
    var t = ArtTree(usize).init(cal);
    defer t.deinit();
    const s1 = "api.foo.bar\x00";
    const s2 = "api.foo.baz\x00";
    const s3 = "api.foe.fum\x00";
    const s4 = "abc.123.456\x00";
    const s5 = "api.foo\x00";
    const s6 = "api\x00";
    testing.expectEqual(t.insert(s1, 0), .missing);
    testing.expectEqual(t.insert(s2, 0), .missing);
    testing.expectEqual(t.insert(s3, 0), .missing);
    testing.expectEqual(t.insert(s4, 0), .missing);
    testing.expectEqual(t.insert(s5, 0), .missing);
    testing.expectEqual(t.insert(s6, 0), .missing);

    // Iterate over api
    const expected = [_][]const u8{ s6, s3, s5, s1, s2 };
    var p = prefix_data{ .count = 0, .max_count = 5, .expected = &expected };
    testing.expect(!t.iterPrefix("api", test_prefix_cb, &p));
    testing.expectEqual(p.max_count, p.count);

    // Iterate over 'a'
    const expected2 = [_][]const u8{ s4, s6, s3, s5, s1, s2 };
    var p2 = prefix_data{ .count = 0, .max_count = 6, .expected = &expected2 };
    testing.expect(!t.iterPrefix("a", test_prefix_cb, &p2));
    testing.expectEqual(p2.max_count, p2.count);

    // Check a failed iteration
    var p3 = prefix_data{ .count = 0, .max_count = 6, .expected = &[_][]const u8{} };
    testing.expect(!t.iterPrefix("b", test_prefix_cb, &p3));
    testing.expectEqual(p3.count, 0);

    // Iterate over api.
    const expected4 = [_][]const u8{ s3, s5, s1, s2 };
    var p4 = prefix_data{ .count = 0, .max_count = 4, .expected = &expected4 };
    testing.expect(!t.iterPrefix("api.", test_prefix_cb, &p4));
    testing.expectEqual(p4.max_count, p4.count);

    // Iterate over api.foo.ba
    const expected5 = [_][]const u8{s1};
    var p5 = prefix_data{ .count = 0, .max_count = 1, .expected = &expected5 };
    testing.expect(!t.iterPrefix("api.foo.bar", test_prefix_cb, &p5));
    testing.expectEqual(p5.max_count, p5.count);

    // Check a failed iteration on api.end
    var p6 = prefix_data{ .count = 0, .max_count = 0, .expected = &[_][]const u8{} };
    testing.expect(!t.iterPrefix("api.end", test_prefix_cb, &p6));
    testing.expectEqual(p6.count, 0);

    // Iterate over empty prefix
    var p7 = prefix_data{ .count = 0, .max_count = 6, .expected = &expected2 };
    testing.expect(!t.iterPrefix("", test_prefix_cb, &p7));
    testing.expectEqual(p7.max_count, p7.count);
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
    inline for (Types) |T| {
        var lca = std.testing.LeakCountAllocator.init(cal);
        var t = ArtTree(T).init(lca.internal_allocator);
        defer t.deinit();

        const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
        defer f.close();

        var linei: usize = 1;
        const stream = &f.inStream();
        var buf: [512:0]u8 = undefined;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = try t.insert(line.*, valAsType(T, linei));
            linei += 1;
        }
        // Seek back to the start
        _ = try f.seekTo(0);

        // Search for each line
        linei = 1;
        while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
            buf[line.len] = 0;
            line.len += 1;
            const result = t.search(line.*);
            testing.expect(result == .found);
            testing.expectEqual(result.found, valAsType(T, linei));
            linei += 1;
        }

        // Check the minimum
        var l = ArtTree(T).minimum(t.root);
        testing.expectEqualSlices(u8, l.?.key, "A\x00");

        // Check the maximum
        l = ArtTree(T).maximum(t.root);
        testing.expectEqualSlices(u8, l.?.key, "zythum\x00");
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

test "insert search delete" {
    var lca = std.testing.LeakCountAllocator.init(std.heap.c_allocator);
    var t = ArtTree(usize).init(lca.internal_allocator);
    defer t.deinit();
    const filename = "./testdata/words.txt";

    const f = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer f.close();

    var linei: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        const result = try t.insert(line.*, linei);
        linei += 1;
    }
    const nlines = linei - 1;
    // Seek back to the start
    _ = try f.seekTo(0);
    // Search for each line
    linei = 1;
    var first_char: u8 = 0;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        const result = t.search(line.*);
        testing.expect(result == .found);
        testing.expectEqual(result.found, linei);

        const result2 = try t.delete(line.*);
        testing.expect(result2 == .found);
        testing.expectEqual(result2.found, linei);
        const expected_size = nlines - linei;
        testing.expectEqual(expected_size, t.size);
        linei += 1;
    }

    // Check the minimum
    var l = UsizeTree.minimum(t.root);
    testing.expectEqual(l, null);

    // Check the maximum
    l = UsizeTree.maximum(t.root);
    testing.expectEqual(l, null);

    try lca.validate();
}

test "insert search delete 2" {
    var lca = std.testing.LeakCountAllocator.init(std.heap.c_allocator);
    const al = lca.internal_allocator;
    var t = ArtTree(usize).init(al);
    defer t.deinit();
    const data = [_][]const u8{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
    const joined = try std.mem.join(al, "\x00\n", &data);
    defer al.free(joined);
    var f = std.io.fixedBufferStream(joined);

    var linei: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        const result = try t.insert(line.*, linei);
        linei += 1;
    }
    const nlines = linei - 1;
    // Seek back to the start
    _ = try f.seekTo(0);
    // Search for each line
    linei = 1;
    var first_char: u8 = 0;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        const result = t.search(line.*);
        testing.expect(result == .found);
        testing.expectEqual(result.found, linei);

        const result2 = try t.delete(line.*);
        testing.expect(result2 == .found);
        testing.expectEqual(result2.found, linei);
        const expected_size = nlines - linei;
        testing.expectEqual(expected_size, t.size);

        var iter_size: usize = 0;
        _ = t.iter(sizeCb, &iter_size);
        testing.expectEqual(expected_size, iter_size);

        linei += 1;
    }

    // Check the minimum
    var l = UsizeTree.minimum(t.root);
    testing.expectEqual(l, null);

    // Check the maximum
    l = UsizeTree.maximum(t.root);
    testing.expectEqual(l, null);

    try lca.validate();
}

test "insert random delete" {
    var lca = std.testing.LeakCountAllocator.init(std.heap.c_allocator);
    var t = ArtTree(usize).init(lca.internal_allocator);
    defer t.deinit();
    const filename = "./testdata/words.txt";

    const f = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer f.close();

    var linei: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        const result = try t.insert(line.*, linei);
        linei += 1;
    }

    const key_to_delete = "A\x00";
    const lineno = 1;
    const result = t.search(key_to_delete);
    testing.expect(result == .found);
    testing.expectEqual(result.found, lineno);

    const result2 = try t.delete(key_to_delete);
    testing.expect(result2 == .found);
    testing.expectEqual(result2.found, lineno);

    const result3 = t.search(key_to_delete);
    testing.expect(result3 == .missing);

    try lca.validate();
}

// TODO test_art_insert_iter

test "max prefix len iter" {
    var t = ArtTree(usize).init(tal);
    defer t.deinit();

    const key1 = "foobarbaz1-test1-foo\x00";
    const key2 = "foobarbaz1-test1-bar\x00";
    const key3 = "foobarbaz1-test2-foo\x00";

    testing.expectEqual(t.insert(key1, 1), .missing);
    testing.expectEqual(t.insert(key2, 2), .missing);
    testing.expectEqual(t.insert(key3, 3), .missing);
    testing.expectEqual(t.size, 3);

    const expected = [_][]const u8{ key2, key1 };
    var p = prefix_data{ .count = 0, .max_count = 2, .expected = &expected };
    testing.expect(!t.iterPrefix("foobarbaz1-test1", test_prefix_cb, &p));
    testing.expectEqual(p.count, p.max_count);
}
