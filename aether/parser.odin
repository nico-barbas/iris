package compiler

import "core:strings"
import "core:path/filepath"

Compiler :: struct {
	source:     string,
	output:     strings.Builder,
	directives: []Directive,
}

Directive :: struct {
	line:  int,
	start: int,
	end:   int,
	name:  string,
	value: string,
}

Procedure :: struct {
	declaration: string,
	body:        string,
}

build_shaders :: proc(filepath: string) {

}
