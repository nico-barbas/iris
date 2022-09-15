package iris

import "core:slice"
import gl "vendor:OpenGL"

Attributes :: struct {
	handle: u32,
	format: Attribute_Format,
	layout: []Buffer_Data_Type,
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

Attribute_Kind :: enum {
	Position,
	Normal,
	Tangent,
	Joint,
	Weight,
	Tex_Coord,
	Color,
}

attribute_layout_size :: proc(layout: []Buffer_Data_Type) -> (size: int) {
	for accessor in layout {
		size += accesor_size(accessor)
	}
	return
}

@(private)
accesor_size :: proc(a: Buffer_Data_Type) -> int {
	return buffer_size_of[a.kind] * buffer_len_of[a.format]
}

@(private)
attribute_layout_equal :: proc(l1, l2: []Buffer_Data_Type) -> bool {
	if len(l1) != len(l2) {
		return false
	}

	for a1, i in l1 {
		a2 := l2[i]
		if a1.kind != a2.kind || a1.format != a2.format {
			return false
		}
	}
	return true
}

@(private)
internal_make_attributes :: proc(
	layout: []Buffer_Data_Type,
	format: Attribute_Format,
) -> Attributes {
	attributes := Attributes {
		layout = slice.clone(layout),
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
			stride_size = attribute_layout_size(attributes.layout),
		}
		stride_offset: u32
		for accessor, i in attributes.layout {
			index := u32(i)
			// size := i32(format)
			gl.VertexArrayAttribBinding(attributes.handle, index, 0)
			gl.VertexArrayAttribFormat(
				attributes.handle,
				index,
				i32(buffer_len_of[accessor.format]),
				gl.FLOAT,
				gl.FALSE,
				stride_offset,
			)
			stride_offset += u32(accesor_size(accessor))
		}


	case .Packed_Blocks:
		for accessor, i in attributes.layout {
			index := u32(i)
			gl.EnableVertexArrayAttrib(attributes.handle, index)
			gl.VertexArrayAttribBinding(attributes.handle, index, index)
			gl.VertexArrayAttribFormat(
				attributes.handle,
				index,
				i32(buffer_len_of[accessor.format]),
				gl.FLOAT,
				gl.FALSE,
				0,
			)
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
		i32(attribute_layout_size(attributes.layout)),
	)
}

link_packed_attributes_vertices :: proc(
	attributes: ^Attributes,
	buffer: ^Buffer,
	info: Packed_Attributes,
) {
	for accessor, i in attributes.layout {
		index := u32(i)
		offset := info.offsets[i]
		gl.VertexArrayVertexBuffer(
			attributes.handle,
			index,
			buffer.handle,
			offset,
			i32(accesor_size(accessor)),
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
