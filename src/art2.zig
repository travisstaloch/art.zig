const std = @import("std");

const ShowDebugLog = true;
fn log(comptime fmt: []const u8, vals: var) void {
    if (ShowDebugLog) std.debug.warn(fmt, vals);
}

pub fn art_tree(comptime T: type) type {
    return struct {
        root: ?*art_node,
        size: usize,
        allr: *std.mem.Allocator,

        const MAX_PREFIX_LEN = 10;
        const art_node_t = struct {
            num_children: u8,
            partial_len: usize,
            partial: [MAX_PREFIX_LEN]u8,
        };

        pub fn art_node_sized(comptime keysLen: usize, comptime childrenLen: usize) type {
            return struct {
                n: art_node_t,
                keys: [keysLen]u8,
                children: [childrenLen]*art_node,
                const Self = @This();
                pub fn init() Self {}
            };
        }

        pub const art_node4 = art_node_sized(4, 4);
        pub const art_node16 = art_node_sized(16, 16);
        pub const art_node48 = art_node_sized(256, 48);
        pub const art_node256 = art_node_sized(0, 256);

        const art_leaf = struct {
            value: ?T,
            key: []u8,
        };

        const art_node = union(enum) {
            leaf: art_leaf,
            node4: art_node4,
            node16: art_node16,
            node48: art_node48,
            node256: art_node256,
            pub fn node(self: *art_node) *art_node_t {
                return switch (self.*) {
                    .node4 => &self.node4.n,
                    .node16 => &self.node16.n,
                    .node48 => &self.node48.n,
                    .node256 => &self.node256.n,
                    .leaf => unreachable,
                };
            }
        };

        const Tree = art_tree(T);

        pub fn init(allr: *std.mem.Allocator) !Tree {
            return Tree{ .root = null, .size = 0, .allr = allr };
        }
        const Result = union(enum) { New, Old: *art_node };
        pub fn deinit(t: *Tree) void {}
        fn make_leaf(key: []const u8, value: T) !*art_node {
            // var l = try a.create(art_leaf);
            var n = try a.create(art_node);
            n.* = .{ .leaf = .{ .value = value, .key = try a.alloc(u8, key.len) } };
            std.mem.copy(u8, n.leaf.key, key);
            return n;
        }
        fn leaf_matches() void {}
        pub fn insert(t: *Tree, key: []const u8, value: T) !Result {
            const res = try t.recursive_insert(t.root, &t.root, key, value, 0);
            if (res == .New) t.size += 1;
            return res;
        }
        fn longest_common_prefix(l: art_leaf, l2: art_leaf, depth: usize) usize {
            const max_cmp = std.math.min(l.key.len, l2.key.len) - depth;
            var common: usize = 0;
            while (common < max_cmp and l.key[common] == l2.key[common]) : (common += 1) {}
            return common;
        }
        fn prefix_mismatch(_n: *art_node, key: []const u8, depth: usize) usize {
            const n = _n.node();
            var max_cmp = std.math.min(std.math.min(MAX_PREFIX_LEN, n.partial_len), key.len - depth);
            var idx: usize = 0;
            while (idx < max_cmp) : (idx += 1) if (n.partial[idx] != key[depth + idx])
                return idx;
            if (n.partial_len > MAX_PREFIX_LEN) {
                const l = minimum(_n);
                max_cmp = std.math.min(l.?.key.len, key.len) - depth;
                while (idx < max_cmp) : (idx += 1) if (l.?.key[idx + depth] != key[depth + idx])
                    return idx;
            }
            return idx;
        }
        fn empty_node4() art_node {
            return .{ .node4 = .{ .n = .{ .num_children = 0, .partial_len = 0, .partial = undefined }, .keys = undefined, .children = undefined } };
        }
        // Find the minimum leaf under a node
        fn minimum(_n: ?*art_node) ?*art_leaf {
            if (_n == null) return null;
            var n = _n orelse unreachable;

            var idx: usize = 0;
            switch (n.*) {
                .leaf => return &n.leaf,
                .node4 => return minimum(n.node4.children[0]),
                .node16 => return minimum(n.node16.children[0]),
                .node48 => {
                    while (n.node48.keys[idx] == 0) : (idx += 1)
                        return minimum(n.node48.children[n.node48.keys[idx] - 1]);
                },
                .node256 => {
                    while (!has_child_idx(n, idx)) : (idx += 1)
                        return minimum(n.node256.children[idx]);
                },
                else => unreachable,
            }
            unreachable;
        }
        fn has_child_idx(n: *art_node, i: usize) bool {
            return switch (n.*) {
                .node4 => @ptrToInt(n.node4.children[i]) != 0,
                .node16 => @ptrToInt(n.node16.children[i]) != 0,
                .node48 => @ptrToInt(n.node48.children[i]) != 0,
                .node256 => @ptrToInt(n.node256.children[i]) != 0,
                else => false,
            };
        }
        const InsertError = error{OutOfMemory};
        pub fn recursive_insert(t: *Tree, _n: ?*art_node, ref: *?*art_node, key: []const u8, value: T, _depth: usize) InsertError!Result {
            if (_n == null) {
                ref.* = try make_leaf(key, value);
                return .New;
            }
            var n = _n orelse unreachable;
            var depth = _depth;
            if (n.* == .leaf) {
                var l = n.leaf;
                if (std.mem.eql(u8, l.key, key)) return Result{ .Old = n };

                var new_node = try t.allr.create(art_node);
                new_node.* = empty_node4();
                var l2 = try make_leaf(key, value);
                const longest_prefix = longest_common_prefix(l, l2.leaf, depth);
                new_node.node4.n.partial_len = longest_prefix;
                var key_copy = key;
                key_copy.ptr += depth;
                key_copy.len -= std.math.min(MAX_PREFIX_LEN, longest_prefix);
                std.mem.copy(u8, &new_node.node4.n.partial, key_copy);
                ref.* = new_node;
                try t.add_child4(new_node, ref, l.key[depth + longest_prefix], n);
                try t.add_child4(new_node, ref, l2.leaf.key[depth + longest_prefix], l2);
                return .New;
            }

            const anode = n.node();

            if (anode.partial_len != 0) {
                const prefix_diff = prefix_mismatch(n, key, depth);
                if (prefix_diff >= anode.partial_len) {
                    depth += anode.partial_len;
                    return t.recurse_search(n, ref, key, value, depth);
                }

                var new_node = try t.allr.create(art_node);
                new_node.* = empty_node4();
                ref.* = new_node;
                anode.partial_len = prefix_diff;
                std.mem.copy(u8, &new_node.node4.n.partial, &anode.partial);

                if (anode.partial_len <= MAX_PREFIX_LEN) {
                    try t.add_child4(new_node, ref, anode.partial[prefix_diff], n);
                    anode.partial_len -= (prefix_diff + 1);
                    std.mem.copy(u8, &anode.partial, anode.partial[prefix_diff + 1 ..]);
                } else {
                    anode.partial_len -= (prefix_diff + 1);
                    const l = minimum(n);
                    try t.add_child4(new_node, ref, l.?.key[depth + prefix_diff], n);
                    std.mem.copy(u8, &anode.partial, l.?.key[depth + prefix_diff + 1 ..]);
                }

                var l = try make_leaf(key, value);
                try t.add_child4(new_node, ref, key[depth + prefix_diff], l);
                return Result{ .New = {} };
            }
            // std.debug.warn("unreachable {} {} {}\n", .{ key, value, n });
            // unreachable;
            return t.recurse_search(n, ref, key, value, depth);
        }
        fn recurse_search(t: *Tree, n: *art_node, ref: *?*art_node, key: []const u8, value: T, depth: usize) InsertError!Result {
            const child = find_child(n, key[depth]);
            if (child.* != null) return t.recursive_insert(child.*, child, key, value, depth);

            var l = try make_leaf(key, value);
            try t.add_child(n, ref, key[depth], l);
            return Result{ .New = {} };
        }
        fn copy_header(dest: *art_node, src: *art_node) void {
            dest.node().num_children = src.node().num_children;
            dest.node().partial_len = src.node().partial_len;
            std.mem.copy(u8, &dest.node().partial, &src.node().partial);
        }
        // TODO: remove this helper for casting away constness
        fn castPtr(comptime P: type, p: var) P {
            return @intToPtr(P, @ptrToInt(p));
        }
        fn add_child(t: *Tree, n: *art_node, ref: *?*art_node, c: u8, child: *art_node) InsertError!void {
            return switch (n.*) {
                .node4 => try t.add_child4(n, ref, c, child),
                .node16 => try t.add_child16(n, ref, c, child),
                .node48 => try t.add_child48(n, ref, c, child),
                .node256 => try t.add_child256(n, ref, c, child),
                else => unreachable,
            };
        }
        fn find_child(n: *art_node, c: u8) *?*art_node {
            const anode = n.node();
            switch (n.*) {
                .node4 => {
                    var i: usize = 0;
                    while (i < anode.num_children) : (i += 1) if (n.node4.keys[i] == c)
                        return &@as(?*art_node, n.node4.children[i]);
                },
                .node16 => {
                    // TODO: simd
                    var bitfield: usize = 0;
                    for (n.node16.keys) |k, i| {
                        if (k == c)
                            bitfield |= (@as(usize, 1) << @truncate(u6, i));
                    }
                    const mask = (@as(usize, 1) << @truncate(u6, anode.num_children)) - 1;
                    bitfield &= mask;
                    // end TODO
                    if (bitfield != 0) return &(@as(?*art_node, n.node16.children[@ctz(usize, bitfield)]));
                },
                .node48 => if (n.node48.keys[c] != 0) return &(@as(?*art_node, n.node48.children[n.node48.keys[c] - 1])),
                .node256 => if (has_child_idx(n, c)) return &(@as(?*art_node, n.node256.children[c])),
                else => unreachable,
            }
            var x: ?*art_node = null;
            return &@as(?*art_node, x);
        }
        fn add_child4(t: *Tree, n: *art_node, ref: *?*art_node, c: u8, child: *art_node) InsertError!void {
            if (n.node4.n.num_children < 4) {
                var idx: usize = 0;
                while (idx < n.node4.n.num_children) : (idx += 1) if (c < n.node4.keys[idx])
                    break;
                std.debug.warn("idx {} {}\n", .{ idx, n.node4.keys });
                std.debug.warn("n {}\n", .{n});
                std.debug.warn("child {}\n", .{child});
                std.mem.copy(u8, n.node4.keys[idx + 1 ..], n.node4.keys[idx .. n.node4.keys.len - 2]);
                std.mem.copy(*art_node, n.node4.children[idx + 1 ..], n.node4.children[idx .. n.node4.children.len - 2]);
                n.node4.keys[idx] = c;
                n.node4.children[idx] = castPtr(*art_node, child);
                n.node4.n.num_children += 1;
            } else {
                const new_node = try t.allr.create(art_node);
                // TODO: support node16
                new_node.* = .{ .node16 = undefined };
                std.mem.copy(*art_node, &new_node.node16.children, &n.node4.children);
                std.mem.copy(u8, &new_node.node16.keys, &n.node4.keys);
                // new_node.* = .{ .node48 = undefined };
                // std.mem.copy(*art_node, &new_node.node48.children, &n.node48.children);
                // std.mem.copy(u8, &new_node.node48.keys, &n.node48.keys);
                // const as_node = @ptrCast(*art_node, new_node);
                // if ()
                copy_header(new_node, n);
                ref.* = new_node;
                t.allr.destroy(n);
                // unreachable;
                try t.add_child16(new_node, ref, c, child);
                // try t.add_child48(new_node, ref, c, child);
            }
        }
        fn add_child16(t: *Tree, n: *art_node, ref: *?*art_node, c: u8, child: var) InsertError!void {
            std.debug.warn("n {}\n", .{n});
            if (n.node16.n.num_children < 16) {
                // TODO: implement with simd
                const mask = (@as(usize, 1) << @truncate(u6, n.node16.n.num_children)) - 1;
                var bitfield: usize = 0;
                for (n.node16.keys) |k, i|
                    bitfield |= (@as(usize, 1) << @truncate(u6, i));
                bitfield &= mask;
                // end TODO
                var idx: usize = 0;
                if (bitfield != 0) {
                    idx = @ctz(usize, bitfield);
                    std.mem.copy(u8, n.node16.keys[idx + 1 ..], n.node16.keys[idx..]);
                    std.mem.copy(*art_node, n.node16.children[idx + 1 ..], n.node16.children[idx..]);
                } else idx = n.node16.n.num_children;

                n.node16.keys[idx] = c;
                n.node16.children[idx] = castPtr(*art_node, child);
                n.node16.n.num_children += 1;
            } else {
                unreachable;
            }
        }
        fn add_child48(t: *Tree, n: *art_node, ref: *?*art_node, c: u8, child: var) InsertError!void {
            // if (n.)
        }
        fn add_child256(t: *Tree, n: *art_node, ref: *?*art_node, c: u8, child: var) InsertError!void {
            // if (n.)
        }
        pub fn delete(t: *Tree, key: []const u8) Result {}
        const art_callback = fn (data: *c_void, key: []const u8, value: T, depth: usize) bool;
        pub fn search(t: *Tree, key: []const u8) Result {}
        pub fn iter(t: *Tree, comptime cb: art_callback, data: var) bool {
            return recursive_iter(t.root, cb, data, 0);
        }
        pub fn recursive_iter(_n: ?*art_node, comptime cb: art_callback, data: *c_void, depth: usize) bool {
            if (_n == null) return false;
            const n = _n orelse unreachable;
            if (n.* == .leaf) return cb(data, n.leaf.key, n.leaf.value.?, depth);
            switch (n.*) {
                .node4 => {
                    var i: usize = 0;
                    while (i < n.node4.n.num_children) : (i += 1) if (recursive_iter(n.node4.children[i], cb, data, depth + 1))
                        return true;
                },
                .node16 => {
                    var i: usize = 0;
                    while (i < n.node16.n.num_children) : (i += 1) if (recursive_iter(n.node16.children[i], cb, data, depth + 1))
                        return true;
                },
                .node48 => {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        const idx = n.node48.keys[i];
                        if (idx == 0) continue;
                        if (recursive_iter(n.node48.children[idx - 1], cb, data, depth + 1))
                            return true;
                    }
                },
                .node256 => {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        // @panic("unimplemented");
                        if (!has_child_idx(n, i)) continue;
                        if (recursive_iter(n.node256.children[i], cb, data, depth + 1))
                            return true;
                    }
                    return false;
                },
                else => unreachable,
            }
            return false;
        }
        pub fn iter_prefix(t: *Tree, prefix: []const u8, comptime cb: art_callback, data: var) Result {}
        const max_spaces = 256;
        const spaces = [1]u8{' '} ** max_spaces;
        pub fn print(t: *Tree) void {
            const cb = struct {
                fn _(data: *c_void, key: []const u8, value: T, depth: usize) bool {
                    const stderr = std.io.getStdOut().outStream();
                    // const depth = @ptrCast(*align(1) usize, data);
                    _ = stderr.print("{}{} {}\n", .{ spaces[0..depth], key, value }) catch unreachable;
                    // depth.* += 2;

                    return false;
                }
            }._;
            var data: usize = 0;
            _ = t.iter(cb, &data);
        }
    };
}

const testing = std.testing;
const use_test_allr = true;
const a = if (use_test_allr) testing.allocator else std.heap.allocator;

test "test_art_insert" {
    var t = try art_tree(usize).init(a);
    const f = try std.fs.cwd().openFile("./testdata/words1.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const result = try t.insert(line, lines);
        log("line {} result {}\n", .{ line, result });
        t.print();
        lines += 1;
    }

    t.deinit();
}
