package main

import "core:mem"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import iris "../"
import gltf "../gltf"

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	// trs := iris.transform(
	// 	t = {3, 45, 1},
	// 	r = linalg.quaternion_angle_axis_f32(45, {0, 1, 0}),
	// 	s = {5, 1, 2},
	// )
	// fmt.println(trs)
	// mat := linalg.matrix4_from_trs_f32(trs.translation, trs.rotation, trs.scale)
	// fmt.println(mat)
	// trs2 := iris.transform_from_matrix(mat)
	// fmt.println(trs2)
	// // assert(trs.translation == trs2.translation && trs.scale == trs2.scale)
	// mat2 := linalg.matrix4_from_trs_f32(trs2.translation, trs2.rotation, trs2.scale)
	// fmt.println(mat2)
	// assert(mat == mat2)

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
	scene:             ^iris.Scene,
	camera:            Camera,
	light:             iris.Light_ID,
	mesh:              ^iris.Mesh,
	lantern:           ^iris.Node,
	rig:               ^iris.Node,
	skin:              ^iris.Node,
	canvas:            ^iris.Canvas_Node,
	model_shader:      ^iris.Shader,
	skeletal_shader:   ^iris.Shader,
	ground_mesh:       ^iris.Mesh,
	// material:      iris.Material,
	delta:             f32,
	flat_material:     ^iris.Material,
	flat_lit_material: ^iris.Material,
	font:              ^iris.Font,
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

	font_res := iris.font_resource(iris.Font_Loader{path = "Roboto-Regular.ttf", sizes = {20}})
	g.font = font_res.data.(^iris.Font)

	scene_res := iris.scene_resource("main")
	g.scene = scene_res.data.(^iris.Scene)

	lantern_document, err := gltf.parse_from_file(
		"lantern/Lantern.gltf",
		.Gltf_External,
		context.temp_allocator,
		context.temp_allocator,
	)
	fmt.assertf(err == nil, "%s\n", err)
	iris.load_resources_from_gltf(&lantern_document)
	root := lantern_document.root.nodes[0]

	model_shader_res := iris.shader_resource(
		iris.Shader_Loader{vertex_source = VERTEX_SHADER, fragment_source = FRAGMENT_SHADER},
	)
	g.model_shader = model_shader_res.data.(^iris.Shader)

	lt := iris.transform(t = {1, 0, 1}, s = {0.1, 0.1, 0.1})
	lantern_transform := linalg.matrix_mul(
		linalg.matrix4_from_trs_f32(lt.translation, lt.rotation, lt.scale),
		root.local_transform,
	)
	g.lantern = iris.new_node(g.scene, iris.Empty_Node, lantern_transform)
	iris.insert_node(g.scene, g.lantern)
	for node in root.children {
		lantern_node := iris.new_node(g.scene, iris.Model_Node)
		iris.model_node_from_gltf(
			lantern_node,
			iris.Model_Loader{
				flags = {
					.Use_Local_Transform,
					.Load_Position,
					.Load_Normal,
					.Load_Tangent,
					.Load_TexCoord0,
				},
				shader = g.model_shader,
			},
			node,
		)
		iris.insert_node(g.scene, lantern_node, g.lantern)
	}

	mesh_res := iris.cube_mesh(1, 1, 1)
	g.mesh = mesh_res.data.(^iris.Mesh)

	ground_res := iris.plane_mesh(10, 10, 3, 3)
	g.ground_mesh = ground_res.data.(^iris.Mesh)


	flat_shader_res := iris.shader_resource(
		iris.Shader_Loader{
			vertex_source = FLAT_VERTEX_SHADER,
			fragment_source = FLAT_FRAGMENT_SHADER,
		},
	)
	flat_material_res := iris.material_resource(
		iris.Material_Loader{name = "flat", shader = flat_shader_res.data.(^iris.Shader)},
	)
	g.flat_material = flat_material_res.data.(^iris.Material)

	flat_lit_shader_res := iris.shader_resource(
		iris.Shader_Loader{
			vertex_source = FLAT_LIT_VERTEX_SHADER,
			fragment_source = FLAT_LIT_FRAGMENT_SHADER,
		},
	)
	flat_lit_material_res := iris.material_resource(
		iris.Material_Loader{name = "flat_lit", shader = flat_lit_shader_res.data.(^iris.Shader)},
	)
	g.flat_lit_material = flat_lit_material_res.data.(^iris.Material)
	iris.set_material_map(
		g.flat_lit_material,
		.Diffuse,
		iris.texture_resource(
			iris.Texture_Loader{path = "cube_texture.png", filter = .Linear, wrap = .Repeat},
		).data.(^iris.Texture),
	)

	g.camera = Camera {
		pitch = 45,
		target = {0, 0.5, 0},
		target_distance = 10,
		target_rotation = 90,
	}
	update_camera(&g.camera, {}, 0)

	iris.add_light(.Directional, iris.Vector3{2, g.delta, 2}, {1, 1, 1, 1})

	{
		skeletal_shader_res := iris.shader_resource(
			iris.Shader_Loader{
				vertex_source = FLAT_SKELETAL_VERTEX_SHADER,
				fragment_source = FLAT_SKELETAL_FRAGMENT_SHADER,
			},
		)
		g.skeletal_shader = skeletal_shader_res.data.(^iris.Shader)

		rig_document, _err := gltf.parse_from_file(
			"human_rig/CesiumMan.gltf",
			.Gltf_External,
			context.temp_allocator,
			context.temp_allocator,
		)
		assert(_err == nil)
		iris.load_resources_from_gltf(&rig_document)

		node, _ := gltf.find_node_with_name(&rig_document, "Cesium_Man")
		g.rig = iris.new_node(g.scene, iris.Empty_Node, node.global_transform)
		// iris.node_offset_transform(g.rig, iris.transform(t = {0, 4.5, 0}))
		iris.insert_node(g.scene, g.rig)

		mesh_node := iris.new_node(g.scene, iris.Model_Node)
		iris.model_node_from_gltf(
			mesh_node,
			iris.Model_Loader{
				flags = {
					.Use_Identity,
					.Load_Position,
					.Load_Normal,
					.Load_TexCoord0,
					.Load_Joints0,
					.Load_Weights0,
					.Load_Bones,
				},
				shader = g.skeletal_shader,
			},
			node,
		)
		iris.insert_node(g.scene, mesh_node, g.rig)

		skin_node := iris.new_node(g.scene, iris.Skin_Node)
		iris.skin_node_from_gltf(skin_node, node)
		iris.skin_node_target(skin_node, mesh_node)
		iris.insert_node(g.scene, skin_node, g.rig)

		animation, _ := iris.animation_from_name("animation0")
		iris.skin_node_add_animation(skin_node, animation)
		iris.skin_node_play_animation(skin_node, "animation0")
	}

	{
		g.canvas = iris.new_node_from(g.scene, iris.Canvas_Node{width = 1600, height = 900})
		iris.insert_node(g.scene, g.canvas)
		ui_node := iris.new_node_from(g.scene, iris.User_Interface_Node{canvas = g.canvas})
		iris.insert_node(g.scene, ui_node, g.canvas)
		iris.ui_node_theme(
			ui_node,
			iris.User_Interface_Theme{
				borders = true,
				border_color = {1, 1, 1, 1},
				contrast_values = {0 = 0.35, 1 = 0.75, 2 = 1, 3 = 1.25, 4 = 1.5},
				base_color = {0.35, 0.35, 0.35, 1},
				highlight_color = {0.7, 0.7, 0.8, 1},
				text_color = 1,
				text_size = 20,
				font = g.font,
				title_style = .Center_Left,
			},
		)
		layout := iris.new_widget_from(
			ui_node,
			iris.Layout_Widget{
				base = iris.Widget{
					flags = {.Active, .Initialized_On_New, .Root_Widget, .Fit_Theme},
					rect = {100, 100, 200, 400},
					background = iris.Widget_Background{style = .Solid},
				},
				options = {.Decorated, .Titled, .Moveable, .Close_Widget},
				optional_title = "Window",
				format = .Row,
				origin = .Up,
				margin = 3,
				padding = 2,
			},
		)

		iris.scene_graph_to_list(layout, g.scene, 20)
	}
}

