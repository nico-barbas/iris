package main

import "core:math"
import "core:math/rand"
import "core:math/linalg"
import "core:slice"
import "core:strings"
import "core:fmt"
import iris "../"

SEA_LEVEL :: -0.15

Terrain :: struct {
	scene:              ^iris.Scene,
	model:              ^iris.Model_Node,
	material:           ^iris.Material,
	vertices:           iris.Buffer_Memory,
	position_memory:    iris.Buffer_Memory,
	normal_memory:      iris.Buffer_Memory,
	texcoord_memory:    iris.Buffer_Memory,
	water_model:        ^iris.Model_Node,
	water_material:     ^iris.Material,

	// States
	positions:          []iris.Vector3,
	normals:            []iris.Vector3,
	texcoords:          []iris.Vector2,
	triangles:          []iris.Triangle,
	seed:               []f32,
	octaves:            uint,
	width:              int,
	height:             int,
	v_width:            int,
	v_height:           int,
	persistance:        f32,
	lacunarity:         f32,
	factor:             f32,

	// Grass Instancing
	grass:              ^iris.Model_Group_Node,
	grass_material:     ^iris.Material,
	grass_in_buffer:    iris.Buffer_Memory,
	grass_compute:      ^iris.Shader,

	// UI
	ui:                 ^iris.User_Interface_Node,
	octaves_widget:     Terrain_Option_Widget,
	lacunarity_widget:  Terrain_Option_Widget,
	persistance_widget: Terrain_Option_Widget,
	factor_widget:      Terrain_Option_Widget,
}

Terrain_Option_Widget :: struct {
	kind:       Terrain_Option_Widget_Kind,
	label:      ^iris.Label_Widget,
	builder:    strings.Builder,
	str_buffer: []byte,
}

Terrain_Option_Widget_Kind :: enum {
	Octaves,
	Locunarity,
	Persistance,
	Factor,
}

Terrain_Option :: enum {
	Octaves_Minus,
	Octaves_Plus,
	Lacunarity_Minus,
	Lacunarity_Plus,
	Persistance_Minus,
	Persistance_Plus,
	Factor_Minus,
	Factor_Plus,
}

