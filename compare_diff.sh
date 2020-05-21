zig test src/clibart.zig --c-source libartc/src/art.c -I/usr/include/ -I/usr/include/x86_64-linux-gnu/ -lc -I libartc/src -I. --test-filter "compare n" -DLANG="'z'" 2> testdata/z.txt
zig test src/clibart.zig --c-source libartc/src/art.c -I/usr/include/ -I/usr/include/x86_64-linux-gnu/ -lc -I libartc/src -I. --test-filter "compare n" -DLANG="'c'" 2> testdata/c.txt
diff --text -y --suppress-common-lines -W180 testdata/c.txt testdata/z.txt > testdata/cz.diff
nvim testdata/cz.diff
