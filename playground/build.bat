@echo off
odin run . -out:./playground.exe -strict-style -vet -collection:lib=../ -debug
@echo on