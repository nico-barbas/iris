package iris

import "core:os"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:path/filepath"
import "core:strings"
import stbtt "vendor:stb/truetype"

Canvas_Node :: struct {
	using base:       Node,
	width:            int,
	height:           int,
	derived_flags:    Canvas_Flags,

	// Graphical states
	projection:       Matrix4,
	framebuffer:      ^Framebuffer,
	attributes:       ^Attributes,
	vertex_buffer:    ^Buffer,
	index_buffer:     ^Buffer,
	paint_shader:     ^Shader,
	default_texture:  ^Resource,

	// CPU Buffers
	vertices:         [dynamic]f32,
	indices:          [dynamic]u32,
	textures:         [16]^Texture,
	texture_count:    int,
	previous_v_count: int,
	previous_i_count: int,
	index_offset:     u32,
}

Canvas_Flags :: distinct bit_set[Canvas_Flag]

Canvas_Flag :: enum {
	Preserve_Last_Frame,
}

Canvas_Draw_Options :: struct {
	dst:     Rectangle,
	src:     Rectangle,
	texture: ^Texture,
	color:   Color,
}

@(private)
init_canvas_node :: proc(canvas: ^Canvas_Node) {
	OVERLAY_QUAD_CAP :: 1000
	OVERLAY_VERTEX_CAP :: OVERLAY_QUAD_CAP * 4
	OVERLAY_INDEX_CAP :: OVERLAY_QUAD_CAP * 6
	OVERLAY_VERT_LAYOUT :: Vertex_Layout{.Float2, .Float2, .Float1, .Float4}


	overlay_stride := vertex_layout_length(OVERLAY_VERT_LAYOUT)
	canvas.projection = linalg.matrix_mul(
		linalg.matrix_ortho3d_f32(0, f32(canvas.width), f32(canvas.height), 0, 1, 100),
		linalg.matrix4_translate_f32({0, 0, f32(-1)}),
	)
	canvas.attributes = attributes_from_layout(OVERLAY_VERT_LAYOUT, .Interleaved)

	vertex_buffer_res := typed_buffer_resource(f32, overlay_stride * OVERLAY_VERTEX_CAP)
	index_buffer_res := typed_buffer_resource(u32, OVERLAY_INDEX_CAP)
	canvas.vertex_buffer = vertex_buffer_res.data.(^Buffer)
	canvas.index_buffer = index_buffer_res.data.(^Buffer)


	framebuffer_res := framebuffer_resource(
		Framebuffer_Loader{
			attachments = {.Color},
			width = canvas.width,
			height = canvas.height,
			clear_colors = {0 = {0, 0, 0, 0}},
		},
	)
	canvas.framebuffer = framebuffer_res.data.(^Framebuffer)

	canvas.default_texture = texture_resource(
		loader = Texture_Loader{
			data = {0xff, 0xff, 0xff, 0xff},
			filter = .Nearest,
			wrap = .Repeat,
			channels = 4,
			width = 1,
			height = 1,
		},
		is_bitmap = true,
	)
	canvas.textures[0] = canvas.default_texture.data.(^Texture)
	canvas.texture_count = 1

	paint_shader_res := shader_resource(
		Shader_Loader{
			vertex_source = OVERLAY_VERTEX_SHADER,
			fragment_source = OVERLAY_FRAGMENT_SHADER,
		},
	)
	canvas.paint_shader = paint_shader_res.data.(^Shader)

	// blit_shader_res := shader_resource(
	// 	Shader_Loader{
	// 		vertex_source = BLIT_FRAMEBUFFER_VERTEX_SHADER,
	// 		fragment_source = BLIT_FRAMEBUFFER_FRAGMENT_SHADER,
	// 	},
	// )
	// canvas.blit_shader = blit_shader_res.data.(^Shader)

	texture_indices := [16]i32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
	set_shader_uniform(canvas.paint_shader, "textures", &texture_indices[0])
}

