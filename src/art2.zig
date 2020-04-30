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

        const MaxPartialLen = 10;
        const BaseNode = struct {
            numChildren: u8,
            partialLen: usize,
            partial: [MaxPartialLen]u8 = [1]u8{0} ** MaxPartialLen,
        };

        pub fn NodeSized(comptime keysLen: usize, comptime childrenLen: usize) type {
            return struct {
                n: BaseNode,
                keys: [keysLen]u8 = [1]u8{0} ** keysLen,
                children: [childrenLen]*Node,
                const Self = @This();
                // pub const KeysLen = keysLen;
                // pub const ChildrenLen = childrenLen;
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
            pub fn node(self: *Node) Node {
                return switch (self.*) {
                    .Node4 => &self.Node4,
                    .Node16 => &self.Node16,
                    .Node48 => &self.Node48,
                    .Node256 => &self.Node256,
                    .Leaf => unreachable,
                };
            }
            pub fn baseNode(self: *Node) *BaseNode {
                return switch (self.*) {
                    .Node4 => &self.Node4.n,
                    .Node16 => &self.Node16.n,
                    .Node48 => &self.Node48.n,
                    .Node256 => &self.Node256.n,
                    .Leaf => unreachable,
                };
            }
            pub fn keys(self: *Node) []u8 {
                return switch (self.*) {
                    .Node4 => &self.Node4.keys,
                    .Node16 => &self.Node16.keys,
                    .Node48 => &self.Node48.keys,
                    .Node256 => &self.Node256.keys,
                    .Leaf => unreachable,
                };
            }
            pub fn children(self: *Node) []*Node {
                return switch (self.*) {
                    .Node4 => &self.Node4.children,
                    .Node16 => &self.Node16.children,
                    .Node48 => &self.Node48.children,
                    .Node256 => &self.Node256.children,
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
        fn leafMatches() void {}
        pub fn insert(t: *Tree, key: []const u8, value: T) !Result {
            const res = try t.recursiveInsert(t.root, &t.root, key, value, 0);
            if (res == .New) t.size += 1;
            return res;
        }
        fn longestCommonPrefix(l: Leaf, l2: Leaf, depth: usize) usize {
            const max_cmp = std.math.min(l.key.len, l2.key.len) - depth;
            var common: usize = 0;
            while (common < max_cmp) : (common += 1) if (l.key[depth + common] != l2.key[depth + common])
                return common;
            return common;
        }
        fn prefixMismatch(n: *Node, key: []const u8, depth: usize) usize {
            const base = n.baseNode();
            var max_cmp = std.math.min(std.math.min(MaxPartialLen, base.partialLen), key.len - depth);
            var idx: usize = 0;
            while (idx < max_cmp) : (idx += 1) if (base.partial[idx] != key[depth + idx])
                return idx;
            if (base.partialLen > MaxPartialLen) {
                const l = minimum(n);
                max_cmp = std.math.min(l.?.key.len, key.len) - depth;
                while (idx < max_cmp) : (idx += 1) if (l.?.key[idx + depth] != key[depth + idx])
                    return idx;
            }
            return idx;
        }
        fn allocNode(t: *Tree, comptime tag: @TagType(Node)) !*Node {
            var node = try t.allr.alloc(Node, 1);
            const tagName = @tagName(tag);
            node[0] = @unionInit(Node, tagName, .{ .n = .{ .numChildren = 0, .partialLen = 0 }, .children = undefined });
            var tagField = @field(node[0], tagName);
            std.mem.secureZero(*Node, &tagField.children);
            return @ptrCast(*Node, node.ptr);
        }
        // Find the minimum Leaf under a node
        fn minimum(_n: ?*Node) ?*Leaf {
            var n = _n orelse return null;

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
            // log("n {}\n", .{_n});
            var n = _n orelse {
                ref.* = try makeLeaf(key, value);
                return .New;
            };
            var depth = _depth;
            if (n.* == .Leaf) {
                var l = n.Leaf;
                if (std.mem.startsWith(u8, l.key, key)) {
                    l.value = value;
                    return Result{ .Old = n };
                }

                var newNode = try t.allocNode(.Node4);
                // log("allocNode sizeOf Node {}\n", .{@sizeOf(Node)});
                var l2 = try makeLeaf(key, value);
                const longestPrefix = longestCommonPrefix(l, l2.Leaf, depth);
                const c1 = if (depth + longestPrefix < l.key.len) l.key[depth + longestPrefix] else 0;
                const c2 = if (depth + longestPrefix < l2.Leaf.key.len) l2.Leaf.key[depth + longestPrefix] else 0;
                // log("longestPrefix {} depth {} l.key {}-{} '{c}' l2.key {}-{} '{c}'\n", .{ longestPrefix, depth, l.key, l.key.len, c1, l2.Leaf.key, l2.Leaf.key.len, c2 });
                newNode.Node4.n.partialLen = longestPrefix;
                std.mem.copy(u8, &newNode.Node4.n.partial, key[depth..][0..std.math.min(MaxPartialLen, longestPrefix)]);
                ref.* = newNode;
                // log("newNode {}\n", .{newNode});
                // try t.addChild4(newNode, ref, if (depth + longestPrefix < l.key.len) l.key[depth + longestPrefix] else 0, n);
                // try t.addChild4(newNode, ref, if (depth + longestPrefix < l2.Leaf.key.len) l2.Leaf.key[depth + longestPrefix] else 0, l2);
                try t.addChild4(newNode, ref, c1, n);
                try t.addChild4(newNode, ref, c2, l2);
                return .New;
            }

            const base = n.baseNode();

            if (base.partialLen != 0) {
                const prefix_diff = prefixMismatch(n, key, depth);
                if (prefix_diff >= base.partialLen) {
                    depth += base.partialLen;
                    return t.recurseSearch(n, ref, key, value, depth);
                }

                // var newNode = try t.allr.create(Node);
                var newNode = try t.allocNode(.Node4);
                ref.* = newNode;
                base.partialLen = prefix_diff;
                std.mem.copy(u8, &newNode.Node4.n.partial, &base.partial);

                if (base.partialLen <= MaxPartialLen) {
                    try t.addChild4(newNode, ref, base.partial[prefix_diff], n);
                    base.partialLen -= (prefix_diff + 1);
                    std.mem.copyBackwards(u8, &base.partial, base.partial[prefix_diff + 1 ..]);
                } else {
                    base.partialLen -= (prefix_diff + 1);
                    const l = minimum(n);
                    try t.addChild4(newNode, ref, l.?.key[depth + prefix_diff], n);
                    std.mem.copy(u8, &base.partial, l.?.key[depth + prefix_diff + 1 ..]);
                }

                var l = try makeLeaf(key, value);
                try t.addChild4(newNode, ref, key[depth + prefix_diff], l);
                return Result{ .New = {} };
            }
            // log("unreachable {} {} {}\n", .{ key, value, n });
            // unreachable;
            return t.recurseSearch(n, ref, key, value, depth);
        }
        fn recurseSearch(t: *Tree, n: *Node, ref: *?*Node, key: []const u8, value: T, depth: usize) InsertError!Result {
            const child = findChild(n, key[depth]);
            if (child.* != null) return t.recursiveInsert(child.*, child, key, value, depth + 1);

            var l = try makeLeaf(key, value);
            try t.addChild(n, ref, key[depth], l);
            return Result{ .New = {} };
        }
        fn copyHeader(dest: *Node, src: *Node) void {
            dest.baseNode().numChildren = src.baseNode().numChildren;
            dest.baseNode().partialLen = src.baseNode().partialLen;
            std.mem.copy(u8, &dest.baseNode().partial, &src.baseNode().partial);
        }
        // TODO: remove this helper for casting away constness
        // fn castPtr(comptime P: type, p: var) P {
        //     return @intToPtr(P, @ptrToInt(p));
        // }
        fn addChild(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: *Node) InsertError!void {
            return switch (n.*) {
                .Node4 => try t.addChild4(n, ref, c, child),
                .Node16 => try t.addChild16(n, ref, c, child),
                .Node48 => try t.addChild48(n, ref, c, child),
                .Node256 => try t.addChild256(n, ref, c, child),
                else => unreachable,
            };
        }
        fn findChild(n: *Node, c: u8) *?*Node {
            const base = n.baseNode();
            switch (n.*) {
                .Node4 => {
                    var i: usize = 0;
                    while (i < base.numChildren) : (i += 1) if (n.Node4.keys[i] == c)
                        return &@as(?*Node, n.Node4.children[i]);
                },
                .Node16 => {
                    // TODO: simd
                    var bitfield: usize = 0;
                    for (n.Node16.keys) |k, i| {
                        if (k == c)
                            bitfield |= (@as(usize, 1) << @truncate(u6, i));
                    }
                    const mask = (@as(usize, 1) << @truncate(u6, base.numChildren)) - 1;
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
                // log("idx {} {}\n", .{ idx, n.Node4.keys });
                // log("n {}\n", .{n});
                // log("child {}\n", .{child});
                std.mem.copyBackwards(u8, n.Node4.keys[idx + 1 ..], n.Node4.keys[idx .. n.Node4.keys.len - 2]);
                std.mem.copyBackwards(*Node, n.Node4.children[idx + 1 ..], n.Node4.children[idx .. n.Node4.children.len - 2]);
                n.Node4.keys[idx] = c;
                n.Node4.children[idx] = child;
                n.Node4.n.numChildren += 1;
            } else {
                const newNode = try t.allr.create(Node);
                newNode.* = .{ .Node16 = undefined };
                std.mem.copy(*Node, &newNode.Node16.children, &n.Node4.children);
                std.mem.copy(u8, &newNode.Node16.keys, &n.Node4.keys);
                copyHeader(newNode, n);
                ref.* = newNode;
                t.allr.destroy(n);
                try t.addChild16(newNode, ref, c, child);
            }
        }
        fn addChild16(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: var) InsertError!void {
            // log("n {}\n", .{n});
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
                    std.mem.copyBackwards(u8, n.Node16.keys[idx + 1 ..], n.Node16.keys[idx..]);
                    std.mem.copyBackwards(*Node, n.Node16.children[idx + 1 ..], n.Node16.children[idx..]);
                } else idx = n.Node16.n.numChildren;

                n.Node16.keys[idx] = c;
                n.Node16.children[idx] = child;
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
        pub fn search(t: *Tree, key: []const u8) Result {}
        pub const Callback = fn (data: *c_void, key: []const u8, value: ?T, depth: usize) bool;
        pub fn iter(t: *Tree, comptime cb: Callback, nodecb: Callback, data: var) bool {
            return recursiveIter(t.root, cb, nodecb, data, 0);
        }
        pub fn recursiveIter(_n: ?*Node, comptime cb: Callback, nodecb: Callback, data: *c_void, depth: usize) bool {
            const n = _n orelse return false;
            if (n.* == .Leaf) return cb(data, n.Leaf.key, n.Leaf.value.?, depth);
            switch (n.*) {
                .Node4 => {
                    var i: usize = 0;
                    while (i < n.Node4.n.numChildren) : (i += 1) {
                        if (nodecb(n, &n.Node4.keys, null, depth) or
                            recursiveIter(n.Node4.children[i], cb, nodecb, data, depth + 1))
                            return true;
                    }
                },
                .Node16 => {
                    var i: usize = 0;
                    while (i < n.Node16.n.numChildren) : (i += 1) {
                        if (nodecb(n, &n.Node16.keys, null, depth) or
                            recursiveIter(n.Node16.children[i], cb, nodecb, data, depth + 1))
                            return true;
                    }
                },
                .Node48 => {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        const idx = n.Node48.keys[i];
                        if (idx == 0) continue;
                        if (nodecb(n, &n.Node48.keys, null, depth) or
                            recursiveIter(n.Node48.children[idx - 1], cb, nodecb, data, depth + 1))
                            return true;
                    }
                },
                .Node256 => {
                    var i: usize = 0;
                    while (i < 256) : (i += 1) {
                        // @panic("unimplemented");
                        if (!hasChildAt(n, i)) continue;
                        if (nodecb(n, &n.Node256.keys, null, depth) or
                            recursiveIter(n.Node256.children[i], cb, nodecb, data, depth + 1))
                            return true;
                    }
                    return false;
                },
                else => unreachable,
            }
            return false;
        }
        pub fn iterPrefix(t: *Tree, prefix: []const u8, comptime cb: Callback, data: var) Result {}
        const max_spaces = 256;
        const spaces = [1]u8{' '} ** max_spaces;
        pub fn print(t: *Tree) !void {
            // const leafcb = struct {
            //     fn _(data: *c_void, key: []const u8, value: ?T, depth: usize) bool {
            //         const stderr = std.io.getStdOut().outStream();
            //         // const depth = @ptrCast(*align(1) usize, data);
            //         _ = stderr.print("\"{}\"", .{key}) catch unreachable;
            //         // depth.* += 2;

            //         return false;
            //     }
            // }._;
            // const nodecb = struct {
            //     fn _(data: *c_void, key: []const u8, value: ?T, depth: usize) bool {
            //         const stderr = std.io.getStdOut().outStream();
            //         // const depth = @ptrCast(*align(1) usize, data);
            //         _ = stderr.print("{}[{}]\n", .{ spaces[0..depth], key }) catch unreachable;
            //         const n = @ptrCast(*Node, @alignCast(@alignOf(*Node), data));
            //         for (n.keys()) |k, i| {
            //             _ = stderr.print("{}`-({c})", .{ spaces[0 .. depth + 2], k }) catch unreachable;
            //         }

            //         // depth.* += 2;

            //         return false;
            //     }
            // }._;
            // var data: usize = 0;
            // _ = t.iter(leafcb, nodecb, &data);
            // std.debug.warn("print {}\n", .{t.root});
            const s = std.io.getStdErr().outStream();
            _ = try s.write("\n");
            try t.recursiveShow(s, 0, 0, t.root orelse return);
        }
        const ShowError = error{ DiskQuota, FileTooBig, InputOutput, NoSpaceLeft, AccessDenied, BrokenPipe, SystemResources, OperationAborted, WouldBlock, Unexpected };
        fn recursiveShow(t: *Tree, stream: var, level: usize, _lpad: usize, n: *Node) ShowError!void {
            // log("show n {*}\n", .{n});
            var lpad = _lpad;
            const isLeaf = n.* == .Leaf;

            const se: []u8 = &(if (isLeaf) [_]u8{ '"', '"' } else [_]u8{ '[', ']' });
            var numchars: usize = 2;
            switch (n.*) {
                .Leaf => _ = try stream.print("{c}{}{c}", .{ se[0], n.Leaf.key, se[1] }),
                else => {
                    const base = n.baseNode();
                    // TODO: this won't work for larger capacity nodes
                    _ = try stream.print("{c}", .{se[0]});
                    for (n.children()) |_, i| {
                        _ = try stream.print("{c}", .{n.keys()[i]});
                    }
                    _ = try stream.print("{c}", .{se[1]});
                    numchars += n.children().len;
                },
            }

            if (isLeaf) {
                _ = try stream.print("={}", .{n.Leaf.value});
                numchars += 4;
            }

            if (level > 0) {
                lpad += switch (n.*) {
                    .Leaf => 4,
                    else => |*nn| switch (nn.baseNode().numChildren) {
                        0 => 4,
                        1 => 4 + numchars,
                        else => 7,
                    },
                };
            }

            switch (n.*) {
                .Leaf => |l| {
                    _ = try stream.print(" -> ", .{});
                    // t.recursiveShow(level + 1, lpad, compressed.next);
                },
                else => |*nn| {
                    const baseNode = nn.baseNode();
                    for (nn.children()) |child, idx| {
                        if (idx >= baseNode.numChildren) break;
                        if (baseNode.numChildren > 1) {
                            _ = try stream.print("\n", .{});
                            var i: usize = 0;
                            while (i < lpad) : (i += 1) _ = try stream.print(" ", .{});
                            _ = try stream.print(" `-({c}) ", .{nn.keys()[idx]});
                        } else {
                            _ = try stream.print(" -> ", .{});
                        }
                        try t.recursiveShow(stream, level + 1, lpad, child);
                    }
                },
            }
        }
    };
}

const testing = std.testing;
const UseTestAllr = true;
const a = if (UseTestAllr) testing.allocator else std.heap.allocator;

test "basic" {
    var t = try ArtTree(usize).init(a);
    const words = [_][]const u8{
        "car",
        "truck",
        "bike",
        "trucker",
        "cars",
        "bikes",
    };
    for (words) |w, i| {
        _ = try t.insert(w, i);
        try t.print();
    }
}

test "test_art_insert" {
    var t = try ArtTree(usize).init(a);
    const f = try std.fs.cwd().openFile("./testdata/words1.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const result = try t.insert(line, lines);
        // log("line {} result {}\n", .{ line, result });
        try t.print();
        log("\n", .{});
        lines += 1;
    }

    t.deinit();
}
