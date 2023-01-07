package iris

import "core:log"
import gl "vendor:OpenGL"

Framebuffer :: struct {
	handle:             u32,
	width:              int,
	height:             int,
	attachments:        Framebuffer_Attachments,
	color_target_count: int,
	clear_colors:       [len(Framebuffer_Attachment)]Color,
	maps:               [len(Framebuffer_Attachment)]Texture,
}

Framebuffer_Loader :: struct {
	width:        int,
	height:       int,
	attachments:  Framebuffer_Attachments,
	filter:       [MAX_COLOR_ATTACHMENT]Texture_Filter_Mode,
	precision:    [MAX_COLOR_ATTACHMENT]int,
	clear_colors: [len(Framebuffer_Attachment)]Color,
}

MAX_COLOR_ATTACHMENT :: int(Framebuffer_Attachment.Color3) + 1

Framebuffer_Attachments :: distinct bit_set[Framebuffer_Attachment]

Framebuffer_Attachment :: enum {
	Color0,
	Color1,
	Color2,
	Color3,
	Depth,
	Stencil,
}

@(private)
internal_make_framebuffer :: proc(l: Framebuffer_Loader) -> Framebuffer {
	create_framebuffer_texture :: proc(
		a: Framebuffer_Attachment,
		w, h: int,
		filter: Texture_Filter_Mode = .Nearest,
		precision := 8,
	) -> Texture {
		texture: Texture
		texture.width = f32(w)
		texture.height = f32(h)
		gl.CreateTextures(gl.TEXTURE_2D, 1, &texture.handle)
		if a >= .Color0 && a <= .Color3 {
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, i32(filter))
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, i32(filter))
			// gl.Texture
			gl.TextureStorage2D(
				texture.handle,
				1,
				gl.RGBA8 if precision == 8 else gl.RGBA16F,
				i32(w),
				i32(h),
			)
		} else if a == .Depth {
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
			gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_BORDER)
			gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_BORDER)
			clr := Color{1, 1, 1, 1}
			gl.TextureParameterfv(texture.handle, gl.TEXTURE_BORDER_COLOR, &clr[0])
			gl.TextureStorage2D(texture.handle, 1, gl.DEPTH_COMPONENT24, i32(w), i32(h))
		} else if a == .Stencil {
			assert(false)
		}

		return texture
	}
	framebuffer := Framebuffer {
		width        = l.width,
		height       = l.height,
		clear_colors = l.clear_colors,
		attachments  = l.attachments,
	}
	gl.CreateFramebuffers(1, &framebuffer.handle)

	draw_buffers: [int(Framebuffer_Attachment.Color3) + 1]u32
	for i in Framebuffer_Attachment.Color0 ..= Framebuffer_Attachment.Color3 {
		a := Framebuffer_Attachment(i)
		if a in l.attachments {
			filter := l.filter[a] == nil ? Texture_Filter_Mode.Nearest : l.filter[a]
			precision := l.precision[a]
			framebuffer.maps[a] = create_framebuffer_texture(
				a,
				l.width,
				l.height,
				filter,
				precision if precision > 0 else 8,
			)
			gl.NamedFramebufferTexture(
				framebuffer.handle,
				u32(gl.COLOR_ATTACHMENT0 + framebuffer.color_target_count),
				framebuffer.maps[a].handle,
				0,
			)
			draw_buffers[framebuffer.color_target_count] = u32(
				gl.COLOR_ATTACHMENT0 + framebuffer.color_target_count,
			)
			framebuffer.color_target_count += 1
		}
	}

	if framebuffer.color_target_count == 0 {
		gl.NamedFramebufferDrawBuffer(framebuffer.handle, gl.NONE)
		gl.NamedFramebufferReadBuffer(framebuffer.handle, gl.NONE)
	} else {
		gl.NamedFramebufferDrawBuffers(
			framebuffer.handle,
			i32(framebuffer.color_target_count),
			&draw_buffers[0],
		)
	}
	if .Depth in l.attachments {
		framebuffer.maps[Framebuffer_Attachment.Depth] = create_framebuffer_texture(
			.Depth,
			l.width,
			l.height,
		)
		gl.NamedFramebufferTexture(
			framebuffer.handle,
			gl.DEPTH_ATTACHMENT,
			framebuffer.maps[Framebuffer_Attachment.Depth].handle,
			0,
		)
	}

	status := gl.CheckNamedFramebufferStatus(framebuffer.handle, gl.FRAMEBUFFER)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.errorf("%s: Framebuffer creation error: %d", App_Module.GPU_Memory, status)
	}
	return framebuffer
}

