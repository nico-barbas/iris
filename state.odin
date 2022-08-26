package iris

// import "core:log"
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

Attributes_State :: struct {
	handle:       u32,
	buffer_index: u32,
	stride_size:  int,
	layout:       Vertex_Layout,
}

make_attributes_state :: proc(layout: Vertex_Layout) -> Attributes_State {
	state := Attributes_State {
		stride_size = vertex_layout_size(layout),
		layout      = layout,
	}
	gl.CreateVertexArrays(1, &state.handle)

	offset: u32 = 0
	for i in 0 ..< len(state.layout) {
		index := u32(i)
		size := i32(state.layout[i])
		gl.EnableVertexArrayAttrib(state.handle, index)
		gl.VertexArrayAttribBinding(state.handle, index, state.buffer_index)
		gl.VertexArrayAttribFormat(state.handle, index, size, gl.FLOAT, gl.FALSE, offset)
		offset += u32(vertex_format_size(state.layout[i]))
	}
	return state
}

destroy_attributes_state :: proc(state: ^Attributes_State) {
	gl.DeleteVertexArrays(1, &state.handle)
}

link_attributes_state_vertices :: proc(state: ^Attributes_State, buffer: Buffer) {
	gl.VertexArrayVertexBuffer(
		state.handle,
		state.buffer_index,
		buffer.handle,
		0,
		i32(state.stride_size),
	)
	state.buffer_index += 1
}

link_attributes_state_indices :: proc(state: ^Attributes_State, buffer: Buffer) {
	gl.VertexArrayElementBuffer(state.handle, buffer.handle)
}

bind_attributes_state :: proc(state: Attributes_State) {
	gl.BindVertexArray(state.handle)
}

unbind_attributes_state :: proc() {
	gl.BindVertexArray(0)
}
