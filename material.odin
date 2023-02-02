package iris

import "core:strings"
import "gltf"

MATERIAL_CACHE_CAP :: 124

Material_Cache :: struct {
	previous_count: int,
	count:          int,
	uniform_memory: Buffer_Memory,
}

@(private)
Material_Cache_Uniform_Data :: struct {
	materials: [MATERIAL_CACHE_CAP]Material_Desc,
	count:     u32,
	_padding:  [3]u32,
}

init_material_cache :: proc(cache: ^Material_Cache) {
	uniform_res := raw_buffer_resource(size_of(Material_Cache_Uniform_Data))
	cache.uniform_memory = buffer_memory_from_buffer_resource(uniform_res)
	set_uniform_buffer_binding(cache.uniform_memory.buf, u32(Render_Uniform_Kind.Material_Cache))
}

refresh_material_cache :: proc(cache: ^Material_Cache) {
	lib := &app.library

	cache.previous_count = cache.count
	cache.count = len(lib.materials)

	if cache.count != cache.previous_count {
		cache_data: Material_Cache_Uniform_Data
		cache_data.count = u32(cache.count)

		cache_id: u32 = 1
		for _, m in app.library.materials {
			material := m.data.(^Material)
			material.cache_id = cache_id
			cache_data.materials[cache_id] = material.pbr
			cache_id += 1
		}

		send_buffer_data(
			&cache.uniform_memory,
			Buffer_Source{
				data = &cache_data,
				byte_size = size_of(Material_Cache_Uniform_Data),
				accessor = Buffer_Data_Accessor{kind = .Byte, format = .Unspecified},
			},
		)
	}
}

Material :: struct {
	name:           string,
	cache_id:       u32,
	shader:         ^Shader,
	specialization: ^Shader_Specialization,
	maps:           Material_Maps,
	textures:       [len(Material_Map)]^Texture,
	double_face:    bool,
	pbr:            Material_Desc,
}

Material_Desc :: struct {
	base_color:   Color,
	roughness:    f32,
	metallicness: f32,
	_padding:     [2]f32,
}

Material_Loader :: struct {
	name:           string,
	shader:         ^Shader,
	specialization: ^Shader_Specialization,
	double_face:    bool,
	pbr:            Material_Desc,
}

Material_Maps :: distinct bit_set[Material_Map]

Material_Map :: enum byte {
	Diffuse0 = 0,
	Diffuse1 = 1,
	Normal0  = 2,
}

material_map_name := map[Material_Map]string {
	.Diffuse0 = "mapDiffuse0",
	.Diffuse1 = "mapDiffuse1",
	.Normal0  = "mapNormal0",
}

@(private)
internal_load_empty_material :: proc(loader: Material_Loader) -> Material {
	material := Material {
		name           = strings.clone(loader.name),
		shader         = loader.shader,
		specialization = loader.specialization,
		double_face    = loader.double_face,
		pbr            = loader.pbr,
	}
	return material
}

load_material_from_gltf :: proc(m: gltf.Material) -> ^Material {
	loader := Material_Loader {
		name = m.name,
	}
	resource := material_resource(loader)
	material := resource.data.(^Material)
	if m.base_color_texture.present {
		base_texture := load_texture_from_gltf(m.base_color_texture.texture^, .sRGB)
		set_material_map(material, .Diffuse0, base_texture)
	}
	if m.normal_texture.present {
		normal_texture := load_texture_from_gltf(m.normal_texture.texture^, .Linear)
		set_material_map(material, .Normal0, normal_texture)
	}
	material.pbr.base_color = Color(m.base_color_factor)
	material.pbr.roughness = m.roughness_factor
	material.pbr.metallicness = m.metallic_factor
	return material
}

set_material_map :: proc(material: ^Material, kind: Material_Map, texture: ^Texture) {
	if kind not_in material.maps {
		material.maps += {kind}
	}
	material.textures[kind] = texture
}

destroy_material :: proc(material: ^Material) {
	delete(material.name)
}
