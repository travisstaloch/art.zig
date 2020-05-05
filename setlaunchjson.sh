#!/bin/bash
#create an executable and write its path to ./.vscode/launch.json at .configurations[0].program

rm -rf zig-cache
#TODO: figure out how to pass run a parameterized command
#echo $@
#$@
#zig test src/art2.zig -lc --test-filter "insert search"
zig test src/clibart.zig --c-source libartc/src/art.c -I/usr/include/ -I/usr/include/x86_64-linux-gnu/ -lc -I libartc/src --test-filter iter
cat ./.vscode/launch.json | jq ".configurations[0].program = \"$(find . -name test)\"" > ./.vscode/launch.json
