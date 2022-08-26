package iris

import "core:os"
import "core:log"
import "core:image"
import "core:image/png"
import gl "vendor:OpenGL"

Texture :: struct {
	handle:     u32,
	width:      f32,
	height:     f32,
	unit_index: u32,
}

Texture_Filtering :: enum u8 {
	Linear,
	Nearest,
}

// TODO: Provide a back up texture in case of failure

load_texture_from_file :: proc(path: string, allocator := context.allocator) -> Texture {
	raw, ok := os.read_entire_file(path, allocator)
	defer delete(raw)

	if !ok {
		log.fatalf("%s: Failed to read file: %s", App_Module.IO, path)
		return {}
	}

	return load_texture_from_bytes(raw, allocator)
}

load_texture_from_bytes :: proc(b: []byte, allocator := context.allocator) -> Texture {
	texture: Texture

	options := image.Options{}
	img, err := png.load_from_bytes(b, options, allocator)
	defer png.destroy(img)
	if err != nil {
		log.fatalf("%s: Texture loading error: %s", err)
		return texture
	}
	if img.depth != 8 {
		log.fatalf("%s: Only supports 8bits channels")
	}

	texture.width = f32(img.width)
	texture.height = f32(img.height)
	gl_internal_format: u32
	gl_format: u32
	switch img.channels {
	case 1:
		gl_format = gl.RED
		gl_internal_format = gl.R8
	case 2:
		gl_format = gl.RG
		gl_internal_format = gl.RG8
	case 3:
		gl_format = gl.RGB
		gl_internal_format = gl.RGB8
	case 4:
		gl_format = gl.RGBA
		gl_internal_format = gl.RGBA8
	}

	gl.CreateTextures(gl.TEXTURE_2D, 1, &texture.handle)

	gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_T, gl.REPEAT)
	gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, gl.NEAREST)

	gl.TextureStorage2D(
		texture.handle,
		1,
		gl_internal_format,
		i32(texture.width),
		i32(texture.height),
	)
	gl.TextureSubImage2D(
		texture.handle,
		0,
		0,
		0,
		i32(texture.width),
		i32(texture.height),
		gl_format,
		gl.UNSIGNED_BYTE,
		raw_data(img.pixels.buf),
	)
	gl.GenerateTextureMipmap(texture.handle)
	return texture
}

// make_texture_from_memory :: proc(
// 	data: []byte,
// 	format: Texture_Format,
// 	allocator := context.allocator,
// ) -> Texture {
// 	texture := Texture{}
// 	if format != .PNG {
// 		log.fatalf("%s: Invalid texture format", App_Module.Texture)
// 		return texture
// 	}

// 	options := image.Options{}
// 	err: image.Error
// 	img: ^image.Image

// 	img, err = png.load_from_bytes(data, options, allocator)

// 	if err != nil {
// 		log.fatalf("%s: Texture loading error: %s", err)
// 		return texture
// 	}
// 	texture.width = f32(img.width)
// 	texture.height = f32(img.height)

// 	gl.GenTextures(1, &texture.handle)
// 	gl.BindTexture(gl.TEXTURE_2D, texture.handle)

// 	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
// 	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)
// 	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
// 	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)

// 	gl.TexImage2D(
// 		gl.TEXTURE_2D,
// 		0,
// 		gl.RGBA8,
// 		i32(texture.width),
// 		i32(texture.height),
// 		0,
// 		gl.RGBA,
// 		gl.UNSIGNED_BYTE,
// 		raw_data(img.pixels.buf),
// 	)
// 	gl.GenerateMipmap(gl.TEXTURE_2D)
// 	gl.BindTexture(gl.TEXTURE_2D, 0)

// 	return texture
// }


// make_texture_from_bitmap :: proc(
// 	data: []byte,
// 	w,
// 	h: int,
// 	c: int,
// 	f := Texture_Filtering.Nearest,
// ) -> Texture {
// 	texture := Texture {
// 		width  = f32(w),
// 		height = f32(h),
// 	}

// 	gl.GenTextures(1, &texture.handle)
// 	gl.BindTexture(gl.TEXTURE_2D, texture.handle)

// 	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
// 	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)
// 	gl.TexParameteri(
// 		gl.TEXTURE_2D,
// 		gl.TEXTURE_MIN_FILTER,
// 		gl.NEAREST if f == .Nearest else gl.LINEAR,
// 	)
// 	gl.TexParameteri(
// 		gl.TEXTURE_2D,
// 		gl.TEXTURE_MAG_FILTER,
// 		gl.NEAREST if f == .Nearest else gl.LINEAR,
// 	)

// 	gl.TexImage2D(
// 		gl.TEXTURE_2D,
// 		0,
// 		gl.RGBA8 if c == 4 else gl.RED,
// 		i32(texture.width),
// 		i32(texture.height),
// 		0,
// 		gl.RGBA if c == 4 else gl.RED,
// 		gl.UNSIGNED_BYTE,
// 		&data[0],
// 	)
// 	gl.GenerateMipmap(gl.TEXTURE_2D)
// 	gl.BindTexture(gl.TEXTURE_2D, 0)

// 	return texture
// }

bind_texture :: proc(texture: ^Texture, unit_index: u32) {
	gl.BindTextureUnit(unit_index, texture.handle)
	texture.unit_index = unit_index
}

unbind_texture :: proc(texture: ^Texture) {
	gl.BindTextureUnit(texture.unit_index, 0)
	texture.unit_index = 0
}

destroy_texture :: proc(texture: ^Texture) {
	gl.DeleteTextures(1, &texture.handle)
}
