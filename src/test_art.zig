const std = @import("std");
const mem = std.mem;
const art = @import("art.zig");
const Art = art.Art;

const tal = std.testing.allocator;
const warn = std.debug.warn;

// set to test against many value types (increases test run time)
const test_all_ValueTypes = false;
const ValueTypes = if (test_all_ValueTypes) [_]type{ u8, u16, u32, u64, usize, f32, f64, bool, [24]u8, [3]usize } else [_]type{usize};
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
    inline for (ValueTypes) |T| {
        var t = Art(T).init(tal);
        defer t.deinit();
        const words = [_][:0]const u8{
            "Aaron",
            "Aaronic",
            "Aaronical",
        };
        for (words) |w, i| {
            _ = try t.insert(w, valAsType(T, i));
        }
    }
}

// TODO make iterator() for Art with same api as StringHashMap
fn free_keys(container: anytype) !void {
    const T = @TypeOf(container.*);
    if (T == std.StringHashMap(usize)) {
        var it = container.iterator();
        while (it.next()) |entry| {
            container.allocator.free(entry.key_ptr.*);
        }
    } else {
        const cbf = struct {
            pub fn f(n: *T.Node, tree: anytype, _: usize) TestingError!bool {
                tree.allocator.free(n.leaf.key);
                return false;
            }
        }.f;
        _ = try container.iter(cbf, container, TestingError!bool);
    }
}

const doInsert = struct {
    fn func(line: [:0]const u8, linei: usize, container: anytype, _: anytype, comptime T: type) anyerror!void {
        const line_ = try container.allocator.dupeZ(u8, line);
        const result = try container.insert(line_, valAsType(T, linei));
        try testing.expect(result == .missing);
    }
}.func;

test "insert many keys" {
    inline for (ValueTypes) |T| {
        var t = Art(T).init(tal);
        defer {
            free_keys(&t) catch unreachable;
            t.deinit();
        }
        const filename = "./testdata/words.txt";
        const lines = try fileEachLine(doInsert, filename, &t, null, T);
        try testing.expectEqual(t.size, lines);
    }
}

fn fileEachLine(comptime do: fn (line: [:0]const u8, linei: usize, container: anytype, data: anytype, comptime T: type) anyerror!void, filename: []const u8, container: anytype, data: anytype, comptime T: type) !usize {
    const f = try std.fs.cwd().openFile(filename, .{ .read = true });
    defer f.close();

    var linei: usize = 1;
    const reader = &f.reader();
    var buf: [512:0]u8 = undefined;
    while (try reader.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;
        try do(buf[0..line.len :0], linei, container, data, T);
        linei += 1;
    }
    return linei - 1;
}

test "insert delete many" {
    inline for (ValueTypes) |T| {
        var t = Art(T).init(tal);
        defer t.deinit();
        const filename = "./testdata/words.txt";

        const lines = try fileEachLine(doInsert, filename, &t, null, T);

        const doDelete = struct {
            fn func(line: [:0]const u8, linei: usize, _t: anytype, data: anytype, comptime _: type) anyerror!void {
                const result = try _t.delete(line);
                try testing.expect(result == .found);
                _t.allocator.free(result.found.key);
                try testing.expectEqual(result.found.value, valAsType(T, linei));
                const nlines = data;
                try testing.expectEqual(_t.size, nlines - linei);
            }
        }.func;
        _ = try fileEachLine(doDelete, filename, &t, lines, T);

        try testing.expectEqual(t.size, 0);
        try free_keys(&t);
    }
}
const testing = std.testing;
test "long prefix" {
    var t = Art(usize).init(tal);
    defer t.deinit();

    try testing.expectEqual(t.insert("this:key:has:a:long:prefix:3", 3), .missing);
    try testing.expectEqual(t.insert("this:key:has:a:long:common:prefix:2", 2), .missing);
    try testing.expectEqual(t.insert("this:key:has:a:long:common:prefix:1", 1), .missing);
    var result = t.search("this:key:has:a:long:common:prefix:1");
    try testing.expectEqual(result.found.value, 1);
    result = t.search("this:key:has:a:long:common:prefix:2");
    try testing.expectEqual(result.found.value, 2);
    result = t.search("this:key:has:a:long:prefix:3");
    try testing.expectEqual(result.found.value, 3);

    const expected = [_][]const u8{
        "this:key:has:a:long:common:prefix:1",
        "this:key:has:a:long:common:prefix:2",
        "this:key:has:a:long:prefix:3",
    };

    var p = prefix_data{ .count = 0, .max_count = 3, .expected = &expected };
    try testing.expect(!try t.iterPrefix("this:key:has", test_prefix_cb, &p, TestingError!bool));
    try testing.expectEqual(p.count, p.max_count);
}

