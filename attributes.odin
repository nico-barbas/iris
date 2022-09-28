package iris

// import "core:slice"
import gl "vendor:OpenGL"

Attributes :: struct {
	using layout: Attribute_Layout,
	handle:       u32,
	format:       Attribute_Format,
	info:         union {
		Interleaved_Attributes,
		Packed_Attributes,
		Array_Attributes,
	},
}

Interleaved_Attributes :: struct {
	stride_size: int,
}

Packed_Attributes :: struct {
	offsets: [len(Attribute_Kind)]int,
}

Array_Attributes :: struct {
	buffers: [len(Attribute_Kind)]^Buffer,
}

Attribute_Format :: enum {
	Interleaved,
	Packed_Blocks,
	Block_Arrays,
}

Attribute_Layout :: struct {
	enabled:   Enabled_Attributes,
	accessors: [len(Attribute_Kind)]Maybe(Buffer_Data_Type),
}

Enabled_Attributes :: distinct bit_set[Attribute_Kind]

Attribute_Kind :: enum {
	Position           = 0,
	Normal             = 1,
	Tangent            = 2,
	Joint              = 3,
	Weight             = 4,
	Tex_Coord          = 5,
	Color              = 6,
	Instance_Transform = 7,
}

attribute_layout_size :: proc(layout: Attribute_Layout) -> (size: int) {
	for kind in Attribute_Kind {
		if kind in layout.enabled {
			size += accesor_size(layout.accessors[kind].?)
		}
	}
	return
}

@(private)
accesor_size :: proc(a: Buffer_Data_Type) -> int {
	return buffer_size_of[a.kind] * buffer_len_of[a.format]
}

@(private)
attribute_layout_equal :: proc(l1, l2: Attribute_Layout) -> bool {
	if l1.enabled != l2.enabled {
		return false
	}

	for kind in Attribute_Kind {
		if kind in l1.enabled {
			a1 := l1.accessors[kind].?
			a2 := l2.accessors[kind].?
			if a1.kind != a2.kind || a1.format != a2.format {
				return false
			}
		}
	}
	return true
}

@(private)
internal_make_attributes :: proc(
	layout: Attribute_Layout,
	format: Attribute_Format,
) -> Attributes {
	attributes := Attributes {
		layout = layout,
		format = format,
	}
	gl.CreateVertexArrays(1, &attributes.handle)

	for kind in Attribute_Kind {
		if kind in attributes.enabled {
			attribute_location := u32(kind)
			gl.EnableVertexArrayAttrib(attributes.handle, attribute_location)
		}
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
		for kind in Attribute_Kind {
			if kind in attributes.enabled {
				attribute_location := u32(kind)
				accessor := attributes.accessors[kind].?
				gl.VertexArrayAttribBinding(attributes.handle, attribute_location, 0)
				gl.VertexArrayAttribFormat(
					attributes.handle,
					attribute_location,
					i32(buffer_len_of[accessor.format]),
					gl.FLOAT,
					gl.FALSE,
					stride_offset,
				)
				stride_offset += u32(accesor_size(accessor))
			}
		}


	case .Packed_Blocks:
		for kind in Attribute_Kind {
			if kind in attributes.enabled {
				enable_single_attribute(attributes, kind)
			}
		}

	case .Block_Arrays:
		unimplemented()
	}
}

