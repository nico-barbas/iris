package iris

import "core:log"
import "core:os"
import "core:fmt"
import "core:mem"
import "core:time"
import "core:intrinsics"
import "allocators"
import "gltf"
import "helios"

Resource_Library :: struct {
	free_list:        allocators.Free_List_Allocator,
	allocator:        mem.Allocator,
	temp_allocator:   mem.Allocator,
	shader_documents: map[string]helios.Document,
	buffers:          [dynamic]^Resource,
	attributes:       [dynamic]^Resource,
	textures:         [dynamic]^Resource,
	shaders:          [dynamic]^Resource,
	fonts:            [dynamic]^Resource,
	framebuffers:     [dynamic]^Resource,
	meshes:           [dynamic]^Resource,
	materials:        map[string]^Resource,
	animations:       map[string]^Resource,
	scenes:           map[string]^Resource,
}

Resource :: struct {
	id:        int,
	load_time: time.Time,
	data:      Resource_Data,
}

Resource_Data :: union {
	^Buffer,
	^Attributes,
	^Texture,
	^Shader,
	^Font,
	^Framebuffer,
	^Mesh,
	^Material,
	^Animation,
	^Scene,
}

Resource_Loader :: union {
	Texture_Loader,
}

init_library :: proc(lib: ^Resource_Library) {
	DEFAULT_ALLOCATOR_SIZE :: mem.Megabyte * 400
	buf := make([]byte, DEFAULT_ALLOCATOR_SIZE, context.allocator)
	allocators.init_free_list_allocator(&lib.free_list, buf, .Find_Best, 8)
	lib.allocator = allocators.free_list_allocator(&lib.free_list)
	lib.temp_allocator = context.temp_allocator

	lib.shader_documents.allocator = lib.allocator
	lib.buffers.allocator = lib.allocator
	lib.attributes.allocator = lib.allocator
	lib.textures.allocator = lib.allocator
	lib.shaders.allocator = lib.allocator
	lib.fonts.allocator = lib.allocator
	lib.framebuffers.allocator = lib.allocator
	lib.meshes.allocator = lib.allocator
	lib.materials.allocator = lib.allocator
	lib.animations.allocator = lib.allocator
	lib.scenes.allocator = lib.allocator
}

close_library :: proc(lib: ^Resource_Library) {
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	for r in lib.buffers {
		free_resource(r)
	}
	delete(lib.framebuffers)

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

	for r in lib.fonts {
		free_resource(r)
	}
	delete(lib.fonts)

	for r in lib.framebuffers {
		free_resource(r)
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

	for _, document in lib.shader_documents {
		helios.destroy(document)
	}
	delete(lib.shader_documents)
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

	data: Resource_Data
	switch l in loader {
	case Shader_Builder:
		if l.document == nil && l.document_name != "" {
			if l.document_name in lib.shader_documents {
				builder := l
				builder.document = &lib.shader_documents[l.document_name]
				data = new_clone(internal_build_shader(builder))
			} else {
				log.errorf("[%s]: Invalid document name: %s", App_Module.IO, l.document_name)
			}
		} else {
			log.errorf(
				"[%s]: Invalid Shader Builder settings:\n\tDetails: Both the document and the document name are nil",
				App_Module.IO,
			)
			unreachable()
		}
	case Raw_Shader_Loader:
		switch l.kind {
		case .Byte:
			data = new_clone(internal_load_shader_from_bytes(l))
		case .File:
			data = new_clone(internal_load_shader_from_file(l))
		}
	}

	resource := new_resource(lib, data)

	append(&lib.shaders, resource)
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

	append(&lib.framebuffers, resource)
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

load_shader_document :: proc(file_path: string) {
	lib := &app.library
	begin_temp_allocation()

	lib_source, read_ok := os.read_entire_file(file_path, context.temp_allocator)
	if !read_ok {
		log.fatalf(
			"[%s]: Failed to read shader library from filepath: %s",
			App_Module.IO,
			file_path,
		)
		intrinsics.trap()
	}

	shader_document, parse_err := helios.parse(file_path, lib_source, lib.allocator)
	if parse_err != nil {
		log.fatalf(
			"[%s]: Failed to parse shader library: %s\n\tDetails: %#v",
			App_Module.IO,
			file_path,
			parse_err,
		)
		intrinsics.trap()
	}
	lib.shader_documents[file_path] = shader_document

	end_temp_allocation()
}

// load_shaders_from_dir :: proc(dir: string) {
// 	lib := &app.library
// 	context.allocator = lib.allocator
// 	context.temp_allocator = lib.temp_allocator

// 	matches, glob_err := filepath.glob(fmt.tprintf("%s/*", dir), context.temp_allocator)

// 	if glob_err != nil {
// 		log.fatalf("%s: Failed to load Shaders from directory %s", App_Module.Shader, dir)
// 		assert(false)
// 	}
// 	for path in matches {
// 		if !strings.has_suffix(path, ".shader") {
// 			continue
// 		}
// 		output, err := aether.split_shader_stages(path, context.temp_allocator)

// 		if err != .None {
// 			log.errorf("%s: [%s] Failed to load shader %s", App_Module.IO, err, path)
// 			continue
// 		}

// 		loader := Shader_Loader {
// 			name = filepath.stem(path),
// 			kind = .Byte,
// 			stages = {
// 				Shader_Stage.Vertex = Shader_Stage_Loader{
// 					source = aether.stage_source(&output, .Vertex),
// 				},
// 				Shader_Stage.Fragment = Shader_Stage_Loader{
// 					source = aether.stage_source(&output, .Fragment),
// 				},
// 			},
// 		}
// 		shader_resource(loader)
// 	}
// }


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
