const std = @import("std");
const art = @import("art");
const Art = art.Art;

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
        std.log.warn("invalid input: '{s}'\n", .{input});
    }
    std.log.warn(usage, .{});
}

fn print(comptime fmt: []const u8, args: anytype) void {
    const stdout = std.io.getStdOut().writer();
    stdout.print(fmt, args) catch @panic("print failed");
}

pub fn main() !void {
    var t = Art(usize).init(&std.heap.c_allocator);
    const stdin = std.io.getStdIn().reader();
    var buf: [256]u8 = undefined;
    replUsage("");
    print("> ", .{});
    while (try stdin.readUntilDelimiterOrEof(&buf, '\n')) |input| {
        var parts: [2][]const u8 = undefined;
        if (std.mem.eql(u8, input, ":q")) {
            break;
        } else if (std.mem.eql(u8, input, ":r")) {
            t.deinit();
            t = Art(usize).init(&std.heap.c_allocator);
            continue;
        }
        var itr = std.mem.split(u8, input, " ");
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
        var key = try std.fmt.bufPrintZ(&buf2, "{s}", .{parts[0]});
        if (delete) {
            res = try t.delete(key);
        } else {
            if (i == 1) {
                res = try t.insert(key, t.size);
            } else if (i == 2) {
                const n = try std.fmt.parseInt(usize, parts[1], 10);
                res = try t.insert(key, n);
            } else replUsage(input);
        }
        if (res) |result| {
            var ouput: []const u8 = if (result == .missing) "insert:"[0..] else "update:"[0..];
            print("{s} size {}\n", .{ ouput, t.size });
            try t.print();
        }
        print("> ", .{});
    }
}
