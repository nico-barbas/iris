package iris

import "core:log"
import "core:os"
import "core:fmt"
import "core:mem"
import "core:time"
import "core:strings"
import "core:intrinsics"
import "allocators"
import "gltf"

Resource_Library :: struct {
	free_list:      allocators.Free_List_Allocator,
	allocator:      mem.Allocator,
	temp_allocator: mem.Allocator,
	last_refresh:   time.Time,
	flags:          Resource_Library_Flags,
	buffers:        [dynamic]^Resource,
	attributes:     [dynamic]^Resource,
	textures:       [dynamic]^Resource,
	shaders:        [dynamic]^Resource,
	shader_specs:   map[string]^Resource,
	fonts:          [dynamic]^Resource,
	framebuffers:   map[string]^Resource,
	meshes:         [dynamic]^Resource,
	materials:      map[string]^Resource,
	animations:     map[string]^Resource,
	scenes:         map[string]^Resource,
}

Resource_Library_Flags :: distinct bit_set[Resource_Library_Flag]

Resource_Library_Flag :: enum {
	Hot_Reload_Shaders,
}

Resource :: struct {
	id:        int,
	load_time: time.Time,
	data:      Resource_Data,
	loader:    Resource_Loader,
}

Resource_Data :: union {
	^Buffer,
	^Attributes,
	^Texture,
	^Shader,
	^Shader_Specialization,
	^Font,
	^Framebuffer,
	^Mesh,
	^Material,
	^Animation,
	^Scene,
}

Resource_Loader :: union {
	Shader_Loader,
}

init_library :: proc(lib: ^Resource_Library) {
	DEFAULT_ALLOCATOR_SIZE :: mem.Megabyte * 400
	buf := make([]byte, DEFAULT_ALLOCATOR_SIZE, context.allocator)
	allocators.init_free_list_allocator(&lib.free_list, buf, .Find_Best, 8)
	lib.allocator = allocators.free_list_allocator(&lib.free_list)
	lib.temp_allocator = context.temp_allocator
	lib.flags = {.Hot_Reload_Shaders}

	// lib.shader_documents.allocator = lib.allocator
	lib.buffers.allocator = lib.allocator
	lib.attributes.allocator = lib.allocator
	lib.textures.allocator = lib.allocator
	lib.shaders.allocator = lib.allocator
	lib.shader_specs.allocator = lib.allocator
	lib.fonts.allocator = lib.allocator
	lib.framebuffers.allocator = lib.allocator
	lib.meshes.allocator = lib.allocator
	lib.materials.allocator = lib.allocator
	lib.animations.allocator = lib.allocator
	lib.scenes.allocator = lib.allocator
}

refresh_library :: proc(lib: ^Resource_Library) {
	RESOURCE_REFRESH_RATE :: 3
	if time.duration_seconds(time.since(lib.last_refresh)) >= RESOURCE_REFRESH_RATE {
		lib.last_refresh = time.now()

		if .Hot_Reload_Shaders in lib.flags {
			reload_shader: for shader_res in lib.shaders {
				loader := shader_res.loader.(Shader_Loader)
				shader := shader_res.data.(^Shader)
				if loader.kind == .File {
					check_stages: for stage in Shader_Stage {
						if stage in shader.stages {
							stage_loader := loader.stages[stage].?
							stat, err := os.stat(stage_loader.file_path, context.temp_allocator)
							if err != os.ERROR_NONE {
								log.errorf(
									"[%s]: Failed to reload shader: %s",
									App_Module.IO,
									stage_loader.file_path,
								)
								continue
							}

							load_time_diff := time.diff(
								shader_res.load_time,
								stat.modification_time,
							)
							if time.duration_seconds(load_time_diff) > 0 {
								recompile_shader_from_file(shader, loader)
								shader_res.data = shader
								shader_res.load_time = stat.modification_time
								continue reload_shader
							}
						}
					}
				}
			}
		}
	}
}

