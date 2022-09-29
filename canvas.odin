package iris

import "core:math/linalg"

CANVAS_MAX_CLIP :: 32

Canvas_Node :: struct {
	using base:            Node,
	width:                 int,
	height:                int,
	derived_flags:         Canvas_Flags,

	// Graphical states
	projection:            Matrix4,
	framebuffer:           ^Framebuffer,
	attributes:            ^Attributes,
	vertex_buffer:         ^Buffer,
	index_buffer:          ^Buffer,
	paint_shader:          ^Shader,
	default_texture:       ^Resource,
	vertex_arena:          Arena_Buffer_Allocator,
	tri_sub_buffer:        Buffer_Memory,
	line_sub_buffer:       Buffer_Memory,
	index_arena:           Arena_Buffer_Allocator,
	it_sub_buffer:         Buffer_Memory,
	il_sub_buffer:         Buffer_Memory,

	// CPU Buffers
	clips:                 [CANVAS_MAX_CLIP]Canvas_Clipping_Info,
	clip_count:            int,
	clip_tri_index_start:  u32,
	clip_line_index_start: u32,
	vertices:              [dynamic]f32,
	line_vertices:         [dynamic]f32,
	textures:              [16]^Texture,
	texture_count:         int,
	previous_v_count:      int,
	previous_lv_count:     int,

	// Indices
	tri_indices:           []u32,
	tri_index_offset:      u32,
	tri_index_count:       u32,
	line_indices:          []u32,
	line_index_offset:     u32,
	line_index_count:      u32,
}

Canvas_Flags :: distinct bit_set[Canvas_Flag]

Canvas_Flag :: enum {
	Preserve_Last_Frame,
}

Canvas_Quad_Options :: struct {
	dst:     Rectangle,
	src:     Rectangle,
	texture: ^Texture,
	color:   Color,
}

Canvas_Line_Options :: struct {
	p1:    Vector2,
	p2:    Vector2,
	color: Color,
}

Canvas_Clipping_Info :: struct {
	bounds:     Rectangle,
	tri_count:  u32,
	line_count: u32,
}

