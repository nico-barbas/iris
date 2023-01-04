package iris

import "core:slice"
import "core:math/linalg"

Mesh :: struct {
	attributes:      ^Attributes,
	attributes_info: Packed_Attributes,
	vertex_buffer:   ^Resource,
	index_buffer:    ^Resource,
	vertices:        Buffer_Memory,
	indices:         Buffer_Memory,
	index_count:     int,
}

Mesh_Loader :: struct {
	format:      Attribute_Format,
	byte_size:   int,
	enabled:     Enabled_Attributes,
	sources:     [len(Attribute_Kind)]Maybe(Buffer_Source),
	indices:     Buffer_Source,
	index_count: int,
}

draw_mesh :: proc(mesh: ^Mesh, t: Transform, mat: ^Material) {
	transform := linalg.matrix4_from_trs_f32(t.translation, t.rotation, t.scale)
	push_draw_command(
		Render_Mesh_Command{mesh = mesh, global_transform = transform, material = mat},
		.Deferred_Geometry_Static,
	)
}

plane_mesh :: proc(w, h: int, s_w, s_h: int, uv_repeat: int, normal := VECTOR_UP) -> ^Resource {
	v_per_row := s_w + 1
	v_per_col := s_h + 1
	v_count := v_per_row * v_per_col

	positions := make([]Vector3, v_count, context.temp_allocator)
	normals := make([]Vector3, v_count, context.temp_allocator)
	tangents := make([]Vector3, v_count, context.temp_allocator)
	uvs := make([]Vector2, v_count, context.temp_allocator)
	p_size := (size_of(Vector3) * v_count)
	n_size := p_size
	tan_size := p_size
	t_size := (size_of(Vector2) * v_count)

	offset := Vector2{f32(w) / 2, f32(h) / 2}
	step_x := f32(w) / f32(s_w)
	step_y := f32(h) / f32(s_h)
	for y in 0 ..< v_per_col {
		for x in 0 ..< v_per_row {
			positions[y * v_per_row + x] = {
				step_x * f32(x) - offset.x,
				0,
				step_y * f32(y) - offset.y,
			}
			normals[y * v_per_row + x] = normal
			tangents[y * v_per_row + x] = VECTOR_RIGHT

			u := f32(x) / f32(uv_repeat)
			v := f32(y) / f32(uv_repeat)
			uvs[y * v_per_row + x] = {u, v}
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
	triangles := slice.reinterpret([]Triangle, faces)
	for triangle in triangles {
		edge1 := positions[triangle.y] - positions[triangle.z]
		edge2 := positions[triangle.x] - positions[triangle.z]
		d_uv1 := uvs[triangle.y] - uvs[triangle.z]
		d_uv2 := uvs[triangle.x] - uvs[triangle.z]

		f := 1 / (d_uv1.x * d_uv2.y - d_uv2.x * d_uv1.y)
		tangent := Vector3{
			f * (d_uv2.y * edge1.x - d_uv1.y * edge2.x),
			f * (d_uv2.y * edge1.y - d_uv1.y * edge2.y),
			f * (d_uv2.y * edge1.z - d_uv1.y * edge2.z),
		}

		tangents[triangle.x] += tangent
		tangents[triangle.y] += tangent
		tangents[triangle.z] += tangent
	}
	for tangent in &tangents {
		tangent = linalg.vector_normalize(tangent)
	}

	indices := slice.reinterpret([]u32, faces)

	resource := mesh_resource(
		Mesh_Loader{
			byte_size = p_size + n_size + tan_size + t_size,
			enabled = {.Position, .Normal, .Tangent, .Tex_Coord},
			sources = {
				Attribute_Kind.Position = Buffer_Source{
					data = &positions[0],
					byte_size = size_of(Vector3) * v_count,
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector3},
				},
				Attribute_Kind.Normal = Buffer_Source{
					data = &normals[0],
					byte_size = size_of(Vector3) * v_count,
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector3},
				},
				Attribute_Kind.Tangent = Buffer_Source{
					data = &tangents[0],
					byte_size = size_of(Vector3) * v_count,
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector3},
				},
				Attribute_Kind.Tex_Coord = Buffer_Source{
					data = &uvs[0],
					byte_size = size_of(Vector2) * v_count,
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector2},
				},
			},
			indices = Buffer_Source{
				data = &indices[0],
				byte_size = size_of(u32) * len(indices),
				accessor = Buffer_Data_Type{kind = .Unsigned_32, format = .Scalar},
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
			enabled = {.Position, .Normal, .Tex_Coord},
			sources = {
				Attribute_Kind.Position = Buffer_Source{
					data = &positions[0],
					byte_size = size_of(Vector3) * CUBE_VERTEX_COUNT,
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector3},
				},
				Attribute_Kind.Normal = Buffer_Source{
					data = &normals[0],
					byte_size = size_of(Vector3) * CUBE_VERTEX_COUNT,
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector3},
				},
				Attribute_Kind.Tex_Coord = Buffer_Source{
					data = &tex_coords[0],
					byte_size = size_of(Vector2) * CUBE_VERTEX_COUNT,
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector2},
				},
			},
			indices = Buffer_Source{
				data = &indices[0],
				byte_size = size_of(u32) * CUBE_INDEX_COUNT,
				accessor = Buffer_Data_Type{kind = .Unsigned_32, format = .Scalar},
			},
			index_count = CUBE_INDEX_COUNT,
			format = .Packed_Blocks,
		},
	)
	return resource
}

@(private)
internal_load_mesh_from_slice :: proc(loader: Mesh_Loader) -> Mesh {
	mesh: Mesh
	offset: int
	layout: Attribute_Layout
	offsets: [len(Attribute_Kind)]int
	mesh.vertex_buffer = raw_buffer_resource(loader.byte_size)
	mesh.index_buffer = raw_buffer_resource(loader.indices.byte_size)

	mesh.vertices = buffer_memory_from_buffer_resource(mesh.vertex_buffer)
	mesh.indices = buffer_memory_from_buffer_resource(mesh.index_buffer)
	mesh.index_count = loader.index_count
	for kind in Attribute_Kind {
		if kind in loader.enabled {
			a := loader.sources[kind].?
			offsets[kind] = offset
			layout.accessors[kind] = a.accessor
			send_buffer_data(&mesh.vertices, a, offset)
			offset += a.byte_size
		}
	}
	send_buffer_data(&mesh.indices, loader.indices)
	layout.enabled = loader.enabled
	mesh.attributes = attributes_from_layout(layout, loader.format)
	mesh.attributes_info = Packed_Attributes {
		offsets = offsets,
	}
	return mesh
}

destroy_mesh :: proc(mesh: ^Mesh) {
}