init_terrain :: proc(t: ^Terrain) {
	terrain_shader_res := iris.shader_resource(
		iris.Shader_Builder{
			info = {
				build_name = "deferred_geometry_default",
				prototype_name = "deferred_geometry",
				stages = {.Vertex, .Fragment},
				stages_info = {
					iris.Shader_Stage.Vertex = {with_extension = false},
					iris.Shader_Stage.Fragment = {with_extension = true, name = "terrain"},
				},
			},
			document_name = "shaders/lib.helios",
		},
	)
	material_res := iris.material_resource(
		iris.Material_Loader{name = "terrain", shader = terrain_shader_res.data.(^iris.Shader)},
	)
	t.material = material_res.data.(^iris.Material)
	iris.set_material_map(
		t.material,
		.Diffuse0,
		iris.texture_resource(
			iris.Texture_Loader{
				info = iris.File_Texture_Info{path = "textures/terrain_sheet.png"},
				filter = .Linear,
				wrap = .Repeat,
				space = .sRGB,
			},
		).data.(^iris.Texture),
	)

	generate_terrain_vertices(t)
	t.seed = make([]f32, (t.width + 1) * (t.height + 1))
	for seed_value in &t.seed {
		seed_value = rand.float32_range(-1, 1)
	}
	compute_height(t)

	// Water
	water_shader_res := iris.shader_resource(
		iris.Shader_Builder{
			info = {
				build_name = "forward_water",
				prototype_name = "forward_water",
				stages = {.Vertex, .Fragment},
				stages_info = {
					iris.Shader_Stage.Vertex = {with_extension = false},
					iris.Shader_Stage.Fragment = {with_extension = false},
				},
			},
			document_name = "shaders/lib.helios",
		},
	)
	water_material_res := iris.material_resource(
		iris.Material_Loader{name = "water", shader = water_shader_res.data.(^iris.Shader)},
	)
	t.water_material = water_material_res.data.(^iris.Material)
	iris.set_material_map(
		t.water_material,
		.Diffuse0,
		iris.texture_resource(
			iris.Texture_Loader{
				info = iris.File_Texture_Info{path = "textures/water_normal0.png"},
				filter = .Linear,
				wrap = .Repeat,
				space = .sRGB,
			},
		).data.(^iris.Texture),
	)
	iris.set_material_map(
		t.water_material,
		.Normal0,
		iris.texture_resource(
			iris.Texture_Loader{
				info = iris.File_Texture_Info{path = "textures/water_normal0.png"},
				filter = .Linear,
				wrap = .Repeat,
				space = .Linear,
			},
		).data.(^iris.Texture),
	)

	water_mesh := iris.plane_mesh(50, 50, 1, 1, 5)
	t.water_model = iris.model_node_from_mesh(
		t.scene,
		water_mesh.data.(^iris.Mesh),
		t.water_material,
		iris.transform(t = {0, t.factor * SEA_LEVEL, 0}),
	)
	t.water_model.options = {.Transparent}
	iris.insert_node(t.scene, t.water_model)
	compute_sea_height(t)

	// Init grass
	billboard := iris.plane_mesh(1, 1, 1, 1, 1, iris.Vector3{0, 0, -1}).data.(^iris.Mesh)
	billboard_shader_res := iris.shader_resource(
		iris.Shader_Builder{
			info = {
				build_name = "forward_geometry_grass",
				prototype_name = "forward_geometry",
				stages = {.Vertex, .Fragment},
				stages_info = {
					iris.Shader_Stage.Vertex = {with_extension = true, name = "grass"},
					iris.Shader_Stage.Fragment = {with_extension = false},
				},
			},
			document_name = "shaders/lib.helios",
		},
	)
	grass_material_res := iris.material_resource(
		iris.Material_Loader{name = "grass", shader = billboard_shader_res.data.(^iris.Shader)},
	)
	t.grass_material = grass_material_res.data.(^iris.Material)
	iris.set_material_map(
		t.grass_material,
		.Diffuse0,
		iris.texture_resource(
			iris.Texture_Loader{
				info = iris.File_Texture_Info{path = "textures/grass_pack.png"},
				filter = .Linear,
				wrap = .Clamp_To_Edge,
				space = .sRGB,
			},
		).data.(^iris.Texture),
	)
	iris.set_material_map(
		t.grass_material,
		.Diffuse1,
		iris.texture_resource(
			iris.Texture_Loader{
				info = iris.File_Texture_Info{path = "textures/noise_map.png"},
				filter = .Linear,
				wrap = .Repeat,
				space = .Linear,
			},
		).data.(^iris.Texture),
	)
	// t.grass_material.double_face = true

	t.grass = iris.new_node(t.scene, iris.Model_Group_Node)
	t.grass.local_transform = linalg.matrix4_from_trs_f32(
		iris.Vector3{},
		linalg.quaternion_from_pitch_yaw_roll_f32(math.to_radians_f32(90), 0, 0),
		// iris.Quaternion(1),
		iris.Vector3{1, 1, 1},
	)
	iris.insert_node(t.scene, t.grass)
	iris.init_group_node(
		group = t.grass,
		meshes = {billboard},
		materials = {t.grass_material},
		count = 32,
	)
	t.grass.options += {.Transparent}

	grass_compute_res := iris.shader_resource(
		iris.Raw_Shader_Loader{
			name = "grass_compute",
			kind = .Byte,
			stages = {
				iris.Shader_Stage.Compute = iris.Shader_Stage_Loader{
					source = GRASS_BILLBOARD_COMPUTE_SHADER,
				},
			},
		},
	)
	t.grass_compute = grass_compute_res.data.(^iris.Shader)

	iris.begin_temp_allocation()
	in_buffer_res := iris.raw_buffer_resource(t.grass.transform_buf.size)
	t.grass_in_buffer = iris.buffer_memory_from_buffer_resource(in_buffer_res)
	in_identity := make([]iris.Matrix4, 32, context.temp_allocator)
	for y in 0 ..< 8 {
		for x in 0 ..< 4 {
			in_identity[y * 4 + x] = linalg.matrix4_from_trs_f32(
				iris.Vector3{f32(x), 0, f32(y)},
				iris.Quaternion(1),
				iris.VECTOR_ONE,
			)
		}
	}
	// for mat in &in_identity {
	// 	mat = linalg.MATRIX4F32_IDENTITY
	// }
	iris.send_buffer_data(
		&t.grass_in_buffer,
		iris.Buffer_Source{
			data = &in_identity[0][0][0],
			byte_size = len(in_identity) * size_of(iris.Matrix4),
			accessor = iris.Buffer_Data_Type{kind = .Float_32, format = .Mat4},
		},
	)
	iris.end_temp_allocation()
}

