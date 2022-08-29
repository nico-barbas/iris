package main

import "core:mem"
import "core:fmt"
// import "core:math"
// import "core:math/linalg"
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
	mesh:     iris.Mesh,
	material: iris.Material,
}

init :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.set_key_proc(.Escape, on_escape_key)


	cube_v, cube_i := iris.cube_mesh(1, 1, 1, context.temp_allocator)
	g.mesh = iris.load_mesh_from_slice(cube_v, cube_i, {.Float3, .Float2})
	g.material = {
		shader = iris.load_shader_from_bytes(VERTEX_SHADER, FRAGMENT_SHADER),
	}
	iris.set_material_map(&g.material, .Diffuse, iris.load_texture_from_file("cube_texture.png"))
	// fmt.println(g.material)

	iris.view_position({10, 2, 10})
	iris.view_target({0, 0, 0})
}

update :: proc(data: iris.App_Data) {
	// g := cast(^Game)data
}

draw :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.start_render()
	{
		iris.draw_mesh(g.mesh, iris.transform(), g.material)
	}
	iris.end_render()
}

close :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.destroy_mesh(g.mesh)
	iris.destroy_texture(g.material.textures[0])
	iris.destroy_shader(g.material.shader)
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
