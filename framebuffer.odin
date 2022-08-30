package iris

import "core:log"
import gl "vendor:OpenGL"

Framebuffer :: struct {
	handle: u32,
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
		gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, gl.LINEAR)

		gl.TextureStorage2D(texture.handle, 1, gl.RGB, i32(w), i32(h))
		return texture
	}
	framebuffer := Framebuffer{}
	gl.CreateFramebuffers(1, &framebuffer.handle)

	if .Color in attach {
		color_texture := create_framebuffer_texture(.Color, w, h)
		gl.NamedFramebufferTexture(
			framebuffer.handle,
			gl.COLOR_ATTACHMENT0,
			color_texture.handle,
			0,
		)
	}
	if .Depth in attach {

	}

	status := gl.CheckNamedFramebufferStatus(framebuffer.handle, gl.FRAMEBUFFER)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.errorf("%s: Framebuffer creation error: %s", App_Module.Buffer, status)
	}
	return framebuffer
}

destroy_framebuffer :: proc(f: Framebuffer) {
	fb := f
	gl.DeleteFramebuffers(1, &fb.handle)
}