update_terrain :: proc(t: ^Terrain) {
	iris.set_storage_buffer_binding(t.grass_in_buffer.buf, 4)
	iris.set_storage_buffer_binding(t.grass.transform_buf.buf, 5)
	iris.set_shader_uniform(t.grass_compute, "matModel", &t.grass.local_transform[0][0])
	iris.dispatch_compute_shader(t.grass_compute, {1, 1, 1})
}

init_terrain_ui :: proc(t: ^Terrain, ui: ^iris.User_Interface_Node) {
	t.ui = ui
	layout := iris.new_widget_from(
		t.ui,
		iris.Layout_Widget{
			base = iris.Widget{
				flags = {.Active, .Initialized_On_New, .Root_Widget, .Fit_Theme},
				rect = {1300, 100, 200, 350},
				background = iris.Widget_Background{style = .Solid},
			},
			options = {.Decorated, .Titled, .Moveable, .Close_Widget},
			optional_title = "Terrain",
			format = .Row,
			origin = .Up,
			margin = 3,
			padding = 2,
		},
	)
	init_terrain_widget(t, layout, &t.octaves_widget, .Octaves)
	init_terrain_widget(t, layout, &t.lacunarity_widget, .Locunarity)
	init_terrain_widget(t, layout, &t.persistance_widget, .Persistance)
	init_terrain_widget(t, layout, &t.factor_widget, .Factor)
}

init_terrain_widget :: proc(
	t: ^Terrain,
	layout: ^iris.Layout_Widget,
	widget: ^Terrain_Option_Widget,
	kind: Terrain_Option_Widget_Kind,
) {
	widget.str_buffer = make([]byte, 10)
	widget.builder = strings.builder_from_slice(widget.str_buffer)
	name: string
	init_value: f32
	switch kind {
	case .Octaves:
		name = "Octaves"
		init_value = f32(t.octaves)
	case .Locunarity:
		name = "Lacunarity"
		init_value = t.lacunarity
	case .Persistance:
		name = "Persistance"
		init_value = t.persistance
	case .Factor:
		name = "Factor"
		init_value = t.factor
	}

	BUTTON_WIDTH :: 20
	BASE :: iris.Widget {
		flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
		background = iris.Widget_Background{style = .Solid},
	}

	title_label := iris.new_widget_from(
		layout.ui,
		iris.Label_Widget{base = BASE, text = iris.Text{data = name, style = .Center}},
	)
	iris.layout_add_widget(layout, title_label, 20)

	options := iris.new_widget_from(
		layout.ui,
		iris.Layout_Widget{base = BASE, format = .Column, origin = .Left, margin = 0, padding = 2},
	)
	iris.layout_add_widget(layout, options, 20)
	options.background.borders = false
	{
		minus := iris.new_widget_from(
			layout.ui,
			iris.Button_Widget{
				base = BASE,
				text = iris.Text{data = "-", style = .Center},
				data = t,
				callback = modify_terrain_options,
			},
		)
		iris.layout_add_widget(options, minus, BUTTON_WIDTH)
		minus.background.borders = false
		minus.id = iris.Widget_ID(Terrain_Option(int(kind) * 2))

		rem := iris.layout_remaining_size(options)
		widget.label = iris.new_widget_from(
			t.ui,
			iris.Label_Widget{base = BASE, text = iris.Text{data = "test", style = .Center}},
		)
		iris.layout_add_widget(options, widget.label, rem - BUTTON_WIDTH - 2)
		widget.label.background.borders = false
		format_widget_value(widget, init_value, kind != .Octaves)

		plus := iris.new_widget_from(
			t.ui,
			iris.Button_Widget{
				base = BASE,
				text = iris.Text{data = "+", style = .Center},
				data = t,
				callback = modify_terrain_options,
			},
		)
		iris.layout_add_widget(options, plus, BUTTON_WIDTH)
		plus.background.borders = false
		plus.id = iris.Widget_ID(Terrain_Option(int(kind) * 2 + 1))
	}
}

