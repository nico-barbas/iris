package iris

import "core:strings"
import "gltf"

Material :: struct {
	name:           string,
	shader:         ^Shader,
	specialization: ^Shader_Specialization,
	maps:           Material_Maps,
	textures:       [len(Material_Map)]^Texture,
	double_face:    bool,
	data:           Material_Data,
}

Material_Data :: struct {
	base_color:   Color,
	roughness:    f32,
	metallicness: f32,
}

Material_Loader :: struct {
	name:           string,
	shader:         ^Shader,
	specialization: ^Shader_Specialization,
	double_face:    bool,
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
