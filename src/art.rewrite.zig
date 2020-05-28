const std = @import("std");
const math = std.math;
const mem = std.mem;
const warn = std.debug.warn;

pub fn RadixTree(comptime T: type) type {
    return struct {
        root: ?*Node,
        size: usize,
        allr: *mem.Allocator,

        const Tree = RadixTree(T);
        const Leaf = struct {
            key: []const u8,
            value: T,
        };
        var emptyNode = Node{ .empty = {} };
        const BaseEdge = extern struct {
            partial: [10]u8,
            partial_len: u8,
            keys_len: u16,
            edges_len: u16,
        };
        fn Edge(comptime keysLen: usize, comptime edgesLen: usize) type {
            return extern struct {
                partial: [10]u8 = [1]u8{0} ** 10,
                partial_len: u8 = 0,
                keys_len: u16 = 0,
                edges_len: u16 = 0,
                keys: [keysLen]u8 = [1]u8{0} ** keysLen,
                edges: [edgesLen]*Node = [1]*Node{undefined} ** edgesLen,
            };
        }
        pub const Edge4 = Edge(4, 4);
        pub const Edge16 = Edge(16, 16);
        pub const Edge48 = Edge(256, 48);
        pub const Edge256 = Edge(0, 256);

        pub const Node = union(enum) {
            empty,
            leaf: Leaf,
            edge4: Edge4,
            edge16: Edge16,
            // edge48: Edge48,
            // edge256: Edge256,
        };

        fn toBaseEdge(e: var) *BaseEdge {
            return @intToPtr(*BaseEdge, @ptrToInt(e));
        }

        fn baseEdge(n: *Node) *BaseEdge {
            return switch (n.*) {
                .edge4 => toBaseEdge(&n.edge4),
                .edge16 => toBaseEdge(&n.edge16),
                // .edge48 => toBaseEdge(&n.edge48),
                // .edge256 => toBaseEdge(&n.edge256),
                else => unreachable,
            };
        }

        const PrefixResult = struct { len: u16, idx: usize };
        fn commonKeyLen(key: []const u8, key2: []const u8) u8 {
            const max_len = std.math.min(key.len, key2.len);
            var i: u8 = 0;
            while (i < max_len) : (i += 1) {
                if (key[i] != key2[i])
                    return i;
            }
            return i;
        }
        const Result = union(enum) { Create, Update: T };
        pub fn init(a: *std.mem.Allocator) Tree {
            return .{ .root = null, .size = 0, .allr = a };
        }
        fn makeLeaf(t: Tree, key: []const u8, value: T) Error!*Node {
            const n = try t.allr.create(Node);
            n.* = .{ .leaf = .{ .key = key, .value = value } };
            return n;
        }
        fn allocEdge(t: *Tree, comptime Tag: @TagType(Node)) !*Node {
            var node = try t.allr.create(Node);
            const tagName = @tagName(Tag);
            node.* = @unionInit(Node, tagName, .{});
            return node;
        }
        // fn allocEdge(t: *Tree) !?*Node {
        //     // TODO maybe dupe key
        //     const nn = try t.allr.create(Node);
        //     nn.* = .{
        //         .edge = .{
        //             .nodes = NodeList.init(t.allr),
        //             .keys = KeyList.init(t.allr),
        //         },
        //     };
        //     return nn;
        // }
        pub fn insert(t: *Tree, key: []const u8, value: T) !Result {
            return try t.insertRec(&t.root, key, value, 0);
        }

        fn addEdge(parent: *Node, n: *Node, key: []const u8) !void {
            _ = try parent.edge4.nodes.append(n);
            // TODO maybe dupe key
            _ = try parent.edge.keys.append(key);
        }
        const Error = error{ DiskQuota, FileTooBig, InputOutput, NoSpaceLeft, AccessDenied, BrokenPipe, SystemResources, OperationAborted, WouldBlock, Unexpected, OutOfMemory, StopIteration };
        pub fn insertRec(t: *Tree, ref: *?*Node, key: []const u8, value: T, depth: usize) Error!Result {
            try printNode(ref.*, stderr, 0);
            warn("\n", .{});
            var n = (ref.* orelse blk: {
                const newLeaf = try t.makeLeaf(key, value);
                ref.* = newLeaf;
                return .Create;
            });
            if (n.* == .leaf) {
                var l = n.*.leaf;
                // match if key is empty, update value
                if (std.mem.eql(u8, l.key, key)) {
                    l.value = value;
                    return Result{ .Update = value };
                }
                // turn this leaf into new edge with child
                var newNode = try t.allocEdge(.edge4);
                var l2 = try t.makeLeaf(key, value);
                var common_len = commonKeyLen(l.key, l2.leaf.key);
                mem.copy(u8, &newNode.edge4.partial, key[0..common_len]);
                ref.* = newNode;
                try t.addChild4(newNode, ref, l.key[depth + common_len], n);
                try t.addChild4(newNode, ref, l2.leaf.key[depth + common_len], l2);
                return .Create;
            }

            const e = baseEdge(n);
            if (e.partial_len != 0) {
                const prefixDiff = prefixMismatch(n, key, depth);
            }

            // const e = n.*.edge4;
            // const key_len = commonKeyLen(e, key);
            // warn("shared len {} key {}\n", .{ shared.len, key });
            // if (shared.len == 0) {
            //     // add a new outgoing edge with remaining key
            //     var newNode = try t.allocEdge(.edge4);
            //     try addEdge(n, newNode.?, key);
            //     return .Missing;
            // } else {
            //     // split into two edges and proceed
            //     // this node becomes edge with prefix
            //     var newParent = try t.allocEdge(.edge4);

            //     const childEdge = e.nodes[shared.idx];
            //     try addEdge(childEdge, key[0..shared.len]);
            //     e.keys.items[shared.idx] = e.keys.items[shared.idx][0..shared.len];

            //     try addEdge(n, newNode.?, key[0..shared.len]);
            //     const suffix = key[shared.len..];
            //     return try t.insertRec(&newNode, suffix, value, depth + 1);
            // }
            unreachable;
        }

        fn addChild4(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: *Node) Error!void {
            warn("addChild4 {c} numChildren {}\n", .{ c, n.edge4.edges_len });
            if (n.edge4.edges_len < 4) {
                var idx: usize = 0;
                while (idx < n.edge4.edges_len) : (idx += 1) {
                    if (c < n.edge4.keys[idx]) break;
                }

                const shift_len = n.edge4.edges_len - idx;
                // shift forward to make room
                mem.copyBackwards(u8, n.edge4.keys[idx + 1 ..], n.edge4.keys[idx..][0..shift_len]);
                mem.copyBackwards(*Node, n.edge4.edges[idx + 1 ..], n.edge4.edges[idx..][0..shift_len]);
                // _ = cstd.memmove(&n.edge4.keys + idx + 1, &n.edge4.keys + idx, shift_len);
                // _ = cstd.memmove(&n.edge4.edges + idx + 1, &n.edge4.edges + idx, shift_len * @sizeOf(*Node));
                n.edge4.keys[idx] = c;
                n.edge4.edges[idx] = child;
                n.edge4.keys_len += 1;
                n.edge4.edges_len += 1;
                warn("n.edge4.keys {} idx {}\n", .{ n.edge4.keys, idx });
            } else {
                var newNode = try t.allocEdge(.edge16);
                mem.copy(*Node, &newNode.edge16.edges, &n.edge4.edges);
                mem.copy(u8, &newNode.edge16.keys, &n.edge4.keys);
                // copyHeader(newNode, n);
                mem.copy(u8, &newNode.edge16.partial, &n.edge4.partial);
                warn("newNode.edge16.keys {}\n", .{newNode.edge16.keys});
                ref.* = newNode;
                t.allr.destroy(n);
                try t.addChild16(newNode, ref, c, child);
            }
        }
        /// Calculates the index at which the prefixes mismatch
        fn prefixMismatch(n: *Node, key: []const u8, keyLen: usize, depth: usize) usize {
            const baseNode = n.baseNode();
            var maxCmp = math.min(math.min(MaxPartialLen, baseNode.partialLen), keyLen - depth);
            // log(.Verbose, "prefixMismatch maxCmp {}\n", .{maxCmp});
            var idx: usize = 0;
            while (idx < maxCmp) : (idx += 1) {
                if (baseNode.partial[idx] != key[depth + idx])
                    return idx;
            }
            if (baseNode.partialLen > MaxPartialLen) {
                const l = minimum(n);
                maxCmp = math.min(l.?.key.len, keyLen) - depth;
                while (idx < maxCmp) : (idx += 1) {
                    if (l.?.key[idx + depth] != key[depth + idx])
                        return idx;
                }
            }
            return idx;
        }

        fn addChild16(t: *Tree, n: *Node, ref: *?*Node, c: u8, child: var) Error!void {
            warn("TODO addChild16 n {}\n", .{n});
        }
        fn copyHeader(dest: *Node, src: *Node) void {
            // dest.numChildren = src.numChildren;
            // dest.partialLen = src.partialLen;
            mem.copy(u8, &dest.partial, src.partial);
        }
        const WalkFn = fn (n: *Node, depth: u8, data: var) Error!void;
        pub fn walk(t: Tree, comptime cb: WalkFn, data: var) Error!void {
            walkRec(t.root, cb, 0, data) catch |e| switch (e) {
                Error.StopIteration => return,
                else => return e,
            };
        }
        fn walkRec(optnp: ?*Node, comptime cb: WalkFn, depth: u8, data: var) !void {
            const np = optnp orelse return;
            try cb(np, depth, data);
            const n = np.*;
            switch (n) {
                .empty, .leaf => {},
                .edge4 => {
                    for (n.edge4.edges) |edge|
                        try cb(edge, depth + 1, data);
                },
                .edge16 => {
                    for (n.edge16.edges) |edge|
                        try cb(edge, depth + 1, data);
                },
                else => unreachable,
            }
        }
        const spaces = [1]u8{' '} ** 128;

        pub fn print(t: Tree, stream: var) Error!void {
            const cb = struct {
                fn _(n: *Node, depth: u8, s: var) Error!void {
                    try printNode(n, s, depth);
                }
            }._;
            try t.walk(cb, stream);
        }
        pub fn printNode(optn: ?*Node, stream: var, depth: u8) !void {
            const n = optn orelse return;
            switch (n.*) {
                .empty => {},
                .leaf => |l| _ = try stream.print("{} -> {}\n", .{ spaces[0 .. depth * 2], n.leaf.key }),
                .edge4 => |e| _ = try stream.print("{}4-{} ({})\n", .{
                    spaces[0 .. depth * 2],
                    n.edge4.keys,
                    n.edge4.partial,
                }),
                .edge16 => |e| _ = try stream.print("{}16-{} ({})\n", .{
                    spaces[0 .. depth * 2],
                    n.edge16.keys,
                    n.edge16.partial,
                }),
            }
        }
    };
}

const allocator = std.testing.allocator;
const stderr = std.io.getStdErr().outStream();
test "insert" {
    var t = RadixTree(u8).init(allocator);
    const words = [_][]const u8{ "romane", "romanus", "romulus", "rubens", "ruber", "rubicon", "rubicundus" };
    for (words) |word, i| {
        warn("{}\n", .{word});
        const result = try t.insert(word, @truncate(u8, i + 1));
        warn("{}\n", .{result});
        // try t.print(stderr);
    }
}
