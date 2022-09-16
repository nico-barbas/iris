package main

import "core:math"
import "core:math/rand"
import "core:math/linalg"
import "core:slice"
import iris "../"

Terrain :: struct {
	scene:           ^iris.Scene,
	model:           ^iris.Model_Node,
	material:        ^iris.Material,
	vertices:        iris.Buffer_Memory,
	position_memory: iris.Buffer_Memory,
	normal_memory:   iris.Buffer_Memory,
	texcoord_memory: iris.Buffer_Memory,

	// States
	positions:       []iris.Vector3,
	normals:         []iris.Vector3,
	texcoords:       []iris.Vector2,
	seed:            []f32,
	octaves:         uint,
	width:           int,
	height:          int,
	v_width:         int,
	v_height:        int,
	persistance:     f32,
	lacunarity:      f32,

	// UI
	ui:              ^iris.User_Interface_Node,
}

init_terrain :: proc(t: ^Terrain) {
	terrain_shader, exist := iris.shader_from_name("terrain_lit")
	assert(exist)
	material_res := iris.material_resource(
		iris.Material_Loader{name = "terrain", shader = terrain_shader},
	)
	t.material = material_res.data.(^iris.Material)
	iris.set_material_map(
		t.material,
		.Diffuse,
		iris.texture_resource(
			iris.Texture_Loader{
				info = iris.File_Texture_Info{path = "cube_texture.png"},
				filter = .Linear,
				wrap = .Repeat,
			},
		).data.(^iris.Texture),
	)
	generate_terrain_vertices(t)
	t.seed = make([]f32, (t.width + 1) * (t.height + 1))
	compute_height(t)
}

init_terrain_ui :: proc(t: ^Terrain, ui: ^iris.User_Interface_Node) {
	t.ui = ui
	layout := iris.new_widget_from(
		ui_node,
		iris.Layout_Widget{
			base = iris.Widget{
				flags = {.Active, .Initialized_On_New, .Root_Widget, .Fit_Theme},
				rect = {800, 100, 200, 350},
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
}

generate_terrain_vertices :: proc(t: ^Terrain) {
	iris.begin_temp_allocation()
	w := int(20)
	h := int(20)
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
			t.texcoords[y * t.v_width + x] = {f32(x) / f32(s_w), f32(y) / f32(s_h)}
		}
	}

	Face :: [6]u32
	f_per_row := (s_w)
	f_per_col := (s_h)
	f_count := f_per_row * f_per_col
	faces := make([]Face, f_count, context.temp_allocator)
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
	indices := slice.reinterpret([]u32, faces)

	resource := iris.mesh_resource(
		iris.Mesh_Loader{
			byte_size = p_size + n_size + t_size,
			attributes = {
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
	for seed_value in &t.seed {
		seed_value = rand.float32_range(-1, 1)
	}

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
	for position in &t.positions {
		position.y = (position.y - min_value) / range
		position.y = (position.y * 2) - 1
	}

	iris.send_buffer_data(
		&t.position_memory,
		iris.Buffer_Source{
			data = &t.positions[0],
			byte_size = size_of(iris.Vector3) * len(t.positions),
			accessor = iris.Buffer_Data_Type{kind = .Float_32, format = .Vector3},
		},
	)
}

// TERRAIN_COMPUTE_SHADER :: `
// #version 450 core
// layout (local_size_x = 1, local_size_y = 1, local_size_z = 1) in;

// layout (std140, binding = 2) buffer VertexBuffer {
// 	vec4 positions[];
// 	vec4 normals[];
// 	vec2 texCoords[];
// };

// layout (std140, binding = 3) readonly buffer TerrainData {
// 	float inputs[];
// 	int computeMode;
// 	int octaves;
// 	float lacunarity;
// 	float persistance;
// };

// const int GenerateMode = 0;
// const int SmoothMode = 1;

// const int width = 101;
// const int height = 101;

// void main() {
// 	ivec2 coord = ivec2(gl_GlobalInvocationID.xy);
// 	int index = int(gl_GlobalInvocationID.y) * width + int(gl_GlobalInvocationID.x);

// 	if (computeMode == GenerateMode) {
// 		float heightValue = 0.0;
// 		float accumulator = 0.0;
// 		float scale = 1.0;
// 		int freq = width;
// 		for (int i = 0; i < octaves; i += 1) {
// 			int samplerX1 = (coord.x / freq) * freq;
// 			int samplerY1 = (coord.y / freq) * freq;

// 			int samplerX2 = (samplerX1 + freq) % width;
// 			int samplerY2 = (samplerY1 + freq) % width;

// 			float blendX = float(coord.x - samplerX1) / float(freq);
// 			float blendY = float(coord.x - samplerY1) / float(freq);

// 			float inValueS1 = inputs[samplerY1 * width + samplerX1];
// 			float inValueS2 = inputs[samplerY1 * width + samplerX2];
// 			float inValueT1 = inputs[samplerY2 * width + samplerX1];
// 			float inValueT2 = inputs[samplerY2 * width + samplerX2];
// 			float sampleS = mix(inValueS1, inValueS2, blendX);
// 			float sampleT = mix(inValueT1, inValueT2, blendX);

// 			accumulator += scale;
// 			heightValue += (blendY * (sampleT - sampleS) + sampleS) * scale;
// 			scale *= persistance;
// 			freq = int(float(freq) / lacunarity);
// 			freq = max(freq, 1);
// 		}
// 		positions[index].y = heightValue / accumulator;
// 	}
// }
// `
