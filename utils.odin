package iris

import "core:math"
import "core:math/rand"
import "core:math/linalg"
import gl "vendor:OpenGL"


import "gltf"

@(private)
draw_triangles :: proc(count: int, byte_offset: uintptr = 0, index_offset := 0) {
	gl.DrawElementsBaseVertex(
		gl.TRIANGLES,
		i32(count),
		gl.UNSIGNED_INT,
		rawptr(byte_offset),
		i32(index_offset),
	)
}

draw_instanced_triangles :: proc(
	count: int,
	instance_count: int,
	byte_offset: uintptr = 0,
	index_offset := 0,
) {
	gl.DrawElementsInstancedBaseVertex(
		gl.TRIANGLES,
		i32(count),
		gl.UNSIGNED_INT,
		rawptr(byte_offset),
		i32(instance_count),
		i32(index_offset),
	)
}

@(private)
draw_lines :: proc(count: int, byte_offset: uintptr = 0, index_offset := 0) {
	gl.DrawElementsBaseVertex(
		gl.LINES,
		i32(count),
		gl.UNSIGNED_INT,
		rawptr(byte_offset),
		i32(index_offset),
	)
}

set_viewport :: proc(r: Rectangle) {
	gl.Viewport(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
}

clip_mode_on :: proc() {
	gl.Enable(gl.SCISSOR_TEST)
}

clip_mode_off :: proc() {
	gl.Disable(gl.SCISSOR_TEST)
}

set_clip_rect :: proc(r: Rectangle) {
	h := i32(app.height)
	gl.Scissor(i32(r.x), h - i32(r.y + r.height), i32(r.width), i32(r.height))
}

default_clip_rect :: proc() {
	gl.Scissor(0, 0, i32(app.width), i32(app.height))
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

blend :: proc(on: bool) {
	if on {
		gl.Enable(gl.BLEND)
	} else {
		gl.Disable(gl.BLEND)
	}
}

depth :: proc(on: bool) {
	if on {
		gl.Enable(gl.DEPTH_TEST)
	} else {
		gl.Disable(gl.DEPTH_TEST)
	}
}

depth_mode :: proc(mode: Depth_Test_Mode) {
	gl.DepthFunc(u32(mode))
}

Depth_Test_Mode :: enum {
	Never         = 0x0200,
	Less          = 0x0201,
	Equal         = 0x0202,
	Less_Equal    = 0x0203,
	Greate        = 0x0204,
	Not_Equal     = 0x0205,
	Greater_Equal = 0x0206,
	Always        = 0x0207,
}

Vector2 :: linalg.Vector2f32
Vector3 :: linalg.Vector3f32
VECTOR_ZERO :: Vector3{0, 0, 0}
VECTOR_UP :: Vector3{0, 1, 0}
VECTOR_RIGHT :: Vector3{0, 0, 1}
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
	sx := linalg.vector_length(Vector3{m[0][0], m[0][1], m[0][2]})
	sy := linalg.vector_length(Vector3{m[1][0], m[1][1], m[1][2]})
	sz := linalg.vector_length(Vector3{m[2][0], m[2][1], m[2][2]})
	if determinant(m) < 0 {
		result.scale.x = -result.scale.x
	}

	result.translation = Vector3{m[3][0], m[3][1], m[3][2]}

	isx := 1 / sx
	isy := 1 / sy
	isz := 1 / sz

	_m := m
	_m[0][0] *= isx
	_m[0][1] *= isx
	_m[0][2] *= isx

	_m[1][0] *= isy
	_m[1][1] *= isy
	_m[1][2] *= isy

	_m[2][0] *= isz
	_m[2][1] *= isz
	_m[2][2] *= isz
	result.rotation = linalg.quaternion_from_matrix4_f32(_m)

	result.scale = {sx, sy, sz}
	return
}

translation_from_matrix :: proc(m: Matrix4) -> Vector3 {
	return Vector3{m[3][0], m[3][1], m[3][2]}
}

Color :: distinct [4]f32

Triangle :: [3]u32

Rectangle :: struct {
	x, y:          f32,
	width, height: f32,
}

in_rect_bounds :: proc(rect: Rectangle, p: Vector2) -> bool {
	ok :=
		(p.x >= rect.x && p.x <= rect.x + rect.width) &&
		(p.y >= rect.y && p.y <= rect.y + rect.height)
	return ok
}

Direction :: enum {
	Up,
	Right,
	Down,
	Left,
}

Timer :: struct {
	reset:    bool,
	duration: f32,
	time:     f32,
}

advance_timer :: proc(t: ^Timer, dt: f32) -> (finished: bool) {
	t.time += dt
	if t.time >= t.duration {
		finished = true
		if t.reset {
			t.time = 0
		}
	}
	return
}

Sample_Interface :: struct($Data, $Elem: typeid) {
	data:       Data,
	size:       [2]int,
	wrap:       Texture_Wrap_Mode,
	blend_proc: proc(v1, v2: Elem, t: f32) -> Elem,
	shape_proc: proc(t: f32) -> f32,
}

sample :: proc(it: $T/Sample_Interface($Data, $Elem), coord: Vector2) -> Elem {
	s := Vector2{f32(it.size.x), f32(it.size.y)}
	c := coord

	switch it.wrap {
	case .Clamp_To_Edge:
		c.x = clamp(c.x, 0, 1)
		c.y = clamp(c.y, 0, 1)
	case .Mirrored_Repeat, .Repeat:
		assert(false)
	}

	c *= s

	sample_x1 := min(int(math.floor(c.x)), it.size.x - 1)
	sample_x2 := min(int(math.ceil(c.x)), it.size.x - 1)
	sample_y1 := min(int(math.floor(c.y)), it.size.x - 1)
	sample_y2 := min(int(math.ceil(c.y)), it.size.x - 1)

	blend_x := it.shape_proc(c.x - math.floor(c.x))
	blend_y := it.shape_proc(c.y - math.floor(c.y))

	in_value_s1 := it.data[sample_y1 * it.size.x + sample_x1]
	in_value_s2 := it.data[sample_y1 * it.size.x + sample_x2]
	in_value_t1 := it.data[sample_y2 * it.size.x + sample_x1]
	in_value_t2 := it.data[sample_y2 * it.size.x + sample_x2]

	sample_s := it.blend_proc(in_value_s1, in_value_s2, blend_x)
	sample_t := it.blend_proc(in_value_t1, in_value_t2, blend_x)

	result := it.blend_proc(sample_s, sample_t, blend_y)
	return result
}

Sampling_Disk :: struct {
	data: []Vector2,
	size: int,
}

make_sampling_disk :: proc(size: int, allocator := context.allocator) -> (result: Sampling_Disk) {
	result = Sampling_Disk {
		data = make([]Vector2, size * size, allocator),
		size = size,
	}

	index := 0
	for v := size - 1; v >= 0; v -= 1 {
		for u in 0 ..< size {
			x := f32(u) + 0.5 + (rand.float32() - 0.5)
			y := f32(v) + 0.5 + (rand.float32() - 0.5)

			result.data[index] = Vector2{
				math.sqrt(y) * math.cos(2 * math.PI * x),
				math.sqrt(y) * math.sin(2 * math.PI * x),
			}
			index += 1
		}
	}

	return
}

Gltf_Task_Data :: struct {
	path:     string,
	format:   gltf.Format,
	document: gltf.Document,
	err:      gltf.Error,
}

parse_gltf_task_proc :: proc(task: Task) {
	data := cast(^Gltf_Task_Data)task.data

	data.document, data.err = gltf.parse_from_file(
		data.path,
		data.format,
		task.allocator,
		task.allocator,
	)
}

DEBUG_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 6) in vec4 attribColor;

out VS_OUT {
	vec4 color;
} frag;

layout (std140, binding = 0) uniform ContextData {
    mat4 projView;
    mat4 matProj;
    mat4 matView;
    vec3 viewPosition;
    float time;
    float dt;
};

void main() {
	frag.color = attribColor;

	gl_Position = projView * vec4(attribPosition, 1.0);
}
`
DEBUG_FRAGMENT_SHADER :: `
#version 450 core
out vec4 finalColor;

in VS_OUT {
	vec4 color;
} frag;

void main() {
	finalColor = vec4(1, 0, 0, 1);
}
`
