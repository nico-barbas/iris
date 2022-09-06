package iris

import "core:os"
import "core:log"
// import "core:fmt"
import "core:runtime"
import "core:strings"
import gl "vendor:OpenGL"

Shader :: struct {
	handle:   u32,
	uniforms: map[string]Shader_Uniform_Info,
}

Shader_Uniform_Loc :: distinct i32

Shader_Uniform_Info :: struct {
	loc:   Shader_Uniform_Loc,
	kind:  Shader_Uniform_Kind,
	count: int,
}

Shader_Uniform_Kind :: enum {
	Int,
	Vec2Int,
	Vec3Int,
	Vec4Int,
	Uint,
	Vec2Uint,
	Vec3Uint,
	Vec4Uint,
	Float,
	Vec2Float,
	Vec3Float,
	Vec4Float,
	Matrix2,
	Matrix3,
	Matrix4,
}

Shader_Loader :: struct {
	vertex_source:   string,
	fragment_source: string,
	vertex_path:     string,
	fragment_path:   string,
}

@(private)
internal_load_shader_from_file :: proc(l: Shader_Loader, allocator := context.allocator) -> Shader {
	v_raw, v_ok := os.read_entire_file(l.vertex_path, context.temp_allocator)
	f_raw, f_ok := os.read_entire_file(l.fragment_path, context.temp_allocator)

	if !(v_ok && f_ok) {
		log.fatalf(
			"%s: Failed to read shader source file:\n\t- %s\n\t- %s\n",
			App_Module.IO,
			l.vertex_path,
			l.fragment_path,
		)
		return {}
	}
	loader := l
	loader.vertex_source = string(v_raw)
	loader.fragment_source = string(f_raw)
	return internal_load_shader_from_bytes(loader)
}

@(private)
internal_load_shader_from_bytes :: proc(
	l: Shader_Loader,
	allocator := context.allocator,
) -> (
	shader: Shader,
) {
	vertex_handle := compile_shader_source(l.vertex_source, .VERTEX_SHADER, l.vertex_path)
	defer gl.DeleteShader(vertex_handle)
	fragment_handle := compile_shader_source(l.fragment_source, .FRAGMENT_SHADER, l.fragment_path)
	defer gl.DeleteShader(vertex_handle)

	switch {
	case vertex_handle == 0:
		log.debug("Failed to compile fragment shader")
	case fragment_handle == 0:
		log.debug("Failed to compile fragment shader")
	}

	shader.handle = gl.CreateProgram()
	gl.AttachShader(shader.handle, vertex_handle)
	gl.AttachShader(shader.handle, fragment_handle)
	gl.LinkProgram(shader.handle)
	compile_ok: i32
	gl.GetProgramiv(shader.handle, gl.LINK_STATUS, &compile_ok)
	if compile_ok == 0 {
		max_length: i32
		gl.GetProgramiv(shader.handle, gl.INFO_LOG_LENGTH, &max_length)

		message: [512]byte
		gl.GetProgramInfoLog(shader.handle, 512, &max_length, &message[0])
		log.debugf(
			"%s: Linkage error Shader[%d]:\n\t%s\n",
			App_Module.Shader,
			shader.handle,
			string(message[:max_length]),
		)
	}

	// populate uniform cache
	u_count: i32
	gl.GetProgramiv(shader.handle, gl.ACTIVE_UNIFORMS, &u_count)
	if u_count == 0 {
		return shader
	}
	shader.uniforms = make(map[string]Shader_Uniform_Info, runtime.DEFAULT_RESERVE_CAPACITY, allocator)

	max_name_len: i32
	cur_name_len: i32
	size: i32
	type: u32
	gl.GetProgramiv(shader.handle, gl.ACTIVE_UNIFORM_MAX_LENGTH, &max_name_len)
	for i in 0 ..< u_count {
		buf := make([]u8, max_name_len, context.temp_allocator)
		gl.GetActiveUniform(shader.handle, u32(i), max_name_len, &cur_name_len, &size, &type, &buf[0])
		u_name := format_uniform_name(buf, cur_name_len, type)
		shader.uniforms[u_name] = Shader_Uniform_Info {
			loc   = Shader_Uniform_Loc(gl.GetUniformLocation(shader.handle, cstring(raw_data(buf)))),
			kind  = uniform_kind(type),
			count = int(size),
		}
	}
	return shader
}

