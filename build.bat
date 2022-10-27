@echo off
odin run src -out:bin/tinier-tactics.exe -debug -strict-style -vet -collection:lib=./lib
@echo on