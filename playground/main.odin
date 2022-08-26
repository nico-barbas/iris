package main

import "core:mem"
import "core:fmt"
// import "core:math"
import "core:math/linalg"
import iris "../"

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	iris.init_app(
		&iris.App_Config{
			width = 800,
			height = 600,
			title = "Small World",
			decorated = true,
			asset_dir = "assets/",
			data = iris.App_Data(&Game{}),
			init = init,
			update = update,
			draw = draw,
			close = close,
		},
	)
	iris.run_app()
	iris.close_app()

	if len(track.allocation_map) > 0 {
		fmt.printf("Leaks:")
		for _, v in track.allocation_map {
			fmt.printf("\t%v\n\n", v)
		}
	}
	fmt.printf("Leak count: %d\n", len(track.allocation_map))
	if len(track.bad_free_array) > 0 {
		fmt.printf("Bad Frees:")
		for v in track.bad_free_array {
			fmt.printf("\t%v\n\n", v)
		}
	}
}

Game :: struct {
	vertices:   iris.Buffer,
	indices:    iris.Buffer,
	attributes: iris.Attributes_State,
	texture:    iris.Texture,
	shader:     iris.Shader,

	// Projection stuff
	projection: iris.Matrix4,
	view:       iris.Matrix4,
	model:      iris.Matrix4,
}

// quad_vertices := [?]f32{
// 	-0.5, -0.5, -0.5,  0.0, 0.0,
//      0.5, -0.5, -0.5,  1.0, 0.0,
//      0.5,  0.5, -0.5,  1.0, 1.0,
//      0.5,  0.5, -0.5,  1.0, 1.0,
//     -0.5,  0.5, -0.5,  0.0, 1.0,
//     -0.5, -0.5, -0.5,  0.0, 0.0,

//     -0.5, -0.5,  0.5,  0.0, 0.0,
//      0.5, -0.5,  0.5,  1.0, 0.0,
//      0.5,  0.5,  0.5,  1.0, 1.0,
//      0.5,  0.5,  0.5,  1.0, 1.0,
//     -0.5,  0.5,  0.5,  0.0, 1.0,
//     -0.5, -0.5,  0.5,  0.0, 0.0,

//     -0.5,  0.5,  0.5,  1.0, 0.0,
//     -0.5,  0.5, -0.5,  1.0, 1.0,
//     -0.5, -0.5, -0.5,  0.0, 1.0,
//     -0.5, -0.5, -0.5,  0.0, 1.0,
//     -0.5, -0.5,  0.5,  0.0, 0.0,
//     -0.5,  0.5,  0.5,  1.0, 0.0,

//      0.5,  0.5,  0.5,  1.0, 0.0,
//      0.5,  0.5, -0.5,  1.0, 1.0,
//      0.5, -0.5, -0.5,  0.0, 1.0,
//      0.5, -0.5, -0.5,  0.0, 1.0,
//      0.5, -0.5,  0.5,  0.0, 0.0,
//      0.5,  0.5,  0.5,  1.0, 0.0,

//     -0.5, -0.5, -0.5,  0.0, 1.0,
//      0.5, -0.5, -0.5,  1.0, 1.0,
//      0.5, -0.5,  0.5,  1.0, 0.0,
//      0.5, -0.5,  0.5,  1.0, 0.0,
//     -0.5, -0.5,  0.5,  0.0, 0.0,
//     -0.5, -0.5, -0.5,  0.0, 1.0,

//     -0.5,  0.5, -0.5,  0.0, 1.0,
//      0.5,  0.5, -0.5,  1.0, 1.0,
//      0.5,  0.5,  0.5,  1.0, 0.0,
//      0.5,  0.5,  0.5,  1.0, 0.0,
//     -0.5,  0.5,  0.5,  0.0, 0.0,
//     -0.5,  0.5, -0.5,  0.0, 1.0,
// }
// quad_indices := [?]u32{
// 	0, 1, 2,
// 	2, 3, 0,
// }

init :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.set_key_proc(.Escape, on_escape_key)


	cube_v, cube_i := iris.cube_mesh(1, 1, 1)

	g.vertices = iris.make_buffer(f32, len(cube_v))
	iris.send_buffer_data(g.vertices, cube_v[:])
	g.indices = iris.make_buffer(u32, len(cube_i))
	iris.send_buffer_data(g.indices, cube_i[:])
	g.attributes = iris.make_attributes_state({.Float3, .Float2})
	iris.link_attributes_state_vertices(&g.attributes, g.vertices)
	iris.link_attributes_state_indices(&g.attributes, g.indices)
	g.texture = iris.load_texture_from_file("cube_texture.png")
	g.shader = iris.load_shader_from_bytes(VERTEX_SHADER, FRAGMENT_SHADER)

	texture_index := 0
	iris.set_shader_uniform(g.shader, "texture0", &texture_index)
	fmt.println(g.shader.uniforms)

	g.projection = linalg.matrix4_perspective_f32(
		f32(45),
		f32(800) / f32(600),
		f32(1),
		f32(100),
	)
	// g.projection = linalg.MATRIX4F32_IDENTITY
	// g.view = linalg.MATRIX4F32_IDENTITY
	g.view = linalg.MATRIX4F32_IDENTITY
	// g.model = linalg.MATRIX4F32_IDENTITY
	// g.model = linalg.matrix4_rotate_f32(math.to_radians_f32(90), {0, 0, 1})
	// g.view = linalg.matrix4_look_at_f32({0, 0, -2}, {0, 0, 0}, {0, 1, 0})
	// g.model = linalg.matrix_mul(
	// 	linalg.matrix4_rotate_f32(math.to_radians_f32(30), {1, 0, 1}),
	// 	linalg.matrix4_translate_f32({0, 0, -2}),
	// )
	// g.model = linalg.MATRIX4F32_IDENTITY
	g.model = linalg.matrix4_translate_f32({0, 0, -2})
}

update :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	mvp := linalg.matrix_mul(linalg.matrix_mul(g.projection, g.view), g.model)
	iris.set_shader_uniform(g.shader, "mvp", &mvp[0][0])
}

draw :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.bind_attributes_state(g.attributes)
	iris.bind_texture(&g.texture, 0)
	iris.bind_shader(g.shader)
	iris.draw_elements(36)
	iris.unbind_shader()
	iris.unbind_texture(&g.texture)
	iris.unbind_attributes_state()
}

close :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.destroy_buffer(&g.vertices)
	iris.destroy_buffer(&g.indices)
	iris.destroy_attributes_state(&g.attributes)
	iris.destroy_texture(&g.texture)
}

on_escape_key :: proc(data: iris.App_Data, state: iris.Key_State) {
	iris.close_app_on_next_frame()
}

VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 1) in vec2 attribTexCoord;

out vec2 fragTexCoord;

uniform mat4 mvp;

void main()
{
	fragTexCoord = attribTexCoord;

    gl_Position = mvp*vec4(attribPosition, 1.0);
}  
`
FRAGMENT_SHADER :: `
#version 450 core
in vec2 fragTexCoord;

out vec4 fragColor;

uniform sampler2D texture0;
  
void main()
{
    fragColor = texture(texture0, fragTexCoord);
}
`
