@echo off
odin run src -out:bin/small-world.exe -strict-style -vet -collection:lib=./lib -debug
@echo on