test "insert search uuid" {
    inline for (ValueTypes) |T| {
        var t = Art(T).init(tal);
        defer t.deinit();

        const filename = "./testdata/uuid.txt";

        _ = try fileEachLine(doInsert, filename, &t, null, T);

        const doSearch = struct {
            fn func(line: [:0]const u8, linei: usize, _t: anytype, data: anytype, comptime _: type) anyerror!void {
                _ = data;
                const result = _t.search(line);

                try testing.expect(result == .found);
                // TODO uncomment this line
                try testing.expectEqualSlices(u8, result.found.key[0 .. result.found.key.len - 1], line);
                try testing.expectEqual(result.found.value, valAsType(T, linei));
            }
        }.func;
        _ = try fileEachLine(doSearch, filename, &t, null, T);

        var l = Art(T).minimum(t.root);
        try testing.expect(l != null);
        // TODO uncomment this line
        // try testing.expectEqualStrings("00026bda-e0ea-4cda-8245-522764e9f325\x00", l.?.key);

        l = Art(T).maximum(t.root);
        try testing.expect(l != null);
        // TODO uncomment this line
        // try testing.expectEqualStrings("ffffcb46-a92e-4822-82af-a7190f9c1ec5\x00", l.?.key);
        try free_keys(&t);
    }
}

const prefix_data = struct {
    count: usize,
    max_count: usize,
    expected: []const []const u8,
};

const TestingError = error{ TestUnexpectedResult, TestExpectedEqual } || art.Error;

fn test_prefix_cb(n: anytype, data: *prefix_data, _: usize) TestingError!bool {
    if (n.* == .leaf) {
        const k = n.*.leaf.key;
        try testing.expect(data.count < data.max_count);
        var expected = data.expected[data.count];
        expected.len += 1;
        try testing.expectEqualSlices(u8, k, expected);
        data.count += 1;
    }
    return false;
}

