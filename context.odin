package iris

import "core:fmt"
import "core:math/linalg"
import "core:strings"

import "gltf"

RENDER_CTX_MAX_LIGHTS :: 4
RENDER_CTX_DEFAULT_FAR :: 100
RENDER_CTX_DEFAULT_NEAR :: 1
RENDER_CTX_DEFAULT_AMBIENT_STR :: 0.4
RENDER_CTX_DEFAULT_AMBIENT_CLR :: Color{0.45, 0.45, 0.75, 1.0}

Rendering_Context :: struct {
	render_width:              int,
	render_height:             int,
	projection:                Matrix4,
	view:                      Matrix4,
	projection_view:           Matrix4,
	projection_uniform_buffer: Buffer,

	// Camera state
	eye:                       Vector3,
	centre:                    Vector3,
	up:                        Vector3,

	// Lighting states
	light_dirty:               bool,
	lights:                    [RENDER_CTX_MAX_LIGHTS]Light,
	light_count:               int,
	light_ambient_clr:         Color,
	light_ambient_strength:    f32,
	light_uniform_buffer:      Buffer,

	// Shadow mapping states
	depth_framebuffer:         Framebuffer,

	// Command buffer
	states:                    [dynamic]Attributes_State,
	commands:                  [dynamic]Render_Command,
	previous_cmd_count:        int,

	// Resource management
	textures:                  map[string]Texture,
	materials:                 map[string]Material,
	shaders:                   map[string]Shader,
}

Render_Uniform_Binding :: enum u32 {
	Projection_Data = 0,
	Light_Data      = 1,
}

@(private)
Render_Uniform_Projection_Data :: struct {
	projection_view: Matrix4,
	view_position:   Vector3,
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
}

Render_Mesh_Command :: struct {
	mesh:         Mesh,
	transform:    Matrix4,
	material:     Material,
	cast_shadows: bool,
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

	ctx.depth_framebuffer = make_framebuffer({.Depth}, ctx.render_width, ctx.render_height)
	load_shader_from_bytes(LIGHT_DEPTH_VERTEX_SHADER, LIGHT_DEPTH_FRAGMENT_SHADER, "lightDepth")

	ctx.projection_uniform_buffer = make_raw_buffer(size_of(Render_Uniform_Projection_Data), true)
	set_uniform_buffer_binding(ctx.projection_uniform_buffer, u32(Render_Uniform_Binding.Projection_Data))

	ctx.light_ambient_strength = RENDER_CTX_DEFAULT_AMBIENT_STR
	ctx.light_ambient_clr = RENDER_CTX_DEFAULT_AMBIENT_CLR
	ctx.light_uniform_buffer = make_raw_buffer(size_of(Render_Uniform_Light_Data), true)
	set_uniform_buffer_binding(ctx.light_uniform_buffer, u32(Render_Uniform_Binding.Light_Data))
}

close_render_ctx :: proc(ctx: ^Rendering_Context) {
	for _, i in ctx.states {
		destroy_attributes_state(&ctx.states[i])
	}
	for name in ctx.textures {
		destroy_texture(&ctx.textures[name])
	}
	for name in ctx.shaders {
		destroy_shader(&ctx.shaders[name])
	}
	destroy_buffer(ctx.projection_uniform_buffer)
	destroy_buffer(ctx.light_uniform_buffer)
	destroy_framebuffer(ctx.depth_framebuffer)
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
		projection = linalg.matrix_ortho3d_f32(-10, 10, -10, 10, f32(RENDER_CTX_DEFAULT_NEAR), f32(10)),
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
}

