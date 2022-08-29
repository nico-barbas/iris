package iris

import "core:math/linalg"
import gl "vendor:OpenGL"

Vector2 :: linalg.Vector2f32
Vector3 :: linalg.Vector3f32
VECTOR_ZERO :: Vector3{0, 0, 0}
VECTOR_UP :: Vector3{0, 1, 0}
VECTOR_ONE :: Vector3{1, 1, 1}

Quaternion :: linalg.Quaternionf32
Matrix4 :: linalg.Matrix4f32

Transform :: struct {
	translation: Vector3,
	rotation:    Quaternion,
	scale:       Vector3,
}

transform :: proc(t := VECTOR_ZERO, r := Quaternion(1), s := VECTOR_ONE) -> Transform {
	return {translation = t, rotation = r, scale = s}
}


set_viewport :: proc(width, height: int) {
	gl.Viewport(0, 0, i32(width), i32(height))
}

// clear_viewport :: proc(clr: Color) {

// }

Material :: struct {
	shader:   Shader,
	maps:     Material_Maps,
	textures: [len(Material_Map)]Texture,
}

Material_Maps :: distinct bit_set[Material_Map]

Material_Map :: enum byte {
	Diffuse,
}

set_material_map :: proc(material: ^Material, kind: Material_Map, texture: Texture) {
	if kind not_in material.maps {
		material.maps += {kind}
	}
	material.textures[kind] = texture
}

destroy_material :: proc(material: ^Material) {
	if material.shader.handle != 0 {
		destroy_shader(&material.shader)
	}
	for kind in Material_Map {
		if kind in material.maps {
			destroy_texture(&material.textures[kind])
		}
	}
}
