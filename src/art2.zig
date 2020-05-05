const std = @import("std");
const math = std.math;
const mem = std.mem;

// const ShowDebugLog = true;
const LogLevel = enum { Info, Verbose, Warning, Error, None };
pub var logLevel = LogLevel.None;
pub fn log(level: LogLevel, comptime fmt: []const u8, vals: var) void {
    const s = std.io.getStdOut().outStream();
    if (@enumToInt(level) >= @enumToInt(logLevel))
    // _ = s.print(fmt, vals) catch unreachable;
        std.debug.warn(fmt, vals);
}

pub fn ArtTree(comptime T: type) type {
    return struct {
        root: *Node,
        size: usize,
        allr: *mem.Allocator,
        const MaxPartialLen = 10;
        const BaseNode = struct {
            numChildren: u8,
            partialLen: usize,
            partial: [MaxPartialLen]u8 = [1]u8{0} ** MaxPartialLen,
        };

        const Leaf = struct {
            value: ?T,
            key: []u8,
        };

        pub fn SizedNode(comptime keysLen: usize, comptime childrenLen: usize) type {
            return struct {
                n: BaseNode,
                keys: [keysLen]u8 = [1]u8{0} ** keysLen,
                children: [childrenLen]*Node = [1]*Node{&emptyNode} ** childrenLen,
            };
        }

        pub const Node4 = SizedNode(4, 4);
        pub const Node16 = SizedNode(16, 16);
        pub const Node48 = SizedNode(256, 48);
        pub const Node256 = SizedNode(0, 256);

        pub const Node = union(enum) {
            Empty,
            Leaf: Leaf,
            Node4: Node4,
            Node16: Node16,
            Node48: Node48,
            Node256: Node256,
            pub fn baseNode(self: *Node) *BaseNode {
                return switch (self.*) {
                    .Node4 => &self.Node4.n,
                    .Node16 => &self.Node16.n,
                    .Node48 => &self.Node48.n,
                    .Node256 => &self.Node256.n,
                    .Leaf, .Empty => unreachable,
                };
            }
            pub fn keys(self: *Node, _buf: ?*[256]u8) ![]u8 {
                return switch (self.*) {
                    .Node4 => &self.Node4.keys,
                    .Node16 => &self.Node16.keys,
                    .Node48 => &self.Node48.keys,
                    .Node256 => blk: {
                        var ki: u8 = 0;
                        var buf = _buf orelse return error.NoBuffer;
                        for (self.Node256.children) |_, i| {
                            if (hasChildAt(self, .Node256, i)) {
                                buf[ki] = @truncate(u8, i);
                                ki += 1;
                            }
                        }
                        break :blk buf[0..ki];
                    },
                    .Leaf, .Empty => unreachable,
                };
            }
            pub fn children(self: *Node) []*Node {
                return switch (self.*) {
                    .Node4 => &self.Node4.children,
                    .Node16 => &self.Node16.children,
                    .Node48 => &self.Node48.children,
                    .Node256 => &self.Node256.children,
                    .Leaf, .Empty => unreachable,
                };
            }
        };

        const Tree = ArtTree(T);
        var emptyNode = Node{ .Empty = {} };
        var emptyNodeRef = &emptyNode;

        fn asNonConst(comptime P: type, comptime p: *const P) *P {
            return comptime @intToPtr(*P, @ptrToInt(p));
        }

        pub fn init(allr: *mem.Allocator) Tree {
            return Tree{ .root = emptyNodeRef, .size = 0, .allr = allr };
        }
        fn allocNode(t: *Tree, comptime Tag: @TagType(Node)) !*Node {
            var node = try t.allr.create(Node);
            const tagName = @tagName(Tag);
            // node.* = @unionInit(Node, tagName, .{ .n = .{ .numChildren = 0, .partialLen = 0 }, .children = undefined });
            node.* = @unionInit(Node, tagName, .{ .n = .{ .numChildren = 0, .partialLen = 0 } });
            var tagField = @field(node, tagName);
            // mem.secureZero(*Node, &tagField.children);
            // @memset(@ptrCast([*]u8, &tagField.children), 0, @sizeOf(*Node) * tagField.children.len);
            return node;
        }
        pub fn deinit(t: *Tree) void {
            t.deinitNode(t.root);
        }
        // Recursively destroys the tree
        pub fn deinitNode(t: *Tree, n: *Node) void {
            switch (n.*) {
                .Empty => return,
                .Leaf => |l| {
                    t.allr.free(l.key);
                    t.allr.destroy(n);
                    return;
                },

                .Node4, .Node16 => {
                    var i: usize = 0;
                    const children = n.children();
                    while (i < n.baseNode().numChildren) : (i += 1) {
                        t.deinitNode(children[i]);
                    }
                },

                .Node48 => {
                    var i: usize = 0;
                    const children = n.children();
                    while (i < 256) : (i += 1) {
                        const idx = n.Node48.keys[i];
                        if (idx == 0)
                            continue;
                        t.deinitNode(children[idx - 1]);
                    }
                },

                .Node256 => {
                    var i: usize = 0;
                    const children = n.children();
                    while (i < 256) : (i += 1) {
                        if (hasChildAt(n, .Node256, i))
                            t.deinitNode(children[i]);
                    }
                },
            }

            t.allr.destroy(n);
        }

        fn makeLeaf(key: []const u8, value: T) !*Node {
            var n = try a.create(Node);
            n.* = .{ .Leaf = .{ .value = value, .key = try a.alloc(u8, key.len) } };
            mem.copy(u8, n.Leaf.key, key);
            return n;
        }
        pub fn insert(t: *Tree, key: []const u8, value: T) !Result {
            std.debug.assert(key[key.len - 1] == 0);
            const res = try t.recursiveInsert(t.root, &t.root, key, value, 0);
            if (res == .Missing) t.size += 1;
            return res;
        }
        fn longestCommonPrefix(l: Leaf, l2: Leaf, depth: usize) usize {
            var max_cmp = math.min(l.key.len, l2.key.len);
            max_cmp = if (max_cmp > depth) max_cmp - depth else 0;
            var common: usize = 0;
            while (common < max_cmp) : (common += 1) if (l.key[depth + common] != l2.key[depth + common])
                return common;
            return common;
        }
        /// Calculates the index at which the prefixes mismatch
        fn prefixMismatch(n: *Node, key: []const u8, depth: usize) usize {
            const base = n.baseNode();
            var max_cmp = math.min(math.min(MaxPartialLen, base.partialLen), key.len - depth);
            var idx: usize = 0;
            while (idx < max_cmp) : (idx += 1) if (base.partial[idx] != key[depth + idx])
                return idx;
            if (base.partialLen > MaxPartialLen) {
                const l = minimum(n);
                max_cmp = math.min(l.?.key.len, key.len) - depth;
                while (idx < max_cmp) : (idx += 1) if (l.?.key[idx + depth] != key[depth + idx])
                    return idx;
            }
            return idx;
        }
        pub fn min(t: *Tree) ?*Leaf {
            return minimum(t.root);
        }
        // Find the minimum Leaf under a node
        fn minimum(n: *Node) ?*Leaf {
            log(.Verbose, "minimum {}\n", .{n});
            var idx: usize = 0;
            switch (n.*) {
                .Leaf => return &n.Leaf,
                .Node4 => return minimum(n.Node4.children[0]),
                .Node16 => return minimum(n.Node16.children[0]),
                .Node48 => {
                    while (n.Node48.keys[idx] == 0) : (idx += 1) {}
                    return minimum(n.Node48.children[n.Node48.keys[idx] - 1]);
                },
                .Node256 => {
                    while (!hasChildAt(n, .Node256, idx)) : (idx += 1) {}
                    return minimum(n.Node256.children[idx]);
                },
                .Empty => return null,
            }
            unreachable;
        }
        // TODO remove as this seems to only be used for Node256
        fn hasChildAt(n: *Node, comptime Tag: @TagType(Node), i: usize) bool {
            // log(.Warning, "hasChildAt {} {} {x}\n", .{ i, n, @ptrToInt(n.Node256.children[i]) });
            const children = @field(n, @tagName(Tag)).children;
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
            return children[i] != emptyNodeRef;
        }
        const Result = union(enum) { Missing, Found: *Node };
        const InsertError = error{OutOfMemory};
        pub fn recursiveInsert(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, _depth: usize) InsertError!Result {
            if (n == &emptyNode) {
                ref.* = try makeLeaf(key, value);
                return .Missing;
            }
            var depth = _depth;
            // If we are at a leaf, we need to replace it with a node
            if (n.* == .Leaf) {
                var l = n.Leaf;
                // Check if we are updating an existing value
                // if (mem.eql(u8, l.key, key)) {
                if (leafMatches(l, key)) {
                    l.value = value;
                    return Result{ .Found = n };
                }
                // New value, we must split the leaf into a node4
                var newNode = try t.allocNode(.Node4);
                // log(.Verbose, "allocNode sizeOf Node {}\n", .{@sizeOf(Node)});
                var l2 = try makeLeaf(key, value);
                const longestPrefix = longestCommonPrefix(l, l2.Leaf, depth);
                // const c1 = if (depth + longestPrefix < l.key.len) l.key[depth + longestPrefix] else 0;
                // const c2 = if (depth + longestPrefix < l2.Leaf.key.len) l2.Leaf.key[depth + longestPrefix] else 0;
                newNode.Node4.n.partialLen = longestPrefix;
                const maxKeyLen = math.min(MaxPartialLen, longestPrefix);
                // if (key.len > depth + maxKeyLen)
                mem.copy(u8, &newNode.Node4.n.partial, key[depth..][0..maxKeyLen]);
                const c1 = l.key[depth + longestPrefix];
                const c2 = l2.Leaf.key[depth + longestPrefix];
                log(.Verbose, "longestPrefix {} depth {} l.key {}-{} '{c}' l2.key {}-{} '{c} ref {*} '\n", .{ longestPrefix, depth, l.key, l.key.len, c1, l2.Leaf.key, l2.Leaf.key.len, c2, ref.* });
                // Add the leaves to the new node4
                // log(.Verbose, "newNode {}\n", .{newNode});
                ref.* = newNode;
                try t.addChild4(newNode, ref, c1, n);
                try t.addChild4(newNode, ref, c2, l2);
                log(.Verbose, "newNode {} ref {*} \n", .{ newNode, ref.* });
                return .Missing;
            }

            const baseNode = n.baseNode();
            // log(.Verbose, "partialLen {}\n", .{baseNode.partialLen});

            if (baseNode.partialLen != 0) {
                const prefixDiff = prefixMismatch(n, key, depth);
                log(.Verbose, "prefixDiff {}\n", .{prefixDiff});
                if (prefixDiff >= baseNode.partialLen) {
                    depth += baseNode.partialLen;
                    return t.recurseInsertSearch(n, ref, key, value, depth);
                }

                var newNode = try t.allocNode(.Node4);
                ref.* = newNode;
                baseNode.partialLen = prefixDiff;
                mem.copy(u8, &newNode.Node4.n.partial, &baseNode.partial);

                if (baseNode.partialLen <= MaxPartialLen) {
                    // try t.addChild4(newNode, ref, if (baseNode.partial.len > prefixDiff) baseNode.partial[prefixDiff] else 0, n);
                    try t.addChild4(newNode, ref, baseNode.partial[prefixDiff], n);
                    if (baseNode.partialLen > prefixDiff)
                        baseNode.partialLen -= (prefixDiff + 1);
                    if (baseNode.partial.len > prefixDiff + 1)
                        mem.copyBackwards(u8, &baseNode.partial, baseNode.partial[prefixDiff + 1 ..]);
                } else {
                    log(.Verbose, "baseNode.partialLen {} prefixDiff {}\n", .{ baseNode.partialLen, prefixDiff });
                    if (baseNode.partialLen > prefixDiff)
                        baseNode.partialLen -= (prefixDiff + 1);
                    const l = minimum(n);
                    try t.addChild4(newNode, ref, l.?.key[depth + prefixDiff], n);
                    mem.copy(u8, &baseNode.partial, l.?.key[depth + prefixDiff + 1 ..]);
                }

                var l = try makeLeaf(key, value);
                const c = key[depth + prefixDiff];
                try t.addChild4(newNode, ref, c, l);
                return Result{ .Missing = {} };
            }
            return t.recurseInsertSearch(n, ref, key, value, depth);
        }
        fn recurseInsertSearch(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, depth: usize) InsertError!Result {
            var child = findChild(n, key[depth]);
            log(.Verbose, "recurseInsertSearch {} {} child {*}\n", .{ key, value, child });
            if (child != &emptyNodeRef) {
                log(.Verbose, "child != null {}\n", .{child});
                return t.recursiveInsert(child.*, child, key, value, depth + 1);
            }

            var l = try makeLeaf(key, value);
            try t.addChild(n, ref, key[depth], l);
            return Result{ .Missing = {} };
        }
        fn copyHeader(dest: *BaseNode, src: *BaseNode) void {
            dest.numChildren = src.numChildren;
            dest.partialLen = src.partialLen;
            mem.copy(u8, &dest.partial, src.partial[0..math.min(MaxPartialLen, src.partialLen)]);
        }
        fn addChild(t: *Tree, n: *Node, ref: **Node, c: u8, child: *Node) InsertError!void {
            switch (n.*) {
                .Node4 => try t.addChild4(n, ref, c, child),
                .Node16 => try t.addChild16(n, ref, c, child),
                .Node48 => try t.addChild48(n, ref, c, child),
                .Node256 => try t.addChild256(n, ref, c, child),
                else => unreachable,
            }
        }
        fn findChild(n: *Node, c: u8) **Node {
            const base = n.baseNode();
            log(.Warning, "findChild {c} {} '{c}'\n", .{ c, @as(@TagType(Node), n.*), c });
            switch (n.*) {
                .Node4 => {
                    log(.Warning, "keys {}\n", .{n.Node4.keys});
                    var i: usize = 0;
                    while (i < base.numChildren) : (i += 1) {
                        if (n.Node4.keys[i] == c)
                            return &n.Node4.children[i];
                    }
                },
                .Node16 => {
                    // TODO: simd
                    var bitfield: u17 = 0;
                    for (n.Node16.keys) |k, i| {
                        if (k == c)
                            bitfield |= (@as(u17, 1) << @truncate(u5, i));
                    }
                    const mask = (@as(u17, 1) << @truncate(u5, base.numChildren)) - 1;
                    bitfield &= mask;
                    log(.Warning, "Node16 bitfield 0x{x} keys {} base.numChildren {}\n", .{ bitfield, n.Node16.keys, base.numChildren });
                    if (bitfield != 0)
                        log(.Warning, "Node16 child {}\n", .{n.Node16.children[@ctz(usize, bitfield)]});

                    // end TODO
                    if (bitfield != 0) return &n.Node16.children[@ctz(usize, bitfield)];
                },
                .Node48 => {
                    log(.Warning, "Node48 '{c}'\n", .{n.Node48.keys[c]});
                    if (n.Node48.keys[c] > 0)
                        log(.Warning, "Node48 '{}'\n", .{n.Node48.children[n.Node48.keys[c] - 1]});
                    if (n.Node48.keys[c] != 0) return &n.Node48.children[n.Node48.keys[c] - 1];
                },
                .Node256 => {
                    log(.Warning, "Node256 {*}\n", .{n.Node256.children[c]});
                    if (hasChildAt(n, .Node256, c)) return &n.Node256.children[c];
                },
                else => unreachable,
            }
            return &emptyNodeRef;
        }
        // const cstd = @cImport({
        //     @cInclude("string.h");
        // });

        fn addChild4(t: *Tree, n: *Node, ref: **Node, c: u8, child: *Node) InsertError!void {
            log(.Verbose, "addChild4 {c} numChildren {}\n", .{ c, n.Node4.n.numChildren });
            if (n.Node4.n.numChildren < 4) {
                var idx: usize = 0;
                while (idx < n.Node4.n.numChildren) : (idx += 1) {
                    if (c < n.Node4.keys[idx]) break;
                }

                const shiftLen = n.Node4.n.numChildren - idx;
                log(.Verbose, "idx {} keys {} shiftLen {}\n", .{ idx, n.Node4.keys, shiftLen });
                // log(.Verbose, "n {}\n", .{n});
                // log(.Verbose, "child {}\n", .{child});
                // shift forward to make room
                mem.copyBackwards(u8, n.Node4.keys[idx + 1 ..], n.Node4.keys[idx..][0..shiftLen]);
                mem.copyBackwards(*Node, n.Node4.children[idx + 1 ..], n.Node4.children[idx..][0..shiftLen]);
                // _ = cstd.memmove(&n.Node4.keys + idx + 1, &n.Node4.keys + idx, shiftLen);
                // _ = cstd.memmove(&n.Node4.children + idx + 1, &n.Node4.children + idx, shiftLen * @sizeOf(*Node));
                n.Node4.keys[idx] = c;
                n.Node4.children[idx] = child;
                n.Node4.n.numChildren += 1;
                log(.Verbose, "n.Node4.keys {}\n", .{n.Node4.keys});
            } else {
                var newNode = try t.allocNode(.Node16);
                mem.copy(*Node, &newNode.Node16.children, &n.Node4.children);
                mem.copy(u8, &newNode.Node16.keys, &n.Node4.keys);
                copyHeader(newNode.baseNode(), n.baseNode());
                log(.Verbose, "newNode.Node16.keys {}\n", .{newNode.Node16.keys});
                ref.* = newNode;
                t.allr.destroy(n);
                try t.addChild16(newNode, ref, c, child);
            }
        }
        fn addChild16(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) InsertError!void {
            log(.Verbose, "addChild16 n {}\n", .{n});
            if (n.Node16.n.numChildren < 16) {
                // TODO: implement with simd
                const mask = (@as(u17, 1) << @truncate(u5, n.Node16.n.numChildren)) - 1;
                var bitfield: u17 = 0;
                var i: u8 = 0;
                while (i < 16) : (i += 1) {
                    if (c < n.Node16.keys[i])
                        bitfield |= (@as(u17, 1) << @truncate(u5, i));
                }
                bitfield &= mask;
                // end TODO
                log(.Verbose, "bitfield 16 0x{x} n.Node16.keys {}\n", .{ bitfield, n.Node16.keys });
                var idx: usize = 0;
                if (bitfield != 0) {
                    idx = @ctz(usize, bitfield);
                    const shiftLen = n.Node16.n.numChildren - idx;
                    mem.copyBackwards(u8, n.Node16.keys[idx + 1 ..], n.Node16.keys[idx..][0..shiftLen]);
                    mem.copyBackwards(*Node, n.Node16.children[idx + 1 ..], n.Node16.children[idx..][0..shiftLen]);
                } else idx = n.Node16.n.numChildren;
                log(.Verbose, "n.Node16.keys {}\n", .{n.Node16.keys});

                n.Node16.keys[idx] = c;
                n.Node16.children[idx] = child;
                n.Node16.n.numChildren += 1;
            } else {
                var newNode = try t.allocNode(.Node48);
                mem.copy(*Node, &newNode.Node48.children, &n.Node16.children);
                // mem.copy(u8, &newNode.Node48.keys, &n.Node4.keys);
                const baseNode = n.baseNode();
                var i: u8 = 0;
                while (i < baseNode.numChildren) : (i += 1) {
                    newNode.Node48.keys[n.Node16.keys[i]] = i + 1;
                    log(.Verbose, "i {} n.Node16.keys[i] {} newNode.Node48.keys[n.Node16.keys[i]] {}\n", .{ i, n.Node16.keys[i], newNode.Node48.keys[n.Node16.keys[i]] });
                }
                copyHeader(newNode.baseNode(), baseNode);
                log(.Verbose, "newNode.Node48.keys: ", .{});
                for (newNode.Node48.keys) |k|
                    log(.Verbose, "{},", .{k});
                log(.Verbose, "\n", .{});
                ref.* = newNode;
                t.allr.destroy(n);
                try t.addChild48(newNode, ref, c, child);
            }
        }
        fn addChild48(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) InsertError!void {
            if (n.Node48.n.numChildren < 48) {
                var pos: u8 = 0;
                while (hasChildAt(n, .Node48, pos)) : (pos += 1) {}

                // const shiftLen = n.Node48.n.numChildren - pos;
                log(.Verbose, "pos {} keys {} \n", .{ pos, n.Node48.keys });
                // log(.Verbose, "n {}\n", .{n});
                // log(.Verbose, "child {}\n", .{child});
                // shift forward to make room
                // mem.copyBackwards(u8, n.Node48.keys[pos + 1 ..], n.Node48.keys[pos..][0..shiftLen]);
                // mem.copyBackwards(*Node, n.Node48.children[pos + 1 ..], n.Node48.children[pos..][0..shiftLen]);
                n.Node48.children[pos] = child;
                n.Node48.keys[c] = pos + 1;
                n.Node48.n.numChildren += 1;
            } else {
                var newNode = try t.allocNode(.Node256);
                var i: usize = 0;
                const oldChildren = n.Node48.children;
                const oldKeys = n.Node48.keys;
                var newChildren = newNode.Node256.children;
                log(.Verbose, "oldkeys {}\n", .{oldKeys});
                while (i < 256) : (i += 1) {
                    if (oldKeys[i] != 0) {
                        log(.Verbose, "oldKeys[{}] {}\n", .{ i, oldKeys[i] });
                        newChildren[i] = oldChildren[oldKeys[i] - 1];
                    }
                }
                copyHeader(newNode.baseNode(), n.baseNode());
                ref.* = newNode;
                t.allr.destroy(n);
                try t.addChild256(newNode, ref, c, child);
            }
        }
        fn addChild256(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) InsertError!void {
            n.Node256.n.numChildren += 1;
            n.Node256.children[c] = child;
        }
        pub fn delete(t: *Tree, key: []const u8) Result {}
        pub fn logNode(level: LogLevel, n: *Node) void {
            var buf: [256]u8 = undefined;
            log(level, "keys {}\n", .{n.keys(&buf) catch unreachable});
        }
        pub fn search(t: *Tree, key: []const u8) Result {
            var _n: ?*Node = t.root;
            var prefixLen: usize = 0;
            var depth: usize = 0;
            while (_n != null) {
                const n = _n.?;
                log(.Warning, "searching {*} '{}'\n", .{ n, key });
                if (n.* == .Leaf) {
                    if (leafMatches(n.Leaf, key))
                        return .{ .Found = n };
                    return .Missing;
                }

                const baseNode = n.baseNode();
                log(.Warning, "baseNode.partialLen {} \n", .{baseNode.partialLen});
                log(.Warning, "n {}\n", .{n});
                logNode(.Warning, n);
                if (baseNode.partialLen != 0) {
                    prefixLen = checkPrefix(baseNode, key, depth);
                    log(.Warning, "prefixLen {}\n", .{prefixLen});
                    if (prefixLen != math.min(MaxPartialLen, baseNode.partialLen))
                        return .Missing;
                    depth += baseNode.partialLen;
                }
                const c2 = key[depth];
                const child = findChild(n, c2);
                log(.Warning, "child {} depth {} key {}\n", .{ child, depth, key });
                _n = if (child) |c| c.* else null;
                depth += 1;
            }
            return .Missing;
        }
        inline fn leafMatches(n: Leaf, key: []const u8) bool {
            return mem.eql(u8, n.key, key);
        }

        fn checkPrefix(n: *BaseNode, key: []const u8, depth: usize) usize {
            const max_cmp = math.min(math.min(n.partialLen, MaxPartialLen), key.len - depth);
            var idx: usize = 0;
            while (idx < max_cmp) : (idx += 1) {
                if (n.partial[idx] != key[depth + idx])
                    return idx;
            }
            return idx;
        }
        pub const Callback = fn (t: *Tree, n: *Node, data: *c_void, depth: usize) bool;
        pub fn iter(t: *Tree, comptime cb: Callback, data: var) bool {
            return t.recursiveIter(t.root, data, 0, cb);
        }
        /// return true to stop iteration
        pub fn recursiveIter(t: *Tree, n: *Node, data: *c_void, depth: usize, comptime cb: Callback) bool {
            // if (n.* == .Empty) return false;
            switch (n.*) {
                // .Empty => return false,
                .Empty, .Leaf => return cb(t, n, data, depth),
                .Node4 => {
                    if (cb(t, n, data, depth)) return true;
                    var i: usize = 0;
                    // log(.Verbose, "{*}\n", .{n});
                    // log(.Verbose, "{}\n", .{n});
                    while (i < n.Node4.n.numChildren) : (i += 1) {
                        if (t.recursiveIter(n.Node4.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
                .Node16 => {
                    if (cb(t, n, data, depth)) return true;
                    var i: usize = 0;
                    while (i < n.Node16.n.numChildren) : (i += 1) {
                        if (t.recursiveIter(n.Node16.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
                .Node48 => {
                    if (cb(t, n, data, depth)) return true;
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        const idx = n.Node48.keys[i];
                        if (idx == 0) continue;
                        if (t.recursiveIter(n.Node48.children[idx - 1], data, depth + 1, cb))
                            return true;
                    }
                },
                .Node256 => {
                    if (cb(t, n, data, depth)) return true;
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        if (!hasChildAt(n, .Node256, i)) continue;
                        if (t.recursiveIter(n.Node256.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
            }
            return false;
        }
        pub fn iterPrefix(t: *Tree, prefix: []const u8, comptime cb: Callback, data: var) Result {}
        const max_spaces = 256;
        const spaces = [1]u8{' '} ** max_spaces;
        pub fn print(t: *Tree) !void {
            const s = std.io.getStdErr().outStream();
            _ = try s.write("\n");
            try t.recursiveShow(s, 0, 0, t.root);
        }
        const ShowError = error{ DiskQuota, FileTooBig, InputOutput, NoSpaceLeft, AccessDenied, BrokenPipe, SystemResources, OperationAborted, WouldBlock, Unexpected };
        fn recursiveShow(t: *Tree, stream: var, level: usize, lpad: usize, n: *Node) ShowError!void {
            switch (n.*) {
                .Empty => _ = try stream.print("Empty\n", .{}),
                .Leaf => _ = try stream.print("{} ", .{n.Leaf.key}),
                .Node4, .Node16 => {
                    const base = n.baseNode();
                    for (n.children()[0..base.numChildren]) |child| {
                        try t.recursiveShow(stream, level + 1, lpad, child);
                    }
                    // _ = try stream.print("{}\n", .{n});
                },
                .Node48 => {
                    const children = n.children();
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        const idx = n.Node48.keys[i];
                        if (idx == 0)
                            continue;
                        try t.recursiveShow(stream, level + 1, lpad, children[idx - 1]);
                    }
                    // _ = try stream.print("{}\n", .{n});
                },
                .Node256 => {
                    const children = n.children();
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        if (hasChildAt(n, .Node256, i))
                            try t.recursiveShow(stream, level + 1, lpad, children[i]);
                    }
                    // _ = try stream.print("{}\n", .{n});
                },
            }
        }
        // fn recursiveShow2(t: *Tree, stream: var, level: usize, _lpad: usize, n: *Node) ShowError!void {
        //     // log(.Verbose, "show n {*}\n", .{n});
        //     var lpad = _lpad;
        //     const isLeaf = n.* == .Leaf;

        //     const se: []u8 = &(if (isLeaf) [_]u8{ '"', '"' } else [_]u8{ '[', ']' });
        //     var numchars: usize = 2;
        //     switch (n.*) {
        //         .Leaf => _ = try stream.print("{c}{}{c}", .{ se[0], n.Leaf.key, se[1] }),
        //         else => {
        //             const base = n.baseNode();
        //             // TODO: this won't work for larger capacity nodes
        //             _ = try stream.print("{c}", .{se[0]});
        //             for (n.children()) |child, i| {
        //                 _ = try stream.print("{c}", .{n.keys()[i]});
        //             }
        //             _ = try stream.print("{c}", .{se[1]});
        //             numchars += n.children().len;
        //             // for (n.children()) |child, i| {
        //             //     if (i >= base.numChildren) break;
        //             //     try t.recursiveShow(stream, level + 1, lpad, child);
        //             // }
        //         },
        //     }

        //     if (isLeaf) {
        //         _ = try stream.print("={}", .{n.Leaf.value});
        //         numchars += 4;
        //     }

        //     if (level > 0) {
        //         lpad += switch (n.*) {
        //             .Leaf => 4,
        //             else => |*nn| switch (nn.baseNode().numChildren) {
        //                 0 => 4,
        //                 1 => 4 + numchars,
        //                 else => 7,
        //             },
        //         };
        //     }

        //     switch (n.*) {
        //         .Leaf => |l| {
        //             _ = try stream.print(" -> ", .{});
        //             // t.recursiveShow(level + 1, lpad, compressed.next);
        //         },
        //         else => |*nn| {
        //             const baseNode = n.baseNode();
        //             _ = try stream.write(baseNode.partial[0..baseNode.partialLen]);
        //             for (nn.children()) |child, idx| {
        //                 if (idx >= baseNode.numChildren) break;
        //                 if (baseNode.numChildren > 1) {
        //                     _ = try stream.print("\n", .{});
        //                     var i: usize = 0;
        //                     while (i < lpad) : (i += 1) _ = try stream.print(" ", .{});
        //                     _ = try stream.print(" `-({c}) ", .{nn.keys()[idx]});
        //                 } else {
        //                     _ = try stream.print(" -> ", .{});
        //                 }
        //                 try t.recursiveShow(stream, level + 1, lpad, child);
        //             }
        //         },
        //     }
        // }
    };
}

const testing = std.testing;
const UseTestAllr = false;
const a = if (UseTestAllr) testing.allocator else std.heap.c_allocator; //std.heap.page_allocator;
const UTree = ArtTree(usize);
fn debugCb(t: *UTree, n: *UTree.Node, data: *c_void, depth: usize) bool {
    const nodeType = switch (n.*) {
        .Node4 => "4   ",
        .Node16 => "16  ",
        .Node48 => "48  ",
        .Node256 => "256 ",
        else => "LEAF",
    };
    const key = if (n.* == .Leaf) n.Leaf.key else "(null)";
    const partial = if (n.* != .Leaf) &n.baseNode().partial else "(null)";
    // std.debug.warn("Node {}: {}-{} {} {}\n", .{ nodeType, key, key.len, depth, partial });
    // std.debug.warn("n {}\n", .{n});
    return false;
}

test "basic" {
    // pub fn main() !void {
    var t = ArtTree(usize).init(a);
    defer t.deinit();
    const words = [_][]const u8{
        "car",
        "truck",
        "bike",
        "trucker",
        "cars",
        "bikes",
    };
    for (words) |w, i| {
        testing.expectEqual(try t.insert(w, i), .Missing);
        testing.expectEqual(t.size, i + 1);
        // log(.Verbose, "\n", .{});
    }
    var data: usize = 0;
    _ = t.iter(debugCb, @as(*c_void, &data));
    log(.Verbose, "\n", .{});
    try t.print();
}

test "49 words" {
    var t = ArtTree(usize).init(a);
    defer t.deinit();
    const words = [_][]const u8{ "A", "A's", "AMD", "AMD's", "AOL", "AOL's", "AWS", "AWS's", "Aachen", "Aachen's", "Aaliyah", "Aaliyah's", "Aaron", "Aaron's", "Abbas", "Abbas's", "Abbasid", "Abbasid's", "Abbott", "Abbott's", "Abby", "Abby's", "Abdul", "Abdul's", "Abe", "Abe's", "Abel", "Abel's", "Abelard", "Abelard's", "Abelson", "Abelson's", "Aberdeen", "Aberdeen's", "Abernathy", "Abernathy's", "Abidjan", "Abidjan's", "Abigail", "Abigail's", "Abilene", "Abilene's", "Abner", "Abner's", "Abraham", "Abraham's", "Abram", "Abram's" };
    for (words) |w, i| {
        _ = try t.insert(w, i);
        // testing.expectEqual(t.size, i + 1);
    }
    var data: usize = 0;
    _ = t.iter(debugCb, @as(*c_void, &data));
    // try t.print();
    // logLevel = .Warning;
    log(.Verbose, "size {}\n", .{t.size});
    testing.expect(t.search("A") == .Found);
    // log(.Verbose, "search result {}\n", .{result});
}
test "insert many keys" {
    var t = ArtTree(usize).init(a);
    defer t.deinit();
    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [256]u8 = undefined;
    logLevel = .Warning;
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
    // try t.print();
    std.debug.warn("root keys {}\n", .{t.root.keys(&buf)});
}

test "insert very long key" {
    var t = ArtTree(void).init(a);
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

    testing.expectEqual(try t.insert(&key1, {}), .Missing);
    testing.expectEqual(try t.insert(&key2, {}), .Missing);
    _ = try t.insert(&key2, {});
    testing.expectEqual(t.size, 2);
}

test "insert search" {
    var t = ArtTree(usize).init(a);
    defer t.deinit();

    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;
        const result = try t.insert(line, lines);
        lines += 1;
        if (lines == 235886) {
            std.debug.warn("", .{});
        }
    }
    std.debug.warn("lines {}\n", .{lines});

    // Seek back to the start
    //   fseek(f, 0, SEEK_SET);
    _ = try f.seekTo(0);

    // logLevel = .Warning;

    // Search for each line
    lines = 1;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        buf[line.len] = 0;
        const result = t.search(line);
        if (result != .Found) {
            const tmp = logLevel;
            logLevel = .Warning;
            log(.Warning, "{} {}\n", .{ line, t.search(line) });
            logLevel = tmp;
        }
        testing.expect(result == .Found);
        testing.expect(result.Found.* == .Leaf);
        testing.expectEqual(result.Found.Leaf.value, lines);
        lines += 1;
        break;
    }

    // Check the minimum
    var l = t.min();
    testing.expectEqual(l.?.key[0], 'A');

    // Check the maximum
    l = t.maximum();
    testing.expectEqualSlices(l.?.key[0], "zythum");
}

test "node keys correctness" {
    var t = ArtTree(usize).init(a);
    defer t.deinit();
    logLevel = .Info;
    _ = try t.insert("A\x00", 1);
    _ = try t.insert("a\x00", 2);
    testing.expect(t.root.* == .Node4);
    std.debug.warn("keys {}\n", .{t.root.Node4.keys});
    testing.expectEqual(t.root.Node4.keys[0], 'A');
    testing.expectEqual(t.root.Node4.keys[1], 'a');
    testing.expectEqual(t.root.Node4.keys[2], '\x00');
    testing.expectEqual(t.root.Node4.keys[3], '\x00');
}

pub fn main() !void {
    var t = ArtTree(usize).init(a);
    defer t.deinit();
    const f = try std.fs.cwd().openFile("./testdata/words.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    // logLevel = .None;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const result = try t.insert(line, lines);
        // log(.Verbose, "line {} result {}\n", .{ line, result });
        // try t.print();
        // log(.Verbose, "\n", .{});
        lines += 1;
    }
    try t.print();
}