VERTEX_CAP :: 5000
QUAD_VERTICES :: 3500
@(private)
init_canvas_node :: proc(canvas: ^Canvas_Node) {
	LINE_VERTICES :: VERTEX_CAP - QUAD_VERTICES
	QUAD_CAP :: QUAD_VERTICES / 4
	LINE_CAP :: LINE_VERTICES / 2
	INDEX_CAP :: (QUAD_CAP * 6) + (LINE_CAP * 2)
	stride := (buffer_len_of[.Vector2] + buffer_len_of[.Vector3] + buffer_len_of[.Vector4])


	canvas.projection = linalg.matrix_mul(
		linalg.matrix_ortho3d_f32(0, f32(canvas.width), f32(canvas.height), 0, 1, 100),
		linalg.matrix4_translate_f32({0, 0, f32(-1)}),
	)
	canvas.attributes = attributes_from_layout(
		Attribute_Layout{
			enabled = {.Position, .Tex_Coord, .Color},
			accessors = {
				Attribute_Kind.Position = Buffer_Data_Type{kind = .Float_32, format = .Vector2},
				Attribute_Kind.Tex_Coord = Buffer_Data_Type{kind = .Float_32, format = .Vector3},
				Attribute_Kind.Color = Buffer_Data_Type{kind = .Float_32, format = .Vector4},
			},
		},
		.Interleaved,
	)

	vertex_buffer_res := raw_buffer_resource(stride * VERTEX_CAP * size_of(f32))
	index_buffer_res := raw_buffer_resource(INDEX_CAP * size_of(u32))
	canvas.vertex_buffer = vertex_buffer_res.data.(^Buffer)
	canvas.index_buffer = index_buffer_res.data.(^Buffer)
	arena_init(
		&canvas.vertex_arena,
		Buffer_Memory{
			buf = canvas.vertex_buffer,
			size = stride * VERTEX_CAP * size_of(f32),
			offset = 0,
		},
	)
	canvas.tri_sub_buffer = arena_allocate(
		&canvas.vertex_arena,
		stride * QUAD_VERTICES * size_of(f32),
	)
	canvas.line_sub_buffer = arena_allocate(
		&canvas.vertex_arena,
		stride * LINE_VERTICES * size_of(f32),
	)

	arena_init(
		&canvas.index_arena,
		Buffer_Memory{buf = canvas.index_buffer, size = INDEX_CAP * size_of(u32), offset = 0},
	)
	canvas.it_sub_buffer = arena_allocate(&canvas.index_arena, (QUAD_CAP * 6) * size_of(u32))
	canvas.il_sub_buffer = arena_allocate(&canvas.index_arena, (LINE_CAP * 2) * size_of(u32))


	framebuffer_res := framebuffer_resource(
		Framebuffer_Loader{
			attachments = {.Color0},
			width = canvas.width,
			height = canvas.height,
			clear_colors = {Framebuffer_Attachment.Color0 = {0, 0, 0, 0}},
		},
	)
	canvas.framebuffer = framebuffer_res.data.(^Framebuffer)

	canvas.default_texture = texture_resource(
		loader = Texture_Loader{
			filter = .Nearest,
			wrap = .Repeat,
			space = .Linear,
			width = 1,
			height = 1,
			info = Byte_Texture_Info{data = {0xff, 0xff, 0xff, 0xff}, channels = 4, bitmap = true},
		},
	)
	canvas.textures[0] = canvas.default_texture.data.(^Texture)
	canvas.texture_count = 1

	paint_shader_res := shader_resource(
		Raw_Shader_Loader{
			name = "paint_canvas",
			kind = .Byte,
			stages = {
				Shader_Stage.Vertex = Shader_Stage_Loader{source = OVERLAY_VERTEX_SHADER},
				Shader_Stage.Fragment = Shader_Stage_Loader{source = OVERLAY_FRAGMENT_SHADER},
			},
		},
	)
	canvas.paint_shader = paint_shader_res.data.(^Shader)

	texture_indices := [16]i32{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
	set_shader_uniform(canvas.paint_shader, "textures", &texture_indices[0])

	canvas.tri_indices = make([]u32, (QUAD_CAP * 6))
	canvas.line_indices = make([]u32, (LINE_CAP * 2))
}

@(private)
prepare_canvas_node_render :: proc(canvas: ^Canvas_Node) {
	canvas.vertices = make([dynamic]f32, 0, canvas.previous_v_count, context.temp_allocator)
	canvas.line_vertices = make([dynamic]f32, 0, canvas.previous_lv_count, context.temp_allocator)
	canvas.texture_count = 1
}

@(private)
push_canvas_quad :: proc(canvas: ^Canvas_Node, c: Canvas_Quad_Options) {
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
			//odinfmt: disable
			append(
				&canvas.vertices, 
				x1, y1, uvx1, uvy1, f32(texture_index), r, g, b, a,
				x2, y1, uvx2, uvy1, f32(texture_index), r, g, b, a,
				x2, y2, uvx2, uvy2, f32(texture_index), r, g, b, a,
				x1, y2, uvx1, uvy2, f32(texture_index), r, g, b, a,
			)
			//odinfmt: enable
	i_off := canvas.tri_index_offset
	start := canvas.tri_index_count
	canvas.tri_indices[start] = i_off + 1
	canvas.tri_indices[start + 1] = i_off + 0
	canvas.tri_indices[start + 2] = i_off + 2
	canvas.tri_indices[start + 3] = i_off + 2
	canvas.tri_indices[start + 4] = i_off + 0
	canvas.tri_indices[start + 5] = i_off + 3


	canvas.tri_index_offset += 4
	canvas.tri_index_count += 6
}

push_canvas_line :: proc(canvas: ^Canvas_Node, c: Canvas_Line_Options) {
	x1 := c.p1.x
	x2 := c.p2.x
	y1 := c.p1.y
	y2 := c.p2.y
	r := c.color.r
	g := c.color.g
	b := c.color.b
	a := c.color.a
	//odinfmt: disable
	append(
		&canvas.line_vertices,
		x1, y1, 0, 0, 0, r, g, b, a,
		x2, y2, 0, 0, 0, r, g, b, a,
	)
	//odinfmt: enable
	i_off := canvas.line_index_offset
	start := canvas.line_index_count
	canvas.line_indices[start] = i_off
	canvas.line_indices[start + 1] = i_off + 1

	canvas.line_index_offset += 2
	canvas.line_index_count += 2
}

push_canvas_clip :: proc(canvas: ^Canvas_Node, rect: Rectangle) {
	canvas.clips[canvas.clip_count] = Canvas_Clipping_Info {
		bounds = rect,
	}
	if canvas.clip_count > 0 {
		previous_clip := &canvas.clips[canvas.clip_count - 1]
		previous_clip.tri_count = canvas.tri_index_count - canvas.clip_tri_index_start
		previous_clip.line_count = canvas.line_index_count - canvas.clip_line_index_start
	}
	canvas.clip_tri_index_start = canvas.tri_index_count
	canvas.clip_line_index_start = canvas.line_index_count
	canvas.clip_count += 1
}

@(private)
flush_canvas_node_buffers :: proc(data: rawptr) {
	canvas := cast(^Canvas_Node)data
	if .Preserve_Last_Frame not_in canvas.derived_flags {
		clip_mode_on()
		default_clip_rect()

		bind_framebuffer(canvas.framebuffer)
		clear_framebuffer(canvas.framebuffer)
		bind_shader(canvas.paint_shader)
		set_shader_uniform(canvas.paint_shader, "matProj", &canvas.projection[0][0])
		for i in 0 ..< canvas.texture_count {
			bind_texture(canvas.textures[i], u32(i))
		}
		bind_attributes(canvas.attributes)
		defer {
			default_shader()
			default_attributes()
			for i in 0 ..< canvas.texture_count {
				unbind_texture(canvas.textures[i])
			}
			default_framebuffer()
			default_clip_rect()
			clip_mode_off()
		}
		link_interleaved_attributes_vertices(canvas.attributes, canvas.vertex_buffer)
		link_attributes_indices(canvas.attributes, canvas.index_buffer)

		if canvas.tri_index_count > 0 {
			send_buffer_data(
				&canvas.it_sub_buffer,
				Buffer_Source{
					data = &canvas.tri_indices[0],
					byte_size = int(size_of(u32) * canvas.tri_index_count),
					accessor = Buffer_Data_Type{kind = .Unsigned_32, format = .Scalar},
				},
			)
			send_buffer_data(
				&canvas.tri_sub_buffer,
				Buffer_Source{
					data = &canvas.vertices[0],
					byte_size = size_of(f32) * len(canvas.vertices),
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Scalar},
				},
			)
			if canvas.clip_count > 0 {
				last_clip := &canvas.clips[canvas.clip_count - 1]
				last_clip.tri_count = canvas.tri_index_count - canvas.clip_tri_index_start

				tri_byte_offset: uintptr = 0
				for clip in canvas.clips[:canvas.clip_count] {
					set_clip_rect(clip.bounds)
					draw_triangles(int(clip.tri_count), tri_byte_offset)
					tri_byte_offset += uintptr(clip.tri_count * size_of(u32))
					default_clip_rect()
				}
			} else {
				draw_triangles(int(canvas.tri_index_count))
			}
		}
		if canvas.line_index_count > 0 {
			send_buffer_data(
				&canvas.il_sub_buffer,
				Buffer_Source{
					data = &canvas.line_indices[0],
					byte_size = int(size_of(u32) * canvas.line_index_count),
					accessor = Buffer_Data_Type{kind = .Unsigned_32, format = .Scalar},
				},
			)
			send_buffer_data(
				&canvas.line_sub_buffer,
				Buffer_Source{
					data = &canvas.line_vertices[0],
					byte_size = size_of(f32) * len(canvas.line_vertices),
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Scalar},
				},
			)
			if canvas.clip_count > 0 {
				last_clip := &canvas.clips[canvas.clip_count - 1]
				last_clip.line_count = canvas.line_index_count - canvas.clip_line_index_start

				line_byte_offset: uintptr = 0
				for clip in canvas.clips[:canvas.clip_count] {
					set_clip_rect(clip.bounds)
					draw_lines(
						int(clip.line_count),
						uintptr(canvas.il_sub_buffer.offset) + line_byte_offset,
						QUAD_VERTICES,
					)
					line_byte_offset += uintptr(clip.line_count * size_of(u32))
					default_clip_rect()
				}
			} else {
				draw_lines(
					int(canvas.line_index_count),
					uintptr(canvas.il_sub_buffer.offset),
					QUAD_VERTICES,
				)
			}
		}
	}
	// push_draw_command(
	// 	Render_Framebuffer_Command{
	// 		render_order = 1,
	// 		framebuffer = canvas.framebuffer,
	// 		vertex_memory = &canvas.tri_sub_buffer,
	// 		index_buffer = canvas.index_buffer,
	// 	},
	// )
	blit_framebuffer(canvas.framebuffer, nil, &canvas.tri_sub_buffer, &canvas.it_sub_buffer)
	canvas.previous_v_count = len(canvas.vertices)
	canvas.previous_lv_count = len(canvas.line_vertices)
	canvas.tri_index_offset = 0
	canvas.tri_index_count = 0
	canvas.line_index_offset = 0
	canvas.line_index_count = 0
	canvas.clip_count = 0
	canvas.derived_flags -= {.Preserve_Last_Frame}
}