@(private)
prepare_canvas_node_render :: proc(canvas: ^Canvas_Node) {
	canvas.vertices = make([dynamic]f32, 0, canvas.previous_v_count, context.temp_allocator)
	canvas.indices = make([dynamic]u32, 0, canvas.previous_i_count, context.temp_allocator)
	canvas.texture_count = 1
}

@(private)
push_canvas_quad :: proc(canvas: ^Canvas_Node, c: Canvas_Draw_Options) {
	x1 := c.dst.x
	x2 := c.dst.x + c.dst.width
	y1 := c.dst.y
	y2 := c.dst.y + c.dst.height
	uvx1 := c.src.x / c.texture.width
	uvx2 := (c.src.x + c.src.width) / c.texture.width
	uvy1 := c.src.y / c.texture.height
	uvy2 := (c.src.y + c.src.height) / c.texture.height
	r := c.color.r
	g := c.color.g
	b := c.color.b
	a := c.color.a

	texture_index := -1
	for texture, i in canvas.textures[:canvas.texture_count] {
		if c.texture.handle == texture.handle {
			texture_index = i
			break
		}
	}
	if texture_index == -1 {
		canvas.textures[canvas.texture_count] = c.texture
		texture_index = canvas.texture_count
		canvas.texture_count += 1
	}
	i_off := canvas.index_offset
			//odinfmt: disable
			append(
				&canvas.vertices, 
				x1, y1, uvx1, uvy1, f32(texture_index), r, g, b, a,
				x2, y1, uvx2, uvy1, f32(texture_index), r, g, b, a,
				x2, y2, uvx2, uvy2, f32(texture_index), r, g, b, a,
				x1, y2, uvx1, uvy2, f32(texture_index), r, g, b, a,
			)
			append(
				&canvas.indices,
				i_off + 1, i_off + 0, i_off + 2,
				i_off + 2, i_off + 0, i_off + 3,
			)
			//odinfmt: enable


	canvas.index_offset += 4
}

@(private)
flush_canvas_node_buffers :: proc(data: rawptr) {
	canvas := cast(^Canvas_Node)data
	if len(canvas.indices) > 0 {
		bind_framebuffer(canvas.framebuffer)
		clear_framebuffer(canvas.framebuffer)
		bind_shader(canvas.paint_shader)
		set_shader_uniform(canvas.paint_shader, "matProj", &canvas.projection[0][0])
		send_buffer_data(canvas.vertex_buffer, canvas.vertices[:])
		send_buffer_data(canvas.index_buffer, canvas.indices[:])


		bind_texture(canvas.textures[0], u32(0))
		bind_texture(canvas.textures[1], u32(1))
		// for i in 0 ..< canvas.texture_count {
		// }
		bind_attributes(canvas.attributes)

		defer {
			default_attributes()
			for i in 0 ..< canvas.texture_count {
				unbind_texture(canvas.textures[i])
			}
			default_framebuffer()
		}
		link_interleaved_attributes_vertices(canvas.attributes, canvas.vertex_buffer)
		link_attributes_indices(canvas.attributes, canvas.index_buffer)
		draw_triangles(len(canvas.indices))
		push_draw_command(
			Render_Framebuffer_Command{
				render_order = 1,
				framebuffer = canvas.framebuffer,
				vertex_buffer = canvas.vertex_buffer,
				index_buffer = canvas.index_buffer,
			},
		)
	}
	canvas.previous_v_count = len(canvas.vertices)
	canvas.previous_i_count = len(canvas.indices)
	canvas.index_offset = 0
}

