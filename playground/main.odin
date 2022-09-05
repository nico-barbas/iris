package main

import "core:mem"
import "core:fmt"
import "core:math"
// import "core:math/linalg"
import iris "../"
import gltf "../gltf"

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	iris.init_app(
		&iris.App_Config{
			width = 1600,
			height = 900,
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
	camera:            Camera,
	light:             iris.Light_ID,
	mesh:              iris.Mesh,
	model:             iris.Model,
	model_shader:      iris.Shader,
	ground_mesh:       iris.Mesh,
	// material:      iris.Material,
	delta:             f32,
	flat_material:     iris.Material,
	flat_lit_material: iris.Material,
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

	doc, err := gltf.parse_from_file("lantern/Lantern.gltf", .Gltf_External)
	fmt.assertf(err == nil, "%s\n", err)
	iris.load_textures_from_gltf(&doc)
	iris.load_materials_from_gltf(&doc)
	root := doc.root.nodes[0]

	g.model_shader = iris.load_shader_from_bytes(VERTEX_SHADER, FRAGMENT_SHADER)
	g.model = iris.load_model_from_gltf_node(
		loader = &iris.Model_Loader{
			document = &doc,
			shader = g.model_shader,
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

	g.flat_material = {
		shader = iris.load_shader_from_bytes(FLAT_VERTEX_SHADER, FLAT_FRAGMENT_SHADER),
	}

	g.flat_lit_material = {
		shader = iris.load_shader_from_bytes(FLAT_LIT_VERTEX_SHADER, FLAT_LIT_FRAGMENT_SHADER),
	}
	iris.set_material_map(
		&g.flat_lit_material,
		.Diffuse,
		iris.load_texture_from_file("cube_texture.png"),
	)

	g.camera = Camera {
		pitch = 45,
		target = {0, 0.5, 0},
		target_distance = 10,
		target_rotation = 0,
	}
	update_camera(&g.camera, {}, 0)

	iris.add_light(.Directional, iris.Vector3{2, g.delta, 2}, {1, 1, 1, 1})
}

update :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	m_delta := iris.mouse_delta()
	m_right := iris.mouse_button_state(.Right)
	m_scroll := iris.mouse_scroll()
	if .Pressed in m_right {
		update_camera(&g.camera, m_delta, 0)
	} else if m_scroll != 0 {
		update_camera(&g.camera, 0, m_scroll)
	}

	g.delta += f32(iris.elapsed_time())
	if g.delta >= 10 {
		g.delta = 0.5
	}

	iris.light_position(g.light, iris.Vector3{2, g.delta, 2})
	iris.set_shader_uniform(g.model_shader, "viewPosition", &g.camera.position)
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
		iris.draw_mesh(g.ground_mesh, iris.transform(), g.flat_lit_material)

		iris.draw_mesh(
			g.mesh,
			iris.transform(t = {2, g.delta, 2}, s = {0.2, 0.2, 0.2}),
			g.flat_material,
		)

		iris.draw_overlay_rect({0, 0, 100, 100}, {1, 0, 0, 1})

		// iris.draw_rectangle({300, 300, 400, 150}, {1, 1, 1, 1})
	}
	iris.end_render()
}

close :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.destroy_mesh(g.mesh)
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

layout (std140, binding = 0) uniform ProjectionData {
	mat4 projView;
	vec3 viewPosition;
};

struct Light {
	uint on;
	vec3 position;
	vec3 color;
};
layout (std140, binding = 1) uniform Lights {
	Light lights[4];
	mat4 matLightSpace;
	vec3 ambientClr;
	float ambientStrength;
};

out VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
	vec3 tanLightPosition;
	vec3 tanViewPosition;
	vec3 tanPosition;
	vec4 lightSpacePosition;
} frag;

// builtin uniforms
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat3 matNormal;

void main()
{
	frag.position = vec3(matModel * vec4(attribPosition, 1.0));
	frag.normal = matNormal * attribNormal;
	frag.texCoord = attribTexCoord;
	frag.lightSpacePosition = matLightSpace * matModel * vec4(attribPosition, 1.0);

	vec3 t = normalize(matNormal * vec3(attribTangent));
	vec3 n = normalize(matNormal * attribNormal);
	t =  normalize(t - dot(t, n) * n);
	vec3 b = cross(n, t);

	mat3 tbn = transpose(mat3(t, b, n));
	frag.tanLightPosition = tbn * lights[0].position;
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
	vec4 lightSpacePosition;
} frag;

out vec4 finalColor;

// Builtin uniforms.
uniform sampler2D texture0;
uniform sampler2D texture1; 
uniform sampler2D mapShadow;

struct Light {
	uint on;
	vec3 position;
	vec3 color;
};
layout (std140, binding = 1) uniform Lights {
	Light lights[4];
	mat4 matLightSpace;
	vec3 ambientClr;
	float ambientStrength;
};

float computeShadowValue(vec4 lightSpacePosition, float bias);

