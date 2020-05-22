# !Important!
This library accepts zig string slices (`[]const u8`) and requires they are null terminated _AND_ their length must be incremented by 1 prior to being submitted to `insert()`, `delete()` and `search()`.  This is a result of having been directly ported from c to zig.  

# References
- [armon/libart](https://github.com/armon/libart)

# Notes
```sh
$ zig test src/clibart.zig --c-source libartc/src/art.c -I/usr/include/ -I/usr/include/x86_64-linux-gnu/ -lc -I libartc/src -I. --test-filter "compare n" -DLANG="'z'" 2> testdata/z.txt
$ zig test src/clibart.zig --c-source libartc/src/art.c -I/usr/include/ -I/usr/include/x86_64-linux-gnu/ -lc -I libartc/src -I. --test-filter "compare n" -DLANG="'c'" 2> testdata/c.txt
$ diff --text -y testdata/c.txt testdata/z.txt  | kak
```

# Todo
- [] Deletion
  - [] test_art "insert search delete" test has revealed a bug in deletion. trying to figure out what node type is has the bug. 
- [] Port more tests and move tests to another file. 
- [] Add print to stream.
- [] Rethink the callback signature.  I'm wondering if using `data: *c_void` param is leading to or related to the failed iter_prefix tests. 
- [] Remove the null termination + increased length requirement without sacrificing performance / simplicity?
- [] Save space by
  - [] Chop off null terminator in leaves.
  - [] Don't store whole key in leaves. 
- [] build.zig
- [] Clean up the mess. 
- [] Benchmark against StringHashMap