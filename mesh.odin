package iris

import "core:slice"
import "core:math/linalg"

// import "gltf"

Mesh :: struct {
	attributes:      ^Attributes,
	attributes_info: Packed_Attributes,
	vertices:        Buffer_Memory,
	indices:         Buffer_Memory,
	index_count:     int,
}

Mesh_Loader :: struct {
	format:      Attribute_Format,
	byte_size:   int,
	attributes:  [len(Attribute_Kind)]Maybe(Buffer_Source),
	// positions:  Maybe(Buffer_Source),
	// normals:    Maybe(Buffer_Source),
	// tangents:   Maybe(Buffer_Source),
	// joints:     Maybe(Buffer_Source),
	// weights:    Maybe(Buffer_Source),
	// tex_coords: Maybe(Buffer_Source),
	// colors:     Maybe(Buffer_Source),
	indices:     Buffer_Source,
	index_count: int,
	// layout:     Vertex_Layout,
	// offsets:    []int,
}

// delete_mesh_loader :: proc(loader: Mesh_Loader) {
// 	delete(loader.vertices)
// 	delete(loader.indices)
// 	delete(loader.layout)
// 	delete(loader.offsets)
// }

draw_mesh :: proc(mesh: ^Mesh, t: Transform, mat: ^Material) {
	transform := linalg.matrix4_from_trs_f32(t.translation, t.rotation, t.scale)
	push_draw_command(
		Render_Mesh_Command{mesh = mesh, global_transform = transform, material = mat},
	)
}

plane_mesh :: proc(w, h: int, s_w, s_h: int) -> ^Resource {
	v_per_row := s_w + 1
	v_per_col := s_h + 1
	v_count := v_per_row * v_per_col

	// normal_offset := v_count * 3
	// uv_offset := v_count * 6
	// vertices := make([]f32, v_count * 8, context.temp_allocator)
	// positions := slice.reinterpret([]Vector3, (vertices[:normal_offset]))
	// normals := slice.reinterpret([]Vector3, (vertices[normal_offset:uv_offset]))
	// uvs := slice.reinterpret([]Vector2, (vertices[uv_offset:]))
	positions := make([]Vector3, v_count, context.temp_allocator)
	normals := make([]Vector3, v_count, context.temp_allocator)
	uvs := make([]Vector2, v_count, context.temp_allocator)
	p_size := (size_of(Vector3) * v_count)
	n_size := p_size
	t_size := (size_of(Vector2) * v_count)

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
	faces := make([]Face, f_count, context.temp_allocator)
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

	resource := mesh_resource(
		Mesh_Loader{
			byte_size = p_size + n_size + t_size,
			attributes = {
				Attribute_Kind.Position = Buffer_Source{
					data = &positions[0],
					byte_size = size_of(Vector3) * v_count,
					accessor = Accessor{kind = .Float_32, format = .Vector3},
				},
				Attribute_Kind.Normal = Buffer_Source{
					data = &normals[0],
					byte_size = size_of(Vector3) * v_count,
					accessor = Accessor{kind = .Float_32, format = .Vector3},
				},
				Attribute_Kind.Tex_Coord = Buffer_Source{
					data = &uvs[0],
					byte_size = size_of(Vector2) * v_count,
					accessor = Accessor{kind = .Float_32, format = .Vector2},
				},
			},
			indices = Buffer_Source{
				data = &indices[0],
				byte_size = size_of(u32) * len(indices),
				accessor = Accessor{kind = .Unsigned_32, format = .Scalar},
			},
			index_count = len(indices),
			format = .Packed_Blocks,
		},
	)
	return resource
}

