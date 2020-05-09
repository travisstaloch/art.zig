# References
- [armon/libart](https://github.com/armon/libart)

# Notes
```sh
$ zig test src/clibart.zig --c-source libartc/src/art.c -I/usr/include/ -I/usr/include/x86_64-linux-gnu/ -lc -I libartc/src --test-filter "compare n"  2> testdata/z.tx
$ diff --text -y testdata/c.txt testdata/z.txt  | kak
```