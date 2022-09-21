package iris

import "core:math/linalg"

Lighting_Context :: struct {
	count:             u32,
	projection:        Matrix4,
	lights:            [RENDER_CTX_MAX_LIGHTS]Light_Info,
	lights_projection: [RENDER_CTX_MAX_LIGHTS]Matrix4,
	ambient:           Color,
}

Light_Info :: struct {
	position:  Vector4,
	color:     Color,
	linear:    f32,
	quadratic: f32,
	kind:      Light_Kind,
}

Light_ID :: distinct int

Light_Kind :: enum u32 {
	Directional,
	Point,
}

@(private)
compute_light_projection :: proc(ctx: ^Lighting_Context, index: int, view_target: Vector3) {
	light := ctx.lights[index]
	light_view := linalg.matrix4_look_at_f32(light.position.xyz, view_target, VECTOR_UP)
	ctx.lights_projection[index] = linalg.matrix_mul(ctx.projection, light_view)
}
