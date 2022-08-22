package zoe

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

Texture_Format :: enum u8 {
	Invalid,
	PNG,
}

Texture_Filtering :: enum u8 {
	Linear,
	Nearest,
}

Pixel_Format :: enum u8 {
	RGB,
	RGBA,
}

make_texture_from_file :: proc(
	path: string,
	format: Texture_Format,
	allocator := context.allocator,
) -> Texture {
	texture := Texture{}
	if format != .PNG {
		log.fatalf("%s: Invalid texture format", App_Module.Texture)
		return texture
	}

	options := image.Options{}
	err: image.Error
	img: ^image.Image

	img, err = png.load(path, options, allocator)

	if err != nil {
		log.fatalf("%s: Texture loading error: %s", err)
		return texture
	}
	texture.width = f32(img.width)
	texture.height = f32(img.height)

	gl.GenTextures(1, &texture.handle)
	gl.BindTexture(gl.TEXTURE_2D, texture.handle)

	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)

	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA8,
		i32(texture.width),
		i32(texture.height),
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		raw_data(img.pixels.buf),
	)
	gl.GenerateMipmap(gl.TEXTURE_2D)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	return texture
}

make_texture_from_memory :: proc(
	data: []byte,
	format: Texture_Format,
	allocator := context.allocator,
) -> Texture {
	texture := Texture{}
	if format != .PNG {
		log.fatalf("%s: Invalid texture format", App_Module.Texture)
		return texture
	}

	options := image.Options{}
	err: image.Error
	img: ^image.Image

	img, err = png.load_from_bytes(data, options, allocator)

	if err != nil {
		log.fatalf("%s: Texture loading error: %s", err)
		return texture
	}
	texture.width = f32(img.width)
	texture.height = f32(img.height)

	gl.GenTextures(1, &texture.handle)
	gl.BindTexture(gl.TEXTURE_2D, texture.handle)

	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST)

	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA8,
		i32(texture.width),
		i32(texture.height),
		0,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		raw_data(img.pixels.buf),
	)
	gl.GenerateMipmap(gl.TEXTURE_2D)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	return texture
}


make_texture_from_bitmap :: proc(
	data: []byte,
	w,
	h: int,
	c: int,
	f := Texture_Filtering.Nearest,
) -> Texture {
	texture := Texture {
		width  = f32(w),
		height = f32(h),
	}

	gl.GenTextures(1, &texture.handle)
	gl.BindTexture(gl.TEXTURE_2D, texture.handle)

	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.REPEAT)
	gl.TexParameteri(
		gl.TEXTURE_2D,
		gl.TEXTURE_MIN_FILTER,
		gl.NEAREST if f == .Nearest else gl.LINEAR,
	)
	gl.TexParameteri(
		gl.TEXTURE_2D,
		gl.TEXTURE_MAG_FILTER,
		gl.NEAREST if f == .Nearest else gl.LINEAR,
	)

	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA8 if c == 4 else gl.RED,
		i32(texture.width),
		i32(texture.height),
		0,
		gl.RGBA if c == 4 else gl.RED,
		gl.UNSIGNED_BYTE,
		&data[0],
	)
	gl.GenerateMipmap(gl.TEXTURE_2D)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	return texture
}

bind_texture :: proc(tex: ^Texture, unit_index: u32) {
	gl.ActiveTexture(gl.TEXTURE0 + unit_index)
	gl.BindTexture(gl.TEXTURE_2D, tex.handle)
	tex.unit_index = unit_index
}

unbind_texture :: proc(tex: ^Texture) {
	gl.ActiveTexture(gl.TEXTURE0 + tex.unit_index)
	gl.BindTexture(gl.TEXTURE_2D, 0)
	tex.unit_index = 0
}

delete_texture :: proc(tex: ^Texture) {
	gl.DeleteTextures(1, &tex.handle)
}