/*@(private)
paint_canvas_node :: proc(canvas: ^Canvas_Node) {
  //odinfmt: disable
	framebuffer_vertices := [?]f32{
		-1.0, -1.0, 0.0, 0.0, 0, 0, 0, 0, 0,
		 1.0, -1.0, 1.0, 0.0, 0, 0, 0, 0, 0,
		 1.0,  1.0, 1.0, 1.0, 0, 0, 0, 0, 0,
		-1.0,  1.0, 0.0, 1.0, 0, 0, 0, 0, 0,
	}
	framebuffer_indices := [?]u32{
		1, 0, 2,
		2, 0, 3,
	}
		//odinfmt: enable


	texture_index: u32 = 0

	// Set the shader up
	bind_shader(canvas.blit_shader)
	set_shader_uniform(canvas.blit_shader, "texture0", &texture_index)
	bind_texture(framebuffer_texture(canvas.framebuffer, .Color), texture_index)
	send_buffer_data(canvas.vertex_buffer, framebuffer_vertices[:])
	send_buffer_data(canvas.index_buffer, framebuffer_indices[:])

	// prepare attributes
	bind_attributes(canvas.attributes)
	defer {
		default_attributes()
		default_shader()
		unbind_texture(framebuffer_texture(canvas.framebuffer, .Color))
	}

	link_interleaved_attributes_vertices(canvas.attributes, canvas.vertex_buffer)
	link_attributes_indices(canvas.attributes, canvas.index_buffer)

	draw_triangles(len(framebuffer_indices))
}*/

@(private)
default_canvas_texture :: proc(canvas: ^Canvas_Node) -> ^Texture {
	return canvas.textures[0]
}

draw_rect :: proc(canvas: ^Canvas_Node, r: Rectangle, clr: Color) {
	push_canvas_quad(
		canvas,
		Canvas_Draw_Options{
			dst = r,
			src = {x = 0, y = 0, width = 1, height = 1},
			color = clr,
			texture = default_canvas_texture(canvas),
		},
	)
}

draw_sub_texture :: proc(canvas: ^Canvas_Node, t: ^Texture, dst, src: Rectangle, clr: Color) {
	push_canvas_quad(canvas, Canvas_Draw_Options{dst = dst, src = src, color = clr, texture = t})
}

draw_text :: proc(
	canvas: ^Canvas_Node,
	f: ^Font,
	text: string,
	p: Vector2,
	size: int,
	clr: Color,
) {
	face := &f.faces[size]
	cursor_pos := p.x
	for r in text {
		glyph := face.glyphs[r]
		r := Rectangle{
			cursor_pos + f32(glyph.left_bearing),
			p.y + f32(glyph.y_offset),
			f32(glyph.width),
			f32(glyph.height),
		}
		draw_sub_texture(
			canvas,
			face.texture,
			r,
			{f32(glyph.x), f32(glyph.y), f32(glyph.width), f32(glyph.height)},
			clr,
		)
		cursor_pos += f32(glyph.advance)
	}
}


@(private)
OVERLAY_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec2 attribPosition;
layout (location = 1) in vec2 attribTexCoord;
layout (location = 2) in float attribTexIndex;
layout (location = 3) in vec4 attribColor;

out VS_OUT {
	vec2 texCoord;
	float texIndex;
	vec4 color;
} frag;

uniform mat4 matProj;

void main() {
	frag.texCoord = attribTexCoord;
	frag.texIndex = attribTexIndex;
	frag.color = attribColor;
	gl_Position = matProj * vec4(attribPosition, 0.0, 1.0);
}
`

@(private)
OVERLAY_FRAGMENT_SHADER :: `
#version 450 core
in VS_OUT {
	vec2 texCoord;
	float texIndex;
	vec4 color;
} frag;

out vec4 fragColor;

uniform sampler2D textures[16];

