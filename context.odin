package iris

import "core:time"
import "core:fmt"
import "core:math/linalg"


RENDER_CTX_MAX_LIGHTS :: 4
RENDER_CTX_DEFAULT_FAR :: 100
RENDER_CTX_DEFAULT_NEAR :: 0.1
RENDER_CTX_DEFAULT_AMBIENT_STR :: 0.4
RENDER_CTX_DEFAULT_AMBIENT_CLR :: Color{0.45, 0.45, 0.75, 1.0}

Rendering_Context :: struct {
	render_width:                int,
	render_height:               int,
	projection:                  Matrix4,
	view:                        Matrix4,
	projection_view:             Matrix4,
	context_uniform_buffer:      ^Buffer,
	context_uniform_memory:      Buffer_Memory,

	// Camera state
	eye:                         Vector3,
	centre:                      Vector3,
	up:                          Vector3,

	// Lighting states
	light_dirty:                 bool,
	lights:                      [RENDER_CTX_MAX_LIGHTS]Light,
	light_count:                 int,
	light_ambient_clr:           Color,
	light_ambient_strength:      f32,
	light_uniform_buffer:        ^Buffer,
	light_uniform_memory:        Buffer_Memory,

	// Shadow mapping states
	depth_framebuffer:           ^Framebuffer,
	depth_shader:                ^Shader,

	// View depth framebuffer
	view_depth_framebuffer:      ^Framebuffer,
	view_depth_shader:           ^Shader,
	deferred_framebuffer:        ^Framebuffer,

	//
	framebuffer_blit_shader:     ^Shader,
	framebuffer_blit_attributes: ^Attributes,

	// Command buffer
	states:                      [dynamic]^Attributes,
	commands:                    [dynamic]Render_Command,
	previous_cmd_count:          int,
	deferred_commands:           [dynamic]Render_Command,
	previous_def_cmd_count:      int,
}

Render_Uniform_Binding :: enum u32 {
	Projection_Data = 0,
	Light_Data      = 1,
}

@(private)
Render_Context_Uniform_Data :: struct {
	projection_view: Matrix4,
	projection:      Matrix4,
	view:            Matrix4,
	view_position:   Vector3,
	time:            f32,
	dt:              f32,
}

@(private)
Render_Uniform_Light_Data :: struct {
	lights:           [RENDER_CTX_MAX_LIGHTS]Light_Data,
	light_space:      Matrix4,
	ambient_clr:      Vector3,
	ambient_strength: f32,
}


Render_Command :: union {
	Render_Mesh_Command,
	Render_Framebuffer_Command,
	Render_Custom_Command,
}

Render_Mesh_Command :: struct {
	mesh:             ^Mesh,
	local_transform:  Matrix4,
	global_transform: Matrix4,
	material:         ^Material,
	options:          Rendering_Options,
}

Render_Custom_Command :: struct {
	data:        rawptr,
	render_proc: proc(data: rawptr),
	options:     Rendering_Options,
}

Render_Framebuffer_Command :: struct {
	render_order:  uint,
	framebuffer:   ^Framebuffer,
	vertex_memory: ^Buffer_Memory,
	index_buffer:  ^Buffer,
}

Rendering_Options :: distinct bit_set[Rendering_Option]

Rendering_Option :: enum {
	Enable_Culling,
	Disable_Culling,
	Transparent,
	Cast_Shadows,
}