@(private)
enable_single_attribute :: proc(attributes: ^Attributes, kind: Attribute_Kind) {
	attribute_location := u32(kind)
	accessor := attributes.accessors[kind].?
	if kind == .Instance_Transform && accessor.format == .Mat4 {
		column_size := size_of(Vector4)
		// 1st Column
		gl.EnableVertexArrayAttrib(attributes.handle, attribute_location)
		gl.VertexArrayAttribBinding(attributes.handle, attribute_location, attribute_location)
		gl.VertexArrayBindingDivisor(attributes.handle, attribute_location, 1)
		gl.VertexArrayAttribFormat(
			attributes.handle,
			attribute_location,
			i32(buffer_len_of[Buffer_Data_Format.Vector4]),
			gl.FLOAT,
			gl.FALSE,
			0,
		)

		// 2nd Column
		gl.EnableVertexArrayAttrib(attributes.handle, attribute_location + 1)
		gl.VertexArrayAttribBinding(
			attributes.handle,
			attribute_location + 1,
			attribute_location + 1,
		)
		gl.VertexArrayBindingDivisor(attributes.handle, attribute_location + 1, 1)
		gl.VertexArrayAttribFormat(
			attributes.handle,
			attribute_location + 1,
			i32(buffer_len_of[Buffer_Data_Format.Vector4]),
			gl.FLOAT,
			gl.FALSE,
			u32(column_size),
		)

		// 3rd Column
		gl.EnableVertexArrayAttrib(attributes.handle, attribute_location + 2)
		gl.VertexArrayAttribBinding(
			attributes.handle,
			attribute_location + 2,
			attribute_location + 2,
		)
		gl.VertexArrayBindingDivisor(attributes.handle, attribute_location + 2, 1)
		gl.VertexArrayAttribFormat(
			attributes.handle,
			attribute_location + 2,
			i32(buffer_len_of[Buffer_Data_Format.Vector4]),
			gl.FLOAT,
			gl.FALSE,
			u32(column_size * 2),
		)

		// 4th Column
		gl.EnableVertexArrayAttrib(attributes.handle, attribute_location + 3)
		gl.VertexArrayAttribBinding(
			attributes.handle,
			attribute_location + 3,
			attribute_location + 3,
		)
		gl.VertexArrayBindingDivisor(attributes.handle, attribute_location + 3, 1)
		gl.VertexArrayAttribFormat(
			attributes.handle,
			attribute_location + 3,
			i32(buffer_len_of[Buffer_Data_Format.Vector4]),
			gl.FLOAT,
			gl.FALSE,
			u32(column_size * 3),
		)
	} else {
		gl.EnableVertexArrayAttrib(attributes.handle, attribute_location)
		gl.VertexArrayAttribBinding(attributes.handle, attribute_location, attribute_location)
		gl.VertexArrayAttribFormat(
			attributes.handle,
			attribute_location,
			i32(buffer_len_of[accessor.format]),
			gl.FLOAT,
			gl.FALSE,
			0,
		)
	}
}

destroy_attributes :: proc(attributes: ^Attributes) {
	gl.DeleteVertexArrays(1, &attributes.handle)
}

link_interleaved_attributes_vertices :: proc(attributes: ^Attributes, buffer: ^Buffer) {
	gl.VertexArrayVertexBuffer(
		attributes.handle,
		0,
		buffer.handle,
		0,
		i32(attribute_layout_size(attributes)),
	)
}

link_packed_attributes_vertices :: proc(
	attributes: ^Attributes,
	buffer: ^Buffer,
	info: Packed_Attributes,
) {
	for kind in Attribute_Kind {
		if kind in attributes.enabled {
			attribute_location := u32(kind)
			accessor := attributes.accessors[kind].?
			offset := info.offsets[kind]
			gl.VertexArrayVertexBuffer(
				attributes.handle,
				attribute_location,
				buffer.handle,
				offset,
				i32(accesor_size(accessor)),
			)
		}
	}
}

link_packed_attributes_vertices_list :: proc(
	attributes: ^Attributes,
	buffer: ^Buffer,
	list: Enabled_Attributes,
	info: Packed_Attributes,
) {
	for kind in Attribute_Kind {
		if kind in list && kind in attributes.enabled {
			attribute_location := u32(kind)
			accessor := attributes.accessors[kind].?
			offset := info.offsets[kind]
			if kind == .Instance_Transform && accessor.format == .Mat4 {
				column_accessor := Buffer_Data_Type {
					kind   = accessor.kind,
					format = .Vector4,
				}
				column_size := accesor_size(column_accessor)
				gl.VertexArrayVertexBuffer(
					attributes.handle,
					attribute_location,
					buffer.handle,
					offset,
					i32(accesor_size(accessor)),
				)
				gl.VertexArrayVertexBuffer(
					attributes.handle,
					attribute_location + 1,
					buffer.handle,
					offset,
					i32(accesor_size(accessor)),
				)
				gl.VertexArrayVertexBuffer(
					attributes.handle,
					attribute_location + 2,
					buffer.handle,
					offset,
					i32(accesor_size(accessor)),
				)
				gl.VertexArrayVertexBuffer(
					attributes.handle,
					attribute_location + 3,
					buffer.handle,
					offset,
					i32(accesor_size(accessor)),
				)
			} else {
				gl.VertexArrayVertexBuffer(
					attributes.handle,
					attribute_location,
					buffer.handle,
					offset,
					i32(accesor_size(accessor)),
				)
			}
		}
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
