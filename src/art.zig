const std = @import("std");
const testing = std.testing;

const ShowDebugLog = true;
fn log(comptime fmt: []const u8, vals: var) void {
    if (ShowDebugLog) std.debug.warn(fmt, vals);
}

pub fn ArtTree(comptime T: type) type {
    return struct {
        root: ANode,
        size: usize,
        allocator: *std.mem.Allocator,
        const Self = @This();
        const ANode = ArtNode(T);
        pub fn init(allocator: *std.mem.Allocator) !Self {
            return Self{
                .root = try ANode.init(allocator),
                .size = 0,
                .allocator = allocator,
            };
        }
        pub fn deinit(self: *Self) void {}

        fn makeLeaf(self: *Self, key: []const u8, value: T) !*ANode.Leaf {
            var l = try self.allocator.create(ANode.Leaf);
            l.key = try std.mem.dupe(self.allocator, u8, key);
            std.mem.copy(u8, l.key, key);
            l.value = value;
            l.node = .{};
            return l;
        }

        fn longest_common_prefix(l1: ANode.Leaf, l2: ANode.Leaf, depth: usize) usize {
            const max_cmp = std.math.min(l1.key.len, l2.key.len) - depth;
            log("l1 key {} {} l2 key {} {} max_cmp {}\n", .{ l1.key, l1.key.len, l2.key, l2.key.len, max_cmp });
            var i: usize = 0;
            while (i < max_cmp) : (i += 1) {
                if (l1.key[depth + i] != l2.key[depth + i])
                    return i;
            }
            return i;
        }

        pub const InsertResult = union(enum) { New, Existing: *ANode, Failed };
        pub fn insert(self: *Self, key: []const u8, value: T) !InsertResult {
            const insertResult = try self.recursiveInsert(&self.root, key, value, 0);
            if (insertResult == .New) self.size += 1;
            return insertResult;
        }

        fn recursiveInsert(self: *Self, node: *ANode, key: []const u8, value: T, depth: usize) !InsertResult {
            log("{} key {} value {} depth {}\n", .{ @tagName(node.*), key, value, depth });
            self.show();
            // If we are at a Empty node, inject a leaf
            if (node.* == .Empty) {
                node.* = .{ .Leaf = try self.makeLeaf(key, value) };
                return .New;
            }

            // If we are at a leaf, we need to replace it with a node
            if (node.* == .Leaf) {
                if (std.mem.eql(u8, key, node.Leaf.node.partial[0..])) {
                    node.Leaf.value = value;
                    return InsertResult{ .Existing = node };
                }

                // New value, we must split the leaf into a node4
                const node4 = try self.allocator.create(ANode.Node4);
                node4.children = try self.allocator.alloc(*ANode, ANode.Node4.ChildLen);
                node4.keys = try self.allocator.alloc(u8, ANode.Node4.KeysLen);
                var newNode = try self.allocator.create(ANode);
                // newNode.Node4 = node4;
                // var newNode = std.mem.dupe(self.allocator, ANode{ .Node4 = node4 });
                // var newNode = ANode{ .Node4 = .{} };
                newNode.* = ANode{ .Node4 = node4 };

                const l2 = ANode{ .Leaf = try self.makeLeaf(key, value) };
                const longestPrefix = longest_common_prefix(node.Leaf.*, l2.Leaf.*, depth);
                // newNode.Node4.node.partial_len = @truncate(u4, longestPrefix);
                newNode.*.baseNode().partial = try std.mem.dupe(self.allocator, u8, key[depth..]);
                // std.mem.copy(u8, newNode.*.baseNode().partial[0..], key[depth..]);
                // log("longestPrefix {} newNode {}\n", .{ longestPrefix, newNode });
                log("longestPrefix {} newNode.partial {} \n", .{ longestPrefix, newNode.*.baseNode().partial });
                // log("node {}\n", .{node});
                // Add the leaves to the new node4
                // node.* = .{ .Node4 = newNode };
                try self.addChild(newNode, node.Leaf.key[depth + longestPrefix], node.*);
                try self.addChild(newNode, l2.Leaf.key[depth + longestPrefix], l2);
                return .New;
            }
            return .Failed;
        }

        fn addChild(self: *Self, node: *ANode, c: u8, child: ANode) !void {
            switch (node.*) {
                .Node4 => {
                    var i: usize = 0;
                    while (i < ANode.Node4.ChildLen) : (i += 1) if (c < node.Node4.keys[i]) break;
                    // std.mem.copy(u8, node.Node4.keys[i + 1 ..][0..ANode.Node4.ChildLen], node.Node4.keys[i..]);
                    std.mem.copy(u8, node.Node4.keys[i + 1 ..][0 .. ANode.Node4.KeysLen - i], node.Node4.keys[i..]);
                    // std.mem.copy(*ANode, node.Node4.children[i + 1 .. i + 2], node.Node4.children[i .. i + 1]);
                    // memmove(n->children+idx+1, n->children+idx,(n->n.num_children - idx)*sizeof(void*));
                    node.Node4.children[i + 1].* = node.Node4.children[i].*;
                },
                .Node16 => {},
                .Node48 => {},
                .Node256 => {},
                else => return error.AddingEmptyChild,
            }
        }

        // pub fn NodeN(comptime keylen: usize, comptime childlen: usize) type {
        //     return struct {
        //         usingnamespace BaseNode;
        //         keys: [keylen]u8,
        //         children: [childlen]BaseNode,
        //     };
        // }
        pub fn show(self: Self) void {
            const cb = struct {
                fn _(data: *c_void, key: []const u8, value: T) bool {
                    std.debug.warn("{} - {}\n", .{ key, value });
                    return true;
                }
            }._;
            self.iter(cb, @intToPtr(*c_void, @ptrToInt(&@as(usize, 0))));
        }
        pub const IterCallback = fn (*c_void, []const u8, T) bool;
        pub fn recursiveIter(self: Self, node: ANode, cb: IterCallback, data: *c_void) void {
            switch (node) {
                .Empty => return,
                .Leaf => if (!cb(data, node.Leaf.key, node.Leaf.value)) return,
                .Node4 => {
                    for (node.Node4.children) |ch|
                        self.recursiveIter(ch.*, cb, data);
                },
                .Node16 => {},
                .Node48 => {},
                .Node256 => {},
            }
        }
        pub fn iter(self: Self, cb: IterCallback, data: *c_void) void {
            return self.recursiveIter(self.root, cb, data);
        }
    };
}

