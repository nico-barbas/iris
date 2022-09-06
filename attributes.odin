package iris

import "core:slice"
import gl "vendor:OpenGL"

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

Attributes :: struct {
	handle: u32,
	format: Attribute_Format,
	layout: Vertex_Layout,
	info:   union {
		Interleaved_Attributes,
		Packed_Attributes,
		Array_Attributes,
	},
}

Interleaved_Attributes :: struct {
	stride_size: int,
}

Packed_Attributes :: struct {
	offsets: []int,
}

Array_Attributes :: struct {
	buffers: []^Buffer,
}

Attribute_Format :: enum {
	Interleaved,
	Packed_Blocks,
	Block_Arrays,
}

@(private)
internal_make_attributes :: proc(layout: Vertex_Layout, format: Attribute_Format) -> Attributes {
	l := cast([]Vertex_Format)layout
	attributes := Attributes {
		layout = Vertex_Layout(slice.clone(l)),
		format = format,
	}
	gl.CreateVertexArrays(1, &attributes.handle)

	for i in 0 ..< len(attributes.layout) {
		index := u32(i)
		gl.EnableVertexArrayAttrib(attributes.handle, index)
	}
	init_attributes(&attributes)
	return attributes
}

init_attributes :: proc(attributes: ^Attributes) {
	switch attributes.format {
	case .Interleaved:
		attributes.info = Interleaved_Attributes {
			stride_size = vertex_layout_size(attributes.layout),
		}
		stride_offset: u32
		for format, i in attributes.layout {
			index := u32(i)
			size := i32(format)
			gl.VertexArrayAttribBinding(attributes.handle, index, 0)
			gl.VertexArrayAttribFormat(attributes.handle, index, size, gl.FLOAT, gl.FALSE, stride_offset)
			stride_offset += u32(vertex_format_size(format))
		}


	case .Packed_Blocks:
		for format, i in attributes.layout {
			index := u32(i)
			size := i32(format)
			gl.EnableVertexArrayAttrib(attributes.handle, index)
			gl.VertexArrayAttribBinding(attributes.handle, index, index)
			gl.VertexArrayAttribFormat(attributes.handle, index, size, gl.FLOAT, gl.FALSE, 0)
		}

	case .Block_Arrays:
		unimplemented()
	}
}

destroy_attributes :: proc(attributes: ^Attributes) {
	gl.DeleteVertexArrays(1, &attributes.handle)
	delete(attributes.layout)
}

link_interleaved_attributes_vertices :: proc(attributes: ^Attributes, buffer: ^Buffer) {
	gl.VertexArrayVertexBuffer(
		attributes.handle,
		0,
		buffer.handle,
		0,
		i32(vertex_layout_size(attributes.layout)),
	)
}

link_packed_attributes_vertices :: proc(attributes: ^Attributes, buffer: ^Buffer, info: Packed_Attributes) {
	for format, i in attributes.layout {
		index := u32(i)
		offset := info.offsets[i]
		gl.VertexArrayVertexBuffer(
			attributes.handle,
			index,
			buffer.handle,
			offset,
			i32(vertex_format_size(format)),
		)
	}
}


link_attributes_indices :: proc(attributes: ^Attributes, buffer: ^Buffer) {
	gl.VertexArrayElementBuffer(attributes.handle, buffer.handle)
}


bind_attributes :: proc(attributes: ^Attributes) {
	gl.BindVertexArray(attributes.handle)
}

default_attributes :: proc() {
	gl.BindVertexArray(0)
}