@(private)
default_canvas_texture :: proc(canvas: ^Canvas_Node) -> ^Texture {
	return canvas.textures[0]
}

draw_rect :: proc(canvas: ^Canvas_Node, r: Rectangle, clr: Color) {
	push_canvas_quad(
		canvas,
		Canvas_Quad_Options{
			dst = r,
			src = {x = 0, y = 0, width = 1, height = 1},
			color = clr,
			texture = default_canvas_texture(canvas),
		},
	)
}

draw_line :: proc(canvas: ^Canvas_Node, s, e: Vector2, clr: Color) {
	push_canvas_line(canvas, Canvas_Line_Options{p1 = s, p2 = e, color = clr})
}

draw_sub_texture :: proc(canvas: ^Canvas_Node, t: ^Texture, dst, src: Rectangle, clr: Color) {
	push_canvas_quad(canvas, Canvas_Quad_Options{dst = dst, src = src, color = clr, texture = t})
}

draw_text :: proc(
	canvas: ^Canvas_Node,
	f: ^Font,
	text: string,
	point: Vector2,
	size: int,
	clr: Color,
) {
	face := &f.faces[size]
	cursor_pos := point
	if len(text) > 1 {
		cursor_pos.x += f32(face.glyphs[text[0]].left_bearing)
	}
	for r in text {
		glyph := face.glyphs[r]
		if r == ' ' {
			cursor_pos.x += f32(glyph.advance)
			continue
		}

		rect := Rectangle{
			cursor_pos.x,
			cursor_pos.y + f32(glyph.y_offset),
			f32(glyph.width),
			f32(glyph.height),
		}
		draw_sub_texture(
			canvas,
			face.texture,
			rect,
			{f32(glyph.x), f32(glyph.y), f32(glyph.width), f32(glyph.height)},
			clr,
		)
		cursor_pos.x += f32(glyph.width)
	}
}


@(private)
OVERLAY_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec2 attribPosition;
layout (location = 5) in vec3 attribTexCoord;
layout (location = 6) in vec4 attribColor;

out VS_OUT {
	vec2 texCoord;
	float texIndex;
	vec4 color;
} frag;

uniform mat4 matProj;

void main() {
	frag.texCoord = attribTexCoord.xy;
	frag.texIndex = attribTexCoord.z;
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
}
`