pub fn ArtNode(comptime T: type) type {
    return union(enum) {
        Empty,
        Leaf: *Leaf,
        Node4: *Node4,
        Node16: *Node16,
        Node48: *Node48,
        Node256: *Node256,

        const Self = @This();
        const BaseNode = struct {
            // partial: []const u8,
            // partial_len: u4 = 0,
            partial: []u8 = undefined,
            // len: usize = 0,
            const MaxPrefixLen = 10;
        };
        const Leaf = struct {
            node: BaseNode,
            value: T,
            key: []u8,
        };

        pub fn NodeN(comptime keyslen: usize, comptime childlen: usize) type {
            return struct {
                node: BaseNode,
                // keys: [keyslen]u8 = [1]u8{0} ** keyslen,
                keys: []u8 = undefined,
                children: []*Self = undefined,
                pub const KeysLen = keyslen;
                pub const ChildLen = childlen;
            };
        }

        pub const Node4 = NodeN(4, 4);
        pub const Node16 = NodeN(16, 16);
        pub const Node48 = NodeN(48, 256);
        pub const Node256 = NodeN(0, 256);

        pub fn init(allocator: *std.mem.Allocator) !Self {
            return .Empty;
        }
        pub fn deinit(self: *Self) void {}
        // pub fn len(self: Self) usize {
        //     return switch (self) {
        //         .Leaf, .Node4, .Node16, .Node48, .Node256 => (self.baseNode() catch unreachable).len,
        //         .Empty => 0,
        //     };
        // }

        // fn addLen(self: *Self, l: usize) void {
        //     switch (self.*) {
        //         .Leaf, .Node4, .Node16, .Node48, .Node256 => (self.baseNode() catch unreachable).len += l,
        //         else => {},
        //     }
        // }

        fn baseNode(self: Self) *BaseNode {
            return switch (self) {
                .Empty => unreachable,
                else => @intToPtr(*BaseNode, @ptrToInt(&self)),
            };
        }
    };
}

test "test_art_init_and_destroy" {
    var t = try ArtTree(void).init(std.heap.page_allocator);
    std.debug.assert(t.size == 0);
    t.deinit();
}

test "test_art_insert" {
    var t = try ArtTree(usize).init(std.heap.page_allocator);
    const f = try std.fs.cwd().openFile("./testdata/words1.txt", .{ .read = true });
    defer f.close();

    var lines: usize = 1;
    const stream = &f.inStream();
    var buf: [512:0]u8 = undefined;
    while (try stream.readUntilDelimiterOrEof(&buf, '\n')) |line| {
        const result = try t.insert(line, lines);
        log("line {} result {}\n", .{ line, result });
        // std.debug.assert(result == .New);
        // std.debug.assert(t.size == lines);
        lines += 1;
    }

    t.deinit();
}