close_library :: proc(lib: ^Resource_Library) {
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	for r in lib.buffers {
		free_resource(r)
	}
	delete(lib.buffers)

	for r in lib.attributes {
		free_resource(r)
	}
	delete(lib.attributes)

	for r in lib.textures {
		free_resource(r)
	}
	delete(lib.textures)

	for r in lib.shaders {
		free_resource(r)
	}
	delete(lib.shaders)

	for name, r in lib.shader_specs {
		delete(name)
		free_resource(r)
	}
	delete(lib.shader_specs)

	for r in lib.fonts {
		free_resource(r)
	}
	delete(lib.fonts)

	for name, r in lib.framebuffers {
		free_resource(r)
		delete(name)
	}
	delete(lib.framebuffers)

	for r in lib.meshes {
		free_resource(r)
	}
	delete(lib.meshes)

	for _, r in lib.materials {
		free_resource(r)
	}
	delete(lib.meshes)

	for _, r in lib.animations {
		free_resource(r)
	}
	delete(lib.animations)

	for _, r in lib.scenes {
		free_resource(r)
	}
	delete(lib.scenes)

	free_all(lib.allocator)
}

@(private)
new_resource :: proc(lib: ^Resource_Library, data: Resource_Data) -> ^Resource {
	resource := new(Resource)
	resource^ = Resource {
		id        = len(lib.buffers),
		load_time = time.now(),
		data      = data,
	}
	return resource
}

raw_buffer_resource :: proc(size: int) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	buf := new_clone(internal_make_raw_buffer(size))
	resource := new_resource(lib, buf)

	append(&lib.buffers, resource)
	return resource
}

attributes_resource :: proc(layout: Attribute_Layout, format: Attribute_Format) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(internal_make_attributes(layout, format))
	resource := new_resource(lib, data)

	append(&lib.attributes, resource)
	return resource
}

texture_resource :: proc(loader: Texture_Loader) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data: Resource_Data
	switch i in loader.info {
	case File_Texture_Info:
		data = new_clone(internal_load_texture_from_file(loader))
	case Byte_Texture_Info:
		if i.bitmap {
			data = new_clone(internal_load_texture_from_bitmap(loader))
		} else {
			data = new_clone(internal_load_texture_from_bytes(loader))
		}
	case File_Cubemap_Info:
		data = new_clone(internal_load_cubemap_from_files(loader))
	case Byte_Cubemap_Info:
		data = new_clone(internal_load_cubemap_from_bytes(loader))
	}
	resource := new_resource(lib, data)

	append(&lib.textures, resource)
	return resource
}

shader_resource :: proc(loader: Shader_Loader) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	begin_temp_allocation()
	defer end_temp_allocation()
	data: Resource_Data
	switch loader.kind {
	case .Byte:
		data = new_clone(internal_load_shader_from_bytes(loader))
	case .File:
		data = new_clone(internal_load_shader_from_file(loader))
	}

	resource := new_resource(lib, data)
	resource.loader = loader

	append(&lib.shaders, resource)
	return resource
}

shader_specialization_resource :: proc(name: string, shader: ^Shader) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(make_shader_specialization(shader))
	resource := new_resource(lib, data)

	n := strings.clone(name)
	lib.shader_specs[n] = resource
	return resource
}

font_resource :: proc(loader: Font_Loader) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(internal_load_font(loader))
	resource := new_resource(lib, data)

	append(&lib.fonts, resource)
	return resource
}

framebuffer_resource :: proc(loader: Framebuffer_Loader) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(internal_make_framebuffer(loader))
	resource := new_resource(lib, data)

	name := strings.clone(loader.name)

	lib.framebuffers[name] = resource
	return resource
}

mesh_resource :: proc(loader: Mesh_Loader) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(internal_load_mesh_from_slice(loader))
	resource := new_resource(lib, data)

	append(&lib.meshes, resource)
	return resource
}

material_resource :: proc(loader: Material_Loader) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(internal_load_empty_material(loader))
	resource := new_resource(lib, data)

	lib.materials[data.name] = resource
	return resource
}

animation_resource :: proc(loader: Animation_Loader) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(internal_load_empty_animation(loader))
	resource := new_resource(lib, data)

	lib.animations[data.name] = resource
	return resource
}

scene_resource :: proc(name: string, flags: Scene_Flags) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new(Scene)
	data.flags = flags
	init_scene(data)
	resource := new_resource(lib, data)

	lib.scenes[data.name] = resource
	return resource
}

