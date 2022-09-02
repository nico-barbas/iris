package iris

import "core:slice"
import gl "vendor:OpenGL"

Vertex_Layout_Map :: struct {
	layout:  Vertex_Layout,
	offsets: []int,
}

delete_vertex_layout_map :: proc(m: Vertex_Layout_Map) {
	delete(m.layout)
	delete(m.offsets)
}

Vertex_Layout :: distinct []Vertex_Format

Vertex_Format :: enum u8 {
	Float1 = 1,
	Float2 = 2,
	Float3 = 3,
	Float4 = 4,
}

vertex_layout_equal :: proc(l1, l2: Vertex_Layout) -> bool {
	if len(l1) != len(l2) {
		return false
	}
	for i in 0 ..< len(l1) {
		if l1[i] != l2[i] {
			return false
		}
	}
	return true
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
	format:       Attribute_Format,
}

Attribute_Format :: enum {
	Interleaved,
	Blocks,
}

make_attributes_state :: proc(
	layout: Vertex_Layout,
	format: Attribute_Format = .Blocks,
) -> Attributes_State {
	l := cast([]Vertex_Format)layout
	state := Attributes_State {
		stride_size = vertex_layout_size(layout),
		layout      = Vertex_Layout(slice.clone(l)),
		format      = format,
	}
	gl.CreateVertexArrays(1, &state.handle)

	offset: u32
	for i in 0 ..< len(state.layout) {
		index := u32(i)
		size := i32(state.layout[i])
		gl.EnableVertexArrayAttrib(state.handle, index)
		if format == .Blocks {
			gl.VertexArrayAttribBinding(state.handle, index, index)
			gl.VertexArrayAttribFormat(state.handle, index, size, gl.FLOAT, gl.FALSE, 0)
		} else {
			gl.VertexArrayAttribBinding(state.handle, index, 0)
			gl.VertexArrayAttribFormat(state.handle, index, size, gl.FLOAT, gl.FALSE, offset)
			offset += u32(vertex_format_size(state.layout[i]))
		}
	}
	return state
}

destroy_attributes_state :: proc(state: ^Attributes_State) {
	gl.DeleteVertexArrays(1, &state.handle)
	delete(state.layout)
}

link_attributes_state_vertices :: proc(state: ^Attributes_State, buffer: Buffer, m: Vertex_Layout_Map = {}) {
	if state.format == .Blocks {
		for format, i in m.layout {
			index := u32(i)
			offset := m.offsets[i]
			gl.VertexArrayVertexBuffer(
				state.handle,
				index,
				buffer.handle,
				offset,
				i32(vertex_format_size(format)),
			)
		}
	} else {
		gl.VertexArrayVertexBuffer(state.handle, 0, buffer.handle, 0, i32(vertex_layout_size(state.layout)))
	}
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
