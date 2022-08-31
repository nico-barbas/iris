package iris

// import "core:fmt"
import "core:mem"
import "core:slice"

import "gltf"

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
			positions[y * v_per_row + x] = {step_x * f32(x) - offset.x, 0, step_y * f32(y) - offset.y}
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
		layout  = Vertex_Layout(slice.clone([]Vertex_Format{.Float3, .Float3, .Float2}, layout_allocator)),
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
		layout  = Vertex_Layout(slice.clone([]Vertex_Format{.Float3, .Float3, .Float2}, layout_allocator)),
		offsets = slice.clone(
			[]int{0, NORMAL_OFFSET * size_of(f32), UV_OFFSET * size_of(f32)},
			layout_allocator,
		),
	}

	return vertices, indices, layout_map
}

load_mesh_from_gltf_node :: proc(
	document: ^gltf.Document,
	node: ^gltf.Node,
	geometry_allocator: mem.Allocator,
	layout_allocator: mem.Allocator,
	flip_normals := false,
) -> Mesh {
	data := node.data.(gltf.Node_Mesh_Data).mesh

	assert(len(data.primitives) == 1)

	primitive := data.primitives[0]
	assert(primitive.indices != nil)

	indices: []u32
	#partial switch data in primitive.indices.data {
	case []u16:
		indices = make([]u32, len(data))
		for index, i in data {
			indices[i] = u32(index)
		}
	case []u32:
		indices = data
	case:
		assert(false)
	}


	kind_to_component_count :: proc(kind: gltf.Accessor_Kind) -> (uint, bool) {
		#partial switch kind {
		case .Vector2:
			return 2, true
		case .Vector3:
			return 3, true
		case .Vector4:
			return 4, true
		case .Scalar:
			return 1, true
		case:
			return 0, false
		}
	}
	v_count: uint
	p_slice: []f32
	n_slice: []f32
	t_slice: []f32
	uv_slice: []f32
	if position, has_position := primitive.attributes["POSITION"]; has_position {
		component_count, ok := kind_to_component_count(position.data.kind)
		assert(ok)
		v_count += position.data.count * component_count
		assert(position.data.component_kind == .Float)
		accessor := position.data
		p_slice = slice.reinterpret([]f32, accessor.data.([]gltf.Vector3f32))
	}
	if normal, has_normal := primitive.attributes["NORMAL"]; has_normal {
		component_count, ok := kind_to_component_count(normal.data.kind)
		assert(ok)
		v_count += normal.data.count * component_count
		assert(normal.data.component_kind == .Float)
		accessor := normal.data
		n_slice = slice.reinterpret([]f32, accessor.data.([]gltf.Vector3f32))
	}
	if tangent, has_tangent := primitive.attributes["TANGENT"]; has_tangent {
		component_count, ok := kind_to_component_count(tangent.data.kind)
		assert(ok)
		v_count += tangent.data.count * component_count
		assert(tangent.data.component_kind == .Float)
		accessor := tangent.data
		t_slice = slice.reinterpret([]f32, accessor.data.([]gltf.Vector4f32))
	}
	if tex_coord, has_tex_coord := primitive.attributes["TEXCOORD_0"]; has_tex_coord {
		component_count, ok := kind_to_component_count(tex_coord.data.kind)
		assert(ok)
		v_count += tex_coord.data.count * component_count
		assert(tex_coord.data.component_kind == .Float)
		accessor := tex_coord.data
		uv_slice = slice.reinterpret([]f32, accessor.data.([]gltf.Vector2f32))
	}
	vertices := make([]f32, v_count, geometry_allocator)
	copy(vertices[:], p_slice[:])
	p_off := len(p_slice)
	if flip_normals {
		for i := 0; i < len(n_slice); i += 3 {
			vertices[p_off + i] = -n_slice[i]
			vertices[p_off + i + 1] = -n_slice[i + 1]
			vertices[p_off + i + 2] = -n_slice[i + 2]
		}
	} else {
		copy(vertices[p_off:], n_slice)
	}
	n_off := p_off + len(n_slice)
	copy(vertices[n_off:], t_slice)
	t_off := n_off + len(t_slice)
	copy(vertices[t_off:], uv_slice)

	layout_map := Vertex_Layout_Map {
		layout  = Vertex_Layout(
			slice.clone([]Vertex_Format{.Float3, .Float3, .Float4, .Float2}, layout_allocator),
		),
		offsets = slice.clone(
			[]int{0, p_off * size_of(f32), n_off * size_of(f32), t_off * size_of(f32)},
			layout_allocator,
		),
	}

	return load_mesh_from_slice(vertices, indices, layout_map)
}

load_mesh_from_slice :: proc(vert_slice: []f32, index_slice: []u32, layout_map: Vertex_Layout_Map) -> Mesh {
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
