package iris

import "core:math/linalg"

Canvas_Node :: struct {
	using base:        Node,
	width:             int,
	height:            int,
	derived_flags:     Canvas_Flags,

	// Graphical states
	projection:        Matrix4,
	framebuffer:       ^Framebuffer,
	attributes:        ^Attributes,
	vertex_buffer:     ^Buffer,
	index_buffer:      ^Buffer,
	paint_shader:      ^Shader,
	default_texture:   ^Resource,
	vertex_arena:      Arena_Buffer_Allocator,
	tri_sub_buffer:    Buffer_Memory,
	line_sub_buffer:   Buffer_Memory,

	// CPU Buffers
	vertices:          [dynamic]f32,
	line_vertices:     [dynamic]f32,
	textures:          [16]^Texture,
	texture_count:     int,
	previous_v_count:  int,
	previous_i_count:  int,

	// Indices
	tri_indices:       []u32,
	tri_index_offset:  u32,
	tri_index_count:   u32,
	line_indices:      []u32,
	line_index_offset: u32,
	line_index_count:  u32,
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

@(private)
init_canvas_node :: proc(canvas: ^Canvas_Node) {
	VERTEX_CAP :: 5000
	QUAD_VERTICES :: 3500
	LINE_VERTICES :: VERTEX_CAP - QUAD_VERTICES
	QUAD_CAP :: QUAD_VERTICES / 4
	LINE_CAP :: LINE_VERTICES / 2
	INDEX_CAP :: (QUAD_CAP * 6) + (LINE_CAP * 2)
	VERTEX_LAYOUT :: Vertex_Layout{.Float2, .Float2, .Float1, .Float4}
	stride := vertex_layout_length(VERTEX_LAYOUT)


	canvas.projection = linalg.matrix_mul(
		linalg.matrix_ortho3d_f32(0, f32(canvas.width), f32(canvas.height), 0, 1, 100),
		linalg.matrix4_translate_f32({0, 0, f32(-1)}),
	)
	canvas.attributes = attributes_from_layout(VERTEX_LAYOUT, .Interleaved)

	vertex_buffer_res := raw_buffer_resource(stride * VERTEX_CAP * size_of(f32), true)
	index_buffer_res := typed_buffer_resource(u32, INDEX_CAP)
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

	canvas.tri_indices = make([]u32, (QUAD_CAP * 6))
	canvas.line_indices = make([]u32, (LINE_CAP * 2))
}

@(private)
prepare_canvas_node_render :: proc(canvas: ^Canvas_Node) {
	canvas.vertices = make([dynamic]f32, 0, canvas.previous_v_count, context.temp_allocator)
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
			// append(
			// 	&canvas.indices,
			// 	i_off + 1, i_off + 0, i_off + 2,
			// 	i_off + 2, i_off + 0, i_off + 3,
			// )
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
}

@(private)
flush_canvas_node_buffers :: proc(data: rawptr) {
	canvas := cast(^Canvas_Node)data
	if .Preserve_Last_Frame not_in canvas.derived_flags {
		if canvas.tri_index_count > 0 {
			bind_framebuffer(canvas.framebuffer)
			clear_framebuffer(canvas.framebuffer)
			bind_shader(canvas.paint_shader)
			set_shader_uniform(canvas.paint_shader, "matProj", &canvas.projection[0][0])
			send_raw_buffer_data(
				&canvas.tri_sub_buffer,
				size_of(f32) * len(canvas.vertices),
				&canvas.vertices[0],
			)
			send_buffer_data(canvas.index_buffer, canvas.tri_indices[:canvas.tri_index_count])


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
			draw_triangles(int(canvas.tri_index_count))
		}
	}
	push_draw_command(
		Render_Framebuffer_Command{
			render_order = 1,
			framebuffer = canvas.framebuffer,
			vertex_memory = &canvas.tri_sub_buffer,
			index_buffer = canvas.index_buffer,
		},
	)
	canvas.previous_v_count = len(canvas.vertices)
	canvas.tri_index_offset = 0
	canvas.tri_index_count = 0
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

draw_sub_texture :: proc(canvas: ^Canvas_Node, t: ^Texture, dst, src: Rectangle, clr: Color) {
	push_canvas_quad(canvas, Canvas_Quad_Options{dst = dst, src = src, color = clr, texture = t})
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