void main()
{
	vec4 texelClr = texture(texture0, frag.texCoord);
	
	vec3 normal = texture(texture1, frag.texCoord).rgb;
	normal = normalize(normal * 2.0 - 1.0);
	vec3 lightDir = normalize(frag.tanLightPosition - frag.tanPosition);
	float diffuseValue = max(dot(lightDir, normal), 0.0);
	vec3 diffuse = diffuseValue * lights[0].color;

	vec3 ambient = ambientStrength * ambientClr;

	vec3 viewDir = normalize(frag.tanViewPosition - frag.tanPosition);
	vec3 reflectDir = reflect(-lightDir, normal);
	float specValue = max(dot(viewDir, reflectDir), 0.0);
	specValue = pow(specValue, 32);
	vec3 specular = 0.5 * (specValue * lights[0].color);
	
	float bias = 0.05 * (1.0 - dot(normal, lightDir));
	bias = max(bias, 0.005);
	float shadowValue = computeShadowValue(frag.lightSpacePosition, bias);

	vec3 result = (ambient + ((1.0 - shadowValue) * (diffuse + specular))) * texelClr.rgb;

	finalColor = vec4(result, 1.0);
}

float computeShadowValue(vec4 lightSpacePosition, float bias) {
	vec3 projCoord = lightSpacePosition.xyz / lightSpacePosition.w;
	if (projCoord.z > 1.0) {
		return 0.0;
	}
	projCoord = projCoord * 0.5 + 0.5;
	float lightDepth = texture(mapShadow, projCoord.xy).r;
	float currentDepth = projCoord.z;

	float result = currentDepth - bias > lightDepth ? 1.0 : 0.0;
	return result;
}
`

FLAT_LIT_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 1) in vec3 attribNormal;
layout (location = 2) in vec2 attribTexCoord;

out VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
	vec4 lightSpacePosition;
} frag;

uniform mat4 mvp;
uniform mat4 matModel;
uniform mat3 matNormal;

struct Light {
	uint on;
	vec3 position;
	vec3 color;
};
layout (std140, binding = 1) uniform Lights {
	Light lights[4];
	mat4 matLightSpace;
	vec3 ambientClr;
	float ambientStrength;
};

void main()
{
	frag.position = vec3(matModel * vec4(attribPosition, 1.0));
	frag.normal = matNormal * attribNormal; 
	frag.texCoord = attribTexCoord;
	frag.lightSpacePosition = matLightSpace * matModel * vec4(attribPosition, 1.0);

    gl_Position = mvp*vec4(attribPosition, 1.0);
}  
`

FLAT_LIT_FRAGMENT_SHADER :: `
#version 450 core
in VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
	vec4 lightSpacePosition;
} frag;

out vec4 finalColor;

// builtin uniforms;
uniform sampler2D texture0;
uniform sampler2D mapShadow;

struct Light {
	uint on;
	vec3 position;
	vec3 color;
};
layout (std140, binding = 1) uniform Lights {
	Light lights[4];
	mat4 matLightSpace;
	vec3 ambientClr;
	float ambientStrength;
};

float computeShadowValue(vec4 lightSpacePosition, float bias);

void main()
{
	vec4 texelClr = texture(texture0, frag.texCoord);

	vec3 normal = normalize(frag.normal);
	vec3 lightDir = normalize(lights[0].position - frag.position);
	float diffuseValue = max(dot(lightDir, normal), 0.0);
	vec3 diffuse = diffuseValue * lights[0].color.rgb;

	vec3 ambient = ambientStrength * ambientClr;

	float bias = 0.05 * (1.0 - dot(normal, lightDir));
	bias = max(bias, 0.005);
	float shadowValue = computeShadowValue(frag.lightSpacePosition, bias);

	vec3 result = (ambient + ((1.0 - shadowValue) * diffuse)) * texelClr.rgb;

	finalColor = vec4(result, 1.0);
}

float computeShadowValue(vec4 lightSpacePosition, float bias) {
	vec3 projCoord = lightSpacePosition.xyz / lightSpacePosition.w;
	if (projCoord.z > 1.0) {
		return 0.0;
	}
	projCoord = projCoord * 0.5 + 0.5;
	// float lightDepth = texture(mapShadow, projCoord.xy).r;
	float currentDepth = projCoord.z;

	float result = 0.0;
	vec2 texelSize = 1.0 / textureSize(mapShadow, 0);
	for (int x = -1; x <= 1; x += 1) {
		for (int y = -1; y <= 1; y += 1) {
			vec2 pcfCoord = projCoord.xy + vec2(x, y) * texelSize;
			float pcfDepth = texture(mapShadow, pcfCoord).r;
			result += currentDepth - bias > pcfDepth ? 1.0 : 0.0;
		}
	}
	result /= 9.0;
	// float result = currentDepth - bias > lightDepth ? 1.0 : 0.0;
	return result;
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
