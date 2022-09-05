package iris

import "core:mem"
import "core:time"
import "allocators"
import "gltf"

Resource_Library :: struct {
	free_list:      allocators.Free_List_Allocator,
	allocator:      mem.Allocator,
	temp_allocator: mem.Allocator,
	buffers:        [dynamic]^Resource,
	attributes:     [dynamic]^Resource,
	textures:       [dynamic]^Resource,
	shaders:        [dynamic]^Resource,
	fonts:          [dynamic]^Resource,
	framebuffers:   [dynamic]^Resource,
	meshes:         [dynamic]^Resource,
	materials:      map[string]^Resource,
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
}

Resource_Loader :: union {
	Texture_Loader,
}

init_library :: proc(lib: ^Resource_Library) {
	DEFAULT_ALLOCATOR_SIZE :: mem.Megabyte * 300
	buf := make([]byte, DEFAULT_ALLOCATOR_SIZE, context.allocator)
	allocators.init_free_list_allocator(&lib.free_list, buf, .Find_Best, 8)
	lib.allocator = allocators.free_list_allocator(&lib.free_list)
	lib.temp_allocator = context.temp_allocator

	lib.buffers.allocator = lib.allocator
	lib.attributes.allocator = lib.allocator
	lib.textures.allocator = lib.allocator
	lib.shaders.allocator = lib.allocator
	lib.fonts.allocator = lib.allocator
	lib.framebuffers.allocator = lib.allocator
	lib.meshes.allocator = lib.allocator
	lib.materials.allocator = lib.allocator
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

raw_buffer_resource :: proc(size: int, reserve := false) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	buf := new_clone(internal_make_raw_buffer(size, reserve))
	resource := new_resource(lib, buf)

	append(&lib.buffers, resource)
	return resource
}

typed_buffer_resource :: proc($T: typeid, cap: int, reserve := false) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(internal_make_typed_buffer(T, cap, reserve))
	resource := new_resource(lib, data)

	append(&lib.buffers, resource)
	return resource
}

attributes_resource :: proc(layout: Vertex_Layout, format: Attribute_Format) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data := new_clone(internal_make_attributes(layout, format))
	resource := new_resource(lib, data)

	append(&lib.attributes, resource)
	return resource
}

texture_resource :: proc(loader: Texture_Loader, is_bitmap := false) -> ^Resource {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	data: Resource_Data
	if loader.data == nil {
		data = new_clone(internal_load_texture_from_file(loader))
	} else {
		if is_bitmap {
			data = new_clone(internal_load_texture_from_bitmap(loader))
		} else {
			data = new_clone(internal_load_texture_from_bytes(loader))
		}
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
	if loader.vertex_source != "" && loader.fragment_source != "" {
		data = new_clone(internal_load_shader_from_bytes(loader))
	} else if loader.vertex_path != "" && loader.fragment_path != "" {
		data = new_clone(internal_load_shader_from_file(loader))
	} else {
		unreachable()
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

free_resource :: proc(resource: ^Resource, remove := false) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	switch r in resource.data {
	case ^Buffer:
		destroy_buffer(r)
		if remove {
			unordered_remove(&lib.buffers, resource.id)
		}
		free(r)
	case ^Attributes:
		destroy_attributes(r)
		if remove {
			unordered_remove(&lib.attributes, resource.id)
		}
		free(r)
	case ^Texture:
		destroy_texture(r)
		if remove {
			unordered_remove(&lib.textures, resource.id)
		}
		free(r)
	case ^Shader:
		destroy_shader(r)
		if remove {
			unordered_remove(&lib.shaders, resource.id)
		}
		free(r)
	case ^Font:
		destroy_font(r)
		if remove {
			unordered_remove(&lib.fonts, resource.id)
		}
		free(r)
	case ^Framebuffer:
		destroy_framebuffer(r)
		if remove {
			unordered_remove(&lib.framebuffers, resource.id)
		}
		free(r)
	case ^Mesh:
		destroy_mesh(r)
		if remove {
			unordered_remove(&lib.meshes, resource.id)
		}
		free(r)

	case ^Material:
		destroy_material(r)
		free(r)
	}
	free(resource)
}

// glTF resource loading
load_resources_from_gltf :: proc(document: ^gltf.Document) {
	for t in document.textures {
		load_texture_from_gltf(t)
	}
	for m in document.materials {
		load_material_from_gltf(m)
	}
}

// Searching procedures
@(private)
attributes_from_layout :: proc(layout: Vertex_Layout, format: Attribute_Format) -> (result: ^Attributes) {
	lib := &app.library
	context.allocator = lib.allocator
	context.temp_allocator = lib.temp_allocator

	for resource in lib.attributes {
		attributes := resource.data.(^Attributes)
		if vertex_layout_equal(layout, attributes.layout) {
			return attributes
		}
	}
	resource := attributes_resource(layout, format)
	attributes := resource.data.(^Attributes)
	return attributes
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
			return texture
		}
	}
	return nil
}
