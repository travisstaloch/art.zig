const LeafIterator = struct {
    child_it: Node.ChildIterator,
    prev_child_its: std.ArrayList(Node.ChildIterator),
    // pub fn next_(self: *LeafIterator) ?Leaf {

    //     while (self.child_it.next()) |child| {
    //         std.debug.print("LeafIterator.next child {}\n", .{child});

    //         switch (child.*) {
    //             .leaf => return child.leaf,
    //             .empty => return null,
    //             else => {
    //                 // const child_it = self.child_it;
    //                 // defer self.child_it = child_it;
    //                 self.child_it = child.childIterator();
    //                 return self.next();
    //             },
    //         }
    //     }
    //     return null;
    // }

    // fn recursiveIter(t: *Tree, n: *Node, data: anytype, depth: usize, cb: anytype) bool {
    pub fn next(self: *LeafIterator) Error!?Leaf {
        // const child = self.child_it.next() orelse if (self.prev_child_its.items.len > 0)
        // // self.prev_child_it.next()
        // blk2: {
        //     self.child_it = self.prev_child_its.pop();
        //     break :blk2 self.child_it.next() orelse return null;
        // } else
        //     return null;
        const child = self.child_it.next() orelse return null;
        // const child_it = self.child_it;
        // defer self.child_it = child_it;
        std.debug.print("LeafIterator.next child {} prev_child_its len {}\n", .{ child, self.prev_child_its.items.len });
        // std.debug.print("LeafIterator.next child {}\nchild_it {}\n", .{ child, self.child_it });
        switch (child.*) {
            .empty => {},
            .leaf => {
                // defer self.child_it = child_it;
                return child.leaf;
            },
            .node4, .node16, .node48, .node256 => {
                // var cli = LeafIterator {.child_it = child.childIterator()};
                // // while (ci.next()) |child2| {
                // //     if (t.recursiveIter(child, data, depth + 1, cb))
                // //         return true;
                // // }
                // return cli.next();
                // defer self.child_it = child_it;
                _ = try self.prev_child_its.append(self.child_it);
                self.child_it = child.childIterator();
                return try self.next();
                // var li = LeafIterator{ .child_it = child.childIterator() };
                // return li.next();
            },
        }
        if (self.prev_child_its.items.len > 0) {
            self.child_it = self.prev_child_its.pop();
            return try self.next();
        }
        return null;
    }
};

pub fn iterator(t: *Tree) LeafIterator {
    return .{ .child_it = t.root.childIterator(), .prev_child_its = std.ArrayList(Node.ChildIterator).init(t.allocator) };
}