init_render_ctx :: proc(ctx: ^Rendering_Context, w, h: int) {
	DEFAULT_FOVY :: 45

	set_backface_culling(true)
	ctx.render_width = w
	ctx.render_height = h
	ctx.projection = linalg.matrix4_perspective_f32(
		f32(DEFAULT_FOVY),
		f32(w) / f32(h),
		f32(RENDER_CTX_DEFAULT_NEAR),
		f32(RENDER_CTX_DEFAULT_FAR),
	)
	ctx.eye = {}
	ctx.centre = {}
	ctx.up = VECTOR_UP

	depth_framebuffer_res := framebuffer_resource(
		Framebuffer_Loader{
			attachments = {.Depth},
			width = ctx.render_width,
			height = ctx.render_height,
		},
	)
	ctx.depth_framebuffer = depth_framebuffer_res.data.(^Framebuffer)
	depth_shader_res := shader_resource(
		Shader_Loader{
			name = "depth_map",
			kind = .Byte,
			stages = {
				Shader_Stage.Vertex = Shader_Stage_Loader{source = LIGHT_DEPTH_VERTEX_SHADER},
				Shader_Stage.Fragment = Shader_Stage_Loader{source = EMPTY_FRAGMENT_SHADER},
			},
		},
	)
	ctx.depth_shader = depth_shader_res.data.(^Shader)

	view_depth_framebuffer_res := framebuffer_resource(
		Framebuffer_Loader{
			attachments = {.Depth},
			width = ctx.render_width,
			height = ctx.render_height,
		},
	)
	ctx.view_depth_framebuffer = view_depth_framebuffer_res.data.(^Framebuffer)
	view_depth_shader_res := shader_resource(
		Shader_Loader{
			name = "view_depth_map",
			kind = .Byte,
			stages = {
				Shader_Stage.Vertex = Shader_Stage_Loader{source = VIEW_DEPTH_VERTEX_SHADER},
				Shader_Stage.Fragment = Shader_Stage_Loader{source = EMPTY_FRAGMENT_SHADER},
			},
		},
	)
	ctx.view_depth_shader = view_depth_shader_res.data.(^Shader)

	deferred_framebuffer_res := framebuffer_resource(
		Framebuffer_Loader{
			attachments = {.Color0, .Color1, .Color2, .Depth},
			width = ctx.render_width,
			height = ctx.render_height,
		},
	)
	ctx.deferred_framebuffer = deferred_framebuffer_res.data.(^Framebuffer)

	context_buffer_res := raw_buffer_resource(size_of(Render_Context_Uniform_Data))
	ctx.context_uniform_buffer = context_buffer_res.data.(^Buffer)
	ctx.context_uniform_memory = Buffer_Memory {
		buf    = ctx.context_uniform_buffer,
		size   = size_of(Render_Context_Uniform_Data),
		offset = 0,
	}
	set_uniform_buffer_binding(
		ctx.context_uniform_buffer,
		u32(Render_Uniform_Binding.Projection_Data),
	)

	ctx.light_ambient_strength = RENDER_CTX_DEFAULT_AMBIENT_STR
	ctx.light_ambient_clr = RENDER_CTX_DEFAULT_AMBIENT_CLR
	light_buffer_res := raw_buffer_resource(size_of(Render_Uniform_Light_Data))
	ctx.light_uniform_buffer = light_buffer_res.data.(^Buffer)
	ctx.light_uniform_memory = Buffer_Memory {
		buf    = ctx.light_uniform_buffer,
		size   = size_of(Render_Uniform_Light_Data),
		offset = 0,
	}
	set_uniform_buffer_binding(ctx.light_uniform_buffer, u32(Render_Uniform_Binding.Light_Data))

	// Framebuffer blitting states
	blit_shader_res := shader_resource(
		Shader_Loader{
			name = "blit_framebuffer",
			kind = .Byte,
			stages = {
				Shader_Stage.Vertex = Shader_Stage_Loader{source = BLIT_FRAMEBUFFER_VERTEX_SHADER},
				Shader_Stage.Fragment = Shader_Stage_Loader{
					source = BLIT_FRAMEBUFFER_FRAGMENT_SHADER,
				},
			},
		},
	)
	ctx.framebuffer_blit_shader = blit_shader_res.data.(^Shader)
	ctx.framebuffer_blit_attributes = attributes_from_layout(
		{
			enabled = {.Position, .Tex_Coord},
			accessors = {
				Attribute_Kind.Position = Buffer_Data_Type{kind = .Float_32, format = .Vector2},
				Attribute_Kind.Tex_Coord = Buffer_Data_Type{kind = .Float_32, format = .Vector2},
			},
		},
		.Interleaved,
	)
}

close_render_ctx :: proc(ctx: ^Rendering_Context) {
}

view_position :: proc(position: Vector3) {
	app.render_ctx.eye = position
}

view_target :: proc(target: Vector3) {
	app.render_ctx.centre = target
}

add_light :: proc(kind: Light_Kind, p: Vector3, clr: Color) -> (id: Light_ID) {
	ctx := &app.render_ctx
	assert(ctx.light_count < 1)
	// h_res := f32(ctx.render_width) / 2
	// v_res := f32(ctx.render_height) / 2
	id = Light_ID(ctx.light_count)
	ctx.lights[id] = Light {
		kind = kind,
		projection = linalg.matrix_ortho3d_f32(
			-17.5,
			17.5,
			-10,
			10,
			f32(RENDER_CTX_DEFAULT_NEAR),
			f32(20),
		),
		data = Light_Data{position = {p.x, p.y, p.z, 1.0}, color = clr},
	}
	ctx.light_count += 1
	ctx.light_dirty = true
	return
}

