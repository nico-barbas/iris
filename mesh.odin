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
			layout.accessors[kind] = a.accessor

			if kind == .Instance_Transform {
				continue
			}

			offsets[kind] = offset
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
