package iris

import "core:log"
import gl "vendor:OpenGL"

// Generic data buffer stored on the GPU
Buffer :: struct {
	handle:    u32,
	elem_size: int,
	cap:       int,
	raw_size:  int,
}

// Make a buffer of the given data type
make_buffer :: proc($T: typeid, cap: int, reserve := false) -> (buffer: Buffer) {
	buffer = Buffer {
		elem_size = size_of(T),
		cap       = cap,
	}
	gl.CreateBuffers(1, &buffer.handle)

	if reserve {
		gl.NamedBufferData(buffer.handle, cap * buffer.elem_size, nil, gl.STATIC_DRAW)
	}
	return
}

make_raw_buffer :: proc(size: int, reserve := false) -> (buffer: Buffer) {
	buffer = Buffer {
		raw_size = size,
	}
	gl.CreateBuffers(1, &buffer.handle)

	if reserve {
		gl.NamedBufferData(buffer.handle, size, nil, gl.STATIC_DRAW)
	}
	return
}

send_buffer_data :: proc(buffer: Buffer, data: $T/[]$E) {
	if size_of(E) != buffer.elem_size {
		log.fatalf(
			"%s: Type mismatch: Buffer [%d] elements are of type %s",
			App_Module.Buffer,
			buffer.handle,
			type_info_of(E),
		)
		assert(false)
	}
	if len(data) > buffer.cap {
		log.fatalf("%s: Data slice is too large for buffer [%d]", App_Module.Buffer, buffer.handle)
		assert(false)
	}
	gl.NamedBufferData(buffer.handle, len(data) * buffer.elem_size, &data[0], gl.STATIC_DRAW)
}

send_raw_buffer_data :: proc(buffer: Buffer, size: int, data: rawptr) {
	if size > buffer.raw_size {
		log.fatalf("%s: Data is too large for buffer [%d]", App_Module.Buffer, buffer.handle)
		assert(false)
	}
	gl.NamedBufferData(buffer.handle, size, data, gl.STATIC_DRAW)
}

set_uniform_buffer_binding :: proc(buffer: Buffer, binding_point: u32) {
	gl.BindBufferRange(gl.UNIFORM_BUFFER, binding_point, buffer.handle, 0, buffer.raw_size)
}

destroy_buffer :: proc(buffer: Buffer) {
	b := buffer
	gl.DeleteBuffers(1, &b.handle)
}