@(private)
compile_shader_source :: proc(
	shader_data: string,
	shader_type: gl.Shader_Type,
	filepath: string = "",
) -> (
	shader_handle: u32,
) {
	shader_handle = gl.CreateShader(cast(u32)shader_type)
	shader_data_copy := cstring(raw_data(shader_data))
	gl.ShaderSource(shader_handle, 1, &shader_data_copy, nil)
	gl.CompileShader(shader_handle)

	compile_ok: i32
	gl.GetShaderiv(shader_handle, gl.COMPILE_STATUS, &compile_ok)
	if compile_ok == 0 {
		max_length: i32
		gl.GetShaderiv(shader_handle, gl.INFO_LOG_LENGTH, &max_length)

		message: [512]byte
		file_name: string
		if filepath != "" {
			file_name = filepath
		} else {
			#partial switch shader_type {
			case .VERTEX_SHADER:
				file_name = "Vertex shader"
			case .FRAGMENT_SHADER:
				file_name = "Fragment shader"
			case:
				file_name = "Unknown shader"
			}
		}
		gl.GetShaderInfoLog(shader_handle, 512, &max_length, &message[0])
		log.debugf(
			"%s: Compilation error [%s]:\n\t%s\n",
			App_Module.Shader,
			file_name,
			string(message[:max_length]),
		)
	}
	return
}

@(private = "file")
format_uniform_name :: proc(buf: []u8, l: i32, t: u32, allocator := context.allocator) -> string {
	length := int(l)
	if t == gl.SAMPLER_2D || t == gl.FLOAT_MAT4 {
		if buf[length - 1] == ']' {
			length -= 3
		}
	}
	return strings.clone_from_bytes(buf[:length], allocator)
}

@(private)
uniform_kind :: proc(t: u32) -> (kind: Shader_Uniform_Kind) {
	switch t {
	case gl.INT:
		kind = .Int
	case gl.INT_VEC2:
		kind = .Vec2Int
	case gl.INT_VEC3:
		kind = .Vec3Int
	case gl.INT_VEC4:
		kind = .Vec4Int
	case gl.UNSIGNED_INT:
		kind = .Uint
	case gl.UNSIGNED_INT_VEC2:
		kind = .Vec2Uint
	case gl.UNSIGNED_INT_VEC3:
		kind = .Vec3Uint
	case gl.UNSIGNED_INT_VEC4:
		kind = .Vec4Uint
	case gl.FLOAT:
		kind = .Float
	case gl.FLOAT_VEC2:
		kind = .Vec2Float
	case gl.FLOAT_VEC3:
		kind = .Vec3Float
	case gl.FLOAT_VEC4:
		kind = .Vec4Float
	case gl.FLOAT_MAT2:
		kind = .Matrix2
	case gl.FLOAT_MAT3:
		kind = .Matrix3
	case gl.FLOAT_MAT4:
		kind = .Matrix4
	}
	return
}

set_shader_uniform :: proc(shader: ^Shader, name: string, value: rawptr, loc := #caller_location) {
	if exist := name in shader.uniforms; !exist {
		log.fatalf(
			"%s: Shader ID[%d]: Failed to retrieve uniform: %s\nCall location: %v",
			App_Module.Shader,
			shader.handle,
			name,
			loc,
		)
		return
	}
	bind_shader(shader)
	info := shader.uniforms[name]
	loc := i32(info.loc)
	switch info.kind {
	case .Int:
		gl.Uniform1iv(loc, i32(info.count), cast([^]i32)value)
	case .Vec2Int:
		gl.Uniform2iv(loc, i32(info.count), cast([^]i32)value)

	case .Vec3Int:
		gl.Uniform3iv(loc, i32(info.count), cast([^]i32)value)

	case .Vec4Int:
		gl.Uniform4iv(loc, i32(info.count), cast([^]i32)value)

	case .Uint:
		gl.Uniform1uiv(loc, i32(info.count), cast([^]u32)value)

	case .Vec2Uint:
		gl.Uniform2uiv(loc, i32(info.count), cast([^]u32)value)

	case .Vec3Uint:
		gl.Uniform3uiv(loc, i32(info.count), cast([^]u32)value)

	case .Vec4Uint:
		gl.Uniform4uiv(loc, i32(info.count), cast([^]u32)value)

	case .Float:
		gl.Uniform1fv(loc, i32(info.count), cast([^]f32)value)

	case .Vec2Float:
		gl.Uniform2fv(loc, i32(info.count), cast([^]f32)value)

	case .Vec3Float:
		gl.Uniform3fv(loc, i32(info.count), cast([^]f32)value)

	case .Vec4Float:
		gl.Uniform4fv(loc, i32(info.count), cast([^]f32)value)

	case .Matrix2:
		gl.UniformMatrix2fv(loc, i32(info.count), gl.FALSE, cast([^]f32)value)

	case .Matrix3:
		gl.UniformMatrix3fv(loc, i32(info.count), gl.FALSE, cast([^]f32)value)

	case .Matrix4:
		gl.UniformMatrix4fv(loc, i32(info.count), gl.FALSE, cast([^]f32)value)

	}
}

destroy_shader :: proc(shader: ^Shader) {
	for k, _ in shader.uniforms {
		delete(k)
	}
	delete(shader.uniforms)
	gl.DeleteProgram(shader.handle)
}

bind_shader :: proc(shader: ^Shader) {
	gl.UseProgram(shader.handle)
}

default_shader :: proc() {
	gl.UseProgram(0)
}