void main() {
	int index = int(frag.texIndex);
	fragColor = texture(textures[index], frag.texCoord) * frag.color;
	// fragColor = vec4(1.0, 0.0, 0.0, 1.0);
}
`

Font :: struct {
	name:  string,
	faces: map[int]Font_Face,
}

Font_Loader :: struct {
	path:  string,
	sizes: []int,
}

Font_Face :: struct {
	name:     string,
	size:     int,
	scale:    f64,
	glyphs:   []Font_Glyph,
	offset:   int,
	texture:  ^Texture,
	ascent:   f64,
	descent:  f64,
	line_gap: f64,
}

Font_Glyph :: struct {
	codepoint:     rune,
	advance:       f64,
	left_bearing:  f64,
	x, y:          f64,
	width, height: f64,
	y_offset:      f64,
}

@(private)
internal_load_font :: proc(loader: Font_Loader, allocator := context.allocator) -> Font {
	context.allocator = allocator
	font := Font {
		name  = strings.clone(filepath.base(loader.path)),
		faces = make(map[int]Font_Face, len(loader.sizes)),
	}

	data, ok := os.read_entire_file(loader.path, context.temp_allocator)
	if !ok {
		log.fatalf("%s: Failed to read font file: %s", App_Module.Texture, loader.path)
		return font
	}
	for size in loader.sizes {
		font.faces[size] = make_face_from_slice(data, size, 0, 128)
	}
	return font
}

destroy_font :: proc(f: ^Font) {
	for size in f.faces {
		face := &f.faces[size]
		delete(face.glyphs)
	}
	delete(f.faces)
	delete(f.name)
}

@(private)
make_face_from_slice :: proc(font: []byte, pixel_size: int, start, end: rune) -> Font_Face {
	face := Font_Face {
		size   = pixel_size,
		glyphs = make([]Font_Glyph, end - start),
		offset = int(start),
	}
	info := stbtt.fontinfo{}
	if !stbtt.InitFont(&info, &font[0], 0) {
		assert(false, "failed to init font")
	}
	ascent, descent, line_gap: i32
	face.scale = f64(stbtt.ScaleForPixelHeight(&info, f32(pixel_size)))
	stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
	face.ascent = math.round_f64(f64(ascent) * face.scale)
	face.descent = math.round_f64(f64(descent) * face.scale)
	face.line_gap = math.round_f64(f64(line_gap) * face.scale)

	for _, i in face.glyphs {
		r := start + rune(i)
		glyph := &face.glyphs[i]
		glyph.codepoint = r

		adv, lsb: i32
		stbtt.GetCodepointHMetrics(&info, r, &adv, &lsb)
		glyph.advance = math.round_f64(f64(adv) * face.scale)
		glyph.left_bearing = math.round_f64(f64(lsb) * face.scale)
	}

	bitmap: []byte
	bitmap_width :: 1024
	bitmap_height := pixel_size
	x := 0
	for glyph in face.glyphs {
		next_x := x + int(glyph.advance)
		if next_x > bitmap_width {
			bitmap_height += pixel_size
			x = int(glyph.advance)
		} else {
			x = next_x
		}
	}

	bitmap_height += 10
	bitmap = make([]byte, bitmap_width * bitmap_height, context.temp_allocator)

	x = 0
	row_y := 10
	for _, i in face.glyphs {
		r := start + rune(i)
		glyph := &face.glyphs[i]

		next_x := x + int(glyph.advance)
		if next_x > bitmap_width {
			row_y += pixel_size
			x = 0
		}

		x1, y1, x2, y2: i32
		stbtt.GetCodepointBitmapBox(&info, r, f32(face.scale), f32(face.scale), &x1, &y1, &x2, &y2)

		glyph.width = f64(x2 - x1)
		glyph.height = f64(y2 - y1)

		y := int(face.ascent) + int(y1)
		offset := x + int(glyph.left_bearing) + ((row_y + y) * bitmap_width)
		stbtt.MakeCodepointBitmap(
			&info,
			&bitmap[offset],
			i32(glyph.width),
			i32(glyph.height),
			bitmap_width,
			f32(face.scale),
			f32(face.scale),
			r,
		)
		glyph.x = f64(x) + glyph.left_bearing
		glyph.y = f64(row_y + y)
		glyph.y_offset = f64(y)

		x += int(glyph.advance)
	}

	// FIXME: temp

	rgba_bmp := make([]byte, len(bitmap) * 4)
	for b, i in bitmap {
		offset := i * 4
		rgba_bmp[offset] = b
		rgba_bmp[offset + 1] = b
		rgba_bmp[offset + 2] = b
		rgba_bmp[offset + 3] = b
	}
	texture_res := texture_resource(
		loader = Texture_Loader{
			data = rgba_bmp,
			channels = 4,
			filter = .Linear,
			wrap = .Repeat,
			width = bitmap_width,
			height = bitmap_height,
		},
		is_bitmap = true,
	)
	face.texture = texture_res.data.(^Texture)
	return face
}

/*
Canvas_Node :: struct {
	preserve_last_frame: bool,
	projection:          Matrix4,
	framebuffer:          ^Framebuffer,
	attributes:          ^Attributes,
	vertex_buffer:       ^Buffer,
	index_buffer:        ^Buffer,
	paint_shader:        ^Shader,
	blit_shader:         ^Shader,
	default_texture:     ^Resource,

	// CPU Buffers
	vertices:            [dynamic]f32,
	indices:             [dynamic]u32,
	textures:            [16]^Texture,
	texture_count:       int,
	previous_v_count:    int,
	previous_i_count:    int,
	index_offset:        u32,
}

@(private)
init_overlay :: proc(canvas: ^Canvas_Node, w, h: int) {
	OVERLAY_QUAD_CAP :: 1000
	OVERLAY_VERTEX_CAP :: OVERLAY_QUAD_CAP * 4
	OVERLAY_INDEX_CAP :: OVERLAY_QUAD_CAP * 6
	OVERLAY_VERT_LAYOUT :: Vertex_Layout{.Float2, .Float2, .Float1, .Float4}


	overlay_stride := vertex_layout_length(OVERLAY_VERT_LAYOUT)
	canvas^ = {
		projection = linalg.matrix_mul(
			linalg.matrix_ortho3d_f32(0, f32(w), f32(h), 0, 1, 100),
			linalg.matrix4_translate_f32({0, 0, f32(-1)}),
		),
	}
	canvas.attributes = attributes_from_layout(OVERLAY_VERT_LAYOUT, .Interleaved)

	vertex_buffer_res := typed_buffer_resource(f32, overlay_stride * OVERLAY_VERTEX_CAP)
	index_buffer_res := typed_buffer_resource(u32, OVERLAY_INDEX_CAP)
	canvas.vertex_buffer = vertex_buffer_res.data.(^Buffer)
	canvas.index_buffer = index_buffer_res.data.(^Buffer)


	framebuffer_res := framebuffer_resource(
		Framebuffer_Loader{
			attachments = {.Color},
			width = w,
			height = h,
			clear_colors = {0 = {0, 0, 0, 0}},
		},
	)
	canvas.framebuffer = framebuffer_res.data.(^Framebuffer)

	canvas.default_texture = texture_resource(
		loader = Texture_Loader{
			data = {0xff, 0xff, 0xff, 0xff},
			filter = .Nearest,
			wrap = .Repeat,
			channels = 4,
			width = 1,
			height = 1,
		},
		is_bitmap = true,
	)
	canvas.textures[0] = canvas.default_texture.data.(^Texture)
	canvas.texture_count = 1

	paint_shader_res := shader_resource(
		Shader_Loader{
			vertex_source = OVERLAY_VERTEX_SHADER,
			fragment_source = OVERLAY_FRAGMENT_SHADER,
		},
	)
	canvas.paint_shader = paint_shader_res.data.(^Shader)

	blit_shader_res := shader_resource(
		Shader_Loader{
			vertex_source = BLIT_FRAMEBUFFER_VERTEX_SHADER,
			fragment_source = BLIT_FRAMEBUFFER_FRAGMENT_SHADER,
		},
	)
	canvas.blit_shader = blit_shader_res.data.(^Shader)

	texture_indices := [16]i32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
	set_shader_uniform(canvas.paint_shader, "textures", &texture_indices[0])
}

close_overlay :: proc(canvas: ^Canvas_Node) {
	delete(canvas.vertices)
	delete(canvas.indices)
}

@(private)
prepare_overlay_frame :: proc(canvas: ^Canvas_Node) {
	canvas.vertices = make([dynamic]f32, 0, canvas.previous_v_count, context.temp_allocator)
	canvas.indices = make([dynamic]u32, 0, canvas.previous_i_count, context.temp_allocator)
	canvas.texture_count = 1
}

@(private)
push_overlay_quad :: proc(canvas: ^Canvas_Node, c: Render_Quad_Command) {
	x1 := c.dst.x
	x2 := c.dst.x + c.dst.width
	y1 := c.dst.y
	y2 := c.dst.y + c.dst.height
	uvx1 := c.src.x / c.texture.width
	uvx2 := (c.src.x + c.src.width) / c.texture.width
	uvy1 := c.src.y / c.texture.height
	uvy2 := (c.src.y + c.src.height) / c.texture.height
	r := c.color.r
	g := c.color.g
	b := c.color.b
	a := c.color.a

	texture_index := -1
	for texture, i in canvas.textures[:canvas.texture_count] {
		if c.texture.handle == texture.handle {
			texture_index = i
			break
		}
	}
	if texture_index == -1 {
		canvas.textures[canvas.texture_count] = c.texture
		texture_index = canvas.texture_count
		canvas.texture_count += 1
	}
	i_off := canvas.index_offset
			//odinfmt: disable
			append(
				&canvas.vertices, 
				x1, y1, uvx1, uvy1, f32(texture_index), r, g, b, a,
				x2, y1, uvx2, uvy1, f32(texture_index), r, g, b, a,
				x2, y2, uvx2, uvy2, f32(texture_index), r, g, b, a,
				x1, y2, uvx1, uvy2, f32(texture_index), r, g, b, a,
			)
			append(
				&canvas.indices,
				i_off + 1, i_off + 0, i_off + 2,
				i_off + 2, i_off + 0, i_off + 3,
			)
			//odinfmt: enable


	canvas.index_offset += 4
}

@(private)
flush_overlay_buffers :: proc(canvas: ^Canvas_Node) {
	if len(canvas.indices) > 0 {
		bind_framebuffer(canvas.framebuffer)
		clear_framebuffer(canvas.framebuffer)
		bind_shader(canvas.paint_shader)
		set_shader_uniform(canvas.paint_shader, "matProj", &canvas.projection[0][0])
		send_buffer_data(canvas.vertex_buffer, canvas.vertices[:])
		send_buffer_data(canvas.index_buffer, canvas.indices[:])


		bind_texture(canvas.textures[0], u32(0))
		bind_texture(canvas.textures[1], u32(1))
		// for i in 0 ..< canvas.texture_count {
		// }
		bind_attributes(canvas.attributes)

		defer {
			default_attributes()
			for i in 0 ..< canvas.texture_count {
				unbind_texture(canvas.textures[i])
			}
		}
		link_interleaved_attributes_vertices(canvas.attributes, canvas.vertex_buffer)
		link_attributes_indices(canvas.attributes, canvas.index_buffer)
		draw_triangles(len(canvas.indices))
		default_framebuffer()
	}
	canvas.previous_v_count = len(canvas.vertices)
	canvas.previous_i_count = len(canvas.indices)
	canvas.index_offset = 0
}

@(private)
paint_overlay :: proc(canvas: ^Canvas_Node) {
  //odinfmt: disable
	framebuffer_vertices := [?]f32{
		-1.0, -1.0, 0.0, 0.0, 0, 0, 0, 0, 0,
		 1.0, -1.0, 1.0, 0.0, 0, 0, 0, 0, 0,
		 1.0,  1.0, 1.0, 1.0, 0, 0, 0, 0, 0,
		-1.0,  1.0, 0.0, 1.0, 0, 0, 0, 0, 0,
	}
	framebuffer_indices := [?]u32{
		1, 0, 2,
		2, 0, 3,
	}
		//odinfmt: enable


	texture_index: u32 = 0

	// Set the shader up
	bind_shader(canvas.blit_shader)
	set_shader_uniform(canvas.blit_shader, "texture0", &texture_index)
	bind_texture(framebuffer_texture(canvas.framebuffer, .Color), texture_index)
	send_buffer_data(canvas.vertex_buffer, framebuffer_vertices[:])
	send_buffer_data(canvas.index_buffer, framebuffer_indices[:])

	// prepare attributes
	bind_attributes(canvas.attributes)
	defer {
		default_attributes()
		default_shader()
		unbind_texture(framebuffer_texture(canvas.framebuffer, .Color))
	}

	link_interleaved_attributes_vertices(canvas.attributes, canvas.vertex_buffer)
	link_attributes_indices(canvas.attributes, canvas.index_buffer)

	draw_triangles(len(framebuffer_indices))
}

@(private)
default_overlay_texture :: proc(canvas: ^Canvas_Node) -> ^Texture {
	return canvas.textures[0]
}

draw_overlay_rect :: proc(r: Rectangle, clr: Color) {
	push_draw_command(
		Render_Quad_Command{
			dst = r,
			src = {x = 0, y = 0, width = 1, height = 1},
			color = clr,
			texture = default_overlay_texture(&app.render_ctx.canvas),
		},
	)
}

draw_overlay_sub_texture :: proc(t: ^Texture, dst, src: Rectangle, clr: Color) {
	push_draw_command(Render_Quad_Command{dst = dst, src = src, color = clr, texture = t})
}

draw_overlay_text :: proc(f: ^Font, text: string, p: Vector2, size: int, clr: Color) {
	face := &f.faces[size]
	cursor_pos := p.x
	for r in text {
		glyph := face.glyphs[r]
		r := Rectangle{
			cursor_pos + f32(glyph.left_bearing),
			p.y + f32(glyph.y_offset),
			f32(glyph.width),
			f32(glyph.height),
		}
		draw_overlay_sub_texture(
			face.texture,
			r,
			{f32(glyph.x), f32(glyph.y), f32(glyph.width), f32(glyph.height)},
			clr,
		)
		cursor_pos += f32(glyph.advance)
	}
}


@(private)
OVERLAY_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec2 attribPosition;
layout (location = 1) in vec2 attribTexCoord;
layout (location = 2) in float attribTexIndex;
layout (location = 3) in vec4 attribColor;

out VS_OUT {
	vec2 texCoord;
	float texIndex;
	vec4 color;
} frag;

uniform mat4 matProj;

void main() {
	frag.texCoord = attribTexCoord;
	frag.texIndex = attribTexIndex;
	frag.color = attribColor;
	gl_Position = matProj * vec4(attribPosition, 0.0, 1.0);
}
`