end_render :: proc() {
	ctx := &app.render_ctx

	// Update light values
	if ctx.light_dirty {
		for _, i in ctx.lights[:ctx.light_count] {
			compute_light_projection(&ctx.lights[i], ctx.centre)
		}

		send_raw_buffer_data(
			ctx.light_uniform_buffer,
			size_of(Render_Uniform_Light_Data),
			&Render_Uniform_Light_Data{
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
		)
		ctx.light_dirty = false
	}

	// Compute the scene's depth map
	// set_frontface_culling(true)
	bind_framebuffer(ctx.depth_framebuffer)
	clear_framebuffer(ctx.depth_framebuffer)
	depth_shader := ctx.shaders["lightDepth"]
	bind_shader(depth_shader)
	set_shader_uniform(depth_shader, "matLightSpace", &ctx.lights[0].projection_view[0][0])
	for command in &ctx.commands {
		switch c in &command {
		case Render_Mesh_Command:
			set_shader_uniform(depth_shader, "matModel", &c.transform[0][0])

			bind_attributes_state(c.mesh.state)
			defer unbind_attributes_state()
			link_attributes_state_vertices(&c.mesh.state, c.mesh.vertices, c.mesh.layout_map)
			link_attributes_state_indices(&c.mesh.state, c.mesh.indices)
			draw_triangles(c.mesh.indices.cap)
		}
	}
	unbind_shader()
	default_framebuffer()
	// set_backface_culling(true)

	compute_projection(ctx)
	set_viewport(ctx.render_width, ctx.render_height)
	current_shader: u32 = 0
	for command in &ctx.commands {
		switch c in &command {
		case Render_Mesh_Command:
			if c.material.shader.handle != current_shader {
				bind_shader(c.material.shader)
				current_shader = c.material.shader.handle
			}
			model_mat := c.transform
			mvp := linalg.matrix_mul(ctx.projection_view, model_mat)
			set_shader_uniform(c.material.shader, "mvp", &mvp[0][0])
			if _, exist := c.material.shader.uniforms["matModel"]; exist {
				set_shader_uniform(c.material.shader, "matModel", &model_mat[0][0])
			}
			if _, exist := c.material.shader.uniforms["matNormal"]; exist {
				inverse_transpose_mat := linalg.matrix4_inverse_transpose_f32(model_mat)
				normal_mat := linalg.matrix3_from_matrix4_f32(inverse_transpose_mat)
				set_shader_uniform(c.material.shader, "matNormal", &normal_mat[0][0])
			}

			unit_index: u32
			for kind in Material_Map {
				if kind in c.material.maps {
					texture_uniform_name := fmt.tprintf("texture%d", u32(kind))
					bind_texture(&c.material.textures[kind], unit_index)
					set_shader_uniform(c.material.shader, texture_uniform_name, &unit_index)
					unit_index += 1
				}
			}
			if _, exist := c.material.shader.uniforms["mapShadow"]; exist {
				bind_texture(&ctx.depth_framebuffer.maps[Framebuffer_Attachment.Depth], unit_index)
				set_shader_uniform(c.material.shader, "mapShadow", &unit_index)
			}

			bind_attributes_state(c.mesh.state)
			defer unbind_attributes_state()
			link_attributes_state_vertices(&c.mesh.state, c.mesh.vertices, c.mesh.layout_map)
			link_attributes_state_indices(&c.mesh.state, c.mesh.indices)
			draw_triangles(c.mesh.indices.cap)

			for kind in Material_Map {
				if kind in c.material.maps {
					unbind_texture(&c.material.textures[kind])
				}
			}
			if _, exist := c.material.shader.uniforms["mapShadow"]; exist {
				unbind_texture(&ctx.depth_framebuffer.maps[Framebuffer_Attachment.Depth])
			}
		}
	}
	ctx.previous_cmd_count = len(ctx.commands)
}

@(private)
compute_projection :: proc(ctx: ^Rendering_Context) {
	ctx.view = linalg.matrix4_look_at_f32(ctx.eye, ctx.centre, ctx.up)
	ctx.projection_view = linalg.matrix_mul(ctx.projection, ctx.view)
	send_raw_buffer_data(
		ctx.projection_uniform_buffer,
		size_of(Render_Uniform_Projection_Data),
		&Render_Uniform_Projection_Data{projection_view = ctx.projection_view, view_position = ctx.eye},
	)
}

@(private)
get_ctx_attribute_state :: proc(layout: Vertex_Layout) -> Attributes_State {
	ctx := &app.render_ctx
	for state in ctx.states {
		equal := vertex_layout_equal(layout, state.layout)
		if equal {
			return state
		}
	}
	state := make_attributes_state(layout)
	append(&ctx.states, state)
	return state
}


@(private)
push_draw_command :: proc(cmd: Render_Command) {
	append(&app.render_ctx.commands, cmd)
}

load_shader_from_bytes :: proc(vertex_src, fragment_src: string, name := "") -> Shader {
	ctx := &app.render_ctx
	shader := internal_load_shader_from_bytes(
		vertex_src = vertex_src,
		fragment_src = fragment_src,
		allocator = app.ctx.allocator,
	)
	shader_name: string
	if name == "" {
		shader_name = fmt.tprintf("raw_shader_%d", len(ctx.shaders))
	} else {
		shader_name = name
	}
	ctx.shaders[shader_name] = shader
	return shader
}


load_materials_from_gltf :: proc(document: ^gltf.Document) {
	ctx := &app.render_ctx
	for material in document.materials {
		if _, exist := ctx.materials[material.name]; !exist {
			name := strings.clone(material.name, app.ctx.allocator)
			m: Material
			if material.base_color_texture.present {
				path := material.base_color_texture.texture.source.reference.(string)
				if texture, has_texture := ctx.textures[path]; has_texture {
					set_material_map(&m, .Diffuse, texture)
				} else {
					assert(false)
				}
			}
			if material.normal_texture.present {
				path := material.normal_texture.texture.source.reference.(string)
				if texture, has_texture := ctx.textures[path]; has_texture {
					set_material_map(&m, .Normal, texture)
				}
			}
			fmt.println(m)
			ctx.materials[name] = m
		}
	}
}

load_textures_from_gltf :: proc(document: ^gltf.Document) {
	ctx := &app.render_ctx
	for texture in document.textures {
		if _, ok := texture.source.reference.(string); !ok {
			unimplemented("Image from buffer view")
		}
		path := texture.source.reference.(string)
		if _, exist := ctx.textures[path]; !exist {
			name := strings.clone(path, app.ctx.allocator)
			ctx.textures[name] = load_texture_from_file(path, app.ctx.allocator)
		}
	}
}

get_material :: proc(name: string) -> Material {
	if material, exist := app.render_ctx.materials[name]; exist {
		return material
	}
	fmt.println(name, app.render_ctx.materials)
	unreachable()
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
LIGHT_DEPTH_FRAGMENT_SHADER :: `
#version 450 core

void main() {

}
`