clone_mesh_resource :: proc(mesh: ^Mesh) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(mesh^)
	resource := new_resource(lib, data)

	append(&lib.meshes, resource)
	return resource
}

free_resource :: proc(resource: ^Resource, remove := false) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	switch r in resource.data {
	case ^Buffer:
		destroy_buffer(r)
		if remove {
			ordered_remove(&lib.buffers, resource.id)
		}
		free(r)
	case ^Attributes:
		destroy_attributes(r)
		if remove {
			ordered_remove(&lib.attributes, resource.id)
		}
		free(r)
	case ^Texture:
		destroy_texture(r)
		if remove {
			ordered_remove(&lib.textures, resource.id)
		}
		free(r)
	case ^Shader:
		destroy_shader(r)
		if remove {
			ordered_remove(&lib.shaders, resource.id)
		}
		free(r)
	case ^Shader_Specialization:
		for stage in Shader_Stage {
			if r[stage] != nil {
				delete(r[stage])
			}
		}
		free(r)

	case ^Font:
		destroy_font(r)
		if remove {
			ordered_remove(&lib.fonts, resource.id)
		}
		free(r)
	case ^Framebuffer:
		destroy_framebuffer(r)
		if remove {
			ordered_remove(&lib.framebuffers, resource.id)
		}
		free(r)
	case ^Mesh:
		destroy_mesh(r)
		if remove {
			ordered_remove(&lib.meshes, resource.id)
		}
		free(r)

	case ^Material:
		destroy_material(r)
		free(r)

	case ^Animation:
		destroy_animation(r)
		free(r)

	case ^Scene:
		destroy_scene(r)
		free(r)
	}
	free(resource)
}

buffer_memory_from_buffer_resource :: proc(resource: ^Resource) -> Buffer_Memory {
	buffer := resource.data.(^Buffer)
	memory := Buffer_Memory {
		buf    = buffer,
		size   = buffer.size,
		offset = 0,
	}
	return memory
}

// glTF resource loading
load_resources_from_gltf :: proc(document: ^gltf.Document) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator
	// for t in document.textures {
	// 	load_texture_from_gltf(t)
	// }
	for m in document.materials {
		load_material_from_gltf(m)
	}
	for a, i in document.animations {
		name: string
		if a.name == "" {
			name = fmt.tprintf("animation%d", i)
		} else {
			name = a.name
		}
		load_animation_from_gltf(name, a)
	}
}


// Searching procedures
@(private)
attributes_from_layout :: proc(
	layout: Attribute_Layout,
	format: Attribute_Format,
) -> (
	result: ^Attributes,
) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	for resource in lib.attributes {
		attributes := resource.data.(^Attributes)
		if attribute_layout_equal(layout, attributes) {
			return attributes
		}
	}
	resource := attributes_resource(layout, format)
	attributes := resource.data.(^Attributes)
	return attributes
}

shader_from_name :: proc(name: string) -> (result: ^Shader, exist: bool) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	for resource in lib.shaders {
		shader := resource.data.(^Shader)
		if shader.name == name {
			result = shader
			exist = true
			return
		}
	}
	return
}

shader_specialization_from_name :: proc(
	name: string,
) -> (
	result: ^Shader_Specialization,
	exist: bool,
) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	if spec_res, _exist := lib.shader_specs[name]; _exist {
		result = spec_res.data.(^Shader_Specialization)
		exist = true
	}

	return
}

framebuffer_from_name :: proc(name: string) -> (result: ^Framebuffer, exist: bool) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	resource: ^Resource
	resource, exist = lib.framebuffers[name]
	result = resource.data.(^Material)
	return
}

material_from_name :: proc(name: string) -> (result: ^Material, exist: bool) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	resource: ^Resource
	resource, exist = lib.materials[name]
	result = resource.data.(^Material)
	return
}

texture_from_name :: proc(name: string) -> (result: ^Texture) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	for resource in lib.textures {
		texture := resource.data.(^Texture)
		if texture.name == name {
			result = texture
			return
		}
	}
	return
}

animation_from_name :: proc(name: string) -> (result: ^Animation, exist: bool) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	resource: ^Resource
	resource, exist = lib.animations[name]
	result = resource.data.(^Animation)
	return
}
