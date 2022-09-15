package main

// import "core:slice"
import iris "../"

Terrain :: struct {
	compute_shader: ^iris.Shader,
	vertices:       iris.Buffer_Memory,
	model:          ^iris.Model_Node,
	options:        iris.Noise_Generator,

	// UI
	ui:             ^iris.User_Interface_Node,
}

TERRAIN_VERTEX_LAYOUT :: []iris.Accessor{
	iris.Accessor{kind = .Float_32, format = .Vector4},
	iris.Accessor{kind = .Float_32, format = .Vector4},
	iris.Accessor{kind = .Float_32, format = .Vector2},
}

init_terrain :: proc(t: ^Terrain, opt: iris.Noise_Generator) {
	vertex_size := iris.attribute_layout_size(TERRAIN_VERTEX_LAYOUT)

	buffer_res := iris.raw_buffer_resource(
		vertex_size * (t.options.width * t.options.height),
		true,
	)
	t.vertices = iris.buffer_memory_from_buffer_resource(buffer_res)


}

generate_terrain_data :: proc(t: ^Terrain) {
	// vertex_length := iris.vertex_layout_length(TERRAIN_VERTEX_LAYOUT)
	// w := t.options.width
	// h := t.options.height
	// s_w := w + 1
	// s_h := h + 1
	// v_per_row := s_w
	// v_per_col := s_h
	// v_count := v_per_row * v_per_col

	// normal_offset := v_count * 3
	// uv_offset := v_count * 6
	// vertices := make([]f32, v_count * vertex_length, context.temp_allocator)
	// positions := slice.reinterpret([]iris.Vector3, (vertices[:normal_offset]))
	// normals := slice.reinterpret([]iris.Vector3, (vertices[normal_offset:uv_offset]))
	// uvs := slice.reinterpret([]iris.Vector2, (vertices[uv_offset:]))

	// offset := iris.Vector2{f32(w / 2), f32(h / 2)}
	// step_x := f32(w) / f32(s_w)
	// step_y := f32(h) / f32(s_h)
	// for y in 0 ..< v_per_col {
	// 	for x in 0 ..< v_per_row {
	// 		positions[y * v_per_row + x] = {
	// 			step_x * f32(x) - offset.x,
	// 			0,
	// 			step_y * f32(y) - offset.y,
	// 		}
	// 		normals[y * v_per_row + x] = iris.VECTOR_UP
	// 		uvs[y * v_per_row + x] = {f32(x) / f32(s_w), f32(y) / f32(s_h)}
	// 	}
	// }

	// Face :: [6]u32
	// f_per_row := (s_w)
	// f_per_col := (s_h)
	// f_count := f_per_row * f_per_col
	// faces := make([]Face, f_count, context.temp_allocator)
	// for i in 0 ..< f_count {
	// 	f_x := i % f_per_row
	// 	f_y := i / f_per_col
	// 	i0 := u32(f_y * v_per_row + f_x)
	// 	i1 := i0 + 1
	// 	i2 := i0 + u32(v_per_row)
	// 	i3 := i1 + u32(v_per_row)
	//   //odinfmt: disable
    //     faces[i] = Face{
    //         i2, i1, i0,
    //         i2, i3, i1,
    //     }
	// 	//odinfmt: enable
	// }
	// indices := slice.reinterpret([]u32, faces)

	// resource := mesh_resource(
	// 	Mesh_Loader{
	// 		vertices = vertices,
	// 		indices = indices,
	// 		format = .Packed_Blocks,
	// 		layout = Vertex_Layout{.Float3, .Float3, .Float2},
	// 		offsets = []int{0, normal_offset * size_of(f32), uv_offset * size_of(f32)},
	// 	},
	// )
}
