package iris

import "core:intrinsics"
import "core:log"
import gl "vendor:OpenGL"

// Generic data buffer stored on the GPU
Buffer :: struct {
	handle: u32,
	info:   union {
		Raw_Buffer,
		Typed_Buffer,
	},
}

Raw_Buffer :: struct {
	size: int,
}

Typed_Buffer :: struct {
	element_type: typeid,
	element_size: int,
	cap:          int,
}

// make_buffer :: proc($T: typeid, cap: int, reserve := false) -> (buffer: Buffer) {
// 	ctx := &app.render_ctx
// 	buffer = internal_make_buffer(T, cap, reserve)

// 	append(&ctx.buffers, buffer)
// 	return buffer
// }

// Make a buffer of the given data type
@(private)
internal_make_typed_buffer :: proc($T: typeid, cap: int, reserve := false) -> (buffer: Buffer) {
	info := Typed_Buffer {
		element_type = T,
		element_size = size_of(T),
		cap          = cap,
	}
	buffer = Buffer {
		info = info,
	}
	gl.CreateBuffers(1, &buffer.handle)

	if reserve {
		gl.NamedBufferData(buffer.handle, info.cap * info.element_size, nil, gl.STATIC_DRAW)
	}
	return
}

@(private)
internal_make_raw_buffer :: proc(size: int, reserve := false) -> (buffer: Buffer) {
	info := Raw_Buffer {
		size = size,
	}
	buffer = Buffer {
		info = info,
	}
	gl.CreateBuffers(1, &buffer.handle)

	if reserve {
		gl.NamedBufferData(buffer.handle, size, nil, gl.STATIC_DRAW)
	}
	return
}

send_buffer_data :: proc(buffer: ^Buffer, data: $T/[]$E) {
	info, ok := buffer.info.(Typed_Buffer)
	if !ok {
		log.fatalf(
			"%s: Invalid Buffer access, trying to send typed data to raw buffer",
			App_Module.GPU_Memory,
		)
		assert(false)
	}
	if size_of(E) != info.element_size {
		log.fatalf(
			"%s: Type mismatch: Buffer [%d] elements are of type %s",
			App_Module.GPU_Memory,
			buffer.handle,
			type_info_of(E),
		)
		assert(false)
	}
	if len(data) > info.cap {
		log.fatalf(
			"%s: Data slice is too large for buffer [%d]",
			App_Module.GPU_Memory,
			buffer.handle,
		)
		assert(false)
	}
	gl.NamedBufferData(buffer.handle, len(data) * info.element_size, &data[0], gl.STATIC_DRAW)
}

send_raw_buffer_data :: proc(dst: ^Buffer_Memory, size: int, data: rawptr) {
	_, ok := dst.buf.info.(Raw_Buffer)
	if !ok {
		log.fatalf(
			"%s: Invalid Buffer access, trying to send raw data to typed buffer",
			App_Module.GPU_Memory,
		)
		assert(false)
	}
	if size > dst.size {
		log.fatalf("%s: Data is too large for buffer [%d]", App_Module.GPU_Memory, dst.buf.handle)
		assert(false)
	}
	// gl.NamedBufferData(dst.buf.handle, size, data, gl.STATIC_DRAW)
	gl.NamedBufferSubData(dst.buf.handle, dst.offset, size, data)
}

set_uniform_buffer_binding :: proc(buffer: ^Buffer, binding_point: u32) {
	info, ok := buffer.info.(Raw_Buffer)
	if !ok {
		log.fatalf(
			"%s: Invalid Buffer access, trying to use a typed buffer as uniform buffer",
			App_Module.GPU_Memory,
		)
		assert(false)
	}
	gl.BindBufferRange(gl.UNIFORM_BUFFER, binding_point, buffer.handle, 0, info.size)
}

destroy_buffer :: proc(buffer: ^Buffer) {
	gl.DeleteBuffers(1, &buffer.handle)
}

Arena_Buffer_Allocator :: struct {
	using memory: Buffer_Memory,
	used:         int,
}

Buffer_Memory :: struct {
	buf:    ^Buffer,
	size:   int,
	offset: int,
}

arena_init :: proc(a: ^Arena_Buffer_Allocator, memory: Buffer_Memory) {
	a.memory = memory
	a.used = 0
}

arena_allocate :: proc(a: ^Arena_Buffer_Allocator, size: int) -> (memory: Buffer_Memory) {
	if size > (a.size - a.used) {
		log.fatalf(
			"%s: Areana allocator out of memory:\n\tsize: %d\n\tused: %d\n\trequested: %d\n",
			App_Module.GPU_Memory,
			a.size,
			a.used,
			size,
		)
		intrinsics.trap()
	}
	memory = Buffer_Memory {
		buf    = a.buf,
		size   = size,
		offset = a.offset + a.used,
	}
	a.used += size
	return memory
}

arena_free_all :: proc(a: ^Arena_Buffer_Allocator) {
	a.used = 0
}
