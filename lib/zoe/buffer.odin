package zoe

import "core:log"
import gl "vendor:OpenGL"

Buffer :: struct {
	kind:      Buffer_Kind,
	handle:    u32,
	elem_size: int,
	stride:    int,
	cap:       int,
}

Buffer_Kind :: enum {
	Vertex,
	Index,
}

make_buffer :: proc($T: typeid, kind: Buffer_Kind, cap: int) -> (buffer: Buffer) {
	gl.CreateBuffers(1, &buffer.handle)
	buffer = Buffer {
		kind      = kind,
		elem_size = size_of(T),
		cap       = cap,
	}

	target := gl.ARRAY_BUFFER if kind == .Vertex else gl.ELEMENT_ARRAY_BUFFER
	return
}

send_buffer_data :: proc(buffer: Buffer, data: $T/[]$E) {
	if size_of(E) != buffer.elem_size {
		log.fatalf(
			"%s: Type mismatch: Buffer [%d] elements are not of type %s",
			App_Module.Buffer,
			buffer.handle,
			type_of(E),
		)
		assert(false)
	}
	if len(data) >= buffer.cap {
		log.fatalf(
			"%s: Data slice is too large for buffer [%d]",
			App_Module.Buffer,
			buffer.handle,
		)
		assert(false)
	}

	// target := gl.ARRAY_BUFFER if kind == .Vertex else gl.ELEMENT_ARRAY_BUFFER
	// gl.BindBuffer(target, buffer)
	// defer gl.BindBuffer(target, 0)

	gl.NamedBufferStorage(
		buffer.handle,
		buffer.cap * buffer.elem_size,
		&data[0],
		gl.STATIC_DRAW,
	)
}