light_position :: proc(id: Light_ID, position: Vector3) {
	ctx := &app.render_ctx
	ctx.lights[id].data.position = {position.x, position.y, position.z, 1.0}
	ctx.light_dirty = true
}

light_ambient :: proc(strength: f32, color: Color) {
	app.render_ctx.light_ambient_strength = strength
	app.render_ctx.light_ambient_clr = color
	app.render_ctx.light_dirty = true
}

start_render :: proc() {
	ctx := &app.render_ctx
	ctx.commands = make([dynamic]Render_Command, 0, ctx.previous_cmd_count, context.temp_allocator)
	ctx.deferred_commands = make(
		[dynamic]Render_Command,
		0,
		ctx.previous_def_cmd_count,
		context.temp_allocator,
	)
}

end_render :: proc() {
	ctx := &app.render_ctx

	// Update light values
	if ctx.light_dirty {
		for _, i in ctx.lights[:ctx.light_count] {
			compute_light_projection(&ctx.lights[i], ctx.centre)
		}

		send_buffer_data(
			&ctx.light_uniform_memory,
			Buffer_Source{
				data = &Render_Uniform_Light_Data{
					lights = [RENDER_CTX_MAX_LIGHTS]Light_Data{
						ctx.lights[0].data,
						ctx.lights[1].data,
						ctx.lights[2].data,
						ctx.lights[3].data,
					},
					light_space = ctx.lights[0].projection_view,
					ambient_clr = ctx.light_ambient_clr.rgb,
					ambient_strength = ctx.light_ambient_strength,
				},
				byte_size = size_of(Render_Uniform_Light_Data),
				accessor = Buffer_Data_Type{kind = .Byte, format = .Unspecified},
			},
		)
		ctx.light_dirty = false
	}

	set_viewport(ctx.render_width, ctx.render_height)
	compute_projection(ctx)

	// Compute the scene's depth map
	set_backface_culling(true)
	bind_framebuffer(ctx.depth_framebuffer)
	clear_framebuffer(ctx.depth_framebuffer)
	bind_shader(ctx.depth_shader)
	set_shader_uniform(ctx.depth_shader, "matLightSpace", &ctx.lights[0].projection_view[0][0])
	for command in &ctx.commands {
		#partial switch c in &command {
		case Render_Mesh_Command:
			if .Transparent in c.options {
				continue
			}
			set_shader_uniform(ctx.depth_shader, "matModel", &c.global_transform[0][0])

			bind_attributes(c.mesh.attributes)
			defer default_attributes()
			link_packed_attributes_vertices(
				c.mesh.attributes,
				c.mesh.vertices.buf,
				c.mesh.attributes_info,
			)
			link_attributes_indices(c.mesh.attributes, c.mesh.indices.buf)
			draw_triangles(c.mesh.index_count)
		}
	}
	default_shader()
	default_framebuffer()

	bind_framebuffer(ctx.view_depth_framebuffer)
	clear_framebuffer(ctx.view_depth_framebuffer)
	bind_shader(ctx.view_depth_shader)
	for command in &ctx.commands {
		#partial switch c in &command {
		case Render_Mesh_Command:
			if .Transparent in c.options {
				continue
			}
			set_shader_uniform(ctx.view_depth_shader, "matModel", &c.global_transform[0][0])

			bind_attributes(c.mesh.attributes)
			defer default_attributes()
			link_packed_attributes_vertices(
				c.mesh.attributes,
				c.mesh.vertices.buf,
				c.mesh.attributes_info,
			)
			link_attributes_indices(c.mesh.attributes, c.mesh.indices.buf)
			draw_triangles(c.mesh.index_count)
		}
	}
	default_shader()
	default_framebuffer()

	current_shader: u32 = 0
	for command in &ctx.commands {
		switch c in &command {
		case Render_Mesh_Command:
			if c.material.shader.handle != current_shader {
				bind_shader(c.material.shader)
				current_shader = c.material.shader.handle
			}
			if c.material.double_face {
				set_backface_culling(false)
				depth_mode(.Less_Equal)
			}
			model_mat := c.global_transform
			mvp := linalg.matrix_mul(ctx.projection_view, model_mat)
			if _, exist := c.material.shader.uniforms["mvp"]; exist {
				set_shader_uniform(c.material.shader, "mvp", &mvp[0][0])
			}
			if _, exist := c.material.shader.uniforms["matModel"]; exist {
				set_shader_uniform(c.material.shader, "matModel", &model_mat[0][0])
			}
			if _, exist := c.material.shader.uniforms["matModelLocal"]; exist {
				set_shader_uniform(c.material.shader, "matModelLocal", &c.local_transform[0][0])
			}
			if _, exist := c.material.shader.uniforms["matNormal"]; exist {
				inverse_transpose_mat := linalg.matrix4_inverse_transpose_f32(model_mat)
				normal_mat := linalg.matrix3_from_matrix4_f32(inverse_transpose_mat)
				set_shader_uniform(c.material.shader, "matNormal", &normal_mat[0][0])
			}
			if _, exist := c.material.shader.uniforms["matNormalLocal"]; exist {
				inverse_transpose_mat := linalg.matrix4_inverse_transpose_f32(c.local_transform)
				normal_mat := linalg.matrix3_from_matrix4_f32(inverse_transpose_mat)
				set_shader_uniform(c.material.shader, "matNormalLocal", &normal_mat[0][0])
			}

			unit_index: u32
			for kind in Material_Map {
				if kind in c.material.maps {
					texture := c.material.textures[kind]
					texture_uniform_name: string
					switch texture.kind {
					case .Texture:
						texture_uniform_name = fmt.tprintf("texture%d", u32(kind))
					case .Cubemap:
						texture_uniform_name = fmt.tprintf("cubemap%d", u32(kind))
					}
					bind_texture(c.material.textures[kind], unit_index)
					if _, exist := c.material.shader.uniforms[texture_uniform_name]; exist {
						set_shader_uniform(c.material.shader, texture_uniform_name, &unit_index)
					}
					unit_index += 1
				}
			}
			if _, exist := c.material.shader.uniforms["mapShadow"]; exist {
				bind_texture(&ctx.depth_framebuffer.maps[Framebuffer_Attachment.Depth], unit_index)
				set_shader_uniform(c.material.shader, "mapShadow", &unit_index)
			}
			unit_index += 1

			if _, exist := c.material.shader.uniforms["mapViewDepth"]; exist {
				bind_texture(
					&ctx.view_depth_framebuffer.maps[Framebuffer_Attachment.Depth],
					unit_index,
				)
				set_shader_uniform(c.material.shader, "mapViewDepth", &unit_index)
			}

			bind_attributes(c.mesh.attributes)
			defer default_attributes()
			link_packed_attributes_vertices(
				c.mesh.attributes,
				c.mesh.vertices.buf,
				c.mesh.attributes_info,
			)
			link_attributes_indices(c.mesh.attributes, c.mesh.indices.buf)
			draw_triangles(c.mesh.index_count)

			for kind in Material_Map {
				if kind in c.material.maps {
					unbind_texture(c.material.textures[kind])
				}
			}
			if _, exist := c.material.shader.uniforms["mapShadow"]; exist {
				unbind_texture(&ctx.depth_framebuffer.maps[Framebuffer_Attachment.Depth])
			}

			if c.material.double_face {
				set_backface_culling(true)
				depth_mode(.Less)
			}

		case Render_Framebuffer_Command:

		case Render_Custom_Command:
			if .Disable_Culling in c.options {
				set_backface_culling(false)
				c.render_proc(c.data)
				set_backface_culling(true)
			} else {
				c.render_proc(c.data)
			}
		}
	}
	ctx.previous_cmd_count = len(ctx.commands)

	for command in ctx.deferred_commands {
		#partial switch c in command {
		case Render_Framebuffer_Command:
			depth(false)
			defer depth(true)
			set_backface_culling(false)
					//odinfmt: disable
			framebuffer_vertices := [?]f32{
				-1.0, -1.0, 0.0, 0.0,
				1.0, -1.0, 1.0, 0.0,
				1.0,  1.0, 1.0, 1.0,
				-1.0,  1.0, 0.0, 1.0,
			}
			framebuffer_indices := [?]u32{
				1, 0, 2,
				2, 0, 3,
			}
			//odinfmt: enable


			texture_index: u32 = 0

			// Set the shader up
			bind_shader(ctx.framebuffer_blit_shader)
			set_shader_uniform(ctx.framebuffer_blit_shader, "texture0", &texture_index)
			bind_texture(framebuffer_texture(c.framebuffer, .Color0), texture_index)
			send_buffer_data(
				c.vertex_memory,
				Buffer_Source{
					data = &framebuffer_vertices[0],
					byte_size = len(framebuffer_vertices) * size_of(f32),
					accessor = Buffer_Data_Type{kind = .Float_32, format = .Scalar},
				},
			)
			send_buffer_data(
				&Buffer_Memory{
					buf = c.index_buffer,
					size = len(framebuffer_vertices) * size_of(u32),
					offset = 0,
				},
				Buffer_Source{
					data = &framebuffer_indices[0],
					byte_size = len(framebuffer_vertices) * size_of(u32),
				},
			)

			// prepare attributes
			bind_attributes(ctx.framebuffer_blit_attributes)
			defer {
				default_attributes()
				default_shader()
				unbind_texture(framebuffer_texture(c.framebuffer, .Color0))
			}

			link_interleaved_attributes_vertices(
				ctx.framebuffer_blit_attributes,
				c.vertex_memory.buf,
			)
			link_attributes_indices(ctx.framebuffer_blit_attributes, c.index_buffer)

			draw_triangles(len(framebuffer_indices))
			set_backface_culling(true)
		case:
			assert(false)
		}
	}

	// set_backface_culling(false)
	// flush_overlay_buffers(&ctx.overlay)
	// paint_overlay(&ctx.overlay)
	// set_backface_culling(true)
}

