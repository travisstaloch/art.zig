const std = @import("std");
const mem = std.mem;
const math = std.math;
const u8x16 = @Vector(16, u8);

pub const Error = error{ OutOfMemory, NoMinimum, Missing };

pub fn Art(comptime T: type) type {
    return extern struct {
        root: ?*Node,
        size: usize,
        allocator: *const std.mem.Allocator,

        const Tree = @This();
        const max_prefix_len = 10;
        const BaseNode = extern struct {
            num_children: u8,
            partial_len: u8,
            partial: [max_prefix_len]u8 = [1]u8{0} ** max_prefix_len,
        };
        const alignment = @typeInfo(*Node).Pointer.alignment;
        fn SizedNode(comptime _num_keys: usize, comptime _num_children: usize) type {
            return extern struct {
                num_children: u8,
                partial_len: u8,
                partial: [max_prefix_len]u8 = [1]u8{0} ** max_prefix_len,
                keys: *[num_keys]u8,
                children: *[num_children]?*Node,
                const Self = @This();
                pub const num_keys = _num_keys;
                pub const num_children = _num_children;
                pub const AlignedBytes = []align(alignment) u8;
                pub fn baseNode(self: *Self) *BaseNode {
                    return @ptrCast(self);
                }
            };
        }
        pub const Leaf = struct {
            value: T,
            key: []const u8,
        };
        pub const Node8 = SizedNode(8, 8);
        pub const Node16 = SizedNode(16, 16);
        pub const Node48 = SizedNode(256, 48);
        pub const Node256 = SizedNode(0, 256);
        const NodeType = std.meta.Tag(Node);
        pub const Node = union(enum) {
            leaf: Leaf,
            node8: Node8,
            node16: Node16,
            node48: Node48,
            node256: Node256,

            pub fn baseNode(n: *Node) *BaseNode {
                return switch (n.*) {
                    .node8 => n.node8.baseNode(),
                    .node16 => n.node16.baseNode(),
                    .node48 => n.node48.baseNode(),
                    .node256 => n.node256.baseNode(),
                    .leaf => unreachable,
                };
            }

            pub fn childIterator(n: *Node) ChildIterator {
                return ChildIterator{ .i = 0, .parent = n };
            }
            pub const ChildIterator = struct {
                i: u9,
                parent: *Node,

                pub fn next(self: *ChildIterator) ?*Node {
                    return switch (self.parent.*) {
                        .node8 => self.yieldNext(self.parent.node8, 8, bodyGeneral),
                        .node16 => self.yieldNext(self.parent.node16, 16, bodyGeneral),
                        .node48 => self.yieldNext(self.parent.node48, 256, body48),
                        .node256 => self.yieldNext(self.parent.node256, 256, bodyGeneral),
                        .leaf => unreachable,
                    };
                }
                fn yieldNext(self: *ChildIterator, node: anytype, max: u9, comptime loopBody: fn (*ChildIterator, anytype) ?*Node) ?*Node {
                    if (self.i == max) return null;
                    defer self.i += 1;
                    while (true) : (self.i += 1) {
                        if (loopBody(self, node)) |n| return n;
                        if (self.i == max - 1) break;
                    }
                    return null;
                }
                fn bodyGeneral(_self: *ChildIterator, parent: anytype) ?*Node {
                    if (parent.children[_self.i] != null)
                        return parent.children[_self.i];
                    return null;
                }
                fn body48(_self: *ChildIterator, parent: anytype) ?*Node {
                    const idx = parent.keys[_self.i];
                    if (idx != 0 and parent.children[idx - 1] != null)
                        return parent.children[idx - 1];
                    return null;
                }
            };
        };

        pub fn init(a: *const mem.Allocator) Tree {
            return .{ .root = null, .size = 0, .allocator = a };
        }
        pub fn deinit(t: *Tree) void {
            t.deinitNode(t.root);
        }
        pub const Result = union(enum) { missing, found: Leaf };
        pub fn insert(t: *Tree, key: [:0]const u8, value: T) !Result {
            var _key = key;
            _key.len += 1;
            const result = try t.recursiveInsert(t.root, &t.root, _key, value, 0);
            if (result == .missing) t.size += 1;
            return result;
        }

        pub fn print(t: *Tree) !void {
            const stderr = std.io.getStdErr().writer();
            _ = try t.iter(showCb, stderr, Error!bool);
        }
        pub fn printToStream(t: *Tree, stream: anytype) !void {
            _ = try t.iter(showCb, stream, Error!bool);
        }
        pub fn displayNode(stream: anytype, n: ?*Node, depth: usize) void {
            _ = showCb(n, stream, depth);
        }
        pub fn displayChildren(stream: anytype, _n: ?*Node, depth: usize) void {
            const n = _n orelse return;
            var it = n.childIterator();
            while (it.next()) |child| {
                displayNode(stream, child, depth + 1);
            }
        }
        pub fn delete(t: *Tree, key: [:0]const u8) Error!Result {
            var _key = key;
            _key.len += 1;
            const result = try t.recursiveDelete(t.root, &t.root, _key, 0);
            if (result == .found) t.size -= 1;
            return result;
        }
        pub fn search(t: *Tree, key: [:0]const u8) Result {
            var _key = key;
            _key.len += 1;
            var child: ?**Node = null;
            var _n: ?*Node = t.root;
            var prefix_len: usize = undefined;
            var depth: u32 = 0;
            while (_n) |n| {
                // Might be a leaf
                if (n.* == .leaf) {
                    // Check if the expanded path matches
                    if (std.mem.eql(u8, n.leaf.key, _key)) {
                        return Result{ .found = n.leaf };
                    }
                    return .missing;
                }
                const base = n.baseNode();

                // Bail if the prefix does not match
                if (base.partial_len > 0) {
                    prefix_len = checkPrefix(base, _key, depth);
                    if (prefix_len != @min(max_prefix_len, base.partial_len))
                        return .missing;
                    depth += base.partial_len;
                }

                // Recursively search
                child = findChild(n, _key[depth]);
                _n = if (child) |c| c.* else null;
                depth += 1;
            }
            return .missing;
        }

        pub fn iter(t: *Tree, comptime cb: anytype, data: anytype, comptime CbRet: type) CbRet {
            return t.recursiveIter(t.root, data, 0, cb, CbRet);
        }

        pub fn iterAll(t: *Tree, comptime cb: anytype, data: anytype, comptime CbRet: type) CbRet {
            return t.recursiveIterAll(t.root, data, 0, cb, CbRet);
        }

        fn leafPrefixMatches(n: Leaf, prefix: []const u8) bool {
            return n.key.len > prefix.len and std.mem.startsWith(u8, n.key, prefix);
        }

        pub fn iterPrefix(t: *Tree, prefix: []const u8, cb: anytype, data: anytype, comptime CbRet: type) CbRet {
            std.debug.assert(prefix.len == 0 or prefix[prefix.len - 1] != 0);
            var child: ?**Node = undefined;
            var _n: ?*Node = t.root;
            var prefix_len: usize = undefined;
            var depth: u32 = 0;
            while (_n) |n| {
                // Might be a leaf
                if (n.* == .leaf) {
                    // Check if the expanded path matches
                    if (leafPrefixMatches(n.leaf, prefix))
                        return cb(n, data, depth);
                    return false;
                }

                // If the depth matches the prefix, we need to handle this node
                if (depth == prefix.len) {
                    if (minimum(n)) |l| {
                        if (leafPrefixMatches(l.*, prefix))
                            return t.recursiveIter(n, data, depth, cb, CbRet);
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
                        return t.recursiveIter(n, data, depth, cb, CbRet);
                    }

                    // if there is a full match, go deeper
                    depth = depth + base.partial_len;
                }

                // Recursively search
                child = findChild(n, prefix[depth]);
                _n = if (child) |c| c.* else null;
                depth += 1;
            }
            return false;
        }

        // Recursively destroys the tree
        fn deinitNode(t: *Tree, _n: ?*Node) void {
            const n = _n orelse return;
            switch (n.*) {
                .leaf => {},
                .node8, .node16, .node48, .node256 => {
                    var it = n.childIterator();
                    while (it.next()) |child| {
                        t.deinitNode(child);
                    }
                },
            }
            t.deinitNodeBytes(n);
        }

        fn deinitNodeBytes(t: *Tree, n: *Node) void {
            if (n.* == .leaf) {
                t.allocator.destroy(n);
                return;
            }
            // destroy Node + [num_keys]u8 + [num_children]*Node
            const bytes_ptr: [*]align(alignment) u8 = @ptrCast(n);
            const bytes_size = switch (n.*) {
                .node8 => nodeSize(Node8),
                .node16 => nodeSize(Node16),
                .node48 => nodeSize(Node48),
                .node256 => nodeSize(Node256),
                else => unreachable,
            };
            const bytes = bytes_ptr[0..bytes_size];
            t.allocator.free(bytes);
        }

        // don't allocate for the key. the client owns the keys
        fn makeLeaf(t: *Tree, key: []const u8, value: T) !*Node {
            const n = try t.allocator.create(Node);
            n.* = .{ .leaf = .{ .key = key, .value = value } };
            return n;
        }

        fn nodeSize(comptime NodeT: type) usize {
            return @sizeOf(Node) + NodeT.num_keys +
                @sizeOf(*Node) * NodeT.num_children;
        }

        fn allocNode(t: *Tree, comptime tag: NodeType) !*align(alignment) Node {
            const NodeT = switch (tag) {
                .node8 => Node8,
                .node16 => Node16,
                .node48 => Node48,
                .node256 => Node256,
                else => unreachable,
            };

            // allocate enough space for a Node + [num_keys]u8 + [num_children]*Node
            var bytes: NodeT.AlignedBytes = try t.allocator.alignedAlloc(u8, alignment, nodeSize(NodeT));
            const n = mem.bytesAsValue(Node, bytes[0..@sizeOf(Node)]);
            bytes = bytes[@sizeOf(Node)..];

            const KeysT = [NodeT.num_keys]u8;
            const keys_ptr: *KeysT = @ptrCast(bytes[0..NodeT.num_keys]);
            if (tag != .node256)
                bytes = bytes[NodeT.num_keys..];

            const ChildrenT = [NodeT.num_children]?*Node;
            const children_ptr_size = @sizeOf(*ChildrenT) * NodeT.num_children;
            const children_ptr: *ChildrenT = @ptrCast(@alignCast(bytes[0..children_ptr_size].ptr));

            const tag_name = @tagName(tag);
            n.* = @unionInit(Node, tag_name, .{
                .num_children = 0,
                .partial_len = 0,
                .keys = keys_ptr,
                .children = children_ptr,
            });

            var node = &@field(n, tag_name);
            node.keys.* = [1]u8{0} ** NodeT.num_keys;
            node.children.* = [1]?*Node{null} ** NodeT.num_children;
            return @ptrCast(@alignCast(n));
        }

        fn recursiveInsert(t: *Tree, _n: ?*Node, ref: *?*Node, key: []const u8, value: T, depth: u32) Error!Result {
            const n = _n orelse {
                ref.* = try t.makeLeaf(key, value);
                return .missing;
            };
            if (n.* == .leaf) {
                var l = n.leaf;
                if (mem.eql(u8, l.key, key)) {
                    const result = Result{ .found = l };
                    n.leaf.value = value;
                    return result;
                }
                var new_node = try t.allocNode(.node8);
                var l2 = try t.makeLeaf(key, value);
                const longest_prefix = longestCommonPrefix(l, l2.*.leaf, depth);
                new_node.node8.partial_len = longest_prefix;
                const len = @min(max_prefix_len, longest_prefix);
                @memcpy(new_node.node8.partial[0..len], key[depth..][0..len]);
                ref.* = new_node;
                try t.addChild8(new_node, ref, l.key[depth + longest_prefix], n);
                try t.addChild8(new_node, ref, l2.leaf.key[depth + longest_prefix], l2);
                return .missing;
            }
            var base = n.baseNode();
            if (base.partial_len != 0) {
                // Determine if the prefixes differ, since we need to split
                const prefix_diff = prefixMismatch(n, key, depth);
                if (prefix_diff >= base.partial_len)
                    return try t.recursiveInsertSearch(n, ref, key, value, depth + base.partial_len);

                // Create a new node
                var new_node = try t.allocNode(.node8);
                ref.* = new_node;
                new_node.node8.partial_len = prefix_diff;
                const len = @min(max_prefix_len, prefix_diff);
                @memcpy(new_node.node8.partial[0..len], base.partial[0..len]);

                // Adjust the prefix of the old node
                if (base.partial_len <= max_prefix_len) {
                    try t.addChild8(new_node, ref, base.partial[prefix_diff], n);
                    base.partial_len -= (prefix_diff + 1);
                    mem.copy(u8, &base.partial, base.partial[prefix_diff + 1 ..][0..@min(max_prefix_len, base.partial_len)]);
                } else {
                    base.partial_len -= (prefix_diff + 1);
                    var l = minimum(n) orelse return error.NoMinimum;
                    try t.addChild8(new_node, ref, l.key[depth + prefix_diff], n);
                    mem.copy(u8, &base.partial, l.key[depth + prefix_diff + 1 ..][0..@min(max_prefix_len, base.partial_len)]);
                }

                // Insert the new leaf
                var l = try t.makeLeaf(key, value);
                try t.addChild8(new_node, ref, key[depth + prefix_diff], l);

                return .missing;
            }
            return try t.recursiveInsertSearch(n, ref, key, value, depth);
        }
        fn recursiveInsertSearch(t: *Tree, _n: ?*Node, ref: *?*Node, key: []const u8, value: T, depth: u32) Error!Result {
            const child = findChild(_n, key[depth]);
            if (child != null) {
                return try t.recursiveInsert(child.?.*, @ptrCast(child.?), key, value, depth + 1);
            }

            // No child, node goes within us
            var l = try t.makeLeaf(key, value);
            const n = _n orelse return error.Missing;
            try t.addChild(n, ref, key[depth], l);
            return .missing;
        }
        fn longestCommonPrefix(l: Leaf, l2: Leaf, depth: usize) u8 {
            const max_cmp = @min(l.key.len, l2.key.len) - depth;
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
            const len = @min(max_prefix_len, src.partial_len);
            @memcpy(dest.partial[0..len], src.partial[0..len]);
        }

        /// Calculates the index at which the prefixes mismatch
        fn prefixMismatch(n: *Node, key: []const u8, depth: u32) u8 {
            const base = n.baseNode();
            var max_cmp: u32 = @intCast(@min(@min(max_prefix_len, base.partial_len), key.len - depth));
            var idx: u8 = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (base.partial[idx] != key[depth + idx])
                    return idx;
            }
            if (base.partial_len > max_prefix_len) {
                const l = minimum(n);
                max_cmp = @as(u32, @truncate(@min(l.?.key.len, key.len))) - depth;
                while (idx < max_cmp) : (idx += 1) {
                    if (l.?.key[idx + depth] != key[depth + idx])
                        return idx;
                }
            }
            return idx;
        }
        // Find the minimum Leaf under a node
        pub fn minimum(_n: ?*Node) ?*Leaf {
            const n = _n orelse return null;
            return switch (n.*) {
                .leaf => &n.leaf,
                .node8 => minimum(n.node8.children[0]),
                .node16 => minimum(n.node16.children[0]),
                .node48 => blk: {
                    var idx: usize = 0;
                    while (n.node48.keys[idx] == 0) : (idx += 1) {}
                    break :blk minimum(n.node48.children[n.node48.keys[idx] - 1]);
                },
                .node256 => blk: {
                    var idx: u8 = 0;
                    while (idx < 255 and n.node256.children[idx] == null) : (idx += 1) {}
                    break :blk minimum(n.node256.children[idx]);
                },
            };
        }
        pub fn maximum(_n: ?*Node) ?*Leaf {
            const n = _n orelse return null;
            // Handle base cases
            return switch (n.*) {
                .leaf => &n.leaf,
                .node8 => maximum(n.node8.children[n.node8.num_children - 1]),
                .node16 => maximum(n.node16.children[n.node16.num_children - 1]),
                .node48 => blk: {
                    var idx: u8 = 255;
                    while (n.node48.keys[idx] == 0) idx -= 1;
                    break :blk maximum(n.node48.children[n.node48.keys[idx] - 1]);
                },
                .node256 => blk: {
                    var idx: u8 = 255;
                    while (idx > 0 and n.node256.children[idx] == null) idx -= 1;
                    break :blk maximum(n.node256.children[idx]);
                },
            };
        }

        fn findChild(_n: ?*Node, c: u8) ?**Node {
            const n = _n orelse return null;
            const base = n.baseNode();
            switch (n.*) {
                .node8 => {
                    var i: u8 = 0;
                    while (i < base.num_children) : (i += 1) {
                        if (n.node8.keys[i] == c) return &n.node8.children[i].?;
                    }
                },
                .node16 => {
                    var cmp = @as(u8x16, @splat(c)) == @as(u8x16, n.node16.keys.*);
                    const mask: u16 = @truncate((@as(u17, 1) << @truncate(n.node16.num_children)) - 1);
                    const bitfield = @as(*u16, @ptrCast(&cmp)).* & mask;

                    if (bitfield != 0) return &n.node16.children[@ctz(bitfield)].?;
                },
                .node48 => {
                    const i = n.node48.keys[c];
                    if (i != 0) return &n.node48.children[i - 1].?;
                },
                .node256 => {
                    // seems like it shouldn't be, but this check is necessary
                    // removing it makes many things fail spectularly and mysteriously
                    // i thought removing this check would be ok as all children are initialized to null
                    // but that is NOT the case...
                    // the reason its necessary is that the address of the child is _NOT_ null. of course it isnt.
                    if (n.node256.children[c]) |*child| return child;
                },
                .leaf => unreachable,
            }
            return null;
        }

        fn addChild(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: *Node) Error!void {
            switch (n.*) {
                .node8 => try t.addChild8(n, ref, c, child),
                .node16 => try t.addChild16(n, ref, c, child),
                .node48 => try t.addChild48(n, ref, c, child),
                .node256 => try t.addChild256(n, ref, c, child),
                .leaf => unreachable,
            }
        }

        fn addChild8(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: *Node) !void {
            if (n.node8.num_children < 8) {
                var idx: usize = 0;
                while (idx < n.node8.num_children) : (idx += 1) {
                    if (c < n.node8.keys[idx]) break;
                }
                const shift_len = n.node8.num_children - idx;
                mem.copyBackwards(u8, n.node8.keys[idx + 1 ..], n.node8.keys[idx..][0..shift_len]);
                mem.copyBackwards(?*Node, n.node8.children[idx + 1 ..], n.node8.children[idx..][0..shift_len]);
                n.node8.keys[idx] = c;
                n.node8.children[idx] = child;
                n.node8.num_children += 1;
            } else {
                var new_node = try t.allocNode(.node16);
                mem.copy(?*Node, new_node.node16.children, n.node8.children);
                @memcpy(new_node.node16.keys[0..8], n.node8.keys);
                copyHeader(new_node.node16.baseNode(), n.node8.baseNode());
                ref.* = new_node;
                t.deinitNodeBytes(n);
                try t.addChild16(new_node, ref, c, child);
            }
        }
        fn addChild16(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: anytype) Error!void {
            if (n.node16.num_children < 16) {
                var cmp = @as(u8x16, @splat(c)) < @as(u8x16, n.node16.keys.*);
                const mask: u16 = @truncate((@as(u17, 1) << @truncate(n.node16.num_children)) - 1);
                const bitfield = @as(*u16, @ptrCast(&cmp)).* & mask;

                var idx: usize = 0;
                if (bitfield != 0) {
                    idx = @ctz(bitfield);
                    const shift_len = n.node16.num_children - idx;
                    mem.copyBackwards(u8, n.node16.keys[idx + 1 ..], n.node16.keys[idx..][0..shift_len]);
                    mem.copyBackwards(?*Node, n.node16.children[idx + 1 ..], n.node16.children[idx..][0..shift_len]);
                } else idx = n.node16.num_children;

                n.node16.keys[idx] = c;
                n.node16.children[idx] = child;
                n.node16.num_children += 1;
            } else {
                var new_node = try t.allocNode(.node48);
                mem.copy(?*Node, new_node.node48.children, n.node16.children);
                const base = n.baseNode();
                var i: u8 = 0;
                while (i < base.num_children) : (i += 1)
                    new_node.node48.keys[n.node16.keys[i]] = i + 1;
                copyHeader(new_node.baseNode(), base);
                ref.* = new_node;
                t.deinitNodeBytes(n);
                try t.addChild48(new_node, ref, c, child);
            }
        }
        fn addChild48(t: *Tree, _n: ?*Node, ref: *?*Node, c: u8, child: anytype) Error!void {
            const n = _n orelse return error.Missing;
            if (n.node48.num_children < 48) {
                var pos: u8 = 0;
                while (n.node48.children[pos] != null) : (pos += 1) {}
                n.node48.children[pos] = child;
                n.node48.keys[c] = pos + 1;
                n.node48.num_children += 1;
            } else {
                var new_node = try t.allocNode(.node256);
                var i: usize = 0;
                const old_children = n.node48.children;
                const old_keys = n.node48.keys;
                while (i < 256) : (i += 1) {
                    if (old_keys[i] != 0)
                        new_node.node256.children[i] = old_children[old_keys[i] - 1];
                }
                copyHeader(new_node.baseNode(), n.baseNode());
                ref.* = new_node;
                t.deinitNodeBytes(n);
                try t.addChild256(new_node, ref, c, child);
            }
        }

        fn addChild256(_: *Tree, _n: ?*Node, _: *?*Node, c: u8, child: anytype) Error!void {
            const n = _n orelse return error.Missing;
            n.node256.children[c] = child;
            // prevent overflow with saturating addition
            n.node256.num_children = n.node256.num_children +| 1;
        }

        fn checkPrefix(n: *BaseNode, key: []const u8, depth: usize) usize {
            // FIXME should this be key.len - 1?
            const max_cmp = @min(@min(n.partial_len, max_prefix_len), key.len - depth);
            var idx: usize = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (n.partial[idx] != key[depth + idx])
                    return idx;
            }
            return idx;
        }

        /// calls cb in order on leaf nodes until cb returns true
        fn recursiveIter(t: *Tree, _n: ?*Node, data: anytype, depth: usize, cb: anytype, comptime CbRet: type) CbRet {
            const n = _n orelse return error.Missing;
            switch (n.*) {
                .leaf => return cb(n, data, depth),
                .node8, .node16, .node48, .node256 => {
                    var ci = n.childIterator();
                    while (ci.next()) |child| {
                        if (try t.recursiveIter(child, data, depth + 1, cb, CbRet))
                            return true;
                    }
                },
            }
            return false;
        }

        /// calls cb in order on all nodes (not just leaves) until cb returns true
        fn recursiveIterAll(t: *Tree, n: ?*Node, data: anytype, depth: usize, cb: anytype, comptime CbRet: type) CbRet {
            switch (n.*) {
                .empty => {},
                .leaf => return cb(n, data, depth),
                .node8, .node16, .node48, .node256 => {
                    if (cb(n, data, depth)) return true;
                    var ci = n.childIterator();
                    while (ci.next()) |child| {
                        if (t.recursiveIterAll(child, data, depth + 1, cb, CbRet))
                            return true;
                    }
                },
            }
            return false;
        }

        const spaces = [1]u8{' '} ** 256;
        pub fn showCb(_n: ?*Node, data: anytype, depth: usize) bool {
            const streamPrint = struct {
                fn _(stream: anytype, comptime fmt: []const u8, args: anytype) void {
                    _ = stream.print(fmt, args) catch unreachable;
                }
            }._;

            const n = _n orelse {
                streamPrint(data, "empty\n", .{});
                return false;
            };

            switch (n.*) {
                .leaf => streamPrint(data, "{s}-> {s} = {}\n", .{ spaces[0 .. depth * 2], n.leaf.key, n.leaf.value }),
                .node8 => streamPrint(data, "{s}8   [{s}] ({s}) {} children\n", .{
                    spaces[0 .. depth * 2],
                    &n.node8.keys.*,
                    n.node8.partial[0..@min(max_prefix_len, n.node8.partial_len)],
                    n.node8.num_children,
                }),
                .node16 => streamPrint(data, "{s}16  [{s}] ({s}) {} children\n", .{
                    spaces[0 .. depth * 2],
                    n.node16.keys.*,
                    n.node16.partial[0..@min(max_prefix_len, n.node16.partial_len)],
                    n.node16.num_children,
                }),
                .node48 => |nn| {
                    streamPrint(data, "{s}48  [", .{spaces[0 .. depth * 2]});
                    for (nn.keys, 0..) |c, i| {
                        if (c != 0)
                            streamPrint(data, "{c}", .{@as(u8, @truncate(i))});
                    }
                    streamPrint(data, "] ({s}) {} children\n", .{ nn.partial, n.node48.num_children });
                },
                .node256 => |nn| {
                    streamPrint(data, "{s}256 [", .{spaces[0 .. depth * 2]});
                    for (nn.children, 0..) |child, i| {
                        if (child != null)
                            streamPrint(data, "{c}", .{@as(u8, @truncate(i))});
                    }
                    streamPrint(data, "] ({s}) {} children\n", .{ nn.partial, n.node256.num_children });
                },
            }
            return false;
        }

        fn recursiveDelete(t: *Tree, _n: ?*Node, ref: *?*Node, key: []const u8, _depth: usize) Error!Result {
            var depth = _depth;
            const n = _n orelse return .missing;
            if (n.* == .leaf) {
                const l = n.leaf;
                if (mem.eql(u8, n.leaf.key, key)) {
                    const result = Result{ .found = l };
                    t.deinitNode(n);
                    ref.* = null;
                    return result;
                }
                return .missing;
            }
            const base = n.baseNode();
            if (base.partial_len > 0) {
                const prefix_len = checkPrefix(base, key, depth);
                if (prefix_len != @min(max_prefix_len, base.partial_len))
                    return .missing;
                depth += base.partial_len;
            }

            const opt_child = findChild(n, key[depth]);
            var child = (opt_child orelse return .missing).*;
            if (child.* == .leaf) {
                const l = child.*.leaf;
                if (mem.eql(u8, l.key, key)) {
                    try t.removeChild(n, ref, key[depth], opt_child);
                    return Result{ .found = l };
                }
                return .missing;
            } else return try t.recursiveDelete(child, @ptrCast(opt_child.?), key, depth + 1);
        }
        fn removeChild(t: *Tree, _n: ?*Node, ref: *?*Node, c: u8, l: ?**Node) !void {
            const n = _n orelse return error.Missing;
            switch (n.*) {
                .node8 => return t.removeChild8(n, ref, l),
                .node16 => return try t.removeChild16(n, ref, l),
                .node48 => return try t.removeChild48(n, ref, c),
                .node256 => return try t.removeChild256(n, ref, c),
                .leaf => unreachable,
            }
        }
        fn removeChild8(t: *Tree, _n: ?*Node, ref: *?*Node, l: ?**Node) Error!void {
            const n = _n orelse return error.Missing;
            const pos = (@intFromPtr(l) - @intFromPtr(&n.node8.children.*)) / 8;
            if (!(0 <= pos and pos < 8)) std.log.err("bad pos found {}\n", .{pos});
            std.debug.assert(0 <= pos and pos < 8);
            t.deinitNode(n.node8.children[pos]);
            const base = n.baseNode();
            mem.copy(u8, n.node8.keys[pos..], n.node8.keys[pos + 1 ..]);
            mem.copy(?*Node, n.node8.children[pos..], n.node8.children[pos + 1 ..]);
            base.num_children -= 1;
            n.node8.keys[base.num_children] = 0;
            n.node8.children[base.num_children] = null;
            // Remove nodes with only a single child
            if (base.num_children == 1) {
                const child = n.node8.children[0] orelse return error.Missing;
                if (child.* != .leaf) {
                    // Concatenate the prefixes
                    var prefix = base.partial_len;
                    if (prefix < max_prefix_len) {
                        base.partial[prefix] = n.node8.keys[0];
                        prefix += 1;
                    }
                    const child_base = child.baseNode();
                    if (prefix < max_prefix_len) {
                        const sub_prefix = @min(child_base.partial_len, max_prefix_len - prefix);
                        @memcpy(base.partial[prefix..][0..sub_prefix], child_base.partial[0..sub_prefix]);
                        prefix += sub_prefix;
                    }
                    const len = @min(prefix, max_prefix_len);
                    @memcpy(child_base.partial[0..len], base.partial[0..len]);
                    child_base.partial_len += base.partial_len + 1;
                }
                ref.* = child;
                t.deinitNodeBytes(n);
            }
        }
        fn removeChild16(t: *Tree, _n: ?*Node, ref: *?*Node, l: ?**Node) Error!void {
            const n = _n orelse return error.Missing;
            const pos = (@intFromPtr(l) - @intFromPtr(&n.node16.children.*)) / 8;
            std.debug.assert(0 <= pos and pos < 16);
            t.deinitNode(n.node16.children[pos]);
            const base = n.baseNode();
            mem.copy(u8, n.node16.keys[pos..], n.node16.keys[pos + 1 ..]);
            mem.copy(?*Node, n.node16.children[pos..], n.node16.children[pos + 1 ..]);
            base.num_children -= 1;
            n.node16.keys[base.num_children] = 0;
            n.node16.children[base.num_children] = null;
            if (base.num_children == 7) {
                const new_node = try t.allocNode(.node8);
                ref.* = new_node;
                copyHeader(new_node.baseNode(), base);
                @memcpy(new_node.node8.keys[0..7], n.node16.keys[0..7]);
                mem.copy(?*Node, new_node.node8.children, n.node16.children[0..7]);
                t.deinitNodeBytes(n);
            }
        }
        fn removeChild48(t: *Tree, _n: ?*Node, ref: *?*Node, c: u8) Error!void {
            const n = _n orelse return error.Missing;
            const base = n.baseNode();
            var pos = n.node48.keys[c];
            n.node48.keys[c] = 0;
            t.deinitNode(n.node48.children[pos - 1]);
            n.node48.children[pos - 1] = null;
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
                t.deinitNodeBytes(n);
            }
        }
        fn removeChild256(t: *Tree, _n: ?*Node, ref: *?*Node, c: u8) Error!void {
            const n = _n orelse return error.Missing;
            const base = n.baseNode();
            t.deinitNode(n.node256.children[c]);
            n.node256.children[c] = null;

            // Resize to a node48 on underflow, not immediately to prevent
            // trashing if we sit on the 48/49 boundary
            if (base.num_children == 37) {
                const new_node = try t.allocNode(.node48);
                ref.* = new_node;
                copyHeader(new_node.baseNode(), base);

                var pos: u8 = 0;
                var i: u8 = 0;
                while (true) : (i += 1) {
                    if (n.node256.children[i] != null) {
                        new_node.node48.children[pos] = n.node256.children[i];
                        new_node.node48.keys[i] = pos + 1;
                        pos += 1;
                    }
                    if (i == 255) break;
                }
                t.deinitNodeBytes(n);
            }
        }
    };
}