test "iter prefix" {
    var t = Art(usize).init(tal);
    defer t.deinit();
    const s1 = "api.foo.bar";
    const s2 = "api.foo.baz";
    const s3 = "api.foe.fum";
    const s4 = "abc.123.456";
    const s5 = "api.foo";
    const s6 = "api";
    try testing.expectEqual(t.insert(s1, 0), .missing);
    try testing.expectEqual(t.insert(s2, 0), .missing);
    try testing.expectEqual(t.insert(s3, 0), .missing);
    try testing.expectEqual(t.insert(s4, 0), .missing);
    try testing.expectEqual(t.insert(s5, 0), .missing);
    try testing.expectEqual(t.insert(s6, 0), .missing);

    // Iterate over api
    const expected = [_][]const u8{ s6, s3, s5, s1, s2 };
    var p = prefix_data{ .count = 0, .max_count = 5, .expected = &expected };
    try testing.expect(!try t.iterPrefix("api", test_prefix_cb, &p, TestingError!bool));
    try testing.expectEqual(p.max_count, p.count);

    // Iterate over 'a'
    const expected2 = [_][]const u8{ s4, s6, s3, s5, s1, s2 };
    var p2 = prefix_data{ .count = 0, .max_count = 6, .expected = &expected2 };
    try testing.expect(!try t.iterPrefix("a", test_prefix_cb, &p2, TestingError!bool));
    try testing.expectEqual(p2.max_count, p2.count);

    // Check a failed iteration
    var p3 = prefix_data{ .count = 0, .max_count = 6, .expected = &[_][]const u8{} };
    try testing.expect(!try t.iterPrefix("b", test_prefix_cb, &p3, TestingError!bool));
    try testing.expectEqual(p3.count, 0);

    // Iterate over api.
    const expected4 = [_][]const u8{ s3, s5, s1, s2 };
    var p4 = prefix_data{ .count = 0, .max_count = 4, .expected = &expected4 };
    try testing.expect(!try t.iterPrefix("api.", test_prefix_cb, &p4, TestingError!bool));
    try testing.expectEqual(p4.max_count, p4.count);

    // Iterate over api.foo.ba
    const expected5 = [_][]const u8{s1};
    var p5 = prefix_data{ .count = 0, .max_count = 1, .expected = &expected5 };
    try testing.expect(!try t.iterPrefix("api.foo.bar", test_prefix_cb, &p5, TestingError!bool));
    try testing.expectEqual(p5.max_count, p5.count);

    // Check a failed iteration on api.end
    var p6 = prefix_data{ .count = 0, .max_count = 0, .expected = &[_][]const u8{} };
    try testing.expect(!try t.iterPrefix("api.end", test_prefix_cb, &p6, TestingError!bool));
    try testing.expectEqual(p6.count, 0);

    // Iterate over empty prefix
    var p7 = prefix_data{ .count = 0, .max_count = 6, .expected = &expected2 };
    try testing.expect(!try t.iterPrefix("", test_prefix_cb, &p7, TestingError!bool));
    try testing.expectEqual(p7.max_count, p7.count);
}

