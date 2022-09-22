package aether

import "core:os"
import "core:fmt"
import "core:mem"
import "core:strings"
import "core:path/filepath"

Compiler :: struct {
	flag:         Compiler_Flag,
	files: map[string]^File,
	current:      Stage_Kind,
	outputs:       map[string]Shader_Output,
	includes:     map[string]Include,
}

Compiler_Flag :: enum {
	Runtime,
	Compile,
}

File :: struct {
	name: string,
	data:         string,
	source:       [dynamic]string,
	directives:   [dynamic]Directive,
	derived: Any_File,
}

Any_File :: union {
	^Standalone_File,
	^Template_File,
}

Standalone_File :: struct {
	using file: File,
	entry_points: [dynamic]int,
}

Template_File :: struct {
	using file: File,
	entry_points: [dynamic]int,
	abstract_declarations: map[string]bool,
}

Extension_File :: struct {
	using file: File,
	parent: ^Template_File,
	parent_name: string,
}

new_file :: proc($T: typeid) -> ^T {
	file := new(T)
	file.derived = file

	return file
}

Directive :: struct {
	kind:  enum {
		Stage_Declaration,
		Textual_Inclusion,
		Abstract_Procedure_Declaration,
		Abstract_Procedure_Implementation,
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
	Compute,
}

Include :: union {
	Uniform_Include,
	Procedure_Include,
}

Uniform_Include :: struct {
	body: string,
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
	includes: map[string]Include,
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
	
	compiler: Compiler
	compiler.flag = .Compile
	compiler.includes = includes
	for path in matches {
		if !strings.has_suffix(path, ".aether") {
			continue
		}
		name := strings.trim_right(path, "aether")
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
		file: ^File
		switch {
		case strings.has_prefix(lines[0], "#Template"):
			file = new_file(Template_File)
		case strings.has_prefix(lines[0], "#Extension"):
			file = new_file(Extension_File)
			ext := cast(^Extension_File)file
			str := strings.trim_left("#Extension", lines[0])
			str = strings.trim_space(str)
			ext.parent_name = str
		case strings.has_prefix(lines[0], "#Standalone"):
			file = new_file(Standalone_File)
		}
		file.name = name
		file.data = string(source)
		d := transmute([dynamic]string)mem.Raw_Dynamic_Array{
			data = raw_data(lines),
			len = len(lines),
			cap = len(lines),
			allocator = context.allocator,
		}
		file.source = d

		compiler.files[name] = file
		campiler.outputs[name] = {}

		find_main(&compiler) or_return
		build_directives(&compiler) or_return
		resolve_stages(&compiler) or_return
		resolve_includes(&compiler) or_return

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
find_main :: proc(file: ^File) -> (err: Error) {
	entry_points: ^[dynamic]int
	switch f in file {
	case ^Standalone_File:
		entry_points = &f.entry_points
	case ^Template_File:
		entry_points = &f.entry_points
	case ^Extension_File:
		return
	}
	for line, i in c.source {
		if strings.has_prefix(line, "void main()") {
			append(entry_points, i)
		}
	}
	if len(entry_points) < 2 {
		err = .Main_Declaration_Not_Found
	}
	return
}

@(private)
build_directives :: proc(file: ^File) -> (err: Error) {
	for line, i in file.source {
		directive: Directive
		switch {
		case strings.has_prefix(line, "@"):
			str := line[1:]
			INCLUDE_PREFIX :: "include"
			ABSTRACT_PREFIX :: "abstract"
			if strings.has_prefix(str, INCLUDE_PREFIX) {
				directive.kind = .Textual_Inclusion
				directive.value = strings.trim_space(strings.trim_left(str, INCLUDE_PREFIX))
			} else if strings.has_prefix(str, ABSTRACT_PREFIX) {
				directive.kind = .Abstract_Procedure_Declaration
				directive.value = strings.trim_space(strings.trim_left(str, ABSTRACT_PREFIX))
			} else {
				err = .Invalid_Directive
				return
			}
		case strings.has_prefix(line, "["):
			str := line[1:]
			str = strings.trim_right_space(str)
			if strings.has_suffix(str, "]") {
				directive.kind = .Stage_Declaration
				directive.value = str[:len(str) - 1]
			} else {
				err = .Invalid_Stage_Declaration_Directive
				return
			}
		}
		directive.line = i
		append(&file.directives, directive)
	}
	return
}

@(private)
resolve_stages :: proc(c: ^Compiler, file: ^File) -> (err: Error) {
	stages: Stage_Kinds
	output: Shader_Output
	for directive in file.directives {
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

			output.stages[c.current] = Stage {
				kind       = c.current,
				line_start = directive.line,
			}
			if previous != .Invalid {
				output.stages[previous].line_end = directive.line - 1
			}
		}
	}

	output.stages[c.current].line_end = len(c.source) - 1
	output.active_stages = stages

	if !(REQUIRED_STAGES <= stages) {
		err = .Missing_Required_Stage
		return
	}

	switch c.flag {
	case .Compile:
		for kind in Stage_Kind {
			if kind == .Invalid || kind not_in stages {
				continue
			}

			matches: int
			stage := &output.stages[kind]
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

			stage := &output.stages[kind]
			current: int
			for line, i in file.source[:stage.line_end + 1] {
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
resolve_includes :: proc(c: ^Compiler) -> (err: Error) {
	for directive in c.directives {
		#partial switch directive.kind {
		case .Textual_Inclusion:
			if include, exist := c.includes[directive.value]; exist {
				switch incl in include {
				case Uniform_Include:
					old := c.source[directive.line]
					defer delete(old)
					body := make([]byte, len(incl.body) + 1)
					copy(body[:], incl.body[:])
					body[len(body) - 1] = '\n'
					c.source[directive.line] = string(body)

				case Procedure_Include:
					old := c.source[directive.line]
					defer delete(old)
					decl := make([]byte, len(incl.decl) + 1)
					copy(decl[:], incl.decl[:])
					decl[len(decl) - 1] = '\n'
					c.source[directive.line] = string(decl)
					body := strings.split_lines_after(incl.body)
					append(&c.source, strings.clone("\r\n"))
					append(&c.source, ..body)
				}
			} else {
				fmt.printf("'%s' not found\nIncludes: %v\n", directive.value, c.includes)
				err = .Include_Not_Found
				return
			}
		}
	}
	return
}
