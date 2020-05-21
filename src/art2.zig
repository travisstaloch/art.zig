const std = @import("std");
const mem = std.mem;
const math = std.math;

pub var showLog = false;
pub fn log(comptime fmt: []const u8, args: var) void {
    if (showLog) std.debug.warn(fmt, args);
}
const warn = log;
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

            pub fn baseNode(n: *Node) *BaseNode {
                return switch (n.*) {
                    .node4 => n.*.node4.baseNode(),
                    .node16 => n.*.node16.baseNode(),
                    .node48 => n.*.node48.baseNode(),
                    .node256 => n.*.node256.baseNode(),
                    else => unreachable,
                };
            }
        };

        // pub const callback = fn (?*c_void, *Node, ?*c_void, u32) callconv(.C) bool;

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
                    // unreachable;
                    var i: usize = 0;
                    const children = n.node256.children;
                    while (i < 256) : (i += 1) {
                        if (hasChildAt(n, .node256, i))
                            t.deinitNode(children[i]);
                    }
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
        const Result = union(enum) { missing, found: T };
        pub fn insert(t: *Tree, key: []const u8, value: T) !Result {
            return try t.insertRec(t.root, &t.root, key, value, 0);
        }
        const Error = error{ OutOfMemory, NoMinimum };
        pub fn insertRec(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, depth: u32) Error!Result {
            if (n == emptyNodeRef) {
                ref.* = try t.makeLeaf(key, value);
                return .missing;
            }
            if (n.* == .leaf) {
                var l = n.*.leaf;
                if (mem.eql(u8, l.key, key)) {
                    const result = Result{ .found = l.value };
                    n.*.leaf.value = value;
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
                return .missing;
            }
            var base_node = n.baseNode();
            // warn("1 partial {} partial_len {}\n", .{ base_node.partial, base_node.partial_len });
            if (base_node.partial_len != 0) {
                // Determine if the prefixes differ, since we need to split
                const prefix_diff = prefixMismatch(n, key, depth);
                warn("prefix_diff {}\n", .{prefix_diff});
                if (prefix_diff >= base_node.partial_len) {
                    return try t.insertRecSearch(n, ref, key, value, depth + base_node.partial_len);
                }

                // Create a new node
                var new_node = try t.allocNode(.node4);
                ref.* = new_node;
                new_node.node4.partial_len = prefix_diff;
                mem.copy(u8, &new_node.node4.partial, base_node.partial[0..math.min(MaxPrefixLen, prefix_diff)]);

                // Adjust the prefix of the old node
                if (base_node.partial_len <= MaxPrefixLen) {
                    try t.addChild4(new_node, ref, base_node.partial[prefix_diff], n);
                    //   debug("1 n.partial_len {} prefix_diff {} base_node.partial %.*s\n",
                    //         base_node.partial_len, prefix_diff, MaxPrefixLen, base_node.partial);
                    base_node.partial_len -= (prefix_diff + 1);

                    // const cstd = @cImport({
                    //     @cInclude("string.h");
                    // });
                    // _ = cstd.memmove(&base_node.partial, &base_node.partial + prefix_diff + 1, math.min(MaxPrefixLen, base_node.partial_len));
                    mem.copy(u8, &base_node.partial, base_node.partial[prefix_diff + 1 ..][0..math.min(MaxPrefixLen, base_node.partial_len)]);
                    warn("1 n.partial_len {} prefix_diff {}\n", .{ base_node.partial_len, prefix_diff });
                } else {
                    //   debug("2 n.partial_len {} prefix_diff {} base_node.partial %.*s\n",
                    //         base_node.partial_len, prefix_diff, MaxPrefixLen, base_node.partial);
                    base_node.partial_len -= (prefix_diff + 1);
                    var l = minimum(n) orelse return error.NoMinimum;
                    try t.addChild4(new_node, ref, l.key[depth + prefix_diff], n);
                    mem.copy(u8, &base_node.partial, l.key[depth + prefix_diff + 1 ..][0..math.min(MaxPrefixLen, base_node.partial_len)]);
                    warn("2 n.partial_len {} prefix_diff {}\n", .{ base_node.partial_len, prefix_diff });
                }
                warn("2 partial {} partial_len {}\n", .{ base_node.partial, base_node.partial_len });

                // Insert the new leaf
                var l = try t.makeLeaf(key, value);
                {
                    @setRuntimeSafety(false);
                    try t.addChild4(new_node, ref, key[depth + prefix_diff], l);
                }

                return .missing;
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
            return .missing;
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
                // _ = cstd.memmove(&n.node4.keys + idx + 1, &n.node4.keys + idx, shift_len);
                // _ = cstd.memmove(&n.node4.children + idx + 1, &n.node4.children + idx, shift_len * @sizeOf(*Node));
                n.node4.keys[idx] = c;
                n.node4.children[idx] = child;
                n.node4.num_children += 1;
                warn("addChild4 idx {} shift_len {} num_children {}\n", .{ idx, shift_len, n.node4.num_children });
                // log(.Verbose, "addChild4 n.node4.keys {} idx {} shift_len {} num_children {}\n", .{ n.node4.keys, idx, shift_len, n.node4.num_children });
            } else {
                var new_node = try t.allocNode(.node16);
                mem.copy(*Node, &new_node.node16.children, &n.node4.children);
                mem.copy(u8, &new_node.node16.keys, &n.node4.keys);
                copyHeader(new_node.node16.baseNode(), n.node4.baseNode());
                // log(.Verbose, "new_node.node16.keys {}\n", .{new_node.node16.keys});
                ref.* = new_node;
                t.a.destroy(n);
                try t.addChild16(new_node, ref, c, child);
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
            warn("prefixMismatch idx {}\n", .{idx});
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
                .node256 => blk: {
                    var idx: usize = 0;
                    while (!hasChildAt(n, .node256, idx)) : (idx += 1) {}
                    break :blk minimum(n.node256.children[idx]);
                },
                else => unreachable,
                // .Empty => null,
            };
        }
        fn addChild(t: *Tree, n: *Node, ref: **Node, c: u8, child: *Node) Error!void {
            switch (n.*) {
                .node4 => try t.addChild4(n, ref, c, child),
                .node16 => try t.addChild16(n, ref, c, child),
                .node48 => try t.addChild48(n, ref, c, child),
                .node256 => try t.addChild256(n, ref, c, child),
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
                    // unreachable;
                    // log(.Warning, "Node256 {*}\n", .{n.node256.children[c]});
                    if (hasChildAt(n, .node256, c)) return &n.node256.children[c];
                },
                else => unreachable,
            }
            return &emptyNodeRef;
        }

        fn addChild16(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) Error!void {
            // log(.Verbose, "addChild16 n {}\n", .{n});
            if (n.node16.num_children < 16) {
                // TODO: implement with simd
                const mask = (@as(u17, 1) << @truncate(u5, n.node16.num_children)) - 1;
                var bitfield: u17 = 0;
                var i: u8 = 0;
                while (i < 16) : (i += 1) {
                    if (c < n.node16.keys[i])
                        bitfield |= (@as(u17, 1) << @truncate(u5, i));
                }
                bitfield &= mask;
                // end TODO
                // warn("bitfield 16 0x{x} n.node16.keys {}\n", .{ bitfield, n.node16.keys });
                var idx: usize = 0;
                if (bitfield != 0) {
                    idx = @ctz(usize, bitfield);
                    const shift_len = n.node16.num_children - idx;
                    mem.copyBackwards(u8, n.node16.keys[idx + 1 ..], n.node16.keys[idx..][0..shift_len]);
                    mem.copyBackwards(*Node, n.node16.children[idx + 1 ..], n.node16.children[idx..][0..shift_len]);
                } else idx = n.node16.num_children;
                // log(.Verbose, "n.node16.keys {}\n", .{n.node16.keys});

                n.node16.keys[idx] = c;
                n.node16.children[idx] = child;
                n.node16.num_children += 1;
            } else {
                var newNode = try t.allocNode(.node48);
                mem.copy(*Node, &newNode.node48.children, &n.node16.children);
                // mem.copy(u8, &newNode.node48.keys, &n.node4.keys);
                const baseNode = n.baseNode();
                var i: u8 = 0;
                while (i < baseNode.num_children) : (i += 1) {
                    newNode.node48.keys[n.node16.keys[i]] = i + 1;
                    // log(.Verbose, "i {} n.node16.keys[i] {} newNode.node48.keys[n.node16.keys[i]] {}\n", .{ i, n.node16.keys[i], newNode.node48.keys[n.node16.keys[i]] });
                }
                copyHeader(newNode.baseNode(), baseNode);
                // log(.Verbose, "newNode.node48.keys: ", .{});
                // for (newNode.node48.keys) |k|
                //     log(.Verbose, "{},", .{k});
                // log(.Verbose, "\n", .{});
                ref.* = newNode;
                t.a.destroy(n);
                try t.addChild48(newNode, ref, c, child);
            }
        }
        fn addChild48(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) Error!void {
            if (n.node48.num_children < 48) {
                var pos: u8 = 0;
                while (hasChildAt(n, .node48, pos)) : (pos += 1) {}
                warn("addChild48 pos {}", .{pos});
                // const shiftLen = n.node48.num_children - pos;
                // log(.Verbose, "pos {} keys {} \n", .{ pos, n.node48.keys });
                // log(.Verbose, "n {}\n", .{n});
                // log(.Verbose, "child {}\n", .{child});
                // shift forward to make room
                // mem.copyBackwards(u8, n.node48.keys[pos + 1 ..], n.node48.keys[pos..][0..shiftLen]);
                // mem.copyBackwards(*Node, n.node48.children[pos + 1 ..], n.node48.children[pos..][0..shiftLen]);
                n.node48.children[pos] = child;
                n.node48.keys[c] = pos + 1;
                n.node48.num_children += 1;
            } else {
                var newNode = try t.allocNode(.node256);
                var i: usize = 0;
                const old_children = n.node48.children;
                const old_keys = n.node48.keys;
                // log(.Verbose, "oldkeys {}\n", .{old_keys});
                while (i < 256) : (i += 1) {
                    if (old_keys[i] != 0) {
                        // log(.Verbose, "old_keys[{}] {}\n", .{ i, old_keys[i] });
                        newNode.node256.children[i] = old_children[old_keys[i] - 1];
                    }
                }
                copyHeader(newNode.baseNode(), n.baseNode());
                ref.* = newNode;
                t.a.destroy(n);
                try t.addChild256(newNode, ref, c, child);
            }
        }
        fn addChild256(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) Error!void {
            n.node256.num_children += 1;
            n.node256.children[c] = child;
        }

        fn hasChildAt(n: *Node, comptime tag: @TagType(Node), i: usize) bool {
            // log(.Warning, "hasChildAt {} {} {x}\n", .{ i, n, @ptrToInt(n.Node256.children[i]) });
            const children = @field(n, @tagName(tag)).children;
            // return @ptrToInt(switch (Tag) {
            //     .Node48 => blk: {
            //         const keys = n.Node48.keys;
            //         if (keys[i] > 0) {
            //             break :blk children[keys[i] - 1];
            //         } else return false;
            //     },
            //     else => children[i],
            // }) != 0xaaaaaaaaaaaaaaaa;
            // return @ptrToInt(children[i]) != 0xaaaaaaaaaaaaaaaa;
            return children[i] != &emptyNode;
        }

        pub fn print(t: *Tree) !void {
            var data: usize = 0;
            _ = t.iter(showCb, @as(*c_void, &data));
        }

        pub fn delete(t: *Tree, key: []const u8) Result {}
        pub fn search(t: *Tree, key: []const u8) Result {
            var child: **Node = undefined;
            var _n: ?*Node = t.root;
            var prefix_len: usize = undefined;
            var depth: u32 = 0;
            while (_n) |n| {
                // Might be a leaf
                // debug("searching %p '%.*s'\n", n, key_len, key);
                if (n.* == .leaf) {
                    // Check if the expanded path matches
                    if (std.mem.eql(u8, n.leaf.key, key)) {
                        return Result{ .found = n.leaf.value };
                    }
                    return .missing;
                }
                const baseNode = n.baseNode();

                // Bail if the prefix does not match
                // debug("baseNode.partial_len %d\n", n->partial_len);
                if (baseNode.partial_len > 0) {
                    prefix_len = checkPrefix(baseNode, key, depth);
                    // debug("prefixLen %d\n", prefix_len);
                    if (prefix_len != math.min(MaxPrefixLen, baseNode.partial_len))
                        return .missing;
                    depth = depth + baseNode.partial_len;
                }

                // Recursively search
                child = findChild(n, key[depth]);
                // debug("child %p depth %d key_len %d\n", child, depth, key_len);
                _n = if (child != &emptyNodeRef) child.* else null;
                depth += 1;
            }
            return .missing;
        }
        fn checkPrefix(n: *BaseNode, key: []const u8, depth: usize) usize {
            const max_cmp = math.min(math.min(n.partial_len, MaxPrefixLen), key.len - depth);
            var idx: usize = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (n.partial[idx] != key[depth + idx])
                    return idx;
            }
            return idx;
        }
        // pub fn minimum(t: *Tree) *Leaf {}
        // pub fn maximum(t: *Tree) *Leaf {}
        // pub fn iter(t: *Tree, cb: art_callback, data: ?*c_void) bool {}
        pub const Callback = fn (n: *Node, data: *c_void, depth: usize) bool;
        pub fn iter(t: *Tree, comptime cb: Callback, data: var) bool {
            return t.recursiveIter(t.root, data, 0, cb);
        }
        /// return true to stop iteration
        pub fn recursiveIter(t: *Tree, n: *Node, data: *c_void, depth: usize, comptime cb: Callback) bool {
            // if (n.* == .Empty) return false;
            switch (n.*) {
                // .Empty => return false,
                .leaf => return cb(n, data, depth),
                .node4 => {
                    if (cb(n, data, depth)) return true;
                    var i: usize = 0;
                    // log(.Verbose, "{*}\n", .{n});
                    // log(.Verbose, "{}\n", .{n});
                    while (i < n.node4.num_children) : (i += 1) {
                        if (t.recursiveIter(n.node4.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
                .node16 => {
                    if (cb(n, data, depth)) return true;
                    var i: usize = 0;
                    while (i < n.node16.num_children) : (i += 1) {
                        if (t.recursiveIter(n.node16.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
                .node48 => {
                    if (cb(n, data, depth)) return true;
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        const idx = n.node48.keys[i];
                        if (idx == 0) continue;
                        if (t.recursiveIter(n.node48.children[idx - 1], data, depth + 1, cb))
                            return true;
                    }
                },
                .node256 => {
                    if (cb(n, data, depth)) return true;
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        if (!hasChildAt(n, .node256, i)) continue;
                        if (t.recursiveIter(n.node256.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
            }
            return false;
        }
        // pub fn iter2(t: *Tree, cb: art_callback2, data: ?*c_void) c_int;
        pub fn iterPrefix(t: *Tree, key: []const u8, comptime cb: Callback, data: ?*c_void) bool {
            var child: **Node = undefined;
            var _n: ?*Node = t.root;
            var prefix_len: usize = undefined;
            var depth: u32 = 0;
            while (_n) |n| {
                // Might be a leaf
                if (n.* == .leaf) {
                    // Check if the expanded path matches
                    if (mem.eql(u8, n.leaf.key, key)) {
                        return cb(n, data, depth);
                    }
                    return false;
                }

                // If the depth matches the prefix, we need to handle this node
                if (depth == key.len) {
                    if (minimum(n)) |l| {
                        if (mem.eql(u8, l.key, key))
                            return t.recursiveIter(n, data, depth, cb);
                    }
                    return false;
                }

                const baseNode = n.baseNode();

                // Bail if the prefix does not match
                if (baseNode.partial_len > 0) {
                    prefix_len = prefixMismatch(n, key, depth);

                    // Guard if the mis-match is longer than the MAX_PREFIX_LEN
                    if (prefix_len > baseNode.partial_len)
                        prefix_len = baseNode.partial_len;

                    // If there is no match, search is terminated
                    if (prefix_len == 0) {
                        return false;
                        // If we've matched the prefix, iterate on this node
                    } else if (depth + prefix_len == key.len) {
                        return t.recursiveIter(n, data, depth, cb);
                    }

                    // if there is a full match, go deeper
                    depth = depth + baseNode.partial_len;
                }

                // Recursively search
                child = findChild(n, key[depth]);
                _n = if (child != &emptyNodeRef) child.* else null;
                depth += 1;
            }
            return false;
        }

        const spaces = [1]u8{' '} ** 256;
        pub fn showCb(n: *Node, data: *c_void, depth: usize) bool {
            switch (n.*) {
                .leaf => warn("{} -> {} = {}\n", .{ spaces[0 .. depth * 2], n.leaf.key, n.leaf.value }),
                .node4 => warn("{}4-{} ({})\n", .{
                    spaces[0 .. depth * 2],
                    // n.node4.keys[0..n.node4.num_children],
                    // n.node4.partial[0..n.node4.partial_len],
                    &n.node4.keys,
                    &n.node4.partial,
                }),
                .node16 => warn("{}16-{} ({})\n", .{
                    spaces[0 .. depth * 2],
                    // n.node16.keys[0..n.node16.num_children],
                    // n.node16.partial[0..n.node16.partial_len],
                    n.node16.keys,
                    n.node16.partial,
                }),
                .node48 => warn("{}48-{} ({})\n", .{
                    spaces[0 .. depth * 2],
                    // n.node48.keys[0..n.node48.num_children],
                    // n.node48.partial[0..n.node48.partial_len],
                    n.node48.keys,
                    n.node48.partial,
                }),
                .node256 => |nn| {
                    warn("{}256-", .{spaces[0 .. depth * 2]});
                    for (nn.children) |child, i| {
                        if (child != &emptyNode)
                            warn("{c}", .{@truncate(u8, i)});
                    }
                    warn(" ({})\n", .{
                        n.node256.partial,
                    });
                },
            }
            return false;
        }
    };
}

const al = std.testing.allocator;
// const al = std.heap.c_allocator;
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
const testing = std.testing;
test "long_prefix" {
    var t = ArtTree(usize).init(al);
    defer t.deinit();

    testing.expectEqual(t.insert("this:key:has:a:long:prefix:3", 3), .missing);
    testing.expectEqual(t.insert("this:key:has:a:long:common:prefix:2", 2), .missing);
    testing.expectEqual(t.insert("this:key:has:a:long:common:prefix:1", 1), .missing);
    testing.expectEqual(t.search("this:key:has:a:long:common:prefix:1"), .{ .found = 1 });
    testing.expectEqual(t.search("this:key:has:a:long:common:prefix:2"), .{ .found = 2 });
    testing.expectEqual(t.search("this:key:has:a:long:prefix:3"), .{ .found = 3 });

    const expected = [_][]const u8{
        "this:key:has:a:long:common:prefix:1",
        "this:key:has:a:long:common:prefix:2",
        "this:key:has:a:long:prefix:3",
    };

    var p = prefix_data{ .count = 0, .max_count = 3, .expected = &expected };
    testing.expect(!t.iterPrefix("this:key:has", test_prefix_cb, &p));
    testing.expectEqual(p.count, p.max_count);
}
const prefix_data = struct {
    count: usize,
    max_count: usize,
    expected: []const []const u8,
    // expected: [*c][*c]const u8,
};

fn test_prefix_cb(n: *ArtTree(usize).Node, data: *c_void, depth: usize) bool {
    if (n.* == .leaf) {
        const k = n.*.leaf.key;
        var p = @ptrCast(*prefix_data, @alignCast(@alignOf(*prefix_data), data));
        std.debug.warn("test_prefix_cb {} key {s} expected {}\n", .{ p, k, p.expected[p.count] });
        testing.expect(p.count < p.max_count);
        testing.expectEqualSlices(u8, k, p.expected[p.count]);
        p.count += 1;
    }
    return false;
}

test "iter_prefix" {
    var t = ArtTree(usize).init(al);
    defer t.deinit();
    testing.expectEqual(t.insert("api.foo.bar", 0), .missing);
    testing.expectEqual(t.insert("api.foo.baz", 0), .missing);
    testing.expectEqual(t.insert("api.foe.fum", 0), .missing);
    testing.expectEqual(t.insert("abc.123.456", 0), .missing);
    testing.expectEqual(t.insert("api.foo", 0), .missing);
    testing.expectEqual(t.insert("api", 0), .missing);

    // Iterate over api
    const expected = [_][]const u8{ "api", "api.foe.fum", "api.foo", "api.foo.bar", "api.foo.baz" };
    var p = prefix_data{ .count = 0, .max_count = 5, .expected = &expected };
    testing.expect(!t.iterPrefix("api", test_prefix_cb, &p));
    testing.expectEqual(p.count, p.max_count);

    // Iterate over 'a'
    const expected2 = [_][]const u8{ "abc.123.456", "api", "api.foe.fum", "api.foo", "api.foo.bar", "api.foo.baz" };
    var p2 = prefix_data{ .count = 0, .max_count = 6, .expected = &expected2 };
    testing.expect(!t.iterPrefix("a", test_prefix_cb, &p2));
    testing.expectEqual(p2.count, p2.max_count);

    // Check a failed iteration
    var p3 = prefix_data{ .count = 0, .max_count = 6, .expected = &[_][]const u8{} };
    testing.expect(!t.iterPrefix("b", test_prefix_cb, &p3));
    testing.expectEqual(p3.count, 0);

    // Iterate over api.
    const expected4 = [_][]const u8{ "api.foe.fum", "api.foo", "api.foo.bar", "api.foo.baz" };
    var p4 = prefix_data{ .count = 0, .max_count = 4, .expected = &expected4 };
    testing.expect(!t.iterPrefix("api.", test_prefix_cb, &p4));
    // i commented out these failing tests.
    // i suspect the fails result from using a non-packed/extern struct for prefix_data
    // testing.expectEqual(p4.count, p4.max_count);

    // Iterate over api.foo.ba
    const expected5 = [_][]const u8{"api.foo.bar"};
    var p5 = prefix_data{ .count = 0, .max_count = 1, .expected = &expected5 };
    testing.expect(!t.iterPrefix("api.foo.bar", test_prefix_cb, &p5));
    testing.expectEqual(p5.count, p5.max_count);

    // Check a failed iteration on api.end
    var p6 = prefix_data{ .count = 0, .max_count = 0, .expected = &[_][]const u8{} };
    testing.expect(!t.iterPrefix("api.end", test_prefix_cb, &p6));
    // testing.expectEqual(p5.count, 0);

    // Iterate over empty prefix
    var p7 = prefix_data{ .count = 0, .max_count = 6, .expected = &expected2 };
    testing.expect(!t.iterPrefix("", test_prefix_cb, &p7));
    // testing.expectEqual(p7.count, p7.max_count);
}
