package zoe

import "core:log"
import "core:runtime"
import "core:strings"
import "core:math/linalg"
import "core:fmt"
import gl "vendor:OpenGL"

Matrix4 :: linalg.Matrix4f32

Shader_Program :: struct {
	handle:   u32,
	uniforms: map[string]i32,
}

make_shader_program :: proc(
	vertex_src,
	fragment_src: string,
	allocator := context.allocator,
) -> Shader_Program {
	program := Shader_Program{}
	ok: bool
	program.handle, ok = gl.load_shaders_source(vertex_src, fragment_src)
	if !ok {
		log.debugf("%s: Are you an idiot?\n", App_Module.Shader)
	}

	// populate uniform cache
	u_count: i32
	gl.GetProgramiv(program.handle, gl.ACTIVE_UNIFORMS, &u_count)
	if u_count == 0 {
		return program
	}
	program.uniforms = make(map[string]i32, runtime.DEFAULT_RESERVE_CAPACITY, allocator)

	max_name_len: i32
	cur_name_len: i32
	size: i32
	type: u32
	gl.GetProgramiv(program.handle, gl.ACTIVE_UNIFORM_MAX_LENGTH, &max_name_len)
	for i in 0 ..< u_count {
		buf := make([]u8, max_name_len, allocator)
		defer delete(buf)
		gl.GetActiveUniform(
			program.handle,
			u32(i),
			max_name_len,
			&cur_name_len,
			&size,
			&type,
			&buf[0],
		)
		u_name := format_uniform_name(buf, cur_name_len, type)
		program.uniforms[u_name] = gl.GetUniformLocation(
			program.handle,
			cstring(raw_data(buf)),
		)
	}
	return program
}

@(private = "file")
format_uniform_name :: proc(
	buf: []u8,
	l: i32,
	t: u32,
	allocator := context.allocator,
) -> string {
	length := int(l)
	if t == gl.SAMPLER_2D {
		if buf[length - 1] == ']' {
			length -= 3
		}
	}
	return strings.clone_from_bytes(buf[:length], allocator)
}

print_shader_program_uniforms :: proc(program: Shader_Program) {
	for name, handle in program.uniforms {
		fmt.println(name, " : ", handle)
	}
}

set_matrix4_uniform :: proc(program: Shader_Program, name: string, value: ^Matrix4) {
	if exist := name in program.uniforms; !exist {
		log.fatalf(
			"%s: Shader ID[%d]: Wrong uniform name: %s",
			App_Module.Shader,
			program.handle,
			name,
		)
		return
	}
	gl.UseProgram(program.handle)
	gl.UniformMatrix4fv(program.uniforms[name], 1, gl.FALSE, &value[0][0])
}

set_int_buffer_uniform :: proc(
	program: Shader_Program,
	name: string,
	count: i32,
	data: ^i32,
) {
	if exist := name in program.uniforms; !exist {
		log.fatalf(
			"%s: Shader ID[%d]: Wrong uniform name: %s",
			App_Module.Shader,
			program.handle,
			name,
		)
		return
	}
	gl.UseProgram(program.handle)
	gl.Uniform1iv(program.uniforms[name], count, data)
}

delete_shader_program :: proc(program: ^Shader_Program) {
	for k, _ in program.uniforms {
		delete(k)
	}
	delete(program.uniforms)
	gl.DeleteProgram(program.handle)
}
