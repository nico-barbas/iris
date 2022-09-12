package compiler

import "core:os"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:path/filepath"

Compiler :: struct {
	path:       string,
	source:     []string,
	output:     strings.Builder,
	directives: [dynamic]Directive,
}

Directive :: struct {
	kind:  enum {
		Stage_Declaration,
		Textual_Inclusion,
	},
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

build_shaders :: proc(dir: string, allocator := context.allocator) {
	context.allocator = allocator
	matches, err := filepath.glob(fmt.tprintf("%s/*", dir))

	if err != .None {
		fmt.printf("Failed to walk the directory: %v", err)
		return
	}

	builder_buf := make([]byte, mem.Megabyte * 4)
	for match in matches {
		source, ok := os.read_entire_file(match)
		lines := strings.split_lines(source)
		defer {
			delete(source)
		}
		if !ok {
			fmt.printf("Failed to read shader source file: %s", match)
			return
		}

		compiler := Compiler {
			path   = match,
			source = lines,
		}
		strings.builder_init(&compiler.output, builder_buf)
	}
}

build_directives :: proc(c: ^Compiler) {
	strings.l
}
