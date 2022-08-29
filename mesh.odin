package iris

import "core:mem"
import "core:slice"

Mesh :: struct {
	state:      Attributes_State,
	layout_map: Vertex_Layout_Map,
	vertices:   Buffer,
	indices:    Buffer,
}

draw_mesh :: proc(mesh: Mesh, t: Transform, mat: Material) {
	push_draw_command(Render_Mesh_Command{mesh = mesh, transform = t, material = mat})
}

plane_mesh :: proc(
	w,
	h: int,
	s_w,
	s_h: int,
	layout_allocator := context.allocator,
	geometry_allocator := context.temp_allocator,
) -> (
	[]f32,
	[]u32,
	Vertex_Layout_Map,
) {
	v_per_row := s_w + 1
	v_per_col := s_h + 1
	v_count := v_per_row * v_per_col

	normal_offset := v_count * 3
	uv_offset := v_count * 6
	vertices := make([]f32, v_count * 8, geometry_allocator)
	positions := slice.reinterpret([]Vector3, (vertices[:normal_offset]))
	normals := slice.reinterpret([]Vector3, (vertices[normal_offset:uv_offset]))
	uvs := slice.reinterpret([]Vector2, (vertices[uv_offset:]))

	offset := Vector2{f32(w / 2), f32(h / 2)}
	step_x := f32(w) / f32(s_w)
	step_y := f32(h) / f32(s_h)
	for y in 0 ..< v_per_col {
		for x in 0 ..< v_per_row {
			positions[y * v_per_row + x] = {
				step_x * f32(x) - offset.x,
				0,
				step_y * f32(y) - offset.y,
			}
			normals[y * v_per_row + x] = VECTOR_UP
			uvs[y * v_per_row + x] = {f32(x) / f32(s_w), f32(y) / f32(s_h)}
		}
	}

	Face :: [6]u32
	f_per_row := (s_w)
	f_per_col := (s_h)
	f_count := f_per_row * f_per_col
	faces := make([]Face, f_count, geometry_allocator)
	for i in 0 ..< f_count {
		f_x := i % f_per_row
		f_y := i / f_per_col
		i0 := u32(f_y * v_per_row + f_x)
		i1 := i0 + 1
		i2 := i0 + u32(v_per_row)
		i3 := i1 + u32(v_per_row)
	  //odinfmt: disable
        faces[i] = Face{
            i2, i1, i0,
            i2, i3, i1,
        }
		//odinfmt: enable
	}
	indices := slice.reinterpret([]u32, faces)

	layout_map := Vertex_Layout_Map {
		layout  = Vertex_Layout(
			slice.clone([]Vertex_Format{.Float3, .Float3, .Float2}, layout_allocator),
		),
		offsets = slice.clone(
			[]int{0, normal_offset * size_of(f32), uv_offset * size_of(f32)},
			layout_allocator,
		),
	}

	return vertices, indices, layout_map
}

