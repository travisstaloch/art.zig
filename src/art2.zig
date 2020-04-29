const std = @import("std");

const ShowDebugLog = true;
fn log(comptime fmt: []const u8, vals: var) void {
    if (ShowDebugLog) std.debug.warn(fmt, vals);
}

pub fn ArtTree(comptime T: type) type {
    return struct {
        root: ?*Node,
        size: usize,
        allr: *std.mem.Allocator,

        const MAX_PREFIX_LEN = 10;
        const BaseNode = struct {
            numChildren: u8,
            partialLen: usize,
            partial: [MAX_PREFIX_LEN]u8,
        };

        pub fn NodeSized(comptime keysLen: usize, comptime childrenLen: usize) type {
            return struct {
                n: BaseNode,
                keys: [keysLen]u8,
                children: [childrenLen]*Node,
                const Self = @This();
                pub fn init() Self {}
            };
        }

        pub const Node4 = NodeSized(4, 4);
        pub const Node16 = NodeSized(16, 16);
        pub const Node48 = NodeSized(256, 48);
        pub const Node256 = NodeSized(0, 256);

        const Leaf = struct {
            value: ?T,
            key: []u8,
        };

        const Node = union(enum) {
            Leaf: Leaf,
            Node4: Node4,
            Node16: Node16,
            Node48: Node48,
            Node256: Node256,
            pub fn node(self: *Node) *BaseNode {
                return switch (self.*) {
                    .Node4 => &self.Node4.n,
                    .Node16 => &self.Node16.n,
                    .Node48 => &self.Node48.n,
                    .Node256 => &self.Node256.n,
                    .Leaf => unreachable,
                };
            }
        };

        const Tree = ArtTree(T);

        pub fn init(allr: *std.mem.Allocator) !Tree {
            return Tree{ .root = null, .size = 0, .allr = allr };
        }
        const Result = union(enum) { New, Old: *Node };
        pub fn deinit(t: *Tree) void {}
        fn makeLeaf(key: []const u8, value: T) !*Node {
            // var l = try a.create(Leaf);
            var n = try a.create(Node);
            n.* = .{ .Leaf = .{ .value = value, .key = try a.alloc(u8, key.len) } };
            std.mem.copy(u8, n.Leaf.key, key);
            return n;
        }
        fn leaf_matches() void {}
        pub fn insert(t: *Tree, key: []const u8, value: T) !Result {
            const res = try t.recursiveInsert(t.root, &t.root, key, value, 0);
            if (res == .New) t.size += 1;
            return res;
        }
        fn longestCommonPrefix(l: Leaf, l2: Leaf, depth: usize) usize {
            const max_cmp = std.math.min(l.key.len, l2.key.len) - depth;
            var common: usize = 0;
            while (common < max_cmp and l.key[common] == l2.key[common]) : (common += 1) {}
            return common;
        }
        fn prefixMismatch(_n: *Node, key: []const u8, depth: usize) usize {
            const n = _n.node();
            var max_cmp = std.math.min(std.math.min(MAX_PREFIX_LEN, n.partialLen), key.len - depth);
            var idx: usize = 0;
            while (idx < max_cmp) : (idx += 1) if (n.partial[idx] != key[depth + idx])
                return idx;
            if (n.partialLen > MAX_PREFIX_LEN) {
                const l = minimum(_n);
                max_cmp = std.math.min(l.?.key.len, key.len) - depth;
                while (idx < max_cmp) : (idx += 1) if (l.?.key[idx + depth] != key[depth + idx])
                    return idx;
            }
            return idx;
        }
        fn emptyNode4() Node {
            return .{ .Node4 = .{ .n = .{ .numChildren = 0, .partialLen = 0, .partial = undefined }, .keys = undefined, .children = undefined } };
        }
        // Find the minimum Leaf under a node
        fn minimum(_n: ?*Node) ?*Leaf {
            if (_n == null) return null;
            var n = _n orelse unreachable;

            var idx: usize = 0;
            switch (n.*) {
                .Leaf => return &n.Leaf,
                .Node4 => return minimum(n.Node4.children[0]),
                .Node16 => return minimum(n.Node16.children[0]),
                .Node48 => {
                    while (n.Node48.keys[idx] == 0) : (idx += 1)
                        return minimum(n.Node48.children[n.Node48.keys[idx] - 1]);
                },
                .Node256 => {
                    while (!hasChildAt(n, idx)) : (idx += 1)
                        return minimum(n.Node256.children[idx]);
                },
                else => unreachable,
            }
            unreachable;
        }
        fn hasChildAt(n: *Node, i: usize) bool {
            return switch (n.*) {
                .Node4 => @ptrToInt(n.Node4.children[i]) != 0,
                .Node16 => @ptrToInt(n.Node16.children[i]) != 0,
                .Node48 => @ptrToInt(n.Node48.children[i]) != 0,
                .Node256 => @ptrToInt(n.Node256.children[i]) != 0,
                else => false,
            };
        }
        const InsertError = error{OutOfMemory};
        pub fn recursiveInsert(t: *Tree, _n: ?*Node, ref: *?*Node, key: []const u8, value: T, _depth: usize) InsertError!Result {
            if (_n == null) {
                ref.* = try makeLeaf(key, value);
                return .New;
            }
            var n = _n orelse unreachable;
            var depth = _depth;
            if (n.* == .Leaf) {
                var l = n.Leaf;
                if (std.mem.eql(u8, l.key, key)) return Result{ .Old = n };

                var newNode = try t.allr.create(Node);
                newNode.* = emptyNode4();
                var l2 = try makeLeaf(key, value);
                const longest_prefix = longestCommonPrefix(l, l2.Leaf, depth);
                newNode.Node4.n.partialLen = longest_prefix;
                var key_copy = key;
                key_copy.ptr += depth;
                key_copy.len -= std.math.min(MAX_PREFIX_LEN, longest_prefix);
                std.mem.copy(u8, &newNode.Node4.n.partial, key_copy);
                ref.* = newNode;
                try t.addChild4(newNode, ref, l.key[depth + longest_prefix], n);
                try t.addChild4(newNode, ref, l2.Leaf.key[depth + longest_prefix], l2);
                return .New;
            }

            const anode = n.node();

            if (anode.partialLen != 0) {
                const prefix_diff = prefixMismatch(n, key, depth);
                if (prefix_diff >= anode.partialLen) {
                    depth += anode.partialLen;
                    return t.recurse_search(n, ref, key, value, depth);
                }

                var newNode = try t.allr.create(Node);
                newNode.* = emptyNode4();
                ref.* = newNode;
                anode.partialLen = prefix_diff;
                std.mem.copy(u8, &newNode.Node4.n.partial, &anode.partial);

                if (anode.partialLen <= MAX_PREFIX_LEN) {
                    try t.addChild4(newNode, ref, anode.partial[prefix_diff], n);
                    anode.partialLen -= (prefix_diff + 1);
                    std.mem.copy(u8, &anode.partial, anode.partial[prefix_diff + 1 ..]);
                } else {
                    anode.partialLen -= (prefix_diff + 1);
                    const l = minimum(n);
                    try t.addChild4(newNode, ref, l.?.key[depth + prefix_diff], n);
                    std.mem.copy(u8, &anode.partial, l.?.key[depth + prefix_diff + 1 ..]);
                }

                var l = try makeLeaf(key, value);
                try t.addChild4(newNode, ref, key[depth + prefix_diff], l);
                return Result{ .New = {} };
            }
            // std.debug.warn("unreachable {} {} {}\n", .{ key, value, n });
            // unreachable;
            return t.recurse_search(n, ref, key, value, depth);
        }
        fn recurse_search(t: *Tree, n: *Node, ref: *?*Node, key: []const u8, value: T, depth: usize) InsertError!Result {
            const child = findChild(n, key[depth]);
            if (child.* != null) return t.recursiveInsert(child.*, child, key, value, depth);

            var l = try makeLeaf(key, value);
            try t.add_child(n, ref, key[depth], l);
            return Result{ .New = {} };
        }
        fn copyHeader(dest: *Node, src: *Node) void {
            dest.node().numChildren = src.node().numChildren;
            dest.node().partialLen = src.node().partialLen;
            std.mem.copy(u8, &dest.node().partial, &src.node().partial);
        }
        // TODO: remove this helper for casting away constness
        fn castPtr(comptime P: type, p: var) P {
            return @intToPtr(P, @ptrToInt(p));
        }
        fn add_child(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: *Node) InsertError!void {
            return switch (n.*) {
                .Node4 => try t.addChild4(n, ref, c, child),
                .Node16 => try t.addChild16(n, ref, c, child),
                .Node48 => try t.addChild48(n, ref, c, child),
                .Node256 => try t.addChild256(n, ref, c, child),
                else => unreachable,
            };
        }
        fn findChild(n: *Node, c: u8) *?*Node {
            const anode = n.node();
            switch (n.*) {
                .Node4 => {
                    var i: usize = 0;
                    while (i < anode.numChildren) : (i += 1) if (n.Node4.keys[i] == c)
                        return &@as(?*Node, n.Node4.children[i]);
                },
                .Node16 => {
                    // TODO: simd
                    var bitfield: usize = 0;
                    for (n.Node16.keys) |k, i| {
                        if (k == c)
                            bitfield |= (@as(usize, 1) << @truncate(u6, i));
                    }
                    const mask = (@as(usize, 1) << @truncate(u6, anode.numChildren)) - 1;
                    bitfield &= mask;
                    // end TODO
                    if (bitfield != 0) return &(@as(?*Node, n.Node16.children[@ctz(usize, bitfield)]));
                },
                .Node48 => if (n.Node48.keys[c] != 0) return &(@as(?*Node, n.Node48.children[n.Node48.keys[c] - 1])),
                .Node256 => if (hasChildAt(n, c)) return &(@as(?*Node, n.Node256.children[c])),
                else => unreachable,
            }
            var x: ?*Node = null;
            return &@as(?*Node, x);
        }
        fn addChild4(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: *Node) InsertError!void {
            if (n.Node4.n.numChildren < 4) {
                var idx: usize = 0;
                while (idx < n.Node4.n.numChildren) : (idx += 1) if (c < n.Node4.keys[idx])
                    break;
                // std.debug.warn("idx {} {}\n", .{ idx, n.Node4.keys });
                // std.debug.warn("n {}\n", .{n});
                // std.debug.warn("child {}\n", .{child});
                std.mem.copy(u8, n.Node4.keys[idx + 1 ..], n.Node4.keys[idx .. n.Node4.keys.len - 2]);
                std.mem.copy(*Node, n.Node4.children[idx + 1 ..], n.Node4.children[idx .. n.Node4.children.len - 2]);
                n.Node4.keys[idx] = c;
                n.Node4.children[idx] = castPtr(*Node, child);
                n.Node4.n.numChildren += 1;
            } else {
                const newNode = try t.allr.create(Node);
                // TODO: support Node16
                newNode.* = .{ .Node16 = undefined };
                std.mem.copy(*Node, &newNode.Node16.children, &n.Node4.children);
                std.mem.copy(u8, &newNode.Node16.keys, &n.Node4.keys);
                // newNode.* = .{ .Node48 = undefined };
                // std.mem.copy(*Node, &newNode.Node48.children, &n.Node48.children);
                // std.mem.copy(u8, &newNode.Node48.keys, &n.Node48.keys);
                // const as_node = @ptrCast(*Node, newNode);
                // if ()
                copyHeader(newNode, n);
                ref.* = newNode;
                t.allr.destroy(n);
                // unreachable;
                try t.addChild16(newNode, ref, c, child);
                // try t.addChild48(newNode, ref, c, child);
            }
        }
        fn addChild16(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: var) InsertError!void {
            // std.debug.warn("n {}\n", .{n});
            if (n.Node16.n.numChildren < 16) {
                // TODO: implement with simd
                const mask = (@as(usize, 1) << @truncate(u6, n.Node16.n.numChildren)) - 1;
                var bitfield: usize = 0;
                for (n.Node16.keys) |k, i|
                    bitfield |= (@as(usize, 1) << @truncate(u6, i));
                bitfield &= mask;
                // end TODO
                var idx: usize = 0;
                if (bitfield != 0) {
                    idx = @ctz(usize, bitfield);
                    std.mem.copy(u8, n.Node16.keys[idx + 1 ..], n.Node16.keys[idx..]);
                    std.mem.copy(*Node, n.Node16.children[idx + 1 ..], n.Node16.children[idx..]);
                } else idx = n.Node16.n.numChildren;

                n.Node16.keys[idx] = c;
                n.Node16.children[idx] = castPtr(*Node, child);
                n.Node16.n.numChildren += 1;
            } else {
                unreachable;
            }
        }
        fn addChild48(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: var) InsertError!void {
            // if (n.)
        }
        fn addChild256(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: var) InsertError!void {
            // if (n.)
        }
        pub fn delete(t: *Tree, key: []const u8) Result {}
        const art_callback = fn (data: *c_void, key: []const u8, value: T, depth: usize) bool;
        pub fn search(t: *Tree, key: []const u8) Result {}
        pub fn iter(t: *Tree, comptime cb: art_callback, data: var) bool {
            return recursiveIter(t.root, cb, data, 0);
        }
        pub fn recursiveIter(_n: ?*Node, comptime cb: art_callback, data: *c_void, depth: usize) bool {
            if (_n == null) return false;
            const n = _n orelse unreachable;
            if (n.* == .Leaf) return cb(data, n.Leaf.key, n.Leaf.value.?, depth);
            switch (n.*) {
                .Node4 => {
                    var i: usize = 0;
                    while (i < n.Node4.n.numChildren) : (i += 1) if (recursiveIter(n.Node4.children[i], cb, data, depth + 1))
                        return true;
                },
                .Node16 => {
                    var i: usize = 0;
                    while (i < n.Node16.n.numChildren) : (i += 1) if (recursiveIter(n.Node16.children[i], cb, data, depth + 1))
                        return true;
                },
                .Node48 => {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        const idx = n.Node48.keys[i];
                        if (idx == 0) continue;
                        if (recursiveIter(n.Node48.children[idx - 1], cb, data, depth + 1))
                            return true;
                    }
                },
                .Node256 => {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        // @panic("unimplemented");
                        if (!hasChildAt(n, i)) continue;
                        if (recursiveIter(n.Node256.children[i], cb, data, depth + 1))
                            return true;
                    }
                    return false;
                },
                else => unreachable,
            }
            return false;
        }
        pub fn iterPrefix(t: *Tree, prefix: []const u8, comptime cb: art_callback, data: var) Result {}
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
    var t = try ArtTree(usize).init(a);
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