modify_terrain_options :: proc(data: rawptr, btn_id: iris.Widget_ID) {
	terrain := cast(^Terrain)data
	option := Terrain_Option(btn_id)

	modify_octaves :: proc(terrain: ^Terrain, option: Terrain_Option) {
		#partial switch option {
		case .Octaves_Minus:
			terrain.octaves -= 1
		case .Octaves_Plus:
			terrain.octaves += 1
		}
		format_widget_value(&terrain.octaves_widget, f32(terrain.octaves), false)
	}

	modify_lacunarity :: proc(terrain: ^Terrain, option: Terrain_Option) {
		#partial switch option {
		case .Lacunarity_Minus:
			terrain.lacunarity -= 0.2
		case .Lacunarity_Plus:
			terrain.lacunarity += 0.2
		}
		format_widget_value(&terrain.lacunarity_widget, terrain.lacunarity, true)
	}

	modify_pesistance :: proc(terrain: ^Terrain, option: Terrain_Option) {
		#partial switch option {
		case .Persistance_Minus:
			terrain.persistance -= 0.2
		case .Persistance_Plus:
			terrain.persistance += 0.2
		}
		format_widget_value(&terrain.persistance_widget, terrain.persistance, true)
	}

	modify_factor :: proc(terrain: ^Terrain, option: Terrain_Option) {
		#partial switch option {
		case .Factor_Minus:
			terrain.factor -= 0.5
		case .Factor_Plus:
			terrain.factor += 0.5
		}
		format_widget_value(&terrain.factor_widget, terrain.factor, true)
	}

	switch option {
	case .Octaves_Minus, .Octaves_Plus:
		modify_octaves(terrain, option)
	case .Lacunarity_Minus, .Lacunarity_Plus:
		modify_lacunarity(terrain, option)
	case .Persistance_Minus, .Persistance_Plus:
		modify_pesistance(terrain, option)
	case .Factor_Minus, .Factor_Plus:
		modify_factor(terrain, option)
	}

	compute_height(terrain)
	compute_sea_height(terrain)
	terrain.model.derived_flags += {.Geomtry_Modified}
}

format_widget_value :: proc(widget: ^Terrain_Option_Widget, value: f32, float: bool) {
	strings.builder_reset(&widget.builder)
	if float {
		fmt.sbprintf(&widget.builder, "%.1f", value)
	} else {
		fmt.sbprintf(&widget.builder, "%d", int(value))
	}
	iris.set_label_text(widget.label, strings.to_string(widget.builder))
}

