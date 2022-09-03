package iris

import "core:log"
import gl "vendor:OpenGL"

Framebuffer :: struct {
	handle:      u32,
	attachments: Framebuffer_Attachments,
	clear_color: Color,
	maps:        [len(Framebuffer_Attachment)]Texture,
}

Framebuffer_Attachments :: distinct bit_set[Framebuffer_Attachment]

Framebuffer_Attachment :: enum {
	Color,
	Depth,
	Stencil,
}

make_framebuffer :: proc(attach: Framebuffer_Attachments, w, h: int) -> Framebuffer {
	create_framebuffer_texture :: proc(a: Framebuffer_Attachment, w, h: int) -> Texture {
		texture: Texture
		gl.CreateTextures(gl.TEXTURE_2D, 1, &texture.handle)
		switch a {
		case .Color:
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
			gl.TextureStorage2D(texture.handle, 1, gl.RGBA8, i32(w), i32(h))
		case .Depth:
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
			gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_BORDER)
			gl.TextureParameteri(texture.handle, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_BORDER)
			clr := Color{1, 1, 1, 1}
			gl.TextureParameterfv(texture.handle, gl.TEXTURE_BORDER_COLOR, &clr[0])
			gl.TextureStorage2D(texture.handle, 1, gl.DEPTH_COMPONENT24, i32(w), i32(h))
		case .Stencil:
			assert(false)
		}

		return texture
	}
	framebuffer := Framebuffer {
		attachments = attach,
	}
	gl.CreateFramebuffers(1, &framebuffer.handle)

	if .Color in attach {
		framebuffer.maps[Framebuffer_Attachment.Color] = create_framebuffer_texture(.Color, w, h)
		gl.NamedFramebufferTexture(
			framebuffer.handle,
			gl.COLOR_ATTACHMENT0,
			framebuffer.maps[Framebuffer_Attachment.Color].handle,
			0,
		)
	} else {
		gl.NamedFramebufferDrawBuffer(framebuffer.handle, gl.NONE)
		gl.NamedFramebufferReadBuffer(framebuffer.handle, gl.NONE)
	}
	if .Depth in attach {
		framebuffer.maps[Framebuffer_Attachment.Depth] = create_framebuffer_texture(.Depth, w, h)
		gl.NamedFramebufferTexture(
			framebuffer.handle,
			gl.DEPTH_ATTACHMENT,
			framebuffer.maps[Framebuffer_Attachment.Depth].handle,
			0,
		)
	}

	status := gl.CheckNamedFramebufferStatus(framebuffer.handle, gl.FRAMEBUFFER)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.errorf("%s: Framebuffer creation error: %d", App_Module.Buffer, status)
	}
	return framebuffer
}

clear_framebuffer :: proc(f: Framebuffer) {
	if .Color in f.attachments {
		rgb := Vector3{f.clear_color.r, f.clear_color.g, f.clear_color.b}
		gl.ClearNamedFramebufferfv(f.handle, gl.COLOR, 0, &rgb[0])
	}
	if .Depth in f.attachments {
		d: f32 = 1
		gl.ClearNamedFramebufferfv(f.handle, gl.DEPTH, 0, &d)
	}
}

bind_framebuffer :: proc(f: Framebuffer) {
	gl.BindFramebuffer(gl.FRAMEBUFFER, f.handle)
}

default_framebuffer :: proc() {
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

blit_framebuffer :: proc(src: Framebuffer, dst: Maybe(Framebuffer)) {
	src_w := i32(src.maps[Framebuffer_Attachment.Color].width)
	src_h := i32(src.maps[Framebuffer_Attachment.Color].height)
	if dst != nil {
		d := dst.?
		gl.BlitNamedFramebuffer(
			src.handle,
			d.handle,
			0,
			0,
			src_w,
			src_h,
			0,
			0,
			i32(d.maps[Framebuffer_Attachment.Color].width),
			i32(d.maps[Framebuffer_Attachment.Color].height),
			gl.COLOR_BUFFER_BIT,
			gl.NEAREST,
		)
	} else {
		gl.BlitNamedFramebuffer(
			src.handle,
			0,
			0,
			0,
			src_w,
			src_h,
			0,
			0,
			i32(app.viewport_width),
			i32(app.viewport_height),
			gl.COLOR_BUFFER_BIT,
			gl.NEAREST,
		)
	}
}

destroy_framebuffer :: proc(f: Framebuffer) {
	fb := f
	gl.DeleteFramebuffers(1, &fb.handle)
}

// FRAMEBUFFER_BLIT_VERTEX_SHADER :: `
// #version 450 core
// layout (location = 0) in vec2 attribPosition;
// layout (location = 1)
// `
