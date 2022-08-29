package iris

Mesh :: struct {
	state:    Attributes_State,
	vertices: Buffer,
	indices:  Buffer,
}

draw_mesh :: proc(mesh: Mesh, t: Transform, mat: Material) {
	push_draw_command(Render_Mesh_Command{mesh = mesh, transform = t, material = mat})
}

cube_mesh :: proc(w, h, l: f32, allocator := context.allocator) -> ([]f32, []u32) {
	hw, hh, hl := w / 2, h / 2, h / 2
	//odinfmt: disable
	v := [24*5]f32 {
		-hw, -hh, hl, 0.0, 0.0,
		hw, -hh, hl, 1.0, 0.0,
		hw, hh, hl, 1.0, 1.0,
		-hw, hh, hl, 0.0, 1.0,
		-hw, -hh, -hl, 1.0, 0.0,
		-hw, hh, -hl, 1.0, 1.0,
		hw, hh, -hl, 0.0, 1.0,
		hw, -hh, -hl, 0.0, 0.0,
		-hw, hh, -hl, 0.0, 1.0,
		-hw, hh, hl, 0.0, 0.0,
		hw, hh, hl, 1.0, 0.0,
		hw, hh, -hl, 1.0, 1.0,
		-hw, -hh, - hl, 1.0, 1.0,
		hw, -hh, -hl, 0.0, 1.0,
		hw, -hh, hl, 0.0, 0.0,
		-hw, -hh, hl, 1.0, 0.0,
		hw, -hh, -hl, 1.0, 0.0,
        hw, hh, -hl, 1.0, 1.0,
        hw, hh, hl, 0.0, 1.0,
        hw, -hh, hl, 0.0, 0.0,
        -hw, -hh, -hl, 0.0, 0.0,
        -hw, -hh, hl, 1.0, 0.0,
        -hw, hh, hl, 1.0, 1.0,
        -hw, hh, -hl, 0.0, 1.0,
	}
	//odinfmt: enable


	vertices := make([]f32, 24 * 5, allocator)
	copy(vertices[:], v[:])

	indices := make([]u32, 36, allocator)
	j: u32 = 0
	for i := 0; i < 36; i, j = i + 6, j + 1 {
		indices[i] = 4 * j
		indices[i + 1] = 4 * j + 1
		indices[i + 2] = 4 * j + 2
		indices[i + 3] = 4 * j
		indices[i + 4] = 4 * j + 2
		indices[i + 5] = 4 * j + 3
	}

	return vertices, indices
}

load_mesh_from_slice :: proc(
	vert_slice: []f32,
	index_slice: []u32,
	layout: Vertex_Layout,
) -> Mesh {
	mesh := Mesh {
		state    = get_ctx_attribute_state(layout),
		vertices = make_buffer(f32, len(vert_slice)),
		indices  = make_buffer(u32, len(index_slice)),
	}
	send_buffer_data(mesh.vertices, vert_slice)
	send_buffer_data(mesh.indices, index_slice)
	return mesh
}

destroy_mesh :: proc(mesh: Mesh) {
	destroy_buffer(mesh.vertices)
	destroy_buffer(mesh.indices)
}