@(private)
compute_projection :: proc(ctx: ^Rendering_Context) {
	ctx.view = linalg.matrix4_look_at_f32(ctx.eye, ctx.centre, ctx.up)
	ctx.projection_view = linalg.matrix_mul(ctx.projection, ctx.view)
	send_buffer_data(
		&ctx.context_uniform_memory,
		Buffer_Source{
			data = &Render_Context_Uniform_Data{
				projection_view = ctx.projection_view,
				projection = ctx.projection,
				view = ctx.view,
				view_position = ctx.eye,
				time = f32(time.duration_seconds(time.since(app.start_time))),
				dt = f32(elapsed_time()),
			},
			byte_size = size_of(Render_Context_Uniform_Data),
			accessor = Buffer_Data_Type{kind = .Byte, format = .Unspecified},
		},
	)
}

@(private)
push_draw_command :: proc(cmd: Render_Command) {
	switch c in cmd {
	case Render_Mesh_Command, Render_Custom_Command:
		append(&app.render_ctx.commands, cmd)
	case Render_Framebuffer_Command:
		append(&app.render_ctx.deferred_commands, cmd)
	}
}

@(private)
LIGHT_DEPTH_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec3 attribPosition;

uniform mat4 matLightSpace;
uniform mat4 matModel;

