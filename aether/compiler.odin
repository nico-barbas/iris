package aether

import "core:os"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:path/filepath"

Compiler :: struct {
	flag:         Compiler_Flag,
	data:         string,
	source:       [dynamic]string,
	current:      Stage_Kind,
	output:       Shader_Output,
	entry_points: [dynamic]int,
	directives:   [dynamic]Directive,
	includes:     map[string]Procedure_Include,
}

Compiler_Flag :: enum {
	Runtime,
	Compile,
}

Directive :: struct {
	kind:  enum {
		Stage_Declaration,
		Textual_Inclusion,
	},
	line:  int,
	value: string,
}

Shader_Output :: struct {
	active_stages: Stage_Kinds,
	stages:        [len(Stage_Kind)]Stage,
}

Stage :: struct {
	source:           string,
	kind:             Stage_Kind,
	line_start:       int,
	line_end:         int,
	start:            int,
	end:              int,
	entry_point_line: int,
}

Stage_Kinds :: distinct bit_set[Stage_Kind]
REQUIRED_STAGES :: Stage_Kinds{.Vertex, .Fragment}

Stage_Kind :: enum {
	Invalid,
	Vertex,
	Fragment,
}

Procedure_Include :: struct {
	decl: string,
	body: string,
}

Error :: enum {
	None,
	Main_Declaration_Not_Found,
	Multiple_Stage_Entry_Points,
	Include_Not_Found,
	Invalid_Directive,
	Invalid_Stage_Declaration_Directive,
	Invalid_Stage_Name,
	Stage_Redeclaration,
	Missing_Required_Stage,
	Failed_To_Read_File,
	Failed_To_Write_File,
}

split_shader_stages :: proc(
	shader_path: string,
	allocator := context.allocator,
) -> (
	out: Shader_Output,
	err: Error,
) {
	context.allocator = allocator
	source, r_ok := os.read_entire_file(shader_path, context.temp_allocator)
	if !r_ok {
		err = .Failed_To_Read_File
		return
	}

	lines := strings.split_lines_after(string(source), context.temp_allocator)
	compiler := Compiler {
		data = string(source),
		flag = .Runtime,
	}
	d := transmute([dynamic]string)mem.Raw_Dynamic_Array{
		data = raw_data(lines),
		len = len(lines),
		cap = len(lines),
		allocator = context.allocator,
	}
	compiler.source = d

	build_directives(&compiler) or_return
	resolve_stages(&compiler) or_return

	out = compiler.output
	return
}

stage_source :: proc(out: ^Shader_Output, kind: Stage_Kind) -> string {
	return out.stages[kind].source
}

build_shaders :: proc(
	src_dir: string,
	build_dir: string,
	includes: map[string]Procedure_Include,
	allocator := context.allocator,
) -> (
	err: Error,
) {
	context.allocator = allocator
	matches, dir_err := filepath.glob(fmt.tprintf("%s/*", src_dir))
	defer {
		for match in matches {
			delete(match)
		}
		delete(matches)
	}

	if dir_err != .None {
		fmt.printf("Failed to walk the directory: %v", err)
		return
	}

	for path in matches {
		if !strings.has_suffix(path, ".aether") {
			continue
		}
		source, ok := os.read_entire_file(path)
		lines := strings.split_lines_after(string(source))
		defer {
			delete(source)
		}
		if !ok {
			fmt.printf("Failed to read shader source file: %s", path)
			err = .Failed_To_Read_File
			return
		}

		compiler: Compiler
		compiler.flag = .Compile
		compiler.data = string(source)
		compiler.includes = includes
		d := transmute([dynamic]string)mem.Raw_Dynamic_Array{
			data = raw_data(lines),
			len = len(lines),
			cap = len(lines),
			allocator = context.allocator,
		}
		compiler.source = d


		find_main(&compiler) or_return
		build_directives(&compiler) or_return
		resolve_stages(&compiler) or_return
		resolve_directives(&compiler) or_return

		file_name := filepath.stem(path)
		file_path := filepath.join(
			elems = {build_dir, file_name},
			allocator = context.temp_allocator,
		)
		file_path = strings.join({file_path, ".shader"}, "", context.temp_allocator)
		os.remove(file_path)

		when ODIN_OS == .Windows {
			out, f_err := os.open(file_path, os.O_CREATE)
			if f_err != os.ERROR_NONE {
				err = .Failed_To_Write_File
				return
			}
			offset: int
			for line in compiler.source {
				n, w_err := os.write_at(out, transmute([]byte)line, i64(offset))
				if w_err != os.ERROR_NONE {
					err = .Failed_To_Write_File
					return
				}
				offset += int(n)
			}
		} else when ODIN_OS == .Linux {
			builder: strings.Builder
			strings.builder_init_len_cap(&builder, 0, mem.Megabyte * 5, context.temp_allocator)
			for line in compiler.source {
				strings.write_string(&builder, line)
			}

			out_data := strings.to_string(builder)
			os.write_entire_file(file_path, transmute([]byte)out_data)
		}
	}
	return
}

