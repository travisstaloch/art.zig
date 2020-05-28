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
            partial_len: u8,
            partial: [MaxPrefixLen]u8 = [1]u8{0} ** MaxPrefixLen,
        };
        fn SizedNode(comptime num_keys: usize, comptime num_children: usize) type {
            return extern struct {
                num_children: u8,
                partial_len: u8,
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
            empty,
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

        pub var emptyNode: Node = .{ .empty = {} };
        pub var emptyNodeRef = &emptyNode;

        pub fn init(a: *std.mem.Allocator) Tree {
            return .{ .root = emptyNodeRef, .size = 0, .a = a };
        }
        pub fn deinit(t: *Tree) void {
            if (t.size == 0) return;
            t.deinitNode(t.root);
        }
        pub const Result = union(enum) { missing, found: T };
        pub fn insert(t: *Tree, key: []const u8, value: T) !Result {
            std.debug.assert(key[key.len - 1] == 0);
            const result = try t.recursiveInsert(t.root, &t.root, key, value, 0);
            if (result == .missing) t.size += 1;
            return result;
        }

        pub fn print(t: *Tree) !void {
            _ = t.iter(showCb, @as(*c_void, emptyNodeRef));
        }
        pub fn printToStream(t: *Tree, stream: var) !void {
            _ = t.iter(showCbStream, @as(*c_void, stream));
        }
        pub fn displayNode(n: *Node, depth: usize) void {
            _ = showCb(n, emptyNodeRef, depth);
        }
        pub fn displayChildren(n: *Node, depth: usize) void {
            if (n.* == .leaf or n.* == .empty) return;
            const base = n.baseNode();
            switch (n.*) {
                else => {},
                .node4 => {
                    for (n.node4.children[0..base.num_children]) |child| {
                        displayNode(child, depth + 1);
                    }
                },
                .node16 => {
                    for (n.node16.children[0..base.num_children]) |child| {
                        displayNode(child, depth + 1);
                    }
                },
                .node48 => {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        const idx = n.node48.keys[i];
                        if (idx == 0)
                            continue;
                        displayNode(n.node48.children[idx - 1], depth + 1);
                    }
                },
                .node256 => {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        if (n.node256.children[i] != &emptyNode)
                            displayNode(n.node256.children[i], depth + 1);
                    }
                },
            }
        }
        pub fn delete(t: *Tree, key: []const u8) Error!Result {
            std.debug.assert(key[key.len - 1] == 0);
            const result = try t.recursiveDelete(t.root, &t.root, key, 0);
            if (result == .found) t.size -= 1;
            if (t.size == 0) std.debug.assert(t.root == emptyNodeRef);
            return result;
        }
        pub fn search(t: *Tree, key: []const u8) Result {
            std.debug.assert(key[key.len - 1] == 0);
            log("search '{}'\n", .{key});
            var child: **Node = &emptyNodeRef;
            var _n: ?*Node = t.root;
            var prefix_len: usize = undefined;
            var depth: u32 = 0;
            while (_n) |n| {
                // log("child {*} depth {}\n", .{ child.*, depth });
                displayNode(n, 0);
                displayChildren(n, 0);
                // if (child != &emptyNodeRef)
                //     _ = showCb(child.*, @as(*c_void, &prefix_len), 0);
                // Might be a leaf
                if (n.* == .leaf) {
                    // Check if the expanded path matches
                    if (std.mem.eql(u8, n.leaf.key, key)) {
                        return Result{ .found = n.leaf.value };
                    }
                    return .missing;
                }
                const base = n.baseNode();

                // Bail if the prefix does not match
                log("base.partial_len {}\n", .{base.partial_len});
                if (base.partial_len > 0) {
                    prefix_len = checkPrefix(base, key, depth);
                    // debug("prefixLen %d\n", prefix_len);
                    if (prefix_len != math.min(MaxPrefixLen, base.partial_len))
                        return .missing;
                    depth += base.partial_len;
                }

                // Recursively search

                child = findChild(n, key[depth]);
                // displayNode(child.*);

                _n = if (child != &emptyNodeRef) child.* else null;
                depth += 1;
            }
            return .missing;
        }

        pub const Callback = fn (n: *Node, data: *c_void, depth: usize) bool;
        pub fn iter(t: *Tree, comptime cb: Callback, data: var) bool {
            return t.recursiveIter(t.root, data, 0, cb);
        }

        pub fn iterPrefix(t: *Tree, key: []const u8, comptime cb: Callback, data: ?*c_void) bool {
            // std.debug.assert(key[key.len - 1] == 0);
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

                const base = n.baseNode();

                // Bail if the prefix does not match
                if (base.partial_len > 0) {
                    prefix_len = prefixMismatch(n, key, depth);

                    // Guard if the mis-match is longer than the MAX_PREFIX_LEN
                    if (prefix_len > base.partial_len)
                        prefix_len = base.partial_len;

                    // If there is no match, search is terminated
                    if (prefix_len == 0) {
                        return false;
                        // If we've matched the prefix, iterate on this node
                    } else if (depth + prefix_len == key.len) {
                        return t.recursiveIter(n, data, depth, cb);
                    }

                    // if there is a full match, go deeper
                    depth = depth + base.partial_len;
                }

                // Recursively search
                child = findChild(n, key[depth]);
                _n = if (child != &emptyNodeRef) child.* else null;
                depth += 1;
            }
            return false;
        }

        // Recursively destroys the tree
        fn deinitNode(t: *Tree, n: *Node) void {
            switch (n.*) {
                .empty => {},
                .leaf => |l| {
                    t.a.free(l.key);
                    t.a.destroy(n);
                    return;
                },
                .node4 => {
                    var i: usize = 0;
                    while (i < n.node4.num_children) : (i += 1) {
                        t.deinitNode(n.node4.children[i]);
                    }
                },
                .node16 => {
                    var i: usize = 0;
                    while (i < n.node16.num_children) : (i += 1) {
                        t.deinitNode(n.node16.children[i]);
                    }
                },
                .node48 => {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        const idx = n.node48.keys[i];
                        if (idx == 0)
                            continue;
                        t.deinitNode(n.node48.children[idx - 1]);
                    }
                },
                .node256 => {
                    // unreachable;
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        if (n.node256.children[i] != &emptyNode)
                            t.deinitNode(n.node256.children[i]);
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
        const Error = error{ OutOfMemory, NoMinimum };
        fn recursiveInsert(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, depth: u32) Error!Result {
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
            var base = n.baseNode();
            // warn("1 partial {} partial_len {}\n", .{ base.partial, base.partial_len });
            if (base.partial_len != 0) {
                // Determine if the prefixes differ, since we need to split
                const prefix_diff = prefixMismatch(n, key, depth);
                warn("prefix_diff {}\n", .{prefix_diff});
                if (prefix_diff >= base.partial_len) {
                    return try t.recursiveInsertSearch(n, ref, key, value, depth + base.partial_len);
                }

                // Create a new node
                var new_node = try t.allocNode(.node4);
                ref.* = new_node;
                new_node.node4.partial_len = prefix_diff;
                mem.copy(u8, &new_node.node4.partial, base.partial[0..math.min(MaxPrefixLen, prefix_diff)]);

                // Adjust the prefix of the old node
                if (base.partial_len <= MaxPrefixLen) {
                    try t.addChild4(new_node, ref, base.partial[prefix_diff], n);
                    //   debug("1 n.partial_len {} prefix_diff {} base.partial %.*s\n",
                    //         base.partial_len, prefix_diff, MaxPrefixLen, base.partial);
                    base.partial_len -= (prefix_diff + 1);

                    // const cstd = @cImport({
                    //     @cInclude("string.h");
                    // });
                    // _ = cstd.memmove(&base.partial, &base.partial + prefix_diff + 1, math.min(MaxPrefixLen, base.partial_len));
                    mem.copy(u8, &base.partial, base.partial[prefix_diff + 1 ..][0..math.min(MaxPrefixLen, base.partial_len)]);
                    warn("1 n.partial_len {} prefix_diff {}\n", .{ base.partial_len, prefix_diff });
                } else {
                    //   debug("2 n.partial_len {} prefix_diff {} base.partial %.*s\n",
                    //         base.partial_len, prefix_diff, MaxPrefixLen, base.partial);
                    base.partial_len -= (prefix_diff + 1);
                    var l = minimum(n) orelse return error.NoMinimum;
                    try t.addChild4(new_node, ref, l.key[depth + prefix_diff], n);
                    mem.copy(u8, &base.partial, l.key[depth + prefix_diff + 1 ..][0..math.min(MaxPrefixLen, base.partial_len)]);
                    warn("2 n.partial_len {} prefix_diff {}\n", .{ base.partial_len, prefix_diff });
                }
                warn("2 partial {} partial_len {}\n", .{ base.partial, base.partial_len });

                // Insert the new leaf
                var l = try t.makeLeaf(key, value);
                {
                    @setRuntimeSafety(false);
                    try t.addChild4(new_node, ref, key[depth + prefix_diff], l);
                }

                return .missing;
            }
            return try t.recursiveInsertSearch(n, ref, key, value, depth);
        }
        fn recursiveInsertSearch(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, depth: u32) Error!Result {
            const child = findChild(n, key[depth]);
            if (child != &emptyNodeRef) {
                return try t.recursiveInsert(child.*, child, key, value, depth + 1);
            }

            // No child, node goes within us
            var l = try t.makeLeaf(key, value);
            try t.addChild(n, ref, key[depth], l);
            return .missing;
        }
        fn longestCommonPrefix(l: Leaf, l2: Leaf, depth: usize) u8 {
            const max_cmp = math.min(l.key.len, l2.key.len) - depth;
            // max_cmp = if (max_cmp > depth) max_cmp - depth else 0;
            var idx: u8 = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (l.key[depth + idx] != l2.key[depth + idx])
                    return idx;
            }
            return idx;
        }
        fn copyHeader(dest: *BaseNode, src: *BaseNode) void {
            dest.num_children = src.num_children;
            dest.partial_len = src.partial_len;
            mem.copy(u8, &dest.partial, src.partial[0..math.min(MaxPrefixLen, src.partial_len)]);
            // log(.Verbose, "copyHeader dest num_children {} partial_len {} partaial {}", .{ dest.num_children, dest.partial_len, dest.partial });
        }

        /// Calculates the index at which the prefixes mismatch
        fn prefixMismatch(n: *Node, key: []const u8, depth: u32) u8 {
            const base = n.baseNode();
            var max_cmp: u32 = math.min(math.min(MaxPrefixLen, base.partial_len), key.len - depth);
            var idx: u8 = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (base.partial[idx] != key[depth + idx])
                    return idx;
            }
            if (base.partial_len > MaxPrefixLen) {
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
        // Find the minimum Leaf under a node
        pub fn minimum(n: *Node) ?*Leaf {
            // log(.Verbose, "minimum {}\n", .{n});
            return switch (n.*) {
                .empty => null,
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
                    while (n.node256.children[idx] == &emptyNode) : (idx += 1) {}
                    break :blk minimum(n.node256.children[idx]);
                },
                else => unreachable,
            };
        }
        pub fn maximum(n: *Node) ?*Leaf {
            // Handle base cases
            return switch (n.*) {
                .empty => null,
                .leaf => &n.leaf,
                .node4 => maximum(n.node4.children[n.node4.num_children - 1]),
                .node16 => maximum(n.node16.children[n.node16.num_children - 1]),
                .node48 => blk: {
                    var idx: u8 = 255;
                    while (n.node48.keys[idx] == 0) idx -= 1;
                    break :blk maximum(n.node48.children[n.node48.keys[idx] - 1]);
                },
                .node256 => blk: {
                    var idx: u8 = 255;
                    while (n.node256.children[idx] == &emptyNode) idx -= 1;
                    break :blk maximum(n.node256.children[idx]);
                },
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
            log("findChild '{c}'\n", .{c});
            // displayNode(n);
            // log("\n", .{});
            // var dummy: u8 = 0;
            // _ = showCb(n, @as(*c_void, &dummy), 0);

            // log(.Warning, "findChild '{c}'\n", .{c});
            switch (n.*) {
                .node4 => {
                    // log("base.num_children {}\n", .{base.num_children});
                    var i: u8 = 0;
                    while (i < base.num_children) : (i += 1) {
                        if (n.node4.keys[i] == c) return &n.node4.children[i];
                    }
                },
                .node16 => {
                    // TODO: simd
                    var bitfield: u17 = 0;
                    for (n.node16.keys[0..n.node16.num_children]) |k, i| {
                        if (k == c)
                            bitfield |= (@as(u17, 1) << @truncate(u5, i));
                    }
                    const mask = (@as(u17, 1) << @truncate(u5, base.num_children)) - 1;
                    bitfield &= mask;
                    log("bitfield 0b{b}\n", .{bitfield});
                    // if (bitfield != 0)
                    //     log(.Warning, "Node16 child {}\n", .{n.node16.children[@ctz(usize, bitfield)]});

                    // end TODO
                    if (bitfield != 0) return &n.node16.children[@ctz(usize, bitfield)];
                },
                .node48 => {
                    // log("Node48 '{c}'\n", .{n.node48.keys[c]});
                    // if (n.node48.keys[c] > 0)
                    //     log(.Warning, "Node48 '{}'\n", .{n.node48.children[n.node48.keys[c] - 1]});
                    const i = n.node48.keys[c];
                    if (i != 0) return &n.node48.children[i - 1];
                },
                .node256 => {
                    // log("Node256 {*} has child '{c}' {}\n", .{ n.node256.children[c], c, n.node256.children[c] != &emptyNode });
                    // no need to check if empty, just return because these are initialized to &emptyNode
                    return &n.node256.children[c];
                },
                else => unreachable,
            }
            return &emptyNodeRef;
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
        fn addChild16(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) Error!void {
            // log(.Verbose, "addChild16 n {}\n", .{n});
            if (n.node16.num_children < 16) {
                // TODO: implement with simd
                const mask = (@as(u17, 1) << @truncate(u5, n.node16.num_children)) - 1;
                var bitfield: u17 = 0;
                var i: u8 = 0;
                while (i < n.node16.num_children) : (i += 1) {
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
                const base = n.baseNode();
                var i: u8 = 0;
                while (i < base.num_children) : (i += 1) {
                    newNode.node48.keys[n.node16.keys[i]] = i + 1;
                    // log(.Verbose, "i {} n.node16.keys[i] {} newNode.node48.keys[n.node16.keys[i]] {}\n", .{ i, n.node16.keys[i], newNode.node48.keys[n.node16.keys[i]] });
                }
                copyHeader(newNode.baseNode(), base);
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
                while (n.node48.children[pos] != &emptyNode) : (pos += 1) {}
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

        fn keysMatch(leaf_key: []const u8, key: []const u8) bool {
            return std.mem.eql(u8, leaf_key, key);
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
        /// return true to stop iteration
        fn recursiveIter(t: *Tree, n: *Node, data: *c_void, depth: usize, comptime cb: Callback) bool {
            switch (n.*) {
                .empty => {},
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
                        if (n.node256.children[i] == &emptyNode) continue;
                        if (t.recursiveIter(n.node256.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
            }
            return false;
        }

        const spaces = [1]u8{' '} ** 256;
        pub fn showCb(n: *Node, data: *c_void, depth: usize) bool {
            switch (n.*) {
                .empty => warn("empty\n", .{}),
                .leaf => warn("{}-> {} = {}\n", .{ spaces[0 .. depth * 2], n.leaf.key, n.leaf.value }),
                .node4 => warn("{}4   [{}] ({}) {} children\n", .{
                    spaces[0 .. depth * 2],
                    &n.node4.keys,
                    // n.node4.keys[0..n.node4.num_children],
                    // &n.node4.partial,
                    n.node4.partial[0..math.min(MaxPrefixLen, n.node4.partial_len)],
                    n.node4.num_children,
                }),
                .node16 => warn("{}16  [{}] ({}) {} children\n", .{
                    spaces[0 .. depth * 2],
                    n.node16.keys,
                    // n.node16.keys[0..n.node16.num_children],
                    // n.node16.partial,
                    n.node16.partial[0..math.min(MaxPrefixLen, n.node16.partial_len)],
                    n.node16.num_children,
                }),
                .node48 => |nn| {
                    warn("{}48  [", .{spaces[0 .. depth * 2]});
                    for (nn.keys) |c, i| {
                        if (c != 0)
                            warn("{c}", .{@truncate(u8, i)});
                    }
                    warn("] ({}) {} children\n", .{ nn.partial, n.node48.num_children });
                    // warn("{}48-{} ({})\n", .{
                    // spaces[0 .. depth * 2],
                    // // n.node48.keys[0..n.node48.num_children],
                    // // n.node48.partial[0..n.node48.partial_len],
                    // n.node48.keys,
                    // n.node48.partial,
                },
                .node256 => |nn| {
                    warn("{}256 [", .{spaces[0 .. depth * 2]});
                    for (nn.children) |child, i| {
                        if (child != &emptyNode)
                            warn("{c}", .{@truncate(u8, i)});
                    }
                    warn("] ({}) {} children\n", .{ nn.partial, n.node256.num_children });
                },
            }
            return false;
        }

        fn showCbStream(n: *Node, data: *c_void, depth: usize) bool {
            const Stream = *@TypeOf(std.io.getStdErr().outStream());

            var stream = @ptrCast(Stream, @alignCast(@alignOf(Stream), data));
            switch (n.*) {
                .leaf => _ = stream.print("{} -> {} = {}\n", .{ spaces[0 .. depth * 2], n.leaf.key, n.leaf.value }) catch unreachable,
                .node4 => _ = stream.print("{}4 [{}] ({})\n", .{
                    spaces[0 .. depth * 2],
                    &n.node4.keys,
                    // n.node4.keys[0..n.node4.num_children],
                    // &n.node4.partial,
                    n.node4.partial[0..math.min(MaxPrefixLen, n.node4.partial_len)],
                }) catch unreachable,
                .node16 => _ = stream.print("{}16 [{}] ({})\n", .{
                    spaces[0 .. depth * 2],
                    n.node16.keys,
                    // n.node16.keys[0..n.node16.num_children],
                    // n.node16.partial,
                    n.node16.partial[0..math.min(MaxPrefixLen, n.node16.partial_len)],
                }) catch unreachable,
                .node48 => |nn| {
                    _ = stream.print("{}48 [", .{spaces[0 .. depth * 2]}) catch unreachable;
                    for (nn.keys) |c, i| {
                        if (c != 0)
                            _ = stream.print("{c}", .{@truncate(u8, i)}) catch unreachable;
                    }
                    _ = stream.print("] ({})\n", .{nn.partial}) catch unreachable;
                    // _ = stream.print("{}48-{} ({})\n", .{
                    // spaces[0 .. depth * 2],
                    // // n.node48.keys[0..n.node48.num_children],
                    // // n.node48.partial[0..n.node48.partial_len],
                    // n.node48.keys,
                    // n.node48.partial,
                },
                .node256 => |nn| {
                    _ = stream.print("{}256 [", .{spaces[0 .. depth * 2]}) catch unreachable;
                    for (nn.children) |child, i| {
                        if (child != &emptyNode)
                            _ = stream.print("{c}", .{@truncate(u8, i)}) catch unreachable;
                    }
                    _ = stream.print("] ({})\n", .{
                        nn.partial,
                    }) catch unreachable;
                },
            }
            return false;
        }

        fn recursiveDelete(t: *Tree, n: *Node, ref: **Node, key: []const u8, _depth: usize) Error!Result {
            var depth = _depth;
            if (n == emptyNodeRef) return .missing;
            if (n.* == .leaf) {
                const l = n.*.leaf;
                if (mem.eql(u8, n.*.leaf.key, key)) {
                    // t.deinitNode(n);
                    log("1 found leaf to delete {}\n", .{l});
                    const result = Result{ .found = l.value };
                    // t.a.free(n.*.leaf.key);
                    // t.a.destroy(n);
                    ref.* = emptyNodeRef;
                    return result;
                }
                return .missing;
            }
            const base = n.baseNode();
            if (base.partial_len > 0) {
                const prefix_len = checkPrefix(base, key, depth);
                if (prefix_len != math.min(MaxPrefixLen, base.partial_len))
                    return .missing;
                depth += base.partial_len;
            }

            const child = findChild(n, key[depth]);
            if (child == &emptyNodeRef) return .missing;
            const childp = child.*;
            log("checking ", .{});
            displayNode(childp, 0);
            displayChildren(childp, 0);
            log("\n", .{});
            if (childp.* == .leaf) {
                const l = childp.*.leaf;
                if (mem.eql(u8, l.key, key)) {
                    log("2 found leaf to delete {}\n", .{l});
                    try t.removeChild(n, ref, key[depth], child);
                    return Result{ .found = l.value };
                }
                return .missing;
            } else return try t.recursiveDelete(child.*, child, key, depth + 1);
        }
        fn removeChild(t: *Tree, n: *Node, ref: **Node, c: u8, l: **Node) !void {
            switch (n.*) {
                .node4 => return t.removeChild4(n, ref, l),
                .node16 => return try t.removeChild16(n, ref, l),
                .node48 => return try t.removeChild48(n, ref, c),
                .node256 => return try t.removeChild256(n, ref, c),
                else => unreachable,
            }
        }
        fn removeChild4(t: *Tree, n: *Node, ref: **Node, l: **Node) void {
            // std.debug.warn("removeChild4 l {*} &children {*}\n", .{ l, &n.node4.children });
            const pos = (@ptrToInt(l) - @ptrToInt(&n.node4.children)) / 8;
            std.debug.assert(0 <= pos and pos < 4);
            t.deinitNode(n.node4.children[pos]);
            const base = n.baseNode();
            // const shift_len = base.num_children - 1 - pos;
            // @memcpy(n.node4.keys[pos..].ptr, n.node4.keys[pos + 1 ..].ptr, shift_len);
            // const shift_len = math.min(base.num_children, 4-(pos + 1));
            // const shift_len = base.num_children - (pos+1);
            mem.copy(u8, n.node4.keys[pos..], n.node4.keys[pos + 1 ..]); //[0..shift_len]);
            // @memcpy(@ptrCast([*]u8, n.node4.children[pos..].ptr), @ptrCast([*]u8, n.node4.children[pos + 1 ..].ptr), @sizeOf(*Node) * shift_len); //[0..shift_len]);
            mem.copy(*Node, n.node4.children[pos..], n.node4.children[pos + 1 ..]);
            base.num_children -= 1;
            n.node4.keys[base.num_children] = 0;
            n.node4.children[base.num_children] = emptyNodeRef;
            log("removeChild4 new keys {s} pos {} num_children {}\n", .{ n.node4.keys[0..], pos, base.num_children });
            // Remove nodes with only a single child
            if (base.num_children == 1) {
                const child = n.node4.children[0];
                if (child.* != .leaf) {
                    // Concatenate the prefixes
                    var prefix = base.partial_len;
                    if (prefix < MaxPrefixLen) {
                        base.partial[prefix] = n.node4.keys[0];
                        prefix += 1;
                    }
                    const child_base = child.baseNode();
                    if (prefix < MaxPrefixLen) {
                        const sub_prefix = math.min(child_base.partial_len, MaxPrefixLen - prefix);
                        mem.copy(u8, base.partial[prefix..], child_base.partial[0..sub_prefix]);
                        prefix += sub_prefix;
                    }
                    mem.copy(u8, &child_base.partial, base.partial[0..math.min(prefix, MaxPrefixLen)]);
                    child_base.partial_len += base.partial_len + 1;
                }
                ref.* = child;
                t.a.destroy(n);
            }
        }
        // const cstr = @cImport({
        //     @cInclude("string.h");
        // });
        fn removeChild16(t: *Tree, n: *Node, ref: **Node, l: **Node) Error!void {
            const pos = (@ptrToInt(l) - @ptrToInt(&n.node16.children)) / 8;
            std.debug.assert(0 <= pos and pos < 16);
            t.deinitNode(n.node16.children[pos]);
            const base = n.baseNode();
            // const shift_len = base.num_children - 1 - pos;
            // @memcpy(n.node16.keys[pos..].ptr, n.node16.keys[pos + 1 ..].ptr, shift_len);
            // @memcpy(@ptrCast([*]u8, n.node16.children[pos..].ptr), @ptrCast([*]u8, n.node16.children[pos + 1 ..].ptr), @sizeOf(*Node) * shift_len);
            log("removeChild16 old keys {s} pos {} num_children {}\n", .{ n.node16.keys[0..], pos, base.num_children });
            mem.copy(u8, n.node16.keys[pos..], n.node16.keys[pos + 1 ..]);
            mem.copy(*Node, n.node16.children[pos..], n.node16.children[pos + 1 ..]);
            base.num_children -= 1;
            n.node16.keys[base.num_children] = 0;
            n.node16.children[base.num_children] = emptyNodeRef;
            // _ = cstr.memmove(@ptrCast(*c_void, n.node16.keys[pos..].ptr), @ptrCast(*c_void, n.node16.keys[pos + 1 ..].ptr), base.num_children - 1 - pos);
            // _ = cstr.memmove(@ptrCast(*c_void, n.node16.children[pos..].ptr), @ptrCast(*c_void, n.node16.children[pos + 1 ..].ptr), (base.num_children - 1 - pos) * @sizeOf(*Node));
            log("removeChild16 new keys {s} pos {} num_children {}\n", .{ n.node16.keys[0..], pos, base.num_children });
            if (base.num_children == 3) {
                const new_node = try t.allocNode(.node4);
                ref.* = new_node;
                copyHeader(new_node.baseNode(), base);
                mem.copy(u8, &new_node.node4.keys, n.node16.keys[0..3]);
                log("new_node.keys {}\n", .{new_node.node4.keys[0..]});
                mem.copy(*Node, &new_node.node4.children, n.node16.children[0..3]);
                t.a.destroy(n);
            }
        }
        fn removeChild48(t: *Tree, n: *Node, ref: **Node, c: u8) Error!void {
            const base = n.baseNode();
            var pos = n.node48.keys[c];
            n.node48.keys[c] = 0;
            t.deinitNode(n.node48.children[pos - 1]);
            n.node48.children[pos - 1] = emptyNodeRef;
            base.num_children -= 1;

            if (base.num_children == 12) {
                const new_node = try t.allocNode(.node16);
                ref.* = new_node;
                copyHeader(new_node.baseNode(), base);

                var childi: u8 = 0;
                var i: u8 = 0;
                while (childi < 12) : (i += 1) {
                    pos = n.node48.keys[i];
                    if (pos != 0) {
                        new_node.node16.keys[childi] = i;
                        new_node.node16.children[childi] = n.node48.children[pos - 1];
                        childi += 1;
                    }
                    if (i == 255) break;
                }
                t.a.destroy(n);
            }
        }
        fn removeChild256(t: *Tree, n: *Node, ref: **Node, c: u8) Error!void {
            const base = n.baseNode();
            t.deinitNode(n.node256.children[c]);
            n.node256.children[c] = emptyNodeRef;
            base.num_children -= 1;

            // Resize to a node48 on underflow, not immediately to prevent
            // trashing if we sit on the 48/49 boundary
            if (base.num_children == 37) {
                const new_node = try t.allocNode(.node48);
                ref.* = new_node;
                copyHeader(new_node.baseNode(), base);

                var pos: u8 = 0;
                var i: u8 = 0;
                while (pos < 37) : (i += 1) {
                    if (n.node256.children[i] != emptyNodeRef) {
                        new_node.node48.children[pos] = n.node256.children[i];
                        new_node.node48.keys[i] = pos + 1;
                        pos += 1;
                    }
                    if (i == 255) break;
                }
                t.a.destroy(n);
            }
        }
    };
}