test "insert very long key" {
    var t = Art(void).init(tal);
    defer t.deinit();

    const key1 = [_:0]u8{
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
    const key2 = [_:0]u8{
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
    try testing.expect((try t.insert(&key1, {})) == .missing);
    try testing.expect((try t.insert(&key2, {})) == .missing);
    _ = try t.insert(&key2, {});
    try testing.expectEqual(t.size, 2);
}

test "insert search" {
    inline for (ValueTypes) |T| {
        var t = Art(T).init(tal);
        defer t.deinit();
        const filename = "./testdata/words.txt";

        _ = try fileEachLine(doInsert, filename, &t, null, T);

        const doSearch = struct {
            fn func(line: [:0]const u8, linei: usize, _t: anytype, data: anytype, comptime _: type) anyerror!void {
                _ = data;
                const result = _t.search(line);
                try testing.expect(result == .found);
                try testing.expectEqual(result.found.value, valAsType(T, linei));
            }
        }.func;
        _ = try fileEachLine(doSearch, filename, &t, null, T);

        var l = Art(T).minimum(t.root);
        try testing.expectEqualSlices(u8, l.?.key, "A\x00");

        l = Art(T).maximum(t.root);
        // TODO uncomment this line
        // try testing.expectEqualSlices(u8, l.?.key, "zythum\x00");
        try free_keys(&t);
    }
}

fn sizeCb(n: anytype, data: *usize, _: usize) TestingError!bool {
    if (n.* == .leaf) {
        data.* += 1;
    }
    return false;
}

test "insert search delete" {
    var t = Art(usize).init(tal);
    defer t.deinit();
    const filename = "./testdata/words.txt";

    const lines = try fileEachLine(doInsert, filename, &t, null, usize);

    const doSearchDelete = struct {
        fn func(line: [:0]const u8, linei: usize, _t: anytype, data: anytype, comptime _: type) anyerror!void {
            const nlines = data;
            const result = _t.search(line);
            try testing.expect(result == .found);
            try testing.expectEqual(result.found.value, linei);

            const result2 = try _t.delete(line);
            try testing.expect(result2 == .found);
            _t.allocator.free(result2.found.key);
            try testing.expectEqual(result2.found.value, linei);
            const expected_size = nlines - linei;
            try testing.expectEqual(expected_size, _t.size);
        }
    }.func;
    _ = try fileEachLine(doSearchDelete, filename, &t, lines, usize);

    var l = Art(usize).minimum(t.root);
    try testing.expectEqual(l, null);

    l = Art(usize).maximum(t.root);
    try testing.expectEqual(l, null);
    try free_keys(&t);
}

const letters = [_][:0]const u8{ "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z" };
test "insert search delete 2" {
    var t = Art(usize).init(tal);
    defer t.deinit();

    var linei: usize = 1;
    for (letters) |letter| {
        _ = try t.insert(letter, linei);
        linei += 1;
    }
    {
        var l = Art(usize).minimum(t.root);
        try testing.expectEqualSlices(u8, l.?.key, "A\x00");

        l = Art(usize).maximum(t.root);
        try testing.expectEqualSlices(u8, l.?.key, "z\x00");
    }
    const nlines = linei - 1;

    // Search for each line
    linei = 1;
    for (letters) |letter| {
        const result = t.search(letter);
        try testing.expect(result == .found);
        try testing.expectEqual(result.found.value, linei);

        const result2 = try t.delete(letter);
        try testing.expect(result2 == .found);
        try testing.expectEqual(result2.found.value, linei);
        const expected_size = nlines - linei;
        try testing.expectEqual(expected_size, t.size);

        var iter_size: usize = 0;
        _ = try t.iter(sizeCb, &iter_size, TestingError!bool);
        try testing.expectEqual(expected_size, iter_size);

        linei += 1;
    }

    var l = Art(usize).minimum(t.root);
    try testing.expectEqual(l, null);

    l = Art(usize).maximum(t.root);
    try testing.expectEqual(l, null);
}

test "insert random delete" {
    var t = Art(usize).init(tal);
    defer t.deinit();
    const filename = "./testdata/words.txt";

    _ = try fileEachLine(doInsert, filename, &t, null, usize);

    const key_to_delete = "A";
    const lineno = 1;
    const result = t.search(key_to_delete);
    try testing.expect(result == .found);
    try testing.expectEqual(result.found.value, lineno);

    const result2 = try t.delete(key_to_delete);
    t.allocator.free(result2.found.key);
    try testing.expect(result2 == .found);
    try testing.expectEqual(result2.found.value, lineno);

    const result3 = t.search(key_to_delete);
    try testing.expect(result3 == .missing);
    try free_keys(&t);
}

fn iter_cb(n: anytype, out: *[2]u64, _: usize) TestingError!bool {
    const l = n.leaf;
    const line = l.value;
    const mask = (line * (l.key[0] + l.key.len - 1));
    out[0] += 1;
    out[1] ^= mask;
    return false;
}

test "insert iter" {
    var t = Art(usize).init(tal);
    defer t.deinit();
    const filename = "./testdata/words.txt";

    var xor_mask: u64 = 0;
    const doInsert_ = struct {
        fn func(line: [:0]const u8, linei: usize, _t: anytype, _xor_mask: anytype, comptime _: type) anyerror!void {
            const line_ = try _t.allocator.dupeZ(u8, line);
            const result = try _t.insert(line_, linei);
            try testing.expect(result == .missing);
            _xor_mask.* ^= (linei * (line[0] + line.len));
        }
    }.func;
    const nlines = try fileEachLine(doInsert_, filename, &t, &xor_mask, usize);

    var out = [1]u64{0} ** 2;
    _ = try t.iter(iter_cb, &out, TestingError!bool);
    try testing.expectEqual(nlines, out[0]);
    try testing.expectEqual(xor_mask, out[1]);
    try free_keys(&t);
}

test "max prefix len iter" {
    var t = Art(usize).init(tal);
    defer t.deinit();

    const key1 = "foobarbaz1-test1-foo";
    const key2 = "foobarbaz1-test1-bar";
    const key3 = "foobarbaz1-test2-foo";

    try testing.expectEqual(t.insert(key1, 1), .missing);
    try testing.expectEqual(t.insert(key2, 2), .missing);
    try testing.expectEqual(t.insert(key3, 3), .missing);
    try testing.expectEqual(t.size, 3);

    const expected = [_][]const u8{ key2, key1 };
    var p = prefix_data{ .count = 0, .max_count = 2, .expected = &expected };
    try testing.expect(!try t.iterPrefix("foobarbaz1-test1", test_prefix_cb, &p, TestingError!bool));
    try testing.expectEqual(p.count, p.max_count);
}

const DummyStream = struct {
    const Self = @This();
    pub const WriteError = error{};

    pub fn print(self: *Self, comptime fmt: []const u8, _: anytype) WriteError!usize {
        _ = fmt;
        _ = self;
        return 0;
    }
};
test "display children" {
    testing.log_level = .debug;
    const letter_ranges = [_][2]u8{ .{ 0, 4 }, .{ 0, 16 }, .{ 0, 26 }, .{ 0, letters.len } };
    for (letter_ranges) |range| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const allr = &arena.allocator;
        var t = Art(usize).init(allr);
        defer t.deinit();
        for (letters[range[0]..range[1]]) |word, i| {
            var j: u8 = 0;
            while (j < 10) : (j += 1) {
                const nt_letter = try allr.allocSentinel(u8, word.len + j, 0);
                mem.set(u8, nt_letter, word[0]);
                try testing.expectEqual(t.insert(nt_letter, i), .missing);
            }
        }

        var dummyStream = DummyStream{};
        Art(usize).displayNode(&dummyStream, t.root, 0);
        Art(usize).displayChildren(&dummyStream, t.root, 0);
    }
}

const CustomType = struct { a: f32, b: struct { c: bool } };
const Uab = union(enum) { a, b };
const IterTypes = [_]type{ u8, u16, i32, bool, f32, f64, @Vector(10, u8), [10]u8, CustomType, Uab, [10]*u32, *u16, *isize };
fn defaultFor(comptime T: type) T {
    const ti = @typeInfo(T);
    return switch (ti) {
        .Void => {},
        .Int, .Float => 42,
        .Pointer => blk: {
            var x: ti.Pointer.child = 42;
            var y = @as(ti.Pointer.child, x);
            break :blk &y;
        },
        .Bool => true,
        .Array => [1]ti.Array.child{defaultFor(ti.Array.child)} ** ti.Array.len,
        .Vector => [1]ti.Vector.child{defaultFor(ti.Vector.child)} ** ti.Vector.len,
        .Struct => switch (T) {
            CustomType => .{ .a = 42, .b = .{ .c = true } },
            else => @compileLog(ti),
        },
        .Union => switch (T) {
            Uab => .a,
            else => @compileLog(ti),
        },
        else => @compileLog(ti),
    };
}
fn cb(node: anytype, data: anytype, _: usize) TestingError!bool {
    _ = node;
    const ti = @typeInfo(@TypeOf(data));
    if (ti != .Pointer)
        try testing.expectEqual(defaultFor(@TypeOf(data)), data);
    return false;
}

test "iter data types" {
    inline for (IterTypes) |T| {
        var t = Art(usize).init(tal);
        defer t.deinit();
        _ = try t.insert("A", 0);
        _ = try t.iter(cb, defaultFor(T), TestingError!bool);
    }
}

test "print to stream" {
    var list = std.ArrayList(u8).init(tal);
    defer list.deinit();
    var writer = &list.writer();
    var t = Art(usize).init(tal);
    defer t.deinit();
    for (letters) |l| {
        _ = try t.insert(l, 0);
    }
    try t.printToStream(writer);
}

fn bench(container: anytype, comptime appen_fn_name: []const u8, comptime get_fn_name: []const u8, comptime del_fn_name: []const u8) !void {
    const filename = "./testdata/words.txt";

    var timer = try std.time.Timer.start();
    const doInsert_ = struct {
        fn func(line: [:0]const u8, linei: usize, _container: anytype, _: anytype, comptime U: type) anyerror!void {
            _ = U;
            const append_fn = @field(_container, appen_fn_name);
            const line_ = try _container.allocator.dupeZ(u8, line);
            _ = try append_fn(line_, linei);
        }
    }.func;
    _ = try fileEachLine(doInsert_, filename, container, null, usize);
    const t1 = timer.read();

    timer.reset();
    const doSearch = struct {
        fn func(line: [:0]const u8, linei: usize, _container: anytype, _: anytype, comptime U: type) anyerror!void {
            _ = U;
            _ = linei;
            const get_fn = @field(_container, get_fn_name);
            if (@TypeOf(_container) == *Art(usize)) {
                const result = get_fn(line);
                try testing.expect(result == .found);
            } else {
                const result = get_fn(line);
                try testing.expect(result != null);
            }
        }
    }.func;
    _ = try fileEachLine(doSearch, filename, container, null, usize);
    const t2 = timer.read();

    timer.reset();
    const doDelete = struct {
        fn func(line: [:0]const u8, linei: usize, _container: anytype, _: anytype, comptime U: type) anyerror!void {
            _ = U;
            _ = linei;
            const del_fn = @field(_container, del_fn_name);
            // @compileLog(@TypeOf(_container));
            if (@TypeOf(_container) == *Art(usize)) {
                const result = try del_fn(line);
                try testing.expect(result == .found);
            } else {
                const result = del_fn(line);
                try testing.expect(result);
            }
        }
    }.func;
    _ = try fileEachLine(doDelete, filename, container, null, usize);
    const t3 = timer.read();

    warn("insert {}ms, search {}ms, delete {}ms, combined {}ms\n", .{ t1 / 1000000, t2 / 1000000, t3 / 1000000, (t1 + t2 + t3) / 1000000 });
    try free_keys(container);
}

test "bench against StringHashMap" {
    {
        var arena = std.heap.ArenaAllocator.init(tal);
        var aa = &arena.allocator;
        var map = std.StringHashMap(usize).init(aa);
        defer arena.deinit();
        warn("\nStringHashMap\n", .{});
        try bench(&map, "put", "get", "remove");
    }
    {
        var arena = std.heap.ArenaAllocator.init(tal);
        var aa = &arena.allocator;
        var t = Art(usize).init(aa);
        defer arena.deinit();
        warn("\nArt\n", .{});
        try bench(&t, "insert", "search", "delete");
    }
}

test "fuzz" {
    var t = Art(u8).init(tal);
    defer t.deinit();
    // generate random keys and values
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allr = &arena.allocator;
    var rnd = std.rand.DefaultPrng.init(@intCast(u64, std.time.nanoTimestamp()));
    var found = std.StringHashMap(void).init(allr);

    const num_keys = 100000;
    var keys: [num_keys][:0]const u8 = undefined;
    var i: usize = 0;
    while (i < num_keys) : (i += 1) {
        const klen = std.rand.Random.intRangeLessThan(rnd.random(), u8, 1, 255);

        var key = try allr.allocSentinel(u8, klen, 0);
        for (key) |*c|
            c.* = std.rand.Random.intRangeLessThan(rnd.random(), u8, 1, 255);
        keys[i] = key;
        _ = try t.insert(key, klen);
    }

    for (keys) |key| {
        const prev_found = found.get(key);
        const already_deleted = prev_found == null;
        const result = t.search(key);
        if (result != .found and already_deleted) {
            std.log.err("result != .found, already_deleted?: {}, key.len: {} key: '{s}' tree.size: {}", .{ already_deleted, key.len, key, t.size });
        } else {
            try found.put(key, .{});
        }
        if (prev_found == null) {
            try testing.expect(result == .found);
            try testing.expectEqual(result.found.value, @truncate(u8, key.len));
        }
        _ = try t.delete(key);
    }
}