update :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	dt := f32(iris.elapsed_time())
	m_delta := iris.mouse_delta()
	m_right := iris.mouse_button_state(.Right)
	m_scroll := iris.mouse_scroll()
	if .Pressed in m_right {
		update_camera(&g.camera, m_delta, 0)
	} else if m_scroll != 0 {
		update_camera(&g.camera, 0, m_scroll)
	}

	g.delta += dt
	if g.delta >= 10 {
		g.delta = 0.5
	}

	iris.light_position(g.light, iris.Vector3{2, g.delta, 2})
	iris.set_shader_uniform(g.model_shader, "viewPosition", &g.camera.position)

	iris.update_scene(g.scene, dt)
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
		iris.render_scene(g.scene)
		iris.draw_mesh(g.ground_mesh, iris.transform(), g.flat_lit_material)

		iris.draw_mesh(
			g.mesh,
			iris.transform(t = {2, g.delta, 2}, s = {0.2, 0.2, 0.2}),
			g.flat_material,
		)
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


FLAT_SKELETAL_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 1) in vec3 attribNormal;
layout (location = 2) in vec4 attribJoints;
layout (location = 3) in vec4 attribWeights;
layout (location = 4) in vec2 attribTexCoord;

layout (std140, binding = 0) uniform ProjectionData {
	mat4 projView;
	vec3 viewPosition;
};

out VS_OUT {
	vec3 normal;
	vec4 joints;
	vec4 weights;
	vec2 texCoord;
} frag;

uniform mat4 matJoints[19];
uniform mat4 matModelLocal;

void main()
{
	frag.normal = attribNormal;
	frag.joints = attribJoints;
	frag.weights = attribWeights;
	frag.texCoord = attribTexCoord;

	mat4 matSkin = 
		attribWeights.x * matJoints[int(attribJoints.x)] +
		attribWeights.y * matJoints[int(attribJoints.y)] +
		attribWeights.z * matJoints[int(attribJoints.z)] +
		attribWeights.w * matJoints[int(attribJoints.w)];
	mat4 mvp = projView * matModelLocal * matSkin;
    gl_Position = mvp*vec4(attribPosition, 1.0);
}  
`

FLAT_SKELETAL_FRAGMENT_SHADER :: `
#version 450 core
in VS_OUT {
	vec3 normal;
	vec4 joints;
	vec4 weights;
	vec2 texCoord;
} frag;

out vec4 finalColor;

uniform sampler2D texture0;

void main()
{
	// finalColor = vec4(frag.weights.xyz * frag.joints.xyz, 1.0);
	finalColor = texture(texture0, frag.texCoord);
}
`
