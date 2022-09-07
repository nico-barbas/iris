package iris

import "core:math/linalg"
import gl "vendor:OpenGL"

@(private)
draw_triangles :: proc(count: int) {
	gl.DrawElements(gl.TRIANGLES, i32(count), gl.UNSIGNED_INT, nil)
}

set_backface_culling :: proc(on: bool) {
	if on {
		gl.Enable(gl.CULL_FACE)
		gl.CullFace(gl.BACK)
	} else {
		gl.Disable(gl.CULL_FACE)
	}
}

set_frontface_culling :: proc(on: bool) {
	if on {
		gl.Enable(gl.CULL_FACE)
		gl.CullFace(gl.FRONT)
	} else {
		gl.Disable(gl.CULL_FACE)
	}
}

Vector2 :: linalg.Vector2f32
Vector3 :: linalg.Vector3f32
VECTOR_ZERO :: Vector3{0, 0, 0}
VECTOR_UP :: Vector3{0, 1, 0}
VECTOR_ONE :: Vector3{1, 1, 1}

Vector4 :: linalg.Vector4f32

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

transform_from_matrix :: proc(m: Matrix4) -> (result: Transform) {
	result.translation = Vector3{m[3][0], m[3][1], m[3][2]}
	result.rotation = linalg.quaternion_from_matrix4_f32(m)
	result.scale = Vector3 {
		0 = linalg.vector_length(Vector3{m[0][0], m[1][0], m[2][0]}),
		1 = linalg.vector_length(Vector3{m[0][1], m[1][1], m[2][1]}),
		2 = linalg.vector_length(Vector3{m[0][2], m[1][2], m[2][2]}),
	}
	if determinant(m) < 0 {
		result.scale.x = -result.scale.x
	}
	return
}


set_viewport :: proc(width, height: int) {
	gl.Viewport(0, 0, i32(width), i32(height))
}

// clear_viewport :: proc(clr: Color) {

// }

Color :: distinct [4]f32


Rectangle :: struct {
	x, y:          f32,
	width, height: f32,
}