@(private)
find_main :: proc(c: ^Compiler) -> (err: Error) {
	for line, i in c.source {
		if strings.has_prefix(line, "void main()") {
			append(&c.entry_points, i)
		}
	}
	if len(c.entry_points) < 2 {
		err = .Main_Declaration_Not_Found
	}
	return
}

@(private)
build_directives :: proc(c: ^Compiler) -> (err: Error) {
	for line, i in c.source {
		directive: Directive
		switch {
		case strings.has_prefix(line, "@"):
			str := line[1:]
			INCLUDE_PREFIX :: "include"
			if strings.has_prefix(str, INCLUDE_PREFIX) {
				directive.kind = .Textual_Inclusion
				directive.line = i
				directive.value = strings.trim_space(strings.trim_left(str, INCLUDE_PREFIX))
				append(&c.directives, directive)
			} else {
				err = .Invalid_Directive
				return
			}
		case strings.has_prefix(line, "["):
			str := line[1:]
			str = strings.trim_right_space(str)
			if strings.has_suffix(str, "]") {
				directive.kind = .Stage_Declaration
				directive.line = i
				directive.value = str[:len(str) - 1]
				append(&c.directives, directive)
			} else {
				err = .Invalid_Stage_Declaration_Directive
				return
			}
		}
	}
	return
}

@(private)
resolve_stages :: proc(c: ^Compiler) -> (err: Error) {
	stages: Stage_Kinds
	for directive in c.directives {
		#partial switch directive.kind {
		case .Stage_Declaration:
			previous := c.current
			switch directive.value {
			case "Vertex":
				if .Vertex not_in stages {
					stages += {.Vertex}
					c.current = .Vertex
				} else {
					err = .Stage_Redeclaration
					return
				}
			case "Fragment":
				if .Fragment not_in stages {
					stages += {.Fragment}
					c.current = .Fragment
				} else {
					err = .Stage_Redeclaration
					return
				}
			case:
				err = .Invalid_Stage_Name
				return
			}

			c.output.stages[c.current] = Stage {
				kind       = c.current,
				line_start = directive.line,
			}
			if previous != .Invalid {
				c.output.stages[previous].line_end = directive.line - 1
			}
		}
	}

	c.output.stages[c.current].line_end = len(c.source) - 1
	c.output.active_stages = stages

	if !(REQUIRED_STAGES <= stages) {
		err = .Missing_Required_Stage
		return
	}

	switch c.flag {
	case .Compile:
		for kind in Stage_Kind {
			if kind == .Invalid {
				continue
			}

			matches: int
			stage := &c.output.stages[kind]
			for entry_point in c.entry_points {
				if entry_point >= stage.line_start && entry_point <= stage.line_end {
					stage.entry_point_line = entry_point
					matches += 1
				}
			}
			if matches < 1 {
				err = .Main_Declaration_Not_Found
				return
			} else if matches > 1 {
				err = .Multiple_Stage_Entry_Points
				return
			}
		}

	case .Runtime:
		for kind in Stage_Kind {
			if kind == .Invalid {
				continue
			}

			stage := &c.output.stages[kind]
			current: int
			for line, i in c.source[:stage.line_end + 1] {
				current += len(line)
				if i == stage.line_start {
					stage.start = current
				}
			}
			stage.end = current
			buf := make([]byte, stage.end - stage.start + 1)
			copy(buf[:], c.data[stage.start:stage.end])
			buf[len(buf) - 1] = '\x00'
			stage.source = string(buf)
		}
	}
	return
}

@(private)
resolve_directives :: proc(c: ^Compiler) -> (err: Error) {
	for directive in c.directives {
		#partial switch directive.kind {
		case .Textual_Inclusion:
			if include, exist := c.includes[directive.value]; exist {
				old := c.source[directive.line]
				defer delete(old)
				decl := make([]byte, len(include.decl) + 1)
				copy(decl[:], include.decl[:])
				decl[len(decl) - 1] = '\n'
				c.source[directive.line] = string(decl)
				body := strings.split_lines_after(include.body)
				append(&c.source, strings.clone("\r\n"))
				append(&c.source, ..body)
			} else {
				fmt.printf("'%s' not found\nIncludes: %v\n", directive.value, c.includes)
				err = .Include_Not_Found
				return
			}
		}
	}
	return
}
