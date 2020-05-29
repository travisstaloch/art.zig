# References
- [the original c library: github.com/armon/libart](https://github.com/armon/libart)
- [The Adaptive Radix Tree: ARTful Indexing for Main-Memory Databases](http://www-db.in.tum.de/~leis/papers/ART.pdf)

# Features
This library provides a zig implementation of the Adaptive Radix Tree or ART. The ART operates similar to a traditional radix tree but avoids the wasted space of internal nodes by changing the node size. It makes use of 4 node sizes (4, 16, 48, 256), and can guarantee that the overhead is no more than 52 bytes per key, though in practice it is much lower.
As a radix tree, it provides the following:

  -  O(k) operations. In many cases, this can be faster than a hash table since the hash function is an O(k) operation, and hash tables have very poor cache locality.
  -  Minimum / Maximum value lookups
  -  Prefix compression
  -  Ordered iteration
  -  Prefix based iteration

# Usage **Important**
This library accepts zig string slices (`[]const u8`) and requires they are null terminated _AND_ their length must be incremented by 1 prior to being submitted to `insert()`, `delete()` and `search()`.  This is demonstrated thoroughly in src/test_art.zig.  

This is a result of having been ported from c to zig. Zig's safe build modes (debug, release-safe) do runtime bounds checks on slices.  So the insert(), search(), and delete() methods assert their key parameters are null terminated and length incremented.  `iterPrefix()` on the other hand expects NON null terminated slices. This is because it needs to check if its key parameter is a prefix of keys stored in the tree.  A random null character would prevent matches.

# Todo
- [x] Deletion
  - [x] test_art "insert search delete" test has revealed a bug in deletion. trying to figure out what node type is has the bug.
- [x] figure out whats wrong with iterPrefix, reenable tests.
- [x] Port more tests and move tests to another file. 
- [] Add print to stream.
- [] Rethink the callback signature.  I'm wondering if using `data: *c_void` param is leading to or related to the failed iter_prefix tests. 
- [] iter which doesn't visit non-leaf nodes.
- [] Remove the null termination + increased length requirement without sacrificing performance / simplicity?
- [] Save space by
  - [] Chop off null terminator in leaves.
  - [] Don't store whole key in leaves. 
  - [] Don't allocate the keys, only store pointers.
- [] build.zig
- [x] Clean up the mess. 
- [] Benchmark against StringHashMap
- [x] Add a simple repl.
  - [] write usage
    - :q - quit
    - key - adds 'key' with value = t.size
    - key number - adds key with value = parse(number)
    - d:key - deletes key
    - :r - reset (deinit/init) the tree
- []

