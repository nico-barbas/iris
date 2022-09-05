package iris

import "core:math/linalg"

Overlay :: struct {
	preserve_last_frame: bool,
	projection:          Matrix4,
	frambuffer:          Framebuffer,
	state:               Attributes_State,
	vertex_buffer:       Buffer,
	index_buffer:        Buffer,
	paint_shader:        Shader,
	blit_shader:         Shader,

	// CPU Buffers
	vertices:            [dynamic]f32,
	indices:             [dynamic]u32,
	textures:            [16]Texture,
	texture_count:       int,
	previous_v_count:    int,
	previous_i_count:    int,
	index_offset:        u32,
}

@(private)
init_overlay :: proc(overlay: ^Overlay, w, h: int) {
	OVERLAY_QUAD_CAP :: 1000
	OVERLAY_VERTEX_CAP :: OVERLAY_QUAD_CAP * 4
	OVERLAY_INDEX_CAP :: OVERLAY_QUAD_CAP * 6
	OVERLAY_VERT_LAYOUT :: Vertex_Layout{.Float2, .Float2, .Float1, .Float4}


	overlay_stride := vertex_layout_length(OVERLAY_VERT_LAYOUT)
	overlay^ = {
		projection    = linalg.matrix_mul(
			linalg.matrix_ortho3d_f32(0, f32(w), f32(h), 0, 1, 100),
			linalg.matrix4_translate_f32({0, 0, f32(-1)}),
		),
		state         = get_ctx_attribute_state(OVERLAY_VERT_LAYOUT, .Interleaved),
		vertex_buffer = make_buffer(f32, overlay_stride * OVERLAY_VERTEX_CAP),
		index_buffer  = make_buffer(u32, OVERLAY_INDEX_CAP),
	}
	overlay.frambuffer = make_framebuffer({.Color}, w, h)
	overlay.frambuffer.clear_color = {0, 0, 0, 0}
	overlay.textures[0] = load_texture_from_bitmap({0xff, 0xff, 0xff, 0xff}, 4, 1, 1)
	overlay.texture_count = 1
	overlay.paint_shader = load_shader_from_bytes(
		OVERLAY_VERTEX_SHADER,
		OVERLAY_FRAGMENT_SHADER,
		"paintOverlay",
	)
	overlay.blit_shader = load_shader_from_bytes(
		BLIT_FRAMEBUFFER_VERTEX_SHADER,
		BLIT_FRAMEBUFFER_FRAGMENT_SHADER,
		"blitFramebuffer",
	)
}

close_overlay :: proc(overlay: ^Overlay) {
	destroy_buffer(overlay.vertex_buffer)
	destroy_buffer(overlay.index_buffer)
	destroy_framebuffer(overlay.frambuffer)
	destroy_texture(&overlay.textures[0])
	destroy_shader(&overlay.paint_shader)
	destroy_shader(&overlay.blit_shader)
}

@(private)
prepare_overlay_frame :: proc(overlay: ^Overlay) {
	overlay.vertices = make([dynamic]f32, 0, overlay.previous_v_count, context.temp_allocator)
	overlay.indices = make([dynamic]u32, 0, overlay.previous_i_count, context.temp_allocator)
	overlay.texture_count = 1
}

@(private)
push_overlay_quad :: proc(overlay: ^Overlay, c: Render_Quad_Command) {
	x1 := c.dst.x
	x2 := c.dst.x + c.dst.width
	y1 := c.dst.y
	y2 := c.dst.x + c.dst.height
	uvx1 := c.src.x / c.texture.width
	uvx2 := (c.src.x + c.src.width) / c.texture.width
	uvy1 := c.src.y / c.texture.width
	uvy2 := (c.src.y + c.src.height) / c.texture.width
	r := c.color.r
	g := c.color.g
	b := c.color.b
	a := c.color.a

	texture_index := -1
	for texture, i in overlay.textures {
		if c.texture.handle == texture.handle {
			texture_index = i
			break
		}
	}
	if texture_index == -1 {
		overlay.textures[overlay.texture_count] = c.texture
		texture_index = overlay.texture_count
		overlay.texture_count += 1
	}
	i_off := overlay.index_offset
			//odinfmt: disable
			append(
				&overlay.vertices, 
				x1, y1, uvx1, uvy1, f32(texture_index), r, g, b, a,
				x2, y1, uvx2, uvy1, f32(texture_index), r, g, b, a,
				x2, y2, uvx2, uvy2, f32(texture_index), r, g, b, a,
				x1, y2, uvx1, uvy2, f32(texture_index), r, g, b, a,
			)
			append(
				&overlay.indices,
				i_off + 1, i_off + 0, i_off + 2,
				i_off + 2, i_off + 0, i_off + 3,
			)
			//odinfmt: enable


	overlay.index_offset += 4
}

@(private)
flush_overlay_buffers :: proc(overlay: ^Overlay) {
	if len(overlay.indices) > 0 {
		bind_framebuffer(overlay.frambuffer)
		clear_framebuffer(overlay.frambuffer)
		bind_shader(overlay.paint_shader)
		set_shader_uniform(overlay.paint_shader, "matProj", &overlay.projection[0][0])
		send_buffer_data(overlay.vertex_buffer, overlay.vertices[:])
		send_buffer_data(overlay.index_buffer, overlay.indices[:])

		for i in 0 ..< overlay.texture_count {
			bind_texture(&overlay.textures[i], u32(i))
		}
		bind_attributes_state(overlay.state)

		defer {
			unbind_attributes_state()
			for i in 0 ..< overlay.texture_count {
				unbind_texture(&overlay.textures[i])
			}
		}
		link_attributes_state_vertices(&overlay.state, overlay.vertex_buffer)
		link_attributes_state_indices(&overlay.state, overlay.index_buffer)
		draw_triangles(len(overlay.indices))
		default_framebuffer()
	}
	overlay.previous_v_count = len(overlay.vertices)
	overlay.previous_i_count = len(overlay.indices)
	overlay.index_offset = 0
}

@(private)
paint_overlay :: proc(overlay: ^Overlay) {
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
	bind_shader(overlay.blit_shader)
	set_shader_uniform(overlay.blit_shader, "texture0", &texture_index)
	bind_texture(framebuffer_texture(&overlay.frambuffer, .Color), texture_index)
	send_buffer_data(overlay.vertex_buffer, framebuffer_vertices[:])
	send_buffer_data(overlay.index_buffer, framebuffer_indices[:])

	// prepare attributes
	bind_attributes_state(overlay.state)
	defer {
		unbind_attributes_state()
		unbind_shader()
		unbind_texture(framebuffer_texture(&overlay.frambuffer, .Color))
	}

	link_attributes_state_vertices(&overlay.state, overlay.vertex_buffer)
	link_attributes_state_indices(&overlay.state, overlay.index_buffer)

	draw_triangles(len(framebuffer_indices))
}

@(private)
default_overlay_texture :: proc(overlay: ^Overlay) -> Texture {
	return overlay.textures[0]
}

draw_overlay_rect :: proc(r: Rectangle, clr: Color) {
	push_draw_command(
		Render_Quad_Command{
			dst = r,
			src = {x = 0, y = 0, width = 1, height = 1},
			color = clr,
			texture = default_overlay_texture(&app.render_ctx.overlay),
		},
	)
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