generate_terrain_vertices :: proc(t: ^Terrain) {
	iris.begin_temp_allocation()
	w := int(50)
	h := int(50)
	s_w := int(t.width)
	s_h := int(t.height)
	t.v_width = s_w + 1
	t.v_height = s_h + 1
	v_count := t.v_width * t.v_height

	t.positions = make([]iris.Vector3, v_count)
	t.normals = make([]iris.Vector3, v_count)
	t.texcoords = make([]iris.Vector2, v_count)
	p_size := (size_of(iris.Vector3) * v_count)
	n_size := p_size
	t_size := (size_of(iris.Vector2) * v_count)

	offset := iris.Vector2{f32(w / 2), f32(h / 2)}
	step_x := f32(w) / f32(s_w)
	step_y := f32(h) / f32(s_h)
	for y in 0 ..< t.v_height {
		for x in 0 ..< t.v_width {
			t.positions[y * t.v_width + x] = {
				step_x * f32(x) - offset.x,
				0,
				step_y * f32(y) - offset.y,
			}
			t.normals[y * t.v_width + x] = iris.VECTOR_UP
			// t.texcoords[y * t.v_width + x] = {f32(x) / f32(s_w), f32(y) / f32(s_h)}

			u := (f32(x % 4) / 4) / 2
			v := (f32(y % 4) / 4)
			t.texcoords[y * t.v_width + x] = {u, v}
		}
	}

	Face :: [6]u32
	f_per_row := (s_w)
	f_per_col := (s_h)
	f_count := f_per_row * f_per_col
	faces := make([]Face, f_count)
	for i in 0 ..< f_count {
		f_x := i % f_per_row
		f_y := i / f_per_col
		i0 := u32(f_y * t.v_width + f_x)
		i1 := i0 + 1
		i2 := i0 + u32(t.v_width)
		i3 := i1 + u32(t.v_width)
	  //odinfmt: disable
        faces[i] = Face{
            i2, i1, i0,
            i2, i3, i1,
        }
		//odinfmt: enable
	}
	t.triangles = slice.reinterpret([]iris.Triangle, faces)
	indices := slice.reinterpret([]u32, faces)

	resource := iris.mesh_resource(
		iris.Mesh_Loader{
			byte_size = p_size + n_size + t_size,
			enabled = {.Position, .Normal, .Tex_Coord},
			sources = {
				iris.Attribute_Kind.Position = iris.Buffer_Source{
					data = &t.positions[0],
					byte_size = p_size,
					accessor = iris.Buffer_Data_Type{kind = .Float_32, format = .Vector3},
				},
				iris.Attribute_Kind.Normal = iris.Buffer_Source{
					data = &t.normals[0],
					byte_size = n_size,
					accessor = iris.Buffer_Data_Type{kind = .Float_32, format = .Vector3},
				},
				iris.Attribute_Kind.Tex_Coord = iris.Buffer_Source{
					data = &t.texcoords[0],
					byte_size = t_size,
					accessor = iris.Buffer_Data_Type{kind = .Float_32, format = .Vector2},
				},
			},
			indices = iris.Buffer_Source{
				data = &indices[0],
				byte_size = size_of(u32) * len(indices),
				accessor = iris.Buffer_Data_Type{kind = .Unsigned_32, format = .Scalar},
			},
			index_count = len(indices),
			format = .Packed_Blocks,
		},
	)

	t.model = iris.model_node_from_mesh(
		t.scene,
		resource.data.(^iris.Mesh),
		t.material,
		iris.transform(),
	)
	t.model.local_bounds = iris.bounding_box_from_min_max(
		iris.Vector3{-offset.x, -10, -offset.y},
		iris.Vector3{offset.x, 10, offset.y},
	)
	iris.insert_node(t.scene, t.model)
	iris.end_temp_allocation()

	arena: iris.Arena_Buffer_Allocator
	iris.arena_init(&arena, resource.data.(^iris.Mesh).vertices)
	t.position_memory = iris.arena_allocate(&arena, p_size)
	t.normal_memory = iris.arena_allocate(&arena, n_size)
	t.texcoord_memory = iris.arena_allocate(&arena, t_size)
}

