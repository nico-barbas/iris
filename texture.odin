package iris

import "core:os"
import "core:log"
import "core:image"
import "core:image/png"
import gl "vendor:OpenGL"

import "gltf"

Cubemap_Face :: enum {
	Front = 0,
	Back  = 1,
	Up    = 2,
	Down  = 3,
	Left  = 4,
	Right = 5,
}

Texture :: struct {
	kind:       enum {
		Texture,
		Cubemap,
	},
	name:       string,
	handle:     u32,
	width:      f32,
	height:     f32,
	unit_index: u32,
}

Texture_Slice :: struct {
	unit_index:   i32,
	atlas_width:  f32,
	atlas_height: f32,
	x:            f32,
	y:            f32,
	width:        f32,
	height:       f32,
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

Texture_Space :: enum {
	Invalid,
	Linear,
	sRGB,
}

Texture_Loader :: struct {
	filter: Texture_Filter_Mode,
	wrap:   Texture_Wrap_Mode,
	space:  Texture_Space,
	width:  int,
	height: int,
	info:   union {
		File_Texture_Info,
		Byte_Texture_Info,
		File_Cubemap_Info,
		Byte_Cubemap_Info,
	},
}

File_Texture_Info :: struct {
	path: string,
}

Byte_Texture_Info :: struct {
	data:     []byte,
	channels: int,
	bitmap:   bool,
}

File_Cubemap_Info :: struct {
	dir:   string,
	paths: [6]string,
}

Byte_Cubemap_Info :: struct {
	data:     [6][]byte,
	channels: int,
	bitmap:   bool,
}

@(private)
internal_load_texture_from_file :: proc(l: Texture_Loader) -> Texture {
	ok: bool
	loader := l
	info := loader.info.(File_Texture_Info)
	byte_info: Byte_Texture_Info
	byte_info.data, ok = os.read_entire_file(info.path, context.temp_allocator)
	defer delete(byte_info.data)

	if !ok {
		log.fatalf("%s: Failed to read file: %s", App_Module.IO, info.path)
		return {}
	}

	loader.info = byte_info
	texture := internal_load_texture_from_bytes(loader)
	texture.name = info.path
	return texture
}

@(private)
internal_load_texture_from_bytes :: proc(l: Texture_Loader) -> Texture {
	assert(int(l.filter) != 0 && int(l.wrap) != 0)
	if l.space == .Invalid {
		assert(false, "Invalid Texture color space")
	}

	texture: Texture

	options := image.Options{}
	info := l.info.(Byte_Texture_Info)
	img, err := png.load_from_bytes(info.data, options, context.temp_allocator)
	defer png.destroy(img)
	if err != nil {
		log.fatalf("%s: Texture loading error: %s", err)
		return texture
	}
	if img.depth != 8 {
		log.fatalf("%s: Only supports 8bits channels")
	}

	texture.kind = .Texture
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
		gl_internal_format = gl.RGB8 if l.space == .Linear else gl.SRGB8
	case 4:
		gl_format = gl.RGBA
		gl_internal_format = gl.RGBA8 if l.space == .Linear else gl.SRGB8_ALPHA8
	}

	gl.CreateTextures(gl.TEXTURE_2D, 1, &texture.handle)

	gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_S, i32(l.wrap))
	gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_T, i32(l.wrap))
	gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, i32(l.filter))
	gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, i32(l.filter))

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

	info := l.info.(Byte_Texture_Info)
	switch info.channels {
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
		raw_data(info.data),
	)
	gl.GenerateTextureMipmap(texture.handle)
	return texture
}

@(private)
internal_load_cubemap_from_files :: proc(l: Texture_Loader) -> Texture {
	ok: bool
	loader := l
	info := loader.info.(File_Cubemap_Info)
	byte_info: Byte_Cubemap_Info

	for direction in Cubemap_Face {
		byte_info.data[direction], ok = os.read_entire_file(
			info.paths[direction],
			context.temp_allocator,
		)
		if !ok {
			log.fatalf("%s: Failed to read file: %s", App_Module.IO, info.paths[direction])
			return {}
		}
	}

	defer {
		for direction in Cubemap_Face {
			defer delete(byte_info.data[direction])
		}
	}


	loader.info = byte_info
	cubemap := internal_load_cubemap_from_bytes(loader)
	cubemap.name = info.dir
	return cubemap
}

@(private)
internal_load_cubemap_from_bytes :: proc(loader: Texture_Loader) -> Texture {
	cubemap: Texture
	cubemap.kind = .Cubemap
	images: [6]^image.Image
	info := loader.info.(Byte_Cubemap_Info)
	gl_internal_format: u32
	gl_format: u32

	defer {
		for direction, i in Cubemap_Face {
			defer png.destroy(images[direction])
		}
	}

	for direction, i in Cubemap_Face {
		options := image.Options{}
		img, err := png.load_from_bytes(info.data[direction], options, context.temp_allocator)
		if err != nil {
			log.fatalf("%s: Cubemap loading error: %s", App_Module.Texture, err)
			return cubemap
		}
		if img.depth != 8 {
			log.fatalf("%s: Only supports 8bits channels")
			assert(false)
		}

		if i == 0 {
			cubemap.width = f32(img.width)
			cubemap.height = f32(img.height)
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
		} else if cubemap.width != f32(img.width) || cubemap.height != f32(img.height) {
			log.fatalf(
				"%s: %s:\n\t[%s] = [%f,%f]\n\t[%s] = [%f,%f]",
				App_Module.Texture,
				"Cubemap loading error: faces with different dimensions",
				Cubemap_Face.Front,
				cubemap.width,
				cubemap.height,
				direction,
				f32(img.width),
				f32(img.height),
			)
			assert(false)
		}

		images[direction] = img
	}

	gl.CreateTextures(gl.TEXTURE_CUBE_MAP, 1, &cubemap.handle)

	gl.TextureParameteri(cubemap.handle, gl.TEXTURE_WRAP_S, i32(loader.wrap))
	gl.TextureParameteri(cubemap.handle, gl.TEXTURE_WRAP_T, i32(loader.wrap))
	gl.TextureParameteri(cubemap.handle, gl.TEXTURE_WRAP_R, i32(loader.wrap))
	gl.TextureParameteri(cubemap.handle, gl.TEXTURE_MIN_FILTER, i32(loader.filter))
	gl.TextureParameteri(cubemap.handle, gl.TEXTURE_MAG_FILTER, i32(loader.filter))

	gl.TextureStorage2D(
		cubemap.handle,
		1,
		gl_internal_format,
		i32(cubemap.width),
		i32(cubemap.height),
	)

	for direction in Cubemap_Face {
		gl.TextureSubImage3D(
			cubemap.handle,
			0,
			0,
			0,
			i32(direction),
			i32(cubemap.width),
			i32(cubemap.height),
			1,
			gl_format,
			gl.UNSIGNED_BYTE,
			raw_data(images[direction].pixels.buf),
		)
		gl.GenerateTextureMipmap(cubemap.handle)
	}

	return cubemap
}

load_texture_from_gltf :: proc(t: gltf.Texture, space: Texture_Space) -> ^Texture {
	loader := Texture_Loader {
		info = File_Texture_Info{path = t.source.reference.(string)},
		space = space,
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
