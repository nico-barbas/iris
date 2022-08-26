package iris

import "core:log"
import gl "vendor:OpenGL"

// Generic data buffer stored on the GPU
Buffer :: struct {
	handle:    u32,
	elem_size: int,
	cap:       int,
}

// Make a buffer of the given data type
make_buffer :: proc($T: typeid, cap: int) -> (buffer: Buffer) {
	buffer = Buffer {
		elem_size = size_of(T),
		cap       = cap,
	}
	gl.CreateBuffers(1, &buffer.handle)
	return
}

send_buffer_data :: proc(buffer: Buffer, data: $T/[]$E) {
	if size_of(E) != buffer.elem_size {
		log.fatalf(
			"%s: Type mismatch: Buffer [%d] elements are not of type %s",
			App_Module.Buffer,
			buffer.handle,
			type_info_of(E),
		)
		assert(false)
	}
	if len(data) > buffer.cap {
		log.fatalf(
			"%s: Data slice is too large for buffer [%d]",
			App_Module.Buffer,
			buffer.handle,
		)
		assert(false)
	}
	log.debug(len(data) * buffer.elem_size, data)
	gl.NamedBufferData(
		buffer.handle,
		len(data) * buffer.elem_size,
		&data[0],
		gl.STATIC_DRAW,
	)
}

destroy_buffer :: proc(buffer: ^Buffer) {
	gl.DeleteBuffers(1, &buffer.handle)
}
