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
	clear_colors: [len(Framebuffer_Attachment)]Color,
}

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
	create_framebuffer_texture :: proc(a: Framebuffer_Attachment, w, h: int) -> Texture {
		texture: Texture
		gl.CreateTextures(gl.TEXTURE_2D, 1, &texture.handle)
		if a >= .Color0 && a <= .Color3 {
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
			gl.TextureParameteri(texture.handle, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
			gl.TextureStorage2D(texture.handle, 1, gl.RGBA8, i32(w), i32(h))
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
		attachments = l.attachments,
	}
	gl.CreateFramebuffers(1, &framebuffer.handle)

	for i in Framebuffer_Attachment.Color0 ..= Framebuffer_Attachment.Color3 {
		a := Framebuffer_Attachment(i)
		if a in l.attachments {
			framebuffer.maps[a] = create_framebuffer_texture(a, l.width, l.height)
			gl.NamedFramebufferTexture(
				framebuffer.handle,
				gl.COLOR_ATTACHMENT0,
				framebuffer.maps[a].handle,
				0,
			)
			framebuffer.color_target_count += 1
		}
	}

	if framebuffer.color_target_count == 0 {
		gl.NamedFramebufferDrawBuffer(framebuffer.handle, gl.NONE)
		gl.NamedFramebufferReadBuffer(framebuffer.handle, gl.NONE)
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
			gl.ClearNamedFramebufferfv(f.handle, gl.COLOR, 0, &rgba[0])
		}
	}
	if .Depth in f.attachments {
		d: f32 = 1
		gl.ClearNamedFramebufferfv(f.handle, gl.DEPTH, 0, &d)
	}
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

@(private)
BLIT_FRAMEBUFFER_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec2 attribPosition;
layout (location = 1) in vec2 attribTexCoord;

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
