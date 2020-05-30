const std = @import("std");
const mem = std.mem;
const math = std.math;

pub fn Art(comptime T: type) type {
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
                    .leaf, .empty => unreachable,
                };
            }

            pub fn numChildren(n: *Node) u8 {
                return switch (n.*) {
                    .node4 => n.*.node4.num_children,
                    .node16 => n.*.node16.num_children,
                    .node48 => n.*.node48.num_children,
                    .node256 => n.*.node256.num_children,
                    .leaf, .empty => 0,
                };
            }

            pub fn childIterator(n: *Node) ChildIterator {
                return ChildIterator{ .i = 0, .parent = n };
            }

            pub const ChildIterator = struct {
                i: u9,
                parent: *Node,
                pub fn next(self: *ChildIterator) ?*Node {
                    const result = switch (self.parent.*) {
                        .node4 => blk: {
                            if (self.i == 4) break :blk emptyNodeRef;
                            defer self.i += 1;
                            break :blk self.parent.node4.children[self.i];
                        },
                        .node16 => blk: {
                            if (self.i == 16) break :blk emptyNodeRef;
                            defer self.i += 1;
                            break :blk self.parent.node16.children[self.i];
                        },
                        .node48 => blk: {
                            if (self.i == 256) break :blk emptyNodeRef;
                            defer self.i += 1;
                            while (true) : (self.i += 1) {
                                const idx = self.parent.node48.keys[self.i];
                                if (idx != 0)
                                    break :blk self.parent.node48.children[idx - 1];
                                if (self.i == 255) break;
                            }
                            break :blk emptyNodeRef;
                        },
                        .node256 => blk: {
                            if (self.i == 256) break :blk emptyNodeRef;
                            defer self.i += 1;
                            while (true) : (self.i += 1) {
                                if (self.parent.node256.children[self.i] != emptyNodeRef) {
                                    break :blk self.parent.node256.children[self.i];
                                }
                                if (self.i == 255) break;
                            }
                            break :blk emptyNodeRef;
                        },
                        .leaf, .empty => unreachable,
                    };
                    if (result == emptyNodeRef) return null;
                    return result;
                }
            };
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
            const stderr = std.io.getStdErr().outStream();
            _ = t.iter(showCb, stderr);
        }
        pub fn printToStream(t: *Tree, stream: var) !void {
            _ = t.iter(showCb, stream);
        }
        pub fn displayNode(stream: var, n: *Node, depth: usize) void {
            _ = showCb(n, stream, depth);
        }
        pub fn displayChildren(stream: var, n: *Node, depth: usize) void {
            var it = n.childIterator();
            while (it.next()) |child| {
                displayNode(stream, child, depth + 1);
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
            var child: **Node = &emptyNodeRef;
            var _n: ?*Node = t.root;
            var prefix_len: usize = undefined;
            var depth: u32 = 0;
            while (_n) |n| {
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
                if (base.partial_len > 0) {
                    prefix_len = checkPrefix(base, key, depth);
                    if (prefix_len != math.min(MaxPrefixLen, base.partial_len))
                        return .missing;
                    depth += base.partial_len;
                }

                // Recursively search
                child = findChild(n, key[depth]);
                _n = if (child != &emptyNodeRef) child.* else null;
                depth += 1;
            }
            return .missing;
        }

        pub fn iter(t: *Tree, comptime cb: var, data: var) bool {
            return t.recursiveIter(t.root, data, 0, cb);
        }

        fn leafPrefixMatches(n: Leaf, prefix: []const u8) bool {
            return n.key.len > prefix.len and std.mem.startsWith(u8, n.key, prefix);
        }

        pub fn iterPrefix(t: *Tree, prefix: []const u8, cb: var, data: var) bool {
            std.debug.assert(prefix.len == 0 or prefix[prefix.len - 1] != 0);
            var child: **Node = undefined;
            var _n: ?*Node = t.root;
            var prefix_len: usize = undefined;
            var depth: u32 = 0;
            while (_n) |n| {
                // Might be a leaf
                if (n.* == .leaf) {
                    // Check if the expanded path matches
                    if (leafPrefixMatches(n.*.leaf, prefix))
                        return cb(n, data, depth);
                    return false;
                }

                // If the depth matches the prefix, we need to handle this node
                if (depth == prefix.len) {
                    if (minimum(n)) |l| {
                        if (leafPrefixMatches(l.*, prefix))
                            return t.recursiveIter(n, data, depth, cb);
                    }
                    return false;
                }

                const base = n.baseNode();

                // Bail if the prefix does not match
                if (base.partial_len > 0) {
                    prefix_len = prefixMismatch(n, prefix, depth);

                    // Guard if the mis-match is longer than the MAX_PREFIX_LEN
                    if (prefix_len > base.partial_len)
                        prefix_len = base.partial_len;

                    // If there is no match, search is terminated
                    if (prefix_len == 0) {
                        return false;
                        // If we've matched the prefix, iterate on this node
                    } else if (depth + prefix_len == prefix.len) {
                        return t.recursiveIter(n, data, depth, cb);
                    }

                    // if there is a full match, go deeper
                    depth = depth + base.partial_len;
                }

                // Recursively search
                child = findChild(n, prefix[depth]);
                _n = if (child != &emptyNodeRef) child.* else null;
                depth += 1;
            }
            return false;
        }
        // Recursively destroys the tree
        fn deinitNode(t: *Tree, n: *Node) void {
            switch (n.*) {
                .empty => return,
                .leaf => |l| t.a.free(l.key),
                .node4, .node16, .node48, .node256 => {
                    var it = n.childIterator();
                    while (it.next()) |child| {
                        t.deinitNode(child);
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
            if (base.partial_len != 0) {
                // Determine if the prefixes differ, since we need to split
                const prefix_diff = prefixMismatch(n, key, depth);
                if (prefix_diff >= base.partial_len)
                    return try t.recursiveInsertSearch(n, ref, key, value, depth + base.partial_len);

                // Create a new node
                var new_node = try t.allocNode(.node4);
                ref.* = new_node;
                new_node.node4.partial_len = prefix_diff;
                mem.copy(u8, &new_node.node4.partial, base.partial[0..math.min(MaxPrefixLen, prefix_diff)]);

                // Adjust the prefix of the old node
                if (base.partial_len <= MaxPrefixLen) {
                    try t.addChild4(new_node, ref, base.partial[prefix_diff], n);
                    base.partial_len -= (prefix_diff + 1);
                    mem.copy(u8, &base.partial, base.partial[prefix_diff + 1 ..][0..math.min(MaxPrefixLen, base.partial_len)]);
                } else {
                    base.partial_len -= (prefix_diff + 1);
                    var l = minimum(n) orelse return error.NoMinimum;
                    try t.addChild4(new_node, ref, l.key[depth + prefix_diff], n);
                    mem.copy(u8, &base.partial, l.key[depth + prefix_diff + 1 ..][0..math.min(MaxPrefixLen, base.partial_len)]);
                }

                // Insert the new leaf
                var l = try t.makeLeaf(key, value);
                try t.addChild4(new_node, ref, key[depth + prefix_diff], l);

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
            // FIXME should these be key.len - 1?
            const max_cmp = math.min(l.key.len, l2.key.len) - depth;
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
        }

        /// Calculates the index at which the prefixes mismatch
        fn prefixMismatch(n: *Node, key: []const u8, depth: u32) u8 {
            const base = n.baseNode();
            // FIXME should this be key.len - 1?
            var max_cmp: u32 = math.min(math.min(MaxPrefixLen, base.partial_len), key.len - depth);
            var idx: u8 = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (base.partial[idx] != key[depth + idx])
                    return idx;
            }
            if (base.partial_len > MaxPrefixLen) {
                const l = minimum(n);
                // FIXME should this be key.len - 1?
                max_cmp = @truncate(u32, math.min(l.?.key.len, key.len)) - depth;
                while (idx < max_cmp) : (idx += 1) {
                    if (l.?.key[idx + depth] != key[depth + idx])
                        return idx;
                }
            }
            return idx;
        }
        // Find the minimum Leaf under a node
        pub fn minimum(n: *Node) ?*Leaf {
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

        fn findChild(n: *Node, c: u8) **Node {
            const base = n.baseNode();
            switch (n.*) {
                .node4 => {
                    var i: u8 = 0;
                    while (i < base.num_children) : (i += 1) {
                        if (n.node4.keys[i] == c) return &n.node4.children[i];
                    }
                },
                .node16 => {
                    var cmp = @splat(16, c) == @as(@Vector(16, u8), n.node16.keys);
                    const mask = (@as(u17, 1) << @truncate(u5, n.node16.num_children)) - 1;
                    const bitfield = @ptrCast(*u17, &cmp).* & mask;

                    if (bitfield != 0) return &n.node16.children[@ctz(usize, bitfield)];
                },
                .node48 => {
                    const i = n.node48.keys[c];
                    if (i != 0) return &n.node48.children[i - 1];
                },
                .node256 => {
                    // seems like it shouldn't be, but this check is necessary
                    // removing it makes many things fail spectularly and mysteriously
                    // i thought removing this check would be ok as all children are initialized to emptyNodeRef
                    // but that is NOT the case...
                    // i believe the reason its necessary is that the address of the child will not equal the
                    // address of emptyNodeRef.
                    if (n.node256.children[c] != emptyNodeRef)
                        return &n.node256.children[c];
                },
                .leaf, .empty => unreachable,
            }
            return &emptyNodeRef;
        }

        fn addChild(t: *Tree, n: *Node, ref: **Node, c: u8, child: *Node) Error!void {
            switch (n.*) {
                .node4 => try t.addChild4(n, ref, c, child),
                .node16 => try t.addChild16(n, ref, c, child),
                .node48 => try t.addChild48(n, ref, c, child),
                .node256 => try t.addChild256(n, ref, c, child),
                .leaf, .empty => unreachable,
            }
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
                n.node4.keys[idx] = c;
                n.node4.children[idx] = child;
                n.node4.num_children += 1;
            } else {
                var new_node = try t.allocNode(.node16);
                mem.copy(*Node, &new_node.node16.children, &n.node4.children);
                mem.copy(u8, &new_node.node16.keys, &n.node4.keys);
                copyHeader(new_node.node16.baseNode(), n.node4.baseNode());
                ref.* = new_node;
                t.a.destroy(n);
                try t.addChild16(new_node, ref, c, child);
            }
        }
        fn addChild16(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) Error!void {
            if (n.node16.num_children < 16) {
                var cmp = @splat(16, c) < @as(@Vector(16, u8), n.node16.keys);
                const mask = (@as(u17, 1) << @truncate(u5, n.node16.num_children)) - 1;
                const bitfield = @ptrCast(*u17, &cmp).* & mask;

                var idx: usize = 0;
                if (bitfield != 0) {
                    idx = @ctz(usize, bitfield);
                    const shift_len = n.node16.num_children - idx;
                    mem.copyBackwards(u8, n.node16.keys[idx + 1 ..], n.node16.keys[idx..][0..shift_len]);
                    mem.copyBackwards(*Node, n.node16.children[idx + 1 ..], n.node16.children[idx..][0..shift_len]);
                } else idx = n.node16.num_children;

                n.node16.keys[idx] = c;
                n.node16.children[idx] = child;
                n.node16.num_children += 1;
            } else {
                var newNode = try t.allocNode(.node48);
                mem.copy(*Node, &newNode.node48.children, &n.node16.children);
                const base = n.baseNode();
                var i: u8 = 0;
                while (i < base.num_children) : (i += 1)
                    newNode.node48.keys[n.node16.keys[i]] = i + 1;
                copyHeader(newNode.baseNode(), base);
                ref.* = newNode;
                t.a.destroy(n);
                try t.addChild48(newNode, ref, c, child);
            }
        }
        fn addChild48(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) Error!void {
            if (n.node48.num_children < 48) {
                var pos: u8 = 0;
                while (n.node48.children[pos] != &emptyNode) : (pos += 1) {}
                n.node48.children[pos] = child;
                n.node48.keys[c] = pos + 1;
                n.node48.num_children += 1;
            } else {
                var newNode = try t.allocNode(.node256);
                var i: usize = 0;
                const old_children = n.node48.children;
                const old_keys = n.node48.keys;
                while (i < 256) : (i += 1) {
                    if (old_keys[i] != 0)
                        newNode.node256.children[i] = old_children[old_keys[i] - 1];
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
        fn checkPrefix(n: *BaseNode, key: []const u8, depth: usize) usize {
            // FIXME should this be key.len - 1?
            const max_cmp = math.min(math.min(n.partial_len, MaxPrefixLen), key.len - depth);
            var idx: usize = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (n.partial[idx] != key[depth + idx])
                    return idx;
            }
            return idx;
        }
        /// return true to stop iteration
        fn recursiveIter(t: *Tree, n: *Node, data: var, depth: usize, cb: var) bool {
            switch (n.*) {
                .empty => {},
                .leaf => return cb(n, data, depth),
                .node4, .node16, .node48, .node256 => {
                    var ci = n.childIterator();
                    while (ci.next()) |child| {
                        if (t.recursiveIter(child, data, depth + 1, cb))
                            return true;
                    }
                },
            }
            return false;
        }

        const spaces = [1]u8{' '} ** 256;
        pub fn showCb(n: *Node, data: var, depth: usize) bool {
            const streamPrint = struct {
                fn _(stream: var, comptime fmt: []const u8, args: var) void {
                    _ = stream.print(fmt, args) catch unreachable;
                }
            }._;

            switch (n.*) {
                .empty => streamPrint(data, "empty\n", .{}),
                .leaf => streamPrint(data, "{}-> {} = {}\n", .{ spaces[0 .. depth * 2], n.leaf.key, n.leaf.value }),
                .node4 => streamPrint(data, "{}4   [{}] ({}) {} children\n", .{
                    spaces[0 .. depth * 2],
                    &n.node4.keys,
                    n.node4.partial[0..math.min(MaxPrefixLen, n.node4.partial_len)],
                    n.node4.num_children,
                }),
                .node16 => streamPrint(data, "{}16  [{}] ({}) {} children\n", .{
                    spaces[0 .. depth * 2],
                    n.node16.keys,
                    n.node16.partial[0..math.min(MaxPrefixLen, n.node16.partial_len)],
                    n.node16.num_children,
                }),
                .node48 => |nn| {
                    streamPrint(data, "{}48  [", .{spaces[0 .. depth * 2]});
                    for (nn.keys) |c, i| {
                        if (c != 0)
                            streamPrint(data, "{c}", .{@truncate(u8, i)});
                    }
                    streamPrint(data, "] ({}) {} children\n", .{ nn.partial, n.node48.num_children });
                },
                .node256 => |nn| {
                    streamPrint(data, "{}256 [", .{spaces[0 .. depth * 2]});
                    for (nn.children) |child, i| {
                        if (child != &emptyNode)
                            streamPrint(data, "{c}", .{@truncate(u8, i)});
                    }
                    streamPrint(data, "] ({}) {} children\n", .{ nn.partial, n.node256.num_children });
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
                    const result = Result{ .found = l.value };
                    t.deinitNode(n);
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
            if (childp.* == .leaf) {
                const l = childp.*.leaf;
                if (mem.eql(u8, l.key, key)) {
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
                .leaf, .empty => unreachable,
            }
        }
        fn removeChild4(t: *Tree, n: *Node, ref: **Node, l: **Node) void {
            const pos = (@ptrToInt(l) - @ptrToInt(&n.node4.children)) / 8;
            std.debug.assert(0 <= pos and pos < 4);
            t.deinitNode(n.node4.children[pos]);
            const base = n.baseNode();
            mem.copy(u8, n.node4.keys[pos..], n.node4.keys[pos + 1 ..]); //[0..shift_len]);
            mem.copy(*Node, n.node4.children[pos..], n.node4.children[pos + 1 ..]);
            base.num_children -= 1;
            n.node4.keys[base.num_children] = 0;
            n.node4.children[base.num_children] = emptyNodeRef;
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
        fn removeChild16(t: *Tree, n: *Node, ref: **Node, l: **Node) Error!void {
            const pos = (@ptrToInt(l) - @ptrToInt(&n.node16.children)) / 8;
            std.debug.assert(0 <= pos and pos < 16);
            t.deinitNode(n.node16.children[pos]);
            const base = n.baseNode();
            mem.copy(u8, n.node16.keys[pos..], n.node16.keys[pos + 1 ..]);
            mem.copy(*Node, n.node16.children[pos..], n.node16.children[pos + 1 ..]);
            base.num_children -= 1;
            n.node16.keys[base.num_children] = 0;
            n.node16.children[base.num_children] = emptyNodeRef;
            if (base.num_children == 3) {
                const new_node = try t.allocNode(.node4);
                ref.* = new_node;
                copyHeader(new_node.baseNode(), base);
                mem.copy(u8, &new_node.node4.keys, n.node16.keys[0..3]);
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
                while (true) : (i += 1) {
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
                while (true) : (i += 1) {
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

const warn = std.debug.warn;
fn replUsage(input: []const u8) void {
    const usage =
        \\ usage - command <command> 
        \\         insert <key ?value> 
        \\         delete <d:key>
        \\ --commands--
        \\   :q - quit
        \\   :r - reset (deinit/init) the tree
        \\   :h - show usage
        \\ --insert--
        \\   key - insert 'key' with value = t.size
        \\   key number - inserts key with value = parse(number)
        \\ --delete--
        \\   d:key - deletes key
        \\
    ;
    if (input.len > 0) {
        warn("invalid input: '{}'\n", .{input});
    }
    warn(usage, .{});
}

pub fn main() !void {
    var t = Art(usize).init(std.heap.c_allocator);
    const stdin = std.io.getStdIn().inStream();
    var buf: [256]u8 = undefined;
    replUsage("");
    warn("> ", .{});
    while (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |input| {
        var parts: [2][]const u8 = undefined;
        if (std.mem.eql(u8, input, ":q")) {
            break;
        } else if (std.mem.eql(u8, input, ":r")) {
            t.deinit();
            t = Art(usize).init(std.heap.c_allocator);
            continue;
        }
        var itr = std.mem.split(input, " ");
        var i: u8 = 0;
        var delete = false;
        while (itr.next()) |part| : (i += 1) {
            if (i == 0 and part.len > 1 and std.mem.eql(u8, "d:", part[0..2])) {
                delete = true;
                parts[i] = part[2..];
            } else parts[i] = part;
        }
        var res: ?Art(usize).Result = null;
        var buf2: [256]u8 = undefined;
        var key = try std.fmt.bufPrint(&buf2, "{}\x00", .{parts[0]});
        if (delete) {
            res = try t.delete(key);
        } else {
            if (i == 1) {
                res = try t.insert(key, t.size);
            } else if (i == 2) {
                const n = try std.fmt.parseInt(usize, parts[1], 10);
                res = try t.insert(key, n);
            } else
                replUsage(input);
        }
        if (res) |result| {
            var ouput: []const u8 = if (result == .missing) "insert:"[0..] else "update:"[0..];
            warn("{} size {}\n", .{ ouput, t.size });
            try t.print();
        }
        warn("> ", .{});
    }
}
