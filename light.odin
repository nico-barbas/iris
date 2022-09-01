package iris

import "core:math/linalg"

Light :: struct {
	kind:            Light_Kind,
	projection:      Matrix4,
	projection_view: Matrix4,
	data:            Light_Data,
}

Light_ID :: distinct int

Light_Kind :: enum {
	Directional,
	Point,
}

Light_Data :: struct {
	on:          uint,
	_on_padding: uint,
	position:    Vector4,
	color:       Color,
}

@(private)
compute_light_projection :: proc(light: ^Light, view_target: Vector3) {
	light_view := linalg.matrix4_look_at_f32(light.data.position.xyz, view_target, VECTOR_UP)
	light.projection_view = linalg.matrix_mul(light.projection, light_view)
}
