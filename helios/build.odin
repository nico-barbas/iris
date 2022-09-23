package helios

import "core:mem"
import "core:strings"

Shader :: struct {
	name:          string,
	active_stages: Stages,
	stages:        [len(Stage)]string,
}

Builder :: struct {
	build_name:     string,
	prototype_name: string,
	stages:         Stages,
	stages_info:    [len(Stage)]struct {
		with_extension: bool,
		name:           string,
	},
}

Build_Error :: enum {
	None,
	Unkown_Shader_Prototype,
	Unkownd_Stage_Extension,
	Desired_Stage_Not_Found,
	Templated_Stage_Extension_Not_Found,
}

build_shader :: proc(
	document: ^Document,
	builder: Builder,
	allocator := context.allocator,
) -> (
	shader: Shader,
	err: Build_Error,
) {
	context.allocator = allocator
	if builder.prototype_name not_in document.prototypes {
		err = .Unkown_Shader_Prototype
		return
	}

	shader.name = strings.clone(builder.build_name)

	sb: strings.Builder
	strings.builder_init(&sb)
	defer strings.builder_destroy(&sb)
	prototype := document.prototypes[builder.prototype_name]
	for stage in Stage {
		if stage not_in builder.stages {
			continue
		}
		if stage not_in prototype.stages {
			err = .Desired_Stage_Not_Found
			return
		}

		sp := prototype.stage_prototypes[stage]

		l := strings.split_lines_after(sp.source)
		lines := transmute([dynamic]string)mem.Raw_Dynamic_Array{
			data = raw_data(l),
			len = len(l),
			cap = len(l),
			allocator = context.allocator,
		}
		line_index := sp.include_line - 1

		for include in sp.includes {
			if include.kind == .Uniform {
				inject_at(&lines, line_index, include.body)
				line_index += 1
			}
		}
		for include in sp.includes {
			if include.kind == .Procedure {
				inject_at(&lines, line_index, include.decl)
				line_index += 1
				append(&lines, include.body)
			}
		}

		if sp.template {
			info := builder.stages_info[stage]
			if !info.with_extension {
				err = .Templated_Stage_Extension_Not_Found
				return
			}
			if info.name not_in sp.extensions {
				err = .Unkownd_Stage_Extension
				return
			}

			append(&lines, sp.extensions[info.name])
		}


		for line in lines {
			strings.write_string(&sb, line)
		}
		strings.write_byte(&sb, '\x00')

		shader.stages[stage] = strings.clone(strings.to_string(sb))
		shader.active_stages += {stage}
		strings.builder_reset(&sb)

		delete(lines)
	}
	return
}

destroy_shader :: proc(shader: ^Shader) {
	delete(shader.name)
	for stage in Stage {
		if stage in shader.active_stages {
			delete(shader.stages[stage])
		}
	}
}