cube_mesh :: proc(
	w,
	h,
	l: f32,
	layout_allocator: mem.Allocator,
	geometry_allocator: mem.Allocator,
) -> (
	[]f32,
	[]u32,
	Vertex_Layout_Map,
) {
	hw, hh, hl := w / 2, h / 2, h / 2
	//odinfmt: disable
	v := [24*8]f32 {
		-hw, -hh,  hl, 0.0, 0.0, 1.0, 0.0, 0.0,
		 hw, -hh,  hl, 0.0, 0.0, 1.0, 1.0, 0.0,
		 hw,  hh,  hl, 0.0, 0.0, 1.0, 1.0, 1.0,
		-hw,  hh,  hl, 0.0, 0.0, 1.0, 0.0, 1.0,

		-hw, -hh, -hl, 0.0, 1.0, -1.0, 1.0, 0.0,
		-hw,  hh, -hl, 0.0, 1.0, -1.0, 1.0, 1.0,
		 hw,  hh, -hl, 0.0, 1.0, -1.0, 0.0, 1.0,
		 hw, -hh, -hl, 0.0, 1.0, -1.0, 0.0, 0.0,

		-hw,  hh, -hl, 0.0, 1.0, 0.0, 0.0, 1.0,
		-hw,  hh,  hl, 0.0, 1.0, 0.0, 0.0, 0.0,
		 hw,  hh,  hl, 0.0, 1.0, 0.0, 1.0, 0.0,
		 hw,  hh, -hl, 0.0, 1.0, 0.0, 1.0, 1.0,

		-hw, -hh, -hl, 0.0, -1.0, 0.0, 1.0, 1.0,
		 hw, -hh, -hl, 0.0, -1.0, 0.0, 0.0, 1.0,
		 hw, -hh,  hl, 0.0, -1.0, 0.0, 0.0, 0.0,
		-hw, -hh,  hl, 0.0, -1.0, 0.0, 1.0, 0.0,

		 hw, -hh, -hl, 1.0, 0.0, 0.0, 1.0, 0.0,
         hw,  hh, -hl, 1.0, 0.0, 0.0, 1.0, 1.0,
         hw,  hh,  hl, 1.0, 0.0, 0.0, 0.0, 1.0,
         hw, -hh,  hl, 1.0, 0.0, 0.0, 0.0, 0.0,

        -hw, -hh, -hl, -1.0, 1.0, 0.0, 0.0, 0.0,
        -hw, -hh,  hl, -1.0, 1.0, 0.0, 1.0, 0.0,
        -hw,  hh,  hl, -1.0, 1.0, 0.0, 1.0, 1.0,
        -hw,  hh, -hl, -1.0, 1.0, 0.0, 0.0, 1.0,
	}
	//odinfmt: enable

	NORMAL_OFFSET :: 24 * 3
	UV_OFFSET :: 24 * 6
	vertices := make([]f32, 24 * 8, geometry_allocator)
	positions := transmute([]Vector3)vertices[:NORMAL_OFFSET]
	normals := transmute([]Vector3)vertices[NORMAL_OFFSET:UV_OFFSET]
	uvs := transmute([]Vector2)vertices[UV_OFFSET:]
	for i in 0 ..< 24 {
		index := i * 8
		positions[i] = {v[index], v[index + 1], v[index + 2]}
		normals[i] = {v[index + 3], v[index + 4], v[index + 5]}
		uvs[i] = {v[index + 6], v[index + 7]}
	}

	indices := make([]u32, 36, geometry_allocator)
	j: u32 = 0
	for i := 0; i < 36; i, j = i + 6, j + 1 {
		indices[i] = 4 * j
		indices[i + 1] = 4 * j + 1
		indices[i + 2] = 4 * j + 2
		indices[i + 3] = 4 * j
		indices[i + 4] = 4 * j + 2
		indices[i + 5] = 4 * j + 3
	}

	layout_map := Vertex_Layout_Map {
		layout  = Vertex_Layout(
			slice.clone([]Vertex_Format{.Float3, .Float3, .Float2}, layout_allocator),
		),
		offsets = slice.clone(
			[]int{0, NORMAL_OFFSET * size_of(f32), UV_OFFSET * size_of(f32)},
			layout_allocator,
		),
	}

	return vertices, indices, layout_map
}

load_mesh_from_slice :: proc(
	vert_slice: []f32,
	index_slice: []u32,
	layout_map: Vertex_Layout_Map,
) -> Mesh {
	mesh := Mesh {
		state      = get_ctx_attribute_state(layout_map.layout),
		layout_map = layout_map,
		vertices   = make_buffer(f32, len(vert_slice)),
		indices    = make_buffer(u32, len(index_slice)),
	}
	send_buffer_data(mesh.vertices, vert_slice)
	send_buffer_data(mesh.indices, index_slice)
	return mesh
}

destroy_mesh :: proc(mesh: Mesh) {
	destroy_buffer(mesh.vertices)
	destroy_buffer(mesh.indices)
	delete_vertex_layout_map(mesh.layout_map)
}
