package main

import "core:mem"
import "core:fmt"
import "core:math"
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
	camera:   Camera,
	mesh:     iris.Mesh,
	material: iris.Material,
}

Camera :: struct {
	pitch:           f32,
	yaw:             f32,
	position:        iris.Vector3,
	target:          iris.Vector3,
	target_distance: f32,
	target_rotation: f32,
}

init :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.set_key_proc(.Escape, on_escape_key)


	cube_v, cube_i := iris.cube_mesh(1, 1, 1, context.temp_allocator)
	g.mesh = iris.load_mesh_from_slice(cube_v, cube_i, {.Float3, .Float2})
	g.material = {
		shader = iris.load_shader_from_bytes(VERTEX_SHADER, FRAGMENT_SHADER),
	}
	iris.set_material_map(
		&g.material,
		.Diffuse,
		iris.load_texture_from_file("cube_texture.png"),
	)

	g.camera = Camera {
		pitch = 45,
		target = {0, 0, 0},
		target_distance = 10,
		target_rotation = 0,
	}
	update_camera(&g.camera, {})
}

update :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	m_delta := iris.mouse_delta()
	m_right := iris.mouse_button_state(.Right)
	if .Pressed in m_right {
		update_camera(&g.camera, m_delta)
	}
}

update_camera :: proc(c: ^Camera, m_delta: iris.Vector2) {
	c.target_rotation += (m_delta.x * 0.5)
	c.pitch -= (m_delta.y * 0.5)

	pitch_in_rad := math.to_radians(c.pitch)
	target_rot_in_rad := math.to_radians(c.target_rotation)
	h_dist := c.target_distance * math.sin(pitch_in_rad)
	v_dist := c.target_distance * math.cos(pitch_in_rad)
	c.position = {
		c.target.x - (h_dist * math.cos(target_rot_in_rad)),
		c.target.y + (v_dist),
		c.target.z - (h_dist * math.sin(target_rot_in_rad)),
	}
	iris.view_position(c.position)
	iris.view_target(c.target)
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
	iris.destroy_material(&g.material)
}

on_escape_key :: proc(data: iris.App_Data, state: iris.Input_State) {
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
