package main

import "core:mem"
import "core:fmt"
import "core:math"
import iris "../"
import gltf "../gltf"

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
	camera:        Camera,
	light:         Light,
	mesh:          iris.Mesh,
	model:         iris.Model,
	ground_mesh:   iris.Mesh,
	material:      iris.Material,
	delta:         f32,
	flat_material: iris.Material,
}

Camera :: struct {
	pitch:           f32,
	yaw:             f32,
	position:        iris.Vector3,
	target:          iris.Vector3,
	target_distance: f32,
	target_rotation: f32,
}

Light :: struct {
	position:     iris.Vector3,
	ambient_clr:  iris.Color,
	diffuse_clr:  iris.Color,
	specular_clr: iris.Color,
}

init :: proc(data: iris.App_Data) {
	g := cast(^Game)data

	doc, err := gltf.parse_from_file("lantern/lantern.gltf", .Gltf_External)
	iris.load_textures_from_gltf(&doc)
	iris.load_materials_from_gltf(&doc)
	assert(err == nil)
	root := doc.root.nodes[0]

	shader := iris.load_shader_from_bytes(VERTEX_SHADER, FRAGMENT_SHADER)
	g.model = iris.load_model_from_gltf_node(
		loader = &iris.Model_Loader{
			document = &doc,
			shader = shader,
			allocator = context.allocator,
			temp_allocator = context.temp_allocator,
		},
		node = root,
	)

	iris.set_key_proc(.Escape, on_escape_key)


	cube_v, cube_i, l_map := iris.cube_mesh(1, 1, 1, context.allocator, context.temp_allocator)
	g.mesh = iris.load_mesh_from_slice(cube_v, cube_i, l_map)

	{
		ground_v, ground_i, ground_layout := iris.plane_mesh(10, 10, 3, 3)
		g.ground_mesh = iris.load_mesh_from_slice(ground_v, ground_i, ground_layout)
	}

	g.material = {
		shader = shader,
	}
	iris.set_material_map(&g.material, .Diffuse, iris.load_texture_from_file("cube_texture.png"))
	{
		ambient_strength: f32 = 0.4
		iris.set_shader_uniform(g.material.shader, "light.ambientStr", &ambient_strength)
		iris.set_shader_uniform(g.material.shader, "light.position", &iris.Vector3{2, 3, 2})
		iris.set_shader_uniform(g.material.shader, "light.ambientClr", &iris.Vector3{0.45, 0.45, 0.75})
		iris.set_shader_uniform(g.material.shader, "light.diffuseClr", &iris.Vector3{1, 1, 1})
		iris.set_shader_uniform(g.material.shader, "light.specularClr", &iris.Vector3{0.0, 0.2, 0.45})
	}

	g.flat_material = {
		shader = iris.load_shader_from_bytes(FLAT_VERTEX_SHADER, FLAT_FRAGMENT_SHADER),
	}

	g.camera = Camera {
		pitch = 45,
		target = {0, 0, 0},
		target_distance = 10,
		target_rotation = 0,
	}
	update_camera(&g.camera, {}, 0)
}

update :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	m_delta := iris.mouse_delta()
	m_right := iris.mouse_button_state(.Right)
	m_scroll := iris.mouse_scroll()
	if .Pressed in m_right || m_scroll != 0 {
		update_camera(&g.camera, m_delta, m_scroll)
	}

	g.delta += f32(iris.elapsed_time())
	if g.delta >= 10 {
		g.delta = 0
	}

	iris.set_shader_uniform(g.material.shader, "light.position", &iris.Vector3{2, g.delta, 2})
	iris.set_shader_uniform(g.material.shader, "lightPosition", &iris.Vector3{2, g.delta, 2})
	iris.set_shader_uniform(g.material.shader, "viewPosition", &g.camera.position)
}

update_camera :: proc(c: ^Camera, m_delta: iris.Vector2, m_scroll: f64) {
	SCROLL_SPEED :: 1
	MIN_TARGET_DISTANCE :: 2
	MAX_PITCH :: 170
	MIN_PITCH :: 10

	c.target_distance = max(c.target_distance - f32(m_scroll), MIN_TARGET_DISTANCE)
	c.target_rotation += (m_delta.x * 0.5)
	c.pitch -= (m_delta.y * 0.5)
	c.pitch = clamp(c.pitch, MIN_PITCH, MAX_PITCH)

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
		iris.draw_model(g.model, iris.transform(s = {0.1, 0.1, 0.1}))
		iris.draw_mesh(g.ground_mesh, iris.transform(), g.material)

		iris.draw_mesh(g.mesh, iris.transform(t = {2, g.delta, 2}, s = {0.2, 0.2, 0.2}), g.flat_material)
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
layout (location = 1) in vec3 attribNormal;
layout (location = 2) in vec4 attribTangent;
layout (location = 3) in vec2 attribTexCoord;

out VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
	vec3 tanLightPosition;
	vec3 tanViewPosition;
	vec3 tanPosition;
} frag;

// builtin uniforms
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat3 matNormal;

// Custom uniforms
uniform vec3 lightPosition;
uniform vec3 viewPosition;

void main()
{
	frag.position = vec3(matModel * vec4(attribPosition, 1.0));
	frag.normal = matNormal * attribNormal;
	frag.texCoord = attribTexCoord;

	vec3 t = normalize(matNormal * vec3(attribTangent));
	vec3 n = normalize(matNormal * attribNormal);
	t =  normalize(t - dot(t, n) * n);
	vec3 b = cross(n, t);

	mat3 tbn = transpose(mat3(t, b, n));
	frag.tanLightPosition = tbn * lightPosition;
	frag.tanViewPosition = tbn * viewPosition;
	frag.tanPosition = tbn * frag.position;

    gl_Position = mvp * vec4(attribPosition, 1.0);
}  
`
FRAGMENT_SHADER :: `
#version 450 core
in VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
	vec3 tanLightPosition;
	vec3 tanViewPosition;
	vec3 tanPosition;
} frag;

out vec4 finalColor;

// Builtin uniforms.
uniform sampler2D texture0;
uniform sampler2D texture1;

// User uniforms.
struct Light {
	vec3 position;
	float ambientStr;
	vec3 ambientClr;
	vec3 diffuseClr;
	vec3 specularClr;
};
uniform Light light;  

void main()
{
	
	vec4 texelClr = texture(texture0, frag.texCoord);
	
	vec3 normal = texture(texture1, frag.texCoord).rgb;
	normal = normalize(normal * 2.0 - 1.0);
	// vec3 normal = normalize(frag.normal);
	vec3 lightDir = normalize(frag.tanLightPosition - frag.tanPosition);
	float diffuseValue = max(dot(lightDir, normal), 0.0);
	vec3 diffuse = texelClr.rgb * (diffuseValue * light.diffuseClr);

	vec3 ambient = texelClr.rgb * light.ambientStr * light.ambientClr;

	vec3 result = diffuse + ambient;
	result.r = min(result.r, texelClr.r);
	result.g = min(result.g, texelClr.g);
	result.b = min(result.b, texelClr.b);
	finalColor = vec4(result, 1.0);
}
`

FLAT_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec3 attribPosition;

uniform mat4 mvp;

void main()
{
    gl_Position = mvp*vec4(attribPosition, 1.0);
}  
`

FLAT_FRAGMENT_SHADER :: `
#version 450 core

out vec4 finalColor;

void main()
{
	finalColor = vec4(1.0, 0.0, 0.0, 1.0);
}
`
