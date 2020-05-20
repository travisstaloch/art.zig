const std = @import("std");
const mem = std.mem;
const math = std.math;
pub fn ArtTree(comptime T: type) type {
    return extern struct {
        root: *Node,
        size: usize,
        a: *std.mem.Allocator,

        const Tree = @This();
        const MaxPrefixLen = 10;
        const BaseNode = extern struct {
            num_children: u8,
            partial_len: u32,
            partial: [MaxPrefixLen]u8 = [1]u8{0} ** MaxPrefixLen,
        };
        pub fn SizedNode(comptime num_keys: usize, comptime num_children: usize) type {
            return extern struct {
                num_children: u8,
                partial_len: u32,
                partial: [MaxPrefixLen]u8 = [1]u8{0} ** MaxPrefixLen,
                keys: [num_keys]u8 = [1]u8{0} ** num_keys,
                children: [num_children]*Node = [1]*Node{&emptyNode} ** num_children,
                const Self = @This();
                pub fn baseNode(self: *Self) *BaseNode {
                    return @ptrCast(*BaseNode, self);
                }
            };
        }
        pub const Leaf = struct {
            value: T,
            key: []const u8,
        };
        pub const Node = union(enum) {
            leaf: Leaf,
            node4: SizedNode(4, 4),
            node16: SizedNode(16, 16),
            node48: SizedNode(256, 48),
            node256: SizedNode(0, 256),

            fn baseNode(n: *Node) *BaseNode {
                return switch (n.*) {
                    .node4 => @ptrCast(*BaseNode, &n.*.node4),
                    .node16 => @ptrCast(*BaseNode, &n.*.node16),
                    .node48 => @ptrCast(*BaseNode, &n.*.node48),
                    .node256 => @ptrCast(*BaseNode, &n.*.node256),
                    else => unreachable,
                };
            }
        };

        pub const callback = fn (?*c_void, *Node, ?*c_void, u32) callconv(.C) bool;

        var emptyNode: Node = undefined;
        var emptyNodeRef = &emptyNode;

        pub fn init(a: *std.mem.Allocator) Tree {
            return .{ .root = emptyNodeRef, .size = 0, .a = a };
        }
        pub fn deinit(t: *Tree) void {
            t.deinitNode(t.root);
        }
        // Recursively destroys the tree
        pub fn deinitNode(t: *Tree, n: *Node) void {
            switch (n.*) {
                .leaf => |l| {
                    t.a.free(l.key);
                    t.a.destroy(n);
                    return;
                },
                .node4 => {
                    var i: usize = 0;
                    const children = n.node4.children;
                    while (i < n.node4.num_children) : (i += 1) {
                        t.deinitNode(children[i]);
                    }
                },
                .node16 => {
                    var i: usize = 0;
                    const children = n.node16.children;
                    while (i < n.node16.num_children) : (i += 1) {
                        t.deinitNode(children[i]);
                    }
                },
                .node48 => {
                    var i: usize = 0;
                    const children = n.node48.children;
                    while (i < 256) : (i += 1) {
                        const idx = n.node48.keys[i];
                        if (idx == 0)
                            continue;
                        t.deinitNode(children[idx - 1]);
                    }
                },
                .node256 => {
                    unreachable;
                    // var i: usize = 0;
                    // const children = n.node256.children;
                    // while (i < 256) : (i += 1) {
                    //     if (hasChildAt(n, .node256, i))
                    //         t.deinitNode(children[i]);
                    // }
                },
            }
            t.a.destroy(n);
        }
        fn makeLeaf(t: *Tree, key: []const u8, value: T) !*Node {
            const n = try t.a.create(Node);
            n.* = .{ .leaf = .{ .key = try mem.dupe(t.a, u8, key), .value = value } };
            return n;
        }
        fn allocNode(t: *Tree, comptime Tag: @TagType(Node)) !*Node {
            var node = try t.a.create(Node);
            const tagName = @tagName(Tag);
            node.* = @unionInit(Node, tagName, .{ .num_children = 0, .partial_len = 0 });
            return node;
        }
        const Result = union(enum) { created, updated: T };
        pub fn insert(t: *Tree, key: []const u8, value: T) !Result {
            return try t.insertRec(t.root, &t.root, key, value, 0);
        }
        const Error = error{ OutOfMemory, NoMinimum };
        pub fn insertRec(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, _depth: u32) Error!Result {
            var depth = _depth;
            if (n == emptyNodeRef) {
                ref.* = try t.makeLeaf(key, value);
                return .created;
            }
            if (n.* == .leaf) {
                var l = n.*.leaf;
                if (mem.eql(u8, l.key, key)) {
                    const result = Result{ .updated = l.value };
                    l.value = value;
                    return result;
                }
                var new_node = try t.allocNode(.node4);
                var l2 = try t.makeLeaf(key, value);
                const longest_prefix = longestCommonPrefix(l, l2.*.leaf, depth);
                new_node.node4.partial_len = longest_prefix;
                mem.copy(u8, &new_node.node4.partial, key[depth..][0..math.min(MaxPrefixLen, longest_prefix)]);
                ref.* = new_node;
                try t.addChild4(new_node, ref, l.key[depth + longest_prefix], n);
                try t.addChild4(new_node, ref, l2.*.leaf.key[depth + longest_prefix], l2);
                return .created;
            }
            var base_node = n.baseNode();
            if (base_node.partial_len != 0) {
                // Determine if the prefixes differ, since we need to split
                const prefix_diff = prefixMismatch(n, key, depth);
                if (prefix_diff >= base_node.partial_len) {
                    depth += base_node.partial_len;
                    return try t.insertRecSearch(n, ref, key, value, depth);
                }

                // Create a new node
                var new_node = try t.allocNode(.node4);
                ref.* = new_node;
                new_node.node4.partial_len = prefix_diff;
                mem.copy(u8, &new_node.node4.partial, base_node.partial[0..math.min(MaxPrefixLen, prefix_diff)]);

                // Adjust the prefix of the old node
                if (base_node.partial_len <= MaxPrefixLen) {
                    try t.addChild4(new_node, ref, base_node.partial[prefix_diff], n);
                    //   debug("1 n.partial_len %d prefixDiff %d base_node.partial %.*s\n",
                    //         base_node.partial_len, prefix_diff, MaxPrefixLen, base_node.partial);
                    base_node.partial_len -= (prefix_diff + 1);
                    //   debug("1 n.partial_len %d prefixDiff %d\n", base_node.partial_len, prefix_diff);
                    mem.copyBackwards(u8, &base_node.partial, base_node.partial[prefix_diff + 1 ..][0..math.min(MaxPrefixLen, base_node.partial_len)]);
                } else {
                    //   debug("2 n.partial_len %d prefixDiff %d base_node.partial %.*s\n",
                    //         base_node.partial_len, prefix_diff, MaxPrefixLen, base_node.partial);
                    base_node.partial_len -= (prefix_diff + 1);
                    //   debug("2 n.partial_len %d prefixDiff %d\n", base_node.partial_len, prefix_diff);
                    var l = minimum(n) orelse return error.NoMinimum;
                    try t.addChild4(new_node, ref, l.key[depth + prefix_diff], n);
                    mem.copy(u8, &base_node.partial, l.key[depth + prefix_diff + 1 ..][math.min(MaxPrefixLen, base_node.partial_len)..]);
                }
                // debug("partial %.*s partial_len %d\n", base_node.partial_len, base_node.partial,
                //       base_node.partial_len);

                // Insert the new leaf
                var l = try t.makeLeaf(key, value);
                try t.addChild4(new_node, ref, key[depth + prefix_diff], l);
                return .created;
            }
            return try t.insertRecSearch(n, ref, key, value, depth);
        }
        fn insertRecSearch(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, depth: u32) Error!Result {
            const child = findChild(n, key[depth]);
            if (child != &emptyNodeRef) {
                return try t.insertRec(child.*, child, key, value, depth + 1);
            }

            // No child, node goes within us
            var l = try t.makeLeaf(key, value);
            try t.addChild(n, ref, key[depth], l);
            return .created;
        }
        fn longestCommonPrefix(l: Leaf, l2: Leaf, depth: usize) u32 {
            var max_cmp = math.min(l.key.len, l2.key.len) - depth;
            // max_cmp = if (max_cmp > depth) max_cmp - depth else 0;
            var idx: u32 = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (l.key[depth + idx] != l2.key[depth + idx])
                    return idx;
            }
            return idx;
        }
        fn addChild4(t: *Tree, n: *Node, ref: **Node, c: u8, child: *Node) !void {
            if (n.node4.num_children < 4) {
                var idx: usize = 0;
                while (idx < n.node4.num_children) : (idx += 1) {
                    if (c < n.node4.keys[idx]) break;
                }

                const shift_len = n.node4.num_children - idx;
                mem.copyBackwards(u8, n.node4.keys[idx + 1 ..], n.node4.keys[idx..][0..shift_len]);
                mem.copyBackwards(*Node, n.node4.children[idx + 1 ..], n.node4.children[idx..][0..shift_len]);
                // log(.Verbose, "idx {} shift_len {}\n", .{ idx, n.node4.keys[0..n.node4.num_children], shift_len });
                // _ = cstd.memmove(&n.node4.keys + idx + 1, &n.node4.keys + idx, shift_len);
                // _ = cstd.memmove(&n.node4.children + idx + 1, &n.node4.children + idx, shift_len * @sizeOf(*Node));
                n.node4.keys[idx] = c;
                n.node4.children[idx] = child;
                n.node4.num_children += 1;
                // log(.Verbose, "addChild4 n.node4.keys {} idx {} shift_len {} num_children {}\n", .{ n.node4.keys, idx, shift_len, n.node4.num_children });
            } else {
                var new_node = try t.allocNode(.node16);
                mem.copy(*Node, &new_node.node16.children, &n.node4.children);
                mem.copy(u8, &new_node.node16.keys, &n.node4.keys);
                copyHeader(new_node.node16.baseNode(), n.node4.baseNode());
                // log(.Verbose, "new_node.node16.keys {}\n", .{new_node.node16.keys});
                ref.* = new_node;
                t.a.destroy(n);

                // try t.addChild16(new_node, ref, c, child);
                unreachable;
            }
        }
        fn copyHeader(dest: *BaseNode, src: *BaseNode) void {
            dest.num_children = src.num_children;
            dest.partial_len = src.partial_len;
            mem.copy(u8, &dest.partial, src.partial[0..math.min(MaxPrefixLen, src.partial_len)]);
            // log(.Verbose, "copyHeader dest num_children {} partial_len {} partaial {}", .{ dest.num_children, dest.partial_len, dest.partial });
        }

        /// Calculates the index at which the prefixes mismatch
        fn prefixMismatch(n: *Node, key: []const u8, depth: u32) u32 {
            const base_node = n.baseNode();
            var max_cmp = math.min(math.min(MaxPrefixLen, base_node.partial_len), key.len - depth);
            // log(.Verbose, "prefixMismatch max_cmp {}\n", .{max_cmp});
            var idx: u32 = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (base_node.partial[idx] != key[depth + idx])
                    return idx;
            }
            if (base_node.partial_len > MaxPrefixLen) {
                const l = minimum(n);
                max_cmp = @truncate(u32, math.min(l.?.key.len, key.len)) - depth;
                while (idx < max_cmp) : (idx += 1) {
                    if (l.?.key[idx + depth] != key[depth + idx])
                        return idx;
                }
            }
            return idx;
        }
        // pub fn min(t: *Tree) ?*Leaf {
        //     return minimum(t.root);
        // }
        // Find the minimum Leaf under a node
        fn minimum(n: *Node) ?*Leaf {
            // log(.Verbose, "minimum {}\n", .{n});
            return switch (n.*) {
                .leaf => &n.leaf,
                .node4 => minimum(n.node4.children[0]),
                .node16 => minimum(n.node16.children[0]),
                .node48 => blk: {
                    var idx: usize = 0;
                    while (n.node48.keys[idx] == 0) : (idx += 1) {}
                    break :blk minimum(n.node48.children[n.node48.keys[idx] - 1]);
                },
                // .node256 => blk: {
                //     var idx: usize = 0;
                //     while (!hasChildAt(n, .node256, idx)) : (idx += 1) {}
                //     break :blk minimum(n.node256.children[idx]);
                // },
                else => unreachable,
                // .Empty => null,
            };
        }
        fn addChild(t: *Tree, n: *Node, ref: **Node, c: u8, child: *Node) Error!void {
            switch (n.*) {
                .node4 => try t.addChild4(n, ref, c, child),
                // .node16 => try t.addChild16(n, ref, c, child),
                // .node48 => try t.addChild48(n, ref, c, child),
                // .node256 => try t.addChild256(n, ref, c, child),
                else => unreachable,
            }
        }
        fn findChild(n: *Node, c: u8) **Node {
            const base = n.baseNode();
            // log(.Warning, "findChild {c} {} '{c}'\n", .{ c, @as(@TagType(Node), n.*), c });
            // log(.Warning, "findChild '{c}'\n", .{c});
            switch (n.*) {
                .node4 => {
                    // log(.Warning, "keys {}\n", .{n.node4.keys});
                    var i: usize = 0;
                    while (i < base.num_children) : (i += 1) {
                        if (n.node4.keys[i] == c)
                            return &n.node4.children[i];
                    }
                },
                .node16 => {
                    // TODO: simd
                    var bitfield: u17 = 0;
                    for (n.node16.keys) |k, i| {
                        if (k == c)
                            bitfield |= (@as(u17, 1) << @truncate(u5, i));
                    }
                    const mask = (@as(u17, 1) << @truncate(u5, base.num_children)) - 1;
                    bitfield &= mask;
                    // log(.Warning, "Node16 bitfield 0x{x} keys {} base.num_children {}\n", .{ bitfield, n.node16.keys, base.num_children });
                    // if (bitfield != 0)
                    //     log(.Warning, "Node16 child {}\n", .{n.node16.children[@ctz(usize, bitfield)]});

                    // end TODO
                    if (bitfield != 0) return &n.node16.children[@ctz(usize, bitfield)];
                },
                .node48 => {
                    // log(.Warning, "Node48 '{c}'\n", .{n.node48.keys[c]});
                    // if (n.node48.keys[c] > 0)
                    //     log(.Warning, "Node48 '{}'\n", .{n.node48.children[n.node48.keys[c] - 1]});
                    if (n.node48.keys[c] != 0) return &n.node48.children[n.node48.keys[c] - 1];
                },
                .node256 => {
                    unreachable;
                    // log(.Warning, "Node256 {*}\n", .{n.node256.children[c]});
                    // if (hasChildAt(n, .node256, c)) return &n.node256.children[c];
                },
                else => unreachable,
            }
            return &emptyNodeRef;
        }

        pub fn print(t: *Tree) !void {
            var data: usize = 0;
            _ = t.iter(showCb, @as(*c_void, &data));
        }

        pub fn delete(t: *Tree, key: []const u8, key_len: usize) Result {}
        pub fn search(t: [*c]const art_tree, key: []const u8, key_len: usize) Result {}
        // pub fn minimum(t: *Tree) *Leaf {}
        // pub fn maximum(t: *Tree) *Leaf {}
        // pub fn iter(t: *Tree, cb: art_callback, data: ?*c_void) bool {}
        pub const Callback = fn (t: *Tree, n: *Node, data: *c_void, depth: usize) bool;
        pub fn iter(t: *Tree, comptime cb: Callback, data: var) bool {
            return t.recursiveIter(t.root, data, 0, cb);
        }
        /// return true to stop iteration
        pub fn recursiveIter(t: *Tree, n: *Node, data: *c_void, depth: usize, comptime cb: Callback) bool {
            // if (n.* == .Empty) return false;
            switch (n.*) {
                // .Empty => return false,
                .leaf => return cb(t, n, data, depth),
                .node4 => {
                    if (cb(t, n, data, depth)) return true;
                    var i: usize = 0;
                    // log(.Verbose, "{*}\n", .{n});
                    // log(.Verbose, "{}\n", .{n});
                    while (i < n.node4.num_children) : (i += 1) {
                        if (t.recursiveIter(n.node4.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
                .node16 => {
                    if (cb(t, n, data, depth)) return true;
                    var i: usize = 0;
                    while (i < n.node16.num_children) : (i += 1) {
                        if (t.recursiveIter(n.node16.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
                .node48 => {
                    if (cb(t, n, data, depth)) return true;
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        const idx = n.node48.keys[i];
                        if (idx == 0) continue;
                        if (t.recursiveIter(n.node48.children[idx - 1], data, depth + 1, cb))
                            return true;
                    }
                },
                .node256 => {
                    unreachable;
                    // if (cb(t, n, data, depth)) return true;
                    // var i: usize = 0;
                    // while (i < 256) : (i += 1) {
                    //     if (!hasChildAt(n, .node256, i)) continue;
                    //     if (t.recursiveIter(n.node256.children[i], data, depth + 1, cb))
                    //         return true;
                    // }
                },
            }
            return false;
        }
        // pub fn iter2(t: *Tree, cb: art_callback2, data: ?*c_void) c_int;
        // pub fn iterPrefix(t: *Tree, prefix: []const u8, prefix_len: c_int, cb: art_callback, data: ?*c_void) bool {}
        const spaces = [1]u8{' '} ** 256;
        pub fn showCb(t: *Tree, n: *Node, data: *c_void, depth: usize) bool {
            switch (n.*) {
                .leaf => std.debug.warn("{} -> {}\n", .{ spaces[0 .. depth * 2], n.leaf.key }),
                .node4 => std.debug.warn("{}4-{} ({})\n", .{
                    spaces[0 .. depth * 2],
                    // n.node4.keys[0..n.node4.num_children],
                    // n.node4.partial[0..n.node4.partial_len],
                    &n.node4.keys,
                    &n.node4.partial,
                }),
                .node16 => std.debug.warn("{}16-{} ({})\n", .{
                    spaces[0 .. depth * 2],
                    n.node16.keys[0..n.node16.num_children],
                    n.node16.partial[0..n.node16.partial_len],
                }),
                .node48 => std.debug.warn("{}48-{} ({})\n", .{
                    spaces[0 .. depth * 2],
                    n.node48.keys[0..n.node48.num_children],
                    n.node48.partial[0..n.node48.partial_len],
                }),
                .node256 => std.debug.warn("{}256-{} ({})\n", .{
                    spaces[0 .. depth * 2],
                    n.node256.keys[0..n.node256.num_children],
                    n.node256.partial[0..n.node256.partial_len],
                }),
            }
            return false;
        }
    };
}

const al = std.testing.allocator;
test "basic" {
    // pub fn main() !void {
    var t = ArtTree(usize).init(al);
    defer t.deinit();
    const words = [_][]const u8{
        "Aaron\x00",
        "Aaronic\x00",
        "Aaronical\x00",
    };
    for (words) |w, i| {
        _ = try t.insert(w, i);
    }
    try t.print();
}

test "insert many keys" {
    var t = ArtTree(usize).init(al);
    defer t.deinit();
    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [256]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        buf[line.len + 1] = 0;
        line.len += 1;
        const result = try t.insert(line.*, lines);
        // log(.Verbose, "line {} result {}\n", .{ line, result });
        // try t.print();
        // log(.Verbose, "\n", .{});
        lines += 1;
        if (lines >= 10) break;
    }
    try t.print();
}
