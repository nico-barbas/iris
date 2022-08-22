package zoe

import gl "vendor:OpenGL"

Vertex_Layout :: distinct []Vertex_Format

Vertex_Format :: enum u8 {
	Float1 = 1,
	Float2 = 2,
	Float3 = 3,
	Float4 = 4,
}

vertex_layout_size :: proc(layout: Vertex_Layout) -> int {
	size := 0
	for format in layout {
		size += vertex_format_size(format)
	}
	return size
}

vertex_layout_length :: proc(layout: Vertex_Layout) -> int {
	length := 0
	for format in layout {
		length += int(u8(format))
	}
	return length
}

vertex_format_size :: proc(format: Vertex_Format) -> int {
	switch format {
	case .Float1:
		return size_of(f32) * 1
	case .Float2:
		return size_of(f32) * 2
	case .Float3:
		return size_of(f32) * 3
	case .Float4:
		return size_of(f32) * 4
	case:
		return 0
	}
}

Vertex_State :: struct {
	handle:       u32,
	buffer_index: u32,
	stride_size:  int,
	layout:       Vertex_Layout,
}

make_vertex_state :: proc(layout: Vertex_Layout) -> Vertex_State {
	state := Vertex_State {
		stride_size = vertex_layout_size(layout),
		layout      = layout,
	}
	gl.CreateVertexArrays(1, &state.handle)

	offset: u32 = 0
	for i in 0 ..< len(state.layout) {
		index := u32(i)
		gl.EnableVertexArrayAttrib(state.handle, index)
		gl.VertexArrayAttribFormat(
			state.handle,
			index,
			i32(state.layout[i]),
			gl.FLOAT,
			gl.FALSE,
			offset,
		)
		offset += u32(vertex_format_size(state.layout[i]))
	}
	return state
}

delete_vertex_state :: proc(state: ^Vertex_State) {
	gl.DeleteVertexArrays(1, &state.handle)
}

link_vertex_state_vertices :: proc(state: ^Vertex_State, buffer: ^Buffer) {
	// gl.BindVertexArray(state.handle)
	// gl.BindBuffer(gl.ARRAY_BUFFER, buffer.handle)
	gl.VertexArrayVertexBuffer(
		state.handle,
		state.buffer_index,
		buffer.handle,
		0,
		i32(buffer.stride),
	)
	state.buffer_index += 1

	// gl.BindVertexArray(0)
	// gl.BindBuffer(gl.ARRAY_BUFFER, 0)
}

link_vertex_state_indices :: proc(state: ^Vertex_State, buffer: ^Buffer) {
	// gl.BindVertexArray(state.handle)
	// gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, buffer.handle)

	// gl.BindVertexArray(0)
	// gl.BindBuffer(gl.ELEMENT_ARRAY_BUFFER, 0)
	gl.VertexArrayElementBuffer(state.handle, buffer.handle)
}

// set_vertex_state_program :: proc(state: ^Vertex_State, program: Shader_Program) {
// 	state.program = program.handle
// }

bind_vertex_state :: proc(state: Vertex_State) {
	gl.BindVertexArray(state.handle)
	// gl.UseProgram(state.program)
}

unbind_vertex_state :: proc(state: Vertex_State) {
	gl.BindVertexArray(0)
	// gl.UseProgram(0)
}
