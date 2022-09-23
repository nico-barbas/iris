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
	// Terrain
	// terrain_shader, exist := iris.shader_from_name("terrain_lit")
	// assert(exist)
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
			},
		).data.(^iris.Texture),
	)
	// iris.set_material_map(
	// 	t.material,
	// 	.Diffuse1,
	// 	iris.texture_resource(
	// 		iris.Texture_Loader{
	// 			info = iris.File_Texture_Info{path = "textures/dirt.png"},
	// 			filter = .Linear,
	// 			wrap = .Repeat,
	// 		},
	// 	).data.(^iris.Texture),
	// )

	// samplers := [2]i32{i32(iris.Material_Map.Diffuse0), i32(iris.Material_Map.Normal0)}
	// iris.set_shader_uniform(terrain_shader, "textures", &samplers[0])

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
	// compute_sea_height(terrain)
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

				blendx := f32(x - sample_x1) / f32(frequency)
				blendy := f32(y - sample_y1) / f32(frequency)

				in_value_s1 := t.seed[sample_y1 * t.v_width + sample_x1]
				in_value_s2 := t.seed[sample_y1 * t.v_width + sample_x2]
				in_value_t1 := t.seed[sample_y2 * t.v_width + sample_x1]
				in_value_t2 := t.seed[sample_y2 * t.v_width + sample_x2]
				sample_s := linalg.lerp(in_value_s1, in_value_s2, blendx)
				sample_t := linalg.lerp(in_value_t1, in_value_t2, blendx)

				accumulator += scale
				noise_value += (blendy * (sample_t - sample_s) + sample_s) * scale
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
		position.y = (position.y - min_value) / range
		position.y = max((position.y * 2) - 1, -rand.float32_range(0.43, 0.435))
		position.y *= t.factor

		// t.texcoords[i].z = range_from_height(position.y)
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