cube_mesh :: proc(w, h, l: f32) -> ^Resource {
	CUBE_VERTEX_COUNT :: 24
	CUBE_INDEX_COUNT :: 36
	hw, hh, hl := w / 2, h / 2, h / 2
	//odinfmt: disable
	positions := [CUBE_VERTEX_COUNT]Vector3 {
		{-hw, -hh,  hl },
		{ hw, -hh,  hl },
		{ hw,  hh,  hl },
		{-hw,  hh,  hl },

		{-hw, -hh, -hl },
		{-hw,  hh, -hl },
		{ hw,  hh, -hl },
		{ hw, -hh, -hl },

		{-hw,  hh, -hl },
		{-hw,  hh,  hl },
		{ hw,  hh,  hl },
		{ hw,  hh, -hl },

		{-hw, -hh, -hl },
		{ hw, -hh, -hl },
		{ hw, -hh,  hl },
		{-hw, -hh,  hl },

		{ hw, -hh, -hl },
        { hw,  hh, -hl },
        { hw,  hh,  hl },
        { hw, -hh,  hl },

        {-hw, -hh, -hl },
        {-hw, -hh,  hl },
        {-hw,  hh,  hl },
        {-hw,  hh, -hl },
	}
	normals := [CUBE_VERTEX_COUNT]Vector3 {
		{ 0.0,  0.0,  1.0 },
		{ 0.0,  0.0,  1.0 },
		{ 0.0,  0.0,  1.0 },
	    { 0.0,  0.0,  1.0 },

	    { 0.0,  1.0, -1.0 },
	    { 0.0,  1.0, -1.0 },
		{ 0.0,  1.0, -1.0 },
		{ 0.0,  1.0, -1.0 },

	    { 0.0,  1.0,  0.0 },
	    { 0.0,  1.0,  0.0 },
		{ 0.0,  1.0,  0.0 },
		{ 0.0,  1.0,  0.0 },

	    { 0.0, -1.0,  0.0 },
	  	{ 0.0, -1.0,  0.0 },
	  	{ 0.0, -1.0,  0.0 },
	    { 0.0, -1.0,  0.0 },

		{ 1.0,  0.0,  0.0 },
		{ 1.0,  0.0,  0.0 },
		{ 1.0,  0.0,  0.0 },
		{ 1.0,  0.0,  0.0 },

	    { -1.0, 1.0,  0.0 },
	    { -1.0, 1.0,  0.0 },
	    { -1.0, 1.0,  0.0 },
	    { -1.0, 1.0,  0.0 },
	}
	tex_coords :=  [CUBE_VERTEX_COUNT]Vector2 {
		{0.0, 0.0},
		{1.0, 0.0},
		{1.0, 1.0},
	    {0.0, 1.0},

	    {1.0, 0.0},
	    {1.0, 1.0},
		{0.0, 1.0},
		{0.0, 0.0},

	    {0.0, 1.0},
	    {0.0, 0.0},
		{1.0, 0.0},
		{1.0, 1.0},

	    {1.0, 1.0},
		{0.0, 1.0},
		{0.0, 0.0},
	    {1.0, 0.0},

		{1.0, 0.0},
		{1.0, 1.0},
		{0.0, 1.0},
		{0.0, 0.0},

	    {0.0, 0.0},
	    {1.0, 0.0},
	    {1.0, 1.0},
	    {0.0, 1.0},
	}
	//odinfmt: enable


	p_size := (size_of(Vector3) * CUBE_VERTEX_COUNT)
	n_size := p_size
	t_size := (size_of(Vector2) * CUBE_VERTEX_COUNT)

	indices := [CUBE_INDEX_COUNT]u32{}
	j: u32 = 0
	for i := 0; i < 36; i, j = i + 6, j + 1 {
		indices[i] = 4 * j
		indices[i + 1] = 4 * j + 1
		indices[i + 2] = 4 * j + 2
		indices[i + 3] = 4 * j
		indices[i + 4] = 4 * j + 2
		indices[i + 5] = 4 * j + 3
	}

	resource := mesh_resource(
		Mesh_Loader{
			byte_size = p_size + n_size + t_size,
			attributes = {
				Attribute_Kind.Position = Buffer_Source{
					data = &positions[0],
					byte_size = size_of(Vector3) * CUBE_VERTEX_COUNT,
					accessor = Accessor{kind = .Float_32, format = .Vector3},
				},
				Attribute_Kind.Normal = Buffer_Source{
					data = &normals[0],
					byte_size = size_of(Vector3) * CUBE_VERTEX_COUNT,
					accessor = Accessor{kind = .Float_32, format = .Vector3},
				},
				Attribute_Kind.Tex_Coord = Buffer_Source{
					data = &tex_coords[0],
					byte_size = size_of(Vector2) * CUBE_VERTEX_COUNT,
					accessor = Accessor{kind = .Float_32, format = .Vector2},
				},
			},
			indices = Buffer_Source{
				data = &indices[0],
				byte_size = size_of(u32) * CUBE_INDEX_COUNT,
				accessor = Accessor{kind = .Unsigned_32, format = .Scalar},
			},
			index_count = CUBE_INDEX_COUNT,
			format = .Packed_Blocks,
		},
	)
	return resource
}

@(private)
internal_load_mesh_from_slice :: proc(loader: Mesh_Loader) -> Mesh {
	attribute_count: int
	for attribute in loader.attributes {
		if attribute != nil {
			attribute_count += 1
		}
	}

	mesh: Mesh
	offset: int
	index: int
	layout := make([]Accessor, attribute_count, context.temp_allocator)
	offsets := make([]int, attribute_count)
	vertex_buffer := raw_buffer_resource(loader.byte_size)
	index_buffer := raw_buffer_resource(loader.indices.byte_size)

	mesh.vertices = buffer_memory_from_buffer_resource(vertex_buffer)
	mesh.indices = buffer_memory_from_buffer_resource(index_buffer)
	mesh.index_count = loader.index_count
	for attribute in loader.attributes {
		if attribute != nil {
			a := attribute.?
			offsets[index] = offset
			layout[index] = a.accessor
			send_buffer_data(&mesh.vertices, a, offset)
			offset += a.byte_size
			index += 1
		}
	}
	send_buffer_data(&mesh.indices, loader.indices)
	mesh.attributes = attributes_from_layout(layout, loader.format)
	mesh.attributes_info = Packed_Attributes {
		offsets = offsets,
	}


	// v_size := size_of(f32) * len(loader.vertices)
	// i_size := size_of(u32) * len(loader.indices)
	// vertex_buffer := raw_buffer_resource(loader.byte_size)
	// index_buffer := raw_buffer_resource(i_size)
	// mesh := Mesh {
	// 	attributes = attributes_from_layout(loader.layout, loader.format),
	// 	attributes_info = Packed_Attributes{offsets = slice.clone(loader.offsets)},
	// 	vertices = buffer_memory_from_buffer_resource(vertex_buffer),
	// 	indices = buffer_memory_from_buffer_resource(index_buffer),
	// 	index_count = len(loader.indices),
	// }
	// send_buffer_data(
	// 	&mesh.vertices,
	// 	Buffer_Source{size = v_size, data = &loader.vertices[0], kind = .Float_32},
	// )
	// send_buffer_data(
	// 	&mesh.indices,
	// 	Buffer_Source{data = &loader.indices[0], kind = .Unsigned_32, size = i_size},
	// )
	return mesh
}

destroy_mesh :: proc(mesh: ^Mesh) {}
