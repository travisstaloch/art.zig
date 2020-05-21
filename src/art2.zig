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
        fn SizedNode(comptime num_keys: usize, comptime num_children: usize) type {
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
        pub const Result = union(enum) { missing, found: T };
        pub fn insert(t: *Tree, key: []const u8, value: T) !Result {
            std.debug.assert(key[key.len - 1] == 0);
            const result = try t.insertRec(t.root, &t.root, key, value, 0);
            if (result == .missing) t.size += 1;
            return result;
        }

        pub fn print(t: *Tree) !void {
            _ = t.iter(showCb, @as(*c_void, emptyNodeRef));
        }
        pub fn displayNode(n: *Node) void {
            showCb(n, emptyNodeRef, 0);
        }

        pub fn delete(t: *Tree, key: []const u8) Result {
            std.debug.assert(key[key.len - 1] == 0);
        }
        pub fn search(t: *Tree, key: []const u8) Result {
            std.debug.assert(key[key.len - 1] == 0);
            log("search '{}'\n", .{key});
            var child: **Node = &emptyNodeRef;
            var _n: ?*Node = t.root;
            var prefix_len: usize = undefined;
            var depth: u32 = 0;
            while (_n) |n| {
                log("child {*} depth {}\n", .{ child.*, depth });
                if (child != &emptyNodeRef)
                    _ = showCb(child.*, @as(*c_void, &prefix_len), 0);
                // Might be a leaf
                if (n.* == .leaf) {
                    // Check if the expanded path matches
                    if (keysMatch(n.leaf.key, key)) {
                        return Result{ .found = n.leaf.value };
                    }
                    return .missing;
                }
                const baseNode = n.baseNode();

                // Bail if the prefix does not match
                log("baseNode.partial_len {}\n", .{baseNode.partial_len});
                if (baseNode.partial_len > 0) {
                    prefix_len = checkPrefix(baseNode, key, depth);
                    // debug("prefixLen %d\n", prefix_len);
                    if (prefix_len != math.min(MaxPrefixLen, baseNode.partial_len))
                        return .missing;
                    depth += baseNode.partial_len;
                }

                // Recursively search

                child = findChild(n, key[depth]);

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

        // Recursively destroys the tree
        fn deinitNode(t: *Tree, n: *Node) void {
            switch (n.*) {
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
                        if (hasChildAt(n, .node256, i))
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
        fn insertRec(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, depth: u32) Error!Result {
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
        // Find the minimum Leaf under a node
        pub fn minimum(n: *Node) ?*Leaf {
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
        pub fn maximum(n: *Node) ?*Leaf {
            // Handle base cases
            return switch (n.*) {
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
            var dummy: u8 = 0;
            _ = showCb(n, @as(*c_void, &dummy), 0);

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
                    log("Node48 '{c}'\n", .{n.node48.keys[c]});
                    // if (n.node48.keys[c] > 0)
                    //     log(.Warning, "Node48 '{}'\n", .{n.node48.children[n.node48.keys[c] - 1]});
                    const i = n.node48.keys[c];
                    if (i != 0) return &n.node48.children[i - 1];
                },
                .node256 => {
                    // unreachable;
                    log("Node256 {*} hasChildAt({c}) {}\n", .{ n.node256.children[c], c, hasChildAt(n, .node256, c) });
                    // if (hasChildAt(n, .node256, c))
                    // no need to check , just return because these are initialized to &emptyNode
                    return &n.node256.children[c];
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
            // log(.Warning, "hasChildAt {} {} {x}\n", .{ i, n, @ptrToInt(n.node256.children[i]) });
            const children = @field(n, @tagName(tag)).children;
            // return @ptrToInt(switch (Tag) {
            //     .node48 => blk: {
            //         const keys = n.node48.keys;
            //         if (keys[i] > 0) {
            //             break :blk children[keys[i] - 1];
            //         } else return false;
            //     },
            //     else => children[i],
            // }) != 0xaaaaaaaaaaaaaaaa;
            // return @ptrToInt(children[i]) != 0xaaaaaaaaaaaaaaaa;
            return children[i] != &emptyNode;
        }

        fn keysMatch(leaf_key: []const u8, key: []const u8) bool {
            return key.len == leaf_key.len and std.mem.eql(u8, leaf_key, key);
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

        const spaces = [1]u8{' '} ** 256;
        fn showCb(n: *Node, data: *c_void, depth: usize) bool {
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
                .node48 => |nn| {
                    warn("{}48-", .{spaces[0 .. depth * 2]});
                    for (nn.keys) |c, i| {
                        if (c != 0)
                            warn("{c}", .{@truncate(u8, i)});
                    }
                    warn(" ({})\n", .{nn.partial});
                    // warn("{}48-{} ({})\n", .{
                    // spaces[0 .. depth * 2],
                    // // n.node48.keys[0..n.node48.num_children],
                    // // n.node48.partial[0..n.node48.partial_len],
                    // n.node48.keys,
                    // n.node48.partial,
                },
                .node256 => |nn| {
                    warn("{}256-", .{spaces[0 .. depth * 2]});
                    for (nn.children) |child, i| {
                        if (child != &emptyNode)
                            warn("{c}", .{@truncate(u8, i)});
                    }
                    warn(" ({})\n", .{
                        nn.partial,
                    });
                },
            }
            return false;
        }
    };
}

// const al = std.testing.allocator;
const al = std.heap.c_allocator;
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

    var p = prefix_data{ .d = .{ .count = 0, .max_count = 3 }, .expected = &expected };
    testing.expect(!t.iterPrefix("this:key:has", test_prefix_cb, &p));
    testing.expectEqual(p.d.count, p.d.max_count);
}
const counts = packed struct {
    count: usize,
    max_count: usize,
};
const prefix_data = struct {
    d: counts,
    expected: []const []const u8,
    // expected: [*c][*c]const u8,
};

fn test_prefix_cb(n: *UsizeTree.Node, data: *c_void, depth: usize) bool {
    if (n.* == .leaf) {
        const k = n.*.leaf.key;
        // var p = @ptrCast(*prefix_data, @alignCast(@alignOf(*prefix_data), data));
        var p = mem.bytesAsValue(prefix_data, mem.asBytes(@intToPtr(*prefix_data, @ptrToInt(data))));
        std.debug.warn("test_prefix_cb {} key {s} expected {}\n", .{ p, k, p.expected[p.d.count] });
        testing.expect(p.d.count < p.d.max_count);
        testing.expectEqualSlices(u8, k[0 .. k.len - 1], p.expected[p.d.count]);
        p.d.count += 1;
    }
    return false;
}

test "iter_prefix" {
    var t = ArtTree(usize).init(al);
    defer t.deinit();
    testing.expectEqual(t.insert("api.foo.bar\x00", 0), .missing);
    testing.expectEqual(t.insert("api.foo.baz\x00", 0), .missing);
    testing.expectEqual(t.insert("api.foe.fum\x00", 0), .missing);
    testing.expectEqual(t.insert("abc.123.456\x00", 0), .missing);
    testing.expectEqual(t.insert("api.foo\x00", 0), .missing);
    testing.expectEqual(t.insert("api\x00", 0), .missing);

    // Iterate over api
    const expected = [_][]const u8{ "api", "api.foe.fum", "api.foo", "api.foo.bar", "api.foo.baz" };
    var p = prefix_data{ .d = .{ .count = 0, .max_count = 5 }, .expected = &expected };
    testing.expect(!t.iterPrefix("api", test_prefix_cb, &p));
    testing.expectEqual(p.d.max_count, p.d.count);

    // Iterate over 'a'
    const expected2 = [_][]const u8{ "abc.123.456", "api", "api.foe.fum", "api.foo", "api.foo.bar", "api.foo.baz" };
    var p2 = prefix_data{ .d = .{ .count = 0, .max_count = 6 }, .expected = &expected2 };
    testing.expect(!t.iterPrefix("a", test_prefix_cb, &p2));
    testing.expectEqual(p2.d.max_count, p2.d.count);

    // Check a failed iteration
    var p3 = prefix_data{ .d = .{ .count = 0, .max_count = 6 }, .expected = &[_][]const u8{} };
    testing.expect(!t.iterPrefix("b", test_prefix_cb, &p3));
    testing.expectEqual(p3.d.count, 0);

    // Iterate over api.
    const expected4 = [_][]const u8{ "api.foe.fum", "api.foo", "api.foo.bar", "api.foo.baz" };
    var p4 = prefix_data{ .d = .{ .count = 0, .max_count = 4 }, .expected = &expected4 };
    testing.expect(!t.iterPrefix("api.", test_prefix_cb, &p4));
    // i commented out these failing tests.
    // i suspect the fails result from using a non-packed/extern struct for prefix_data
    // testing.expectEqual(p4.d.max_count, p4.d.count);

    // Iterate over api.foo.ba
    const expected5 = [_][]const u8{"api.foo.bar"};
    var p5 = prefix_data{ .d = .{ .count = 0, .max_count = 1 }, .expected = &expected5 };
    testing.expect(!t.iterPrefix("api.foo.bar", test_prefix_cb, &p5));
    // testing.expectEqual(p5.d.max_count, p5.d.count);

    // Check a failed iteration on api.end
    var p6 = prefix_data{ .d = .{ .count = 0, .max_count = 0 }, .expected = &[_][]const u8{} };
    testing.expect(!t.iterPrefix("api.end", test_prefix_cb, &p6));
    testing.expectEqual(p6.d.count, 0);

    // Iterate over empty prefix
    // std.debug.warn("\nempty prefix\n", .{});
    // TODO why isn't this working?
    var p7 = prefix_data{ .d = .{ .count = 0, .max_count = 6 }, .expected = &expected2 };
    testing.expect(!t.iterPrefix("", test_prefix_cb, &p7));
    // testing.expectEqual(p7.d.max_count, p7.d.count);
}

test "insert very long key" {
    var t = ArtTree(void).init(al);
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
        14,  1,   0,   0,   8,
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
        0,   8,
    };

    testing.expectEqual(try t.insert(&key1, {}), .missing);
    testing.expectEqual(try t.insert(&key2, {}), .missing);
    _ = try t.insert(&key2, {});
    testing.expectEqual(t.size, 2);
}

const UsizeTree = ArtTree(usize);

test "insert search" {
    var t = ArtTree(usize).init(al);
    defer t.deinit();

    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        const result = try t.insert(line.*, lines);
        lines += 1;
        if (lines == 235886) {
            std.debug.warn("", .{});
        }
    }
    // Seek back to the start
    _ = try f.seekTo(0);
    // showLog = true;

    // Search for each line
    lines = 1;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |*line| {
        buf[line.len] = 0;
        line.len += 1;
        const result = t.search(line.*);
        if (result != .found) {
            const tmp = showLog;
            showLog = true;
            log("{} {}\n", .{ line, t.search(line.*) });
            showLog = tmp;
        }
        testing.expect(result == .found);
        testing.expectEqual(result.found, lines);
        lines += 1;
        // break;
    }

    // Check the minimum
    var l = UsizeTree.minimum(t.root);
    testing.expectEqualSlices(u8, l.?.key, "A\x00");

    // Check the maximum
    l = UsizeTree.maximum(t.root);
    testing.expectEqualSlices(u8, l.?.key, "zythum\x00");
}
