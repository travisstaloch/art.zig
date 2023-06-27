# Features

This library provides a zig implementation of the Adaptive Radix Tree or ART. The ART operates similar to a traditional radix tree but avoids the wasted space of internal nodes by changing the node size. It makes use of 4 node sizes (8, 16, 48, 256), and can guarantee that the overhead is no more than 52 bytes per key, though in practice it is much lower.
As a radix tree, it provides the following:

  -  O(k) operations. In many cases, this can be faster than a hash table since the hash function is an O(k) operation, and hash tables have very poor cache locality.
  -  Minimum / Maximum value lookups
  -  Prefix compression
  -  Ordered iteration
  -  Prefix based iteration

NOTES: 
> taken from [armon/libart](https://github.com/armon/libart)

> the memory footprint described here is unverified


# Usage 
See [src/test_art.zig](src/test_art.zig)

### **Important Notes**
This library requires null terminated string slices (`[:0]const u8`).

Developed and tested against zig's latest master version. The zig version when this readme was updated was `0.11.0-dev.3834+d98147414`.

### Use with the zig package manager
```zig
// build.zig.zon
.{
    .name = "my lib",
    .version = "0.0.1",

    .dependencies = .{
        .art = .{
            .url = "https://github.com/travisstaloch/art.zig/archive/e8866a9f5b29a5b40db215e2242a8e265ccf300c.tar.gz",
            .hash = "1220d4b11d054408f1026fcdb026ef44939120e9a11a1ca2963a1c66e5adf3639ab6",
        },
    }
}
```

```zig
// build.zig
const art_dep = b.dependency("art", .{});
const art_mod = art_dep.module("art");
exe.addModule("art", art_mod);
```

```zig
// example zig app
const art = @import("art");

pub fn main() !void {
    const A = art.Art(usize);
    var a = A.init(&std.heap.page_allocator);
    _ = try a.insert("foo", 0);
}

```

### Test
```sh
$ zig build test -Doptimize=ReleaseSafe
```

### Run repl
```sh
$ zig run src/art.zig -lc
```

### REPL
The repl is very simple and responds to these commands:
- :q - quit
- key - adds 'key' with value = tree.size
- key number - adds key with value = parse(number)
- d:key - deletes key
- :r - reset (destroy and then init) the tree

A representation of the tree will be printed after each operation.

# Benchmarks
```sh
zig build bench
```

This simple benchark consists of inserting, searching for and deleting each line from testdata/words.txt (235886 lines).  Benchmarks are compiled with --release-fast. 

### vs StringHashMap 
(from zig's standard library) can be found here [src/test_art.zig](src/test_art.zig#L589).

The results of the benchark on my machine:
```
Art           insert 507ms, search 481ms, delete 495ms, combined 1484ms
StringHashMap insert 487ms, search 482ms, delete 485ms, combined 1456ms
```

| Operation| % difference |
| --- | --- | 
|insert|04.1% slower|
|search|00.2% faster|
|delete|02.0% slower|
|combined|01.9% slower|

### vs armon/libart
Can be found [src/clibart.zig](src/clibart.zig#L139)
```
art.zig insert 505ms, search 482ms, delete 494ms, combined 1481ms
art.c   insert 494ms, search 481ms, delete 484ms, combined 1459ms
```
| Operation| % difference |
| --- | --- |
|insert|2.22% slower|
|search|0.20% slower|
|delete|2.06% slower|
|combined|1.50% slower|

# References
- [the original c library: github.com/armon/libart](https://github.com/armon/libart)
- [The Adaptive Radix Tree: ARTful Indexing for Main-Memory Databases](http://www-db.in.tum.de/~leis/papers/ART.pdf)
