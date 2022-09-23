package helios

import "core:fmt"
import "core:strings"
import toml "../toml"

Error :: enum {
	None,
	Include_Kind_Not_Found,
	Include_Declaration_Not_Found,
	Include_Body_Not_Found,
	Unkown_Include,
	Stage_Template_Flag_Not_Found,
	Stage_Source_Not_Found,
	Stage_Extensions_Not_Found,
	Invalid_Stage_Extension,
}

parse :: proc(
	name: string,
	data: []byte,
	allocator := context.allocator,
) -> (
	document: Document,
	err: Error,
) {
	context.allocator = allocator

	toml_document, toml_err := toml.parse(data)
	defer {
		toml.destroy(toml_document)
		delete(data)
	}
	if toml_err != nil {
		fmt.println(toml_err)
		assert(false, "Failed to parse library file")
	}

	toml_includes := toml_document.root["includes"].(toml.Array)
	document.name = strings.clone(name)
	document.includes = make(map[string]Include, len(toml_includes))
	for toml_include in toml_includes {
		include_info := toml_include.(toml.Table)

		include: Include
		include.name = strings.clone(include_info["name"].(string) or_else "")

		if include_kind, has_kind := include_info["type"]; has_kind {
			k := include_kind.(string)
			switch k {
			case "uniform":
				include.kind = .Uniform
			case "procedure":
				include.kind = .Procedure
			}
		} else {
			err = .Include_Kind_Not_Found
			return
		}

		if include.kind == .Procedure {
			if include_decl, has_decl := include_info["decl"]; has_decl {
				include.decl = strings.clone(include_decl.(string) or_else "")
			} else {
				err = .Include_Declaration_Not_Found
				return
			}
		}

		if include_body, has_body := include_info["body"]; has_body {
			include.body = strings.clone(include_body.(string) or_else "")
		} else {
			err = .Include_Body_Not_Found
			return
		}

		document.includes[include.name] = include
	}

	toml_shaders := toml_document.root["shaders"].(toml.Array)
	document.prototypes = make(map[string]Shader_Prototype, len(toml_shaders))
	for toml_shader in toml_shaders {
		prototype_info := toml_shader.(toml.Table)

		prototype: Shader_Prototype
		prototype.name = strings.clone(prototype_info["name"].(string) or_else "")

		for stage in Stage {
			stage_prototype, exist := parse_prototype_stage(
				document,
				prototype_info,
				stage,
			) or_return

			if exist {
				prototype.stage_prototypes[stage] = stage_prototype
				prototype.stages += {stage}
			}
		}

		document.prototypes[prototype.name] = prototype
	}

	return
}

@(private)
parse_prototype_stage :: proc(
	document: Document,
	info: toml.Table,
	stage: Stage,
) -> (
	result: Stage_Prototype,
	exist: bool,
	err: Error,
) {
	str := stage_str[stage]
	if toml_stage, has_stage := info[str]; has_stage {
		stage_info := toml_stage.(toml.Table)

		if stage_template, has_template := stage_info["template"]; has_template {
			result.template = stage_template.(toml.Boolean)

			if result.template {
				if toml_extensions, has_ext := stage_info["extensions"]; has_ext {
					extensions_info := toml_extensions.(toml.Array)
					result.extensions = make(map[string]string, len(extensions_info))

					for toml_extension in extensions_info {
						ext_info := toml_extension.(toml.Table)

						if "name" not_in ext_info || "source" not_in ext_info {
							err = .Invalid_Stage_Extension
							return
						}
						ext_name := strings.clone(ext_info["name"].(string) or_else "")
						ext_source := strings.clone(ext_info["source"].(string) or_else "")
						result.extensions[ext_name] = ext_source
					}
				} else {
					err = .Stage_Extensions_Not_Found
					return
				}
			}
		} else {
			err = .Stage_Template_Flag_Not_Found
			return
		}

		if stage_includes, has_includes := stage_info["includes"]; has_includes {
			includes_info := stage_includes.(toml.Array)
			result.includes = make([]^Include, len(includes_info))
			result.include_line = int(stage_info["include_line"].(toml.Float))

			for stage_include, i in includes_info {
				include_name := stage_include.(string)
				if include_name not_in document.includes {
					err = .Unkown_Include
					return
				}
				result.includes[i] = &document.includes[include_name]
			}
		}

		if source, has_source := stage_info["source"]; has_source {
			result.source = strings.clone(source.(string) or_else "")
		} else {
			err = .Stage_Source_Not_Found
			return
		}

		exist = true
	}

	return
}

destroy :: proc(document: Document) {
	for _, include in document.includes {
		delete(include.name)
		if include.kind == .Procedure {
			delete(include.decl)
		}
		delete(include.body)
	}
	delete(document.includes)

	for _, prototype in document.prototypes {
		delete(prototype.name)
		for stage in Stage {
			if stage in prototype.stages {
				stage_prototype := prototype.stage_prototypes[stage]
				delete(stage_prototype.includes)
				delete(stage_prototype.source)

				if stage_prototype.template {
					for name, source in stage_prototype.extensions {
						delete(name)
						delete(source)
					}
					delete(stage_prototype.extensions)
				}
			}
		}
	}
	delete(document.prototypes)
	delete(document.name)
}
