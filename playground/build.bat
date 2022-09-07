@echo off
if "%1" == "build" (
    odin build . -out:./playground.exe -strict-style -vet -debug
) else if "%1" == "run" (
    odin run . -out:./playground.exe -strict-style -vet -debug
)
@echo on