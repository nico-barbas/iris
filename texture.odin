package iris

import "core:os"
import "core:log"
import "core:image"
import "core:image/png"
import gl "vendor:OpenGL"

import "gltf"

Texture :: struct {
	name:       string,
	handle:     u32,
	width:      f32,
	height:     f32,
	unit_index: u32,
}

Texture_Filter_Mode :: enum uint {
	Nearest                = 9728,
	Linear                 = 9729,
	Nearest_Mipmap_Nearest = 9984,
	Linear_Mipmap_Nearest  = 9985,
	Nearest_Mipmap_Linear  = 9986,
	Linear_Mipmap_Linear   = 9987,
}

Texture_Wrap_Mode :: enum uint {
	Clamp_To_Edge   = 33071,
	Mirrored_Repeat = 33648,
	Repeat          = 10497,
}

Texture_Loader :: struct {
	path:     string,
	data:     []byte,
	filter:   Texture_Filter_Mode,
	wrap:     Texture_Wrap_Mode,
	channels: int,
	width:    int,
	height:   int,
}

@(private)
internal_load_texture_from_file :: proc(l: Texture_Loader, allocator := context.allocator) -> Texture {
	ok: bool
	loader := l
	loader.data, ok = os.read_entire_file(loader.path, allocator)
	defer delete(loader.data)

	if !ok {
		log.fatalf("%s: Failed to read file: %s", App_Module.IO, loader.path)
		return {}
	}

	texture := internal_load_texture_from_bytes(loader, allocator)
	texture.name = l.path
	return texture
}

@(private)
internal_load_texture_from_bytes :: proc(l: Texture_Loader, allocator := context.allocator) -> Texture {
	assert(int(l.filter) != 0 && int(l.wrap) != 0)

	texture: Texture

	options := image.Options{}
	img, err := png.load_from_bytes(l.data, options, allocator)
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

	gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_S, i32(l.wrap))
	gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_T, i32(l.wrap))
	gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, i32(l.filter))
	gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, i32(l.filter))

	gl.TextureStorage2D(texture.handle, 1, gl_internal_format, i32(texture.width), i32(texture.height))
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

@(private)
internal_load_texture_from_bitmap :: proc(l: Texture_Loader) -> Texture {
	if int(l.filter) == 0 || int(l.wrap) == 0 {
		assert(false)
	}

	texture := Texture {
		width  = f32(l.width),
		height = f32(l.height),
	}
	gl_internal_format: u32
	gl_format: u32

	switch l.channels {
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

	gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_S, i32(l.wrap))
	gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_T, i32(l.wrap))
	gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, i32(l.filter))
	gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, i32(l.filter))

	gl.TextureStorage2D(texture.handle, 1, gl_internal_format, i32(texture.width), i32(texture.height))
	gl.TextureSubImage2D(
		texture.handle,
		0,
		0,
		0,
		i32(texture.width),
		i32(texture.height),
		gl_format,
		gl.UNSIGNED_BYTE,
		raw_data(l.data),
	)
	gl.GenerateTextureMipmap(texture.handle)
	return texture
}

load_texture_from_gltf :: proc(t: gltf.Texture) -> ^Texture {
	loader := Texture_Loader {
		path = t.source.reference.(string),
	}

	if t.sampler != nil {
		loader.filter = Texture_Filter_Mode(t.sampler.min_filter)
		loader.wrap = Texture_Wrap_Mode(t.sampler.wrap_s)
	} else {
		loader.filter = .Nearest
		loader.wrap = .Repeat
	}

	resource := texture_resource(loader)
	texture := resource.data.(^Texture)
	return texture
}

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
