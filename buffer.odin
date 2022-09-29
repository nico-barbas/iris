package iris

import "core:intrinsics"
import "core:log"
import gl "vendor:OpenGL"

// Generic data buffer stored on the GPU
Buffer :: struct {
	handle: u32,
	size:   int,
}

Buffer_Source :: struct {
	data:      rawptr,
	byte_size: int,
	accessor:  Buffer_Data_Type,
}

Buffer_Data_Kind :: enum {
	Byte,
	Boolean,
	Unsigned_16,
	Signed_16,
	Unsigned_32,
	Signed_32,
	Float_16,
	Float_32,
}

buffer_size_of := map[Buffer_Data_Kind]int {
	.Byte        = size_of(byte),
	.Boolean     = size_of(bool),
	.Unsigned_16 = size_of(u16),
	.Signed_16   = size_of(i16),
	.Unsigned_32 = size_of(u32),
	.Signed_32   = size_of(i32),
	.Float_16    = size_of(f16be),
	.Float_32    = size_of(f32),
}

Buffer_Data_Format :: enum {
	Unspecified,
	Scalar,
	Vector2,
	Vector3,
	Vector4,
	Mat2,
	Mat3,
	Mat4,
}

buffer_len_of := map[Buffer_Data_Format]int {
	.Unspecified = 1,
	.Scalar      = 1,
	.Vector2     = 2,
	.Vector3     = 3,
	.Vector4     = 4,
	.Mat2        = 4,
	.Mat3        = 9,
	.Mat4        = 16,
}

Buffer_Data_Type :: struct {
	kind:   Buffer_Data_Kind,
	format: Buffer_Data_Format,
}

@(private)
internal_make_raw_buffer :: proc(size: int) -> (buffer: Buffer) {
	buffer = Buffer {
		size = size,
	}
	gl.CreateBuffers(1, &buffer.handle)
	gl.NamedBufferData(buffer.handle, size, nil, gl.STATIC_DRAW)
	return
}

send_buffer_data :: proc(dst: ^Buffer_Memory, src: Buffer_Source, offset := 0) {
	if src.byte_size > dst.size {
		log.fatalf("%s: Data is too large for buffer [%d]", App_Module.GPU_Memory, dst.buf.handle)
		assert(false)
	}
	gl.NamedBufferSubData(dst.buf.handle, dst.offset + offset, src.byte_size, src.data)
}

set_uniform_buffer_binding :: proc(buffer: ^Buffer, binding_point: u32) {
	gl.BindBufferRange(gl.UNIFORM_BUFFER, binding_point, buffer.handle, 0, buffer.size)
}

set_storage_buffer_binding :: proc(buffer: ^Buffer, binding_point: u32) {
	gl.BindBufferRange(gl.SHADER_STORAGE_BUFFER, binding_point, buffer.handle, 0, buffer.size)
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