@(private)
OVERLAY_FRAGMENT_SHADER :: `
#version 450 core
in VS_OUT {
	vec2 texCoord;
	float texIndex;
	vec4 color;
} frag;

out vec4 fragColor;

uniform sampler2D textures[16];

void main() {
	int index = int(frag.texIndex);
	fragColor = texture(textures[index], frag.texCoord) * frag.color;
	// fragColor = vec4(1.0, 0.0, 0.0, 1.0);
}
`

Font :: struct {
	name:  string,
	faces: map[int]Font_Face,
}

Font_Loader :: struct {
	path:  string,
	sizes: []int,
}

Font_Face :: struct {
	name:     string,
	size:     int,
	scale:    f64,
	glyphs:   []Font_Glyph,
	offset:   int,
	texture:  ^Texture,
	ascent:   f64,
	descent:  f64,
	line_gap: f64,
}

Font_Glyph :: struct {
	codepoint:     rune,
	advance:       f64,
	left_bearing:  f64,
	x, y:          f64,
	width, height: f64,
	y_offset:      f64,
}

@(private)
internal_load_font :: proc(loader: Font_Loader, allocator := context.allocator) -> Font {
	context.allocator = allocator
	font := Font {
		name  = strings.clone(filepath.base(loader.path)),
		faces = make(map[int]Font_Face, len(loader.sizes)),
	}

	data, ok := os.read_entire_file(loader.path, context.temp_allocator)
	if !ok {
		log.fatalf("%s: Failed to read font file: %s", App_Module.Texture, loader.path)
		return font
	}
	for size in loader.sizes {
		font.faces[size] = make_face_from_slice(data, size, 0, 128)
	}
	return font
}