compute_height :: proc(t: ^Terrain) {
	min_value := math.INF_F32
	max_value := -math.INF_F32

	// unique_value: f32
	for y in 0 ..< t.v_height {
		for x in 0 ..< t.v_width {
			noise_value: f32
			accumulator: f32
			scale := f32(1)
			frequency := t.v_width

			for octave in 0 ..< t.octaves {
				sample_x1 := (x / frequency) * frequency
				sample_y1 := (y / frequency) * frequency

				sample_x2 := (sample_x1 + frequency) % t.v_width
				sample_y2 := (sample_y1 + frequency) % t.v_width

				// Smoothstep blending instead of bilinear
				blendx := f32(x - sample_x1) / f32(frequency)
				blendx = linalg.smoothstep(f32(0), f32(1), blendx)
				blendy := f32(y - sample_y1) / f32(frequency)
				blendy = linalg.smoothstep(f32(0), f32(1), blendy)

				in_value_s1 := t.seed[sample_y1 * t.v_width + sample_x1]
				in_value_s2 := t.seed[sample_y1 * t.v_width + sample_x2]
				in_value_t1 := t.seed[sample_y2 * t.v_width + sample_x1]
				in_value_t2 := t.seed[sample_y2 * t.v_width + sample_x2]
				sample_s := linalg.lerp(in_value_s1, in_value_s2, blendx)
				sample_t := linalg.lerp(in_value_t1, in_value_t2, blendx)

				accumulator += scale
				noise_value += linalg.lerp(sample_s, sample_t, blendy) * scale
				scale *= t.persistance
				frequency = max(int(f32(frequency) / t.lacunarity), 1)
			}

			output_value := noise_value / accumulator
			min_value = min(min_value, output_value)
			max_value = max(max_value, output_value)

			t.positions[y * t.v_width + x].y = output_value
		}
	}

	range := max_value - min_value

	for position, i in &t.positions {
		if t.octaves > 1 {
			position.y = abs(position.y - min_value) / range
			position.y = max((position.y * 2) - 1, -rand.float32_range(0.43, 0.435))
		}
		position.y *= t.factor
	}

	for triangle in t.triangles {
		pa := t.positions[triangle.x]
		pb := t.positions[triangle.y]
		pc := t.positions[triangle.z]

		side_ab := pb - pa
		side_ac := pc - pa

		triangle_normal := linalg.vector_cross3(side_ab, side_ac)
		triangle_normal = linalg.vector_normalize(triangle_normal)

		t.normals[triangle.x] += triangle_normal
		t.normals[triangle.y] += triangle_normal
		t.normals[triangle.z] += triangle_normal
	}

	for normal in &t.normals {
		normal = linalg.vector_normalize(normal)
	}

	iris.send_buffer_data(
		&t.position_memory,
		iris.Buffer_Source{
			data = &t.positions[0],
			byte_size = size_of(iris.Vector3) * len(t.positions),
			accessor = iris.Buffer_Data_Type{kind = .Float_32, format = .Vector3},
		},
	)
	iris.send_buffer_data(
		&t.normal_memory,
		iris.Buffer_Source{
			data = &t.normals[0],
			byte_size = size_of(iris.Vector3) * len(t.normals),
			accessor = iris.Buffer_Data_Type{kind = .Float_32, format = .Vector3},
		},
	)
	iris.send_buffer_data(
		&t.texcoord_memory,
		iris.Buffer_Source{
			data = &t.texcoords[0],
			byte_size = size_of(iris.Vector2) * len(t.texcoords),
			accessor = iris.Buffer_Data_Type{kind = .Float_32, format = .Vector2},
		},
	)

}

range_from_height :: proc(h: f32) -> f32 {
	if h < 2 {
		return 0
	} else if h >= 2 && h < 3 {
		value := h - math.floor(h)
		return value
	} else {
		return 1
	}
}

compute_sea_height :: proc(terrain: ^Terrain) {
	iris.node_local_transform(
		terrain.water_model,
		iris.transform(t = {0, terrain.factor * SEA_LEVEL, 0}),
	)
}

GRASS_BILLBOARD_COMPUTE_SHADER :: `
#version 450 core
layout (local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout (std140, binding = 0) uniform ContextData {
    mat4 projView;
    mat4 matProj;
    mat4 matView;
    vec3 viewPosition;
    float time;
    float dt;
};

layout (std140, binding = 4) buffer bufferedIn {
	mat4 instanceMatIn[];
};

layout (std140, binding = 5) buffer bufferedOut {
	mat4 instanceMatOut[];
};

layout (location = 0) uniform mat4 matModel; 

void main() {
	mat4 matIn = instanceMatIn[gl_LocalInvocationIndex];
	mat4 matGlobal = matModel * matIn;
	vec3 position = matGlobal[3].xyz;

	vec3 f = normalize(position - viewPosition);
	vec3 r = normalize(cross(f, vec3(0, 1, 0)));
	vec3 u = normalize(cross(r, f));

	float fe = dot(f, position);

	mat4 lookAt = mat4(
		vec4(r.x, r.y, r.z, 0.0),
		vec4(u.x, u.y, u.z, 0.0),
		vec4(-f.x, -f.y, -f.z, 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));

	// mat4 lookAt = mat4(mat3(matView));
	mat4 matOut = matIn * lookAt;
	instanceMatOut[gl_LocalInvocationIndex] = matOut;
}
`