void main() {
	gl_Position = matLightSpace * matModel * vec4(attribPosition, 1.0);
}
`

@(private)
EMPTY_FRAGMENT_SHADER :: `
#version 450 core

void main() {

}
`

@(private)
VIEW_DEPTH_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec3 attribPosition;

layout (std140, binding = 0) uniform ContextData {
	mat4 projView;
    mat4 matProj;
    mat4 matView;
	vec3 viewPosition;
};

uniform mat4 matModel;

void main() {
	gl_Position = projView * matModel * vec4(attribPosition, 1.0);
}
`

// @(private)
// ORTHO_VERTEX_SHADER :: `
// #version 450 core
// layout (location = 0) in vec2 attribPosition;
// layout (location = 1) in vec2 attribTexCoord;
// layout (location = 2) in float attribTexIndex;
// layout (location = 3) in vec4 attribColor;

// out VS_OUT {
// 	vec2 texCoord;
// 	float texIndex;
// 	vec4 color;
// } frag;

// uniform mat4 matProj;

// void main() {
// 	frag.texCoord = attribTexCoord;
// 	frag.texIndex = attribTexIndex;
// 	frag.color = attribColor;
// 	gl_Position = matProj * vec4(attribPosition, 0.0, 1.0);
// }
// `

// @(private)
// ORTHO_FRAGMENT_SHADER :: `
// #version 450 core
// in VS_OUT {
// 	vec2 texCoord;
// 	float texIndex;
// 	vec4 color;
// } frag;

// out vec4 fragColor;

// uniform sampler2D textures[16];

// void main() {
// 	int index = int(frag.texIndex);
// 	fragColor = texture(textures[index], frag.texCoord) * frag.color;
// 	// fragColor = vec4(1.0, 0.0, 0.0, 1.0);
// }
// `