clear_framebuffer :: proc(f: ^Framebuffer) {
	for i in 0 ..< f.color_target_count {
		a := Framebuffer_Attachment(i)
		if a in f.attachments {
			rgba := f.clear_colors[a].rgba
			gl.ClearNamedFramebufferfv(f.handle, gl.COLOR, i32(a), &rgba[0])
		}
	}
	if .Depth in f.attachments {
		d: f32 = 1
		gl.ClearNamedFramebufferfv(f.handle, gl.DEPTH, 0, &d)
	}
}

clear_framebuffer_region :: proc(f: ^Framebuffer, r: Rectangle) {
	clip_mode_on()
	defer clip_mode_off()
	gl.Scissor(i32(r.x), i32(r.y), i32(r.width), i32(r.height))
	clear_framebuffer(f)
}

bind_framebuffer :: proc(f: ^Framebuffer) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, f.handle)
}

default_framebuffer :: proc() {
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

framebuffer_texture :: proc(f: ^Framebuffer, a: Framebuffer_Attachment) -> ^Texture {
	return &f.maps[a]
}

destroy_framebuffer :: proc(f: ^Framebuffer) {
	gl.DeleteFramebuffers(1, &f.handle)
}

blit_framebuffer :: proc(src, dst: ^Framebuffer, v_mem, i_mem: ^Buffer_Memory) {
	ctx := &app.render_ctx
	if dst == nil {
		default_framebuffer()
	} else {
		bind_framebuffer(dst)
	}

	depth(false)
			//odinfmt: disable
			framebuffer_vertices := [?]f32{
				-1.0,  1.0, 0.0, 1.0,
				1.0,  1.0, 1.0, 1.0,
				-1.0, -1.0, 0.0, 0.0,
				1.0, -1.0, 1.0, 0.0,
			}
			framebuffer_indices := [?]u32{
				2, 1, 0,
				2, 3, 1,
			}
			//odinfmt: enable


	texture_index: u32 = 0

	// Set the shader up
	bind_shader(ctx.framebuffer_blit_shader)
	set_shader_uniform(ctx.framebuffer_blit_shader, "texture0", &texture_index)
	bind_texture(framebuffer_texture(src, .Color0), texture_index)
	send_buffer_data(
		v_mem,
		Buffer_Source{
			data = &framebuffer_vertices[0],
			byte_size = len(framebuffer_vertices) * size_of(f32),
			accessor = Buffer_Data_Type{kind = .Float_32, format = .Scalar},
		},
	)
	send_buffer_data(
		i_mem,
		Buffer_Source{
			data = &framebuffer_indices[0],
			byte_size = len(framebuffer_vertices) * size_of(u32),
		},
	)

	// prepare attributes
	bind_attributes(ctx.framebuffer_blit_attributes)
	defer {
		depth(true)
		default_attributes()
		default_shader()
		unbind_texture(framebuffer_texture(src, .Color0))
	}

	link_interleaved_attributes_vertices(ctx.framebuffer_blit_attributes, v_mem.buf)
	link_attributes_indices(ctx.framebuffer_blit_attributes, i_mem.buf)

	draw_triangles(len(framebuffer_indices))
}

blit_framebuffer_depth :: proc(src: ^Framebuffer, dst: ^Framebuffer = nil, sr, dr: Rectangle) {
	dst_width := app.render_ctx.render_width if dst == nil else int(dr.width)
	dst_height := app.render_ctx.render_height if dst == nil else int(dr.height)
	gl.BlitNamedFramebuffer(
		readFramebuffer = src.handle,
		drawFramebuffer = 0 if dst == nil else dst.handle,
		srcX0 = i32(sr.x),
		srcY0 = i32(sr.y),
		srcX1 = i32(sr.width),
		srcY1 = i32(sr.height),
		dstX0 = i32(dr.x),
		dstY0 = i32(dr.y),
		dstX1 = i32(dst_width),
		dstY1 = i32(dst_height),
		mask = gl.DEPTH_BUFFER_BIT,
		filter = gl.NEAREST,
	)
}

framebuffer_bounding_rect :: proc(f: ^Framebuffer) -> Rectangle {
	return Rectangle{x = 0, y = 0, width = f32(f.width), height = f32(f.height)}
}

@(private)
BLIT_FRAMEBUFFER_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec2 attribPosition;
layout (location = 5) in vec2 attribTexCoord;

out VS_OUT {
	vec2 texCoord;
} frag;

void main() {
	frag.texCoord = attribTexCoord;

	gl_Position = vec4(attribPosition, 0.0, 1.0);
}
`

@(private)
BLIT_FRAMEBUFFER_FRAGMENT_SHADER :: `
#version 450 core
in VS_OUT {
	vec2 texCoord;
} frag;

out vec4 fragColor;

uniform sampler2D texture0;

void main() {
	fragColor = texture(texture0, frag.texCoord);
}
`
