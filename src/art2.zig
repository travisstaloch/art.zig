const std = @import("std");

const ShowDebugLog = true;
fn log(comptime fmt: []const u8, vals: var) void {
    if (ShowDebugLog) std.debug.warn(fmt, vals);
}

pub fn ArtTree(comptime T: type) type {
    return struct {
        root: *Node,
        size: usize,
        allr: *std.mem.Allocator,

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
                children: [childrenLen]*Node,
                // const Self = @This();
                // pub fn init() Self {}
            };
        }

        pub const Node4 = SizedNode(4, 4);
        pub const Node16 = SizedNode(16, 16);
        pub const Node48 = SizedNode(256, 48);
        pub const Node256 = SizedNode(0, 256);

        const Node = union(enum) {
            Empty,
            Leaf: Leaf,
            Node4: Node4,
            Node16: Node16,
            Node48: Node48,
            Node256: Node256,
            // pub fn node(self: *Node) *Node {
            //     return switch (self.*) {
            //         .Node4 => &self.Node4,
            //         .Node16 => &self.Node16,
            //         .Node48 => &self.Node48,
            //         .Node256 => &self.Node256,
            //         .Leaf, .Empty => unreachable,
            //     };
            // }
            pub fn baseNode(self: *Node) *BaseNode {
                return switch (self.*) {
                    .Node4 => &self.Node4.n,
                    .Node16 => &self.Node16.n,
                    .Node48 => &self.Node48.n,
                    .Node256 => &self.Node256.n,
                    .Leaf, .Empty => unreachable,
                };
            }
            pub fn keys(self: *Node) []u8 {
                return switch (self.*) {
                    .Node4 => &self.Node4.keys,
                    .Node16 => &self.Node16.keys,
                    .Node48 => &self.Node48.keys,
                    .Node256 => &self.Node256.keys,
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

        pub fn init(allr: *std.mem.Allocator) Tree {
            return Tree{ .root = &emptyNode, .size = 0, .allr = allr };
        }
        const Result = union(enum) { New, Old: *Node };
        pub fn deinit(t: *Tree) void {
            if (t.root.* == .Empty) return;
            const n = t.root;
            const cb = struct {
                fn inner(tree: *Tree, node: *Node, data: *c_void, depth: usize) bool {
                    // log("cb {}\n", .{node});
                    // switch (node.*) {
                    //     .Leaf => |l| {
                    //         tree.allr.free(l.key);
                    //         tree.allr.destroy(node);
                    //     },
                    //     else => {
                    //         tree.allr.destroy(node);
                    //     },
                    // }
                    return false;
                }
            }.inner;
            _ = t.iter(cb, n);
        }
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
        /// Calculates the index at which the prefixes mismatch
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
        fn allocNode(t: *Tree, comptime Tag: @TagType(Node)) !*Node {
            var node = try t.allr.alloc(Node, 1);
            const tagName = @tagName(Tag);
            node[0] = @unionInit(Node, tagName, .{ .n = .{ .numChildren = 0, .partialLen = 0 }, .children = undefined });
            var tagField = @field(node[0], tagName);
            std.mem.secureZero(*Node, &tagField.children);
            return @ptrCast(*Node, node.ptr);
        }
        // Find the minimum Leaf under a node
        fn minimum(n: *Node) ?*Leaf {
            if (n.* == .Empty) return null;

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
                .Empty => return null,
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
        pub fn recursiveInsert(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, _depth: usize) InsertError!Result {
            log("recursiveInsert {}\n", .{key});
            if (n.* == .Empty) {
                ref.* = try makeLeaf(key, value);
                return .New;
            }
            var depth = _depth;
            // If we are at a leaf, we need to replace it with a node
            if (n.* == .Leaf) {
                var l = n.Leaf;
                // Check if we are updating an existing value
                if (std.mem.eql(u8, l.key, key)) {
                    l.value = value;
                    return Result{ .Old = n };
                }
                // New value, we must split the leaf into a node4
                var newNode = try t.allocNode(.Node4);
                // log("allocNode sizeOf Node {}\n", .{@sizeOf(Node)});
                var l2 = try makeLeaf(key, value);
                const longestPrefix = longestCommonPrefix(l, l2.Leaf, depth);
                const c1 = if (depth + longestPrefix < l.key.len) l.key[depth + longestPrefix] else 0;
                const c2 = if (depth + longestPrefix < l2.Leaf.key.len) l2.Leaf.key[depth + longestPrefix] else 0;
                newNode.Node4.n.partialLen = longestPrefix;
                std.mem.copy(u8, &newNode.Node4.n.partial, key[depth..][0..std.math.min(MaxPartialLen, longestPrefix)]);
                log("longestPrefix {} depth {} l.key {}-{} '{c}' l2.key {}-{} '{c} ref {*} '\n", .{ longestPrefix, depth, l.key, l.key.len, c1, l2.Leaf.key, l2.Leaf.key.len, c2, ref.* });
                // Add the leaves to the new node4
                // log("newNode {}\n", .{newNode});
                // try t.addChild4(newNode, ref, if (depth + longestPrefix < l.key.len) l.key[depth + longestPrefix] else 0, n);
                // try t.addChild4(newNode, ref, if (depth + longestPrefix < l2.Leaf.key.len) l2.Leaf.key[depth + longestPrefix] else 0, l2);
                ref.* = newNode;
                try t.addChild4(newNode, ref, c1, n);
                try t.addChild4(newNode, ref, c2, l2);
                log("newNode {} ref {*} \n", .{ newNode, ref.* });
                return .New;
            }

            const baseNode = n.baseNode();
            log("partialLen {}\n", .{baseNode.partialLen});

            if (baseNode.partialLen != 0) {
                const prefixDiff = prefixMismatch(n, key, depth);
                log("prefixDiff {}\n", .{prefixDiff});
                if (prefixDiff >= baseNode.partialLen) {
                    depth += baseNode.partialLen;
                    return t.recurseInsertSearch(n, ref, key, value, depth);
                }

                // var newNode = try t.allr.create(Node);
                var newNode = try t.allocNode(.Node4);
                ref.* = newNode;
                baseNode.partialLen = prefixDiff;
                std.mem.copy(u8, &newNode.Node4.n.partial, &baseNode.partial);

                if (baseNode.partialLen <= MaxPartialLen) {
                    try t.addChild4(newNode, ref, baseNode.partial[prefixDiff], n);
                    baseNode.partialLen -= (prefixDiff + 1);
                    std.mem.copyBackwards(u8, &baseNode.partial, baseNode.partial[prefixDiff + 1 ..]);
                } else {
                    baseNode.partialLen -= (prefixDiff + 1);
                    const l = minimum(n);
                    try t.addChild4(newNode, ref, l.?.key[depth + prefixDiff], n);
                    std.mem.copy(u8, &baseNode.partial, l.?.key[depth + prefixDiff + 1 ..]);
                }

                var l = try makeLeaf(key, value);
                try t.addChild4(newNode, ref, key[depth + prefixDiff], l);
                return Result{ .New = {} };
            }
            return t.recurseInsertSearch(n, ref, key, value, depth);
        }
        fn recurseInsertSearch(t: *Tree, n: *Node, ref: **Node, key: []const u8, value: T, depth: usize) InsertError!Result {
            var child = findChild(n, key[depth]);
            log("recurseInsertSearch {} {} child {*}\n", .{ key, value, child });
            if (child.* != .Empty) {
                log("child != null {}\n", .{child});
                return t.recursiveInsert(child, &child, key, value, depth + 1);
            }

            var l = try makeLeaf(key, value);
            try t.addChild(n, ref, key[depth], l);
            return Result{ .New = {} };
        }
        fn copyHeader(dest: *BaseNode, src: *BaseNode) void {
            dest.numChildren = src.numChildren;
            dest.partialLen = src.partialLen;
            std.mem.copy(u8, &dest.partial, &src.partial);
        }
        // TODO: remove this helper for casting away constness
        // fn castPtr(comptime P: type, p: var) P {
        //     return @intToPtr(P, @ptrToInt(p));
        // }
        fn addChild(t: *Tree, n: *Node, ref: **Node, c: u8, child: *Node) InsertError!void {
            switch (n.*) {
                .Node4 => try t.addChild4(n, ref, c, child),
                .Node16 => try t.addChild16(n, ref, c, child),
                .Node48 => try t.addChild48(n, ref, c, child),
                .Node256 => try t.addChild256(n, ref, c, child),
                else => unreachable,
            }
        }
        fn findChild(n: *Node, c: u8) *Node {
            const base = n.baseNode();
            switch (n.*) {
                .Node4 => {
                    var i: usize = 0;
                    while (i < base.numChildren) : (i += 1) if (n.Node4.keys[i] == c)
                        return n.Node4.children[i];
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
                    if (bitfield != 0) return n.Node16.children[@ctz(usize, bitfield)];
                },
                .Node48 => if (n.Node48.keys[c] != 0) return n.Node48.children[n.Node48.keys[c] - 1],
                .Node256 => if (hasChildAt(n, c)) return n.Node256.children[c],
                else => unreachable,
            }
            return &emptyNode;
        }
        fn addChild4(t: *Tree, n: *Node, ref: **Node, c: u8, child: *Node) InsertError!void {
            log("addChild4 {c} numChildren {}\n", .{ c, n.Node4.n.numChildren });
            if (n.Node4.n.numChildren < 4) {
                var idx: usize = 0;
                while (idx < n.Node4.n.numChildren and c < n.Node4.keys[idx]) : (idx += 1) {}

                const shiftLen = n.Node4.n.numChildren - idx;
                log("idx {} keys {} shiftLen {}\n", .{ idx, n.Node4.keys, shiftLen });
                // log("n {}\n", .{n});
                // log("child {}\n", .{child});
                // shift forward to make room
                std.mem.copyBackwards(u8, n.Node4.keys[idx + 1 ..], n.Node4.keys[idx..][0..shiftLen]);
                std.mem.copyBackwards(*Node, n.Node4.children[idx + 1 ..], n.Node4.children[idx..][0..shiftLen]);
                n.Node4.keys[idx] = c;
                n.Node4.children[idx] = child;
                n.Node4.n.numChildren += 1;
            } else {
                log("adding .Node16 \n", .{});
                var newNode = try t.allocNode(.Node16);
                std.mem.copy(*Node, &newNode.Node16.children, &n.Node4.children);
                std.mem.copy(u8, &newNode.Node16.keys, &n.Node4.keys);
                copyHeader(newNode.baseNode(), n.baseNode());
                ref.* = newNode;
                t.allr.destroy(n);
                try t.addChild16(newNode, ref, c, child);
            }
        }
        fn addChild16(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) InsertError!void {
            log("addChild16 n {}\n", .{n});
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
        fn addChild48(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) InsertError!void {
            // if (n.)
        }
        fn addChild256(t: *Tree, n: *Node, ref: **Node, c: u8, child: var) InsertError!void {
            // if (n.)
        }
        pub fn delete(t: *Tree, key: []const u8) Result {}
        pub fn search(t: *Tree, key: []const u8) Result {}
        pub const Callback = fn (t: *Tree, n: *Node, data: *c_void, depth: usize) bool;
        // pub fn nopCallback(t: *Tree, n: *Node, data: *c_void, depth: usize) bool {
        //     return false;
        // }
        pub fn iter(t: *Tree, comptime cb: Callback, data: var) bool {
            return t.recursiveIter(t.root, data, 0, cb);
        }
        /// return true to stop iteration
        pub fn recursiveIter(t: *Tree, n: *Node, data: *c_void, depth: usize, comptime cb: Callback) bool {
            if (n.* == .Empty) return false;
            switch (n.*) {
                .Empty => return false,
                .Leaf => return cb(t, n, data, depth),
                .Node4 => {
                    if (cb(t, n, data, depth)) return true;
                    var i: usize = 0;
                    // log("{*}\n", .{n});
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
                        // @panic("unimplemented");
                        if (!hasChildAt(n, i)) continue;
                        if (t.recursiveIter(n.Node256.children[i], data, depth + 1, cb))
                            return true;
                    }
                },
                // else => unreachable,
            }
            return false;
        }
        pub fn iterPrefix(t: *Tree, prefix: []const u8, comptime cb: Callback, data: var) Result {}
        const max_spaces = 256;
        const spaces = [1]u8{' '} ** max_spaces;
        pub fn print(t: *Tree) !void {
            // const leafcb = struct {
            //     fn _(t: *Tree, n: *Node, data: *c_void, key: []const u8, value: ?T, depth: usize) bool {
            //         const stderr = std.io.getStdOut().outStream();
            //         // const depth = @ptrCast(*align(1) usize, data);
            //         _ = stderr.print("\"{}\"", .{key}) catch unreachable;
            //         // depth.* += 2;

            //         return false;
            //     }
            // }._;
            // const nodecb = struct {
            //     fn _(t: *Tree, n: *Node, data: *c_void, key: []const u8, value: ?T, depth: usize) bool {
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
            try t.recursiveShow(s, 0, 0, t.root);
        }
        const ShowError = error{ DiskQuota, FileTooBig, InputOutput, NoSpaceLeft, AccessDenied, BrokenPipe, SystemResources, OperationAborted, WouldBlock, Unexpected };
        fn recursiveShow(t: *Tree, stream: var, level: usize, lpad: usize, n: *Node) ShowError!void {
            switch (n.*) {
                .Empty => _ = try stream.print("Empty\n", .{}),
                .Leaf => _ = try stream.print("{}\n", .{n}),
                else => {
                    _ = try stream.print("{}\n", .{n});
                    const base = n.baseNode();
                    for (n.children()[0..base.numChildren]) |child| {
                        try t.recursiveShow(stream, level + 1, lpad, child);
                    }
                },
            }
        }
        fn recursiveShow2(t: *Tree, stream: var, level: usize, _lpad: usize, n: *Node) ShowError!void {
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
                    for (n.children()) |child, i| {
                        _ = try stream.print("{c}", .{n.keys()[i]});
                    }
                    _ = try stream.print("{c}", .{se[1]});
                    numchars += n.children().len;
                    // for (n.children()) |child, i| {
                    //     if (i >= base.numChildren) break;
                    //     try t.recursiveShow(stream, level + 1, lpad, child);
                    // }
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
                    const baseNode = n.baseNode();
                    _ = try stream.write(baseNode.partial[0..baseNode.partialLen]);
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
const UseTestAllr = false;
const a = if (UseTestAllr) testing.allocator else std.heap.page_allocator;

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
        testing.expectEqual(try t.insert(w, i), .New);
        testing.expectEqual(t.size, i + 1);
        log("\n", .{});
    }
    var data: usize = 0;
    _ = t.iter(debugCb, @as(*c_void, &data));
    log("\n", .{});
    try t.print();
}
const TreeT = ArtTree(usize);
fn debugCb(t: *TreeT, n: *TreeT.Node, data: *c_void, depth: usize) bool {
    const nodeType = switch (n.*) {
        .Node4 => "4   ",
        .Node16 => "16  ",
        .Node48 => "48  ",
        .Node256 => "256 ",
        else => "LEAF",
    };
    const key = if (n.* == .Leaf) n.Leaf.key else "(null)";
    const partial = if (n.* != .Leaf) &n.baseNode().partial else "(null)";
    std.debug.warn("Node {}: {}-{} {} {}\n", .{ nodeType, key, key.len, depth, partial });
    // std.debug.warn("n {}\n", .{n});
    return false;
}

test "test_art_insert" {
    var t = ArtTree(usize).init(a);
    defer t.deinit();
    const f = try std.fs.cwd().openFile("./testdata/words1.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const result = try t.insert(line, lines);
        // log("line {} result {}\n", .{ line, result });
        try t.print();
        // log("\n", .{});
        lines += 1;
    }
}