destroy_font :: proc(f: ^Font) {
	for size in f.faces {
		face := &f.faces[size]
		delete(face.glyphs)
	}
	delete(f.faces)
	delete(f.name)
}

@(private)
make_face_from_slice :: proc(font: []byte, pixel_size: int, start, end: rune) -> Font_Face {
	face := Font_Face {
		size   = pixel_size,
		glyphs = make([]Font_Glyph, end - start),
		offset = int(start),
	}
	info := stbtt.fontinfo{}
	if !stbtt.InitFont(&info, &font[0], 0) {
		assert(false, "failed to init font")
	}
	ascent, descent, line_gap: i32
	face.scale = f64(stbtt.ScaleForPixelHeight(&info, f32(pixel_size)))
	stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
	face.ascent = math.round_f64(f64(ascent) * face.scale)
	face.descent = math.round_f64(f64(descent) * face.scale)
	face.line_gap = math.round_f64(f64(line_gap) * face.scale)

	for _, i in face.glyphs {
		r := start + rune(i)
		glyph := &face.glyphs[i]
		glyph.codepoint = r

		adv, lsb: i32
		stbtt.GetCodepointHMetrics(&info, r, &adv, &lsb)
		glyph.advance = math.round_f64(f64(adv) * face.scale)
		glyph.left_bearing = math.round_f64(f64(lsb) * face.scale)
	}

	bitmap: []byte
	bitmap_width :: 1024
	bitmap_height := pixel_size
	x := 0
	for glyph in face.glyphs {
		next_x := x + int(glyph.advance)
		if next_x > bitmap_width {
			bitmap_height += pixel_size
			x = int(glyph.advance)
		} else {
			x = next_x
		}
	}

	bitmap_height += 10
	bitmap = make([]byte, bitmap_width * bitmap_height, context.temp_allocator)

	x = 0
	row_y := 10
	for _, i in face.glyphs {
		r := start + rune(i)
		glyph := &face.glyphs[i]

		next_x := x + int(glyph.advance)
		if next_x > bitmap_width {
			row_y += pixel_size
			x = 0
		}

		x1, y1, x2, y2: i32
		stbtt.GetCodepointBitmapBox(&info, r, f32(face.scale), f32(face.scale), &x1, &y1, &x2, &y2)

		glyph.width = f64(x2 - x1)
		glyph.height = f64(y2 - y1)

		y := int(face.ascent) + int(y1)
		offset := x + int(glyph.left_bearing) + ((row_y + y) * bitmap_width)
		stbtt.MakeCodepointBitmap(
			&info,
			&bitmap[offset],
			i32(glyph.width),
			i32(glyph.height),
			bitmap_width,
			f32(face.scale),
			f32(face.scale),
			r,
		)
		glyph.x = f64(x) + glyph.left_bearing
		glyph.y = f64(row_y + y)
		glyph.y_offset = f64(y)

		x += int(glyph.advance)
	}

	// FIXME: temp

	rgba_bmp := make([]byte, len(bitmap) * 4)
	for b, i in bitmap {
		offset := i * 4
		rgba_bmp[offset] = b
		rgba_bmp[offset + 1] = b
		rgba_bmp[offset + 2] = b
		rgba_bmp[offset + 3] = b
	}
	texture_res := texture_resource(
		loader = Texture_Loader{
			data = rgba_bmp,
			channels = 4,
			filter = .Linear,
			wrap = .Repeat,
			width = bitmap_width,
			height = bitmap_height,
		},
		is_bitmap = true,
	)
	face.texture = texture_res.data.(^Texture)
	return face
}
*/
