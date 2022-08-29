package iris

import "core:fmt"
// import "core:log"
import "core:math/linalg"

Rendering_Context :: struct {
	render_width:       int,
	render_height:      int,
	projection:         Matrix4,
	view:               Matrix4,

	// Camera state
	eye:                Vector3,
	centre:             Vector3,
	up:                 Vector3,

	// Command buffer
	states:             [dynamic]Attributes_State,
	commands:           [dynamic]Render_Command,
	previous_cmd_count: int,
}

Render_Command :: union {
	Render_Mesh_Command,
}

Render_Mesh_Command :: struct {
	mesh:      Mesh,
	transform: Transform,
	material:  Material,
}

init_render_ctx :: proc(ctx: ^Rendering_Context, w, h: int) {
	DEFAULT_FAR :: 100
	DEFAULT_NEAR :: 1
	DEFAULT_FOVY :: 45

	ctx.render_width = w
	ctx.render_height = h
	ctx.projection = linalg.matrix4_perspective_f32(
		f32(DEFAULT_FOVY),
		f32(w) / f32(h),
		f32(DEFAULT_NEAR),
		f32(DEFAULT_FAR),
	)
	ctx.eye = {}
	ctx.centre = {}
	ctx.up = VECTOR_UP
}

close_render_ctx :: proc(ctx: ^Rendering_Context) {
	for _, i in ctx.states {
		destroy_attributes_state(&ctx.states[i])
	}
}

view_position :: proc(position: Vector3) {
	app.render_ctx.eye = position
}

view_target :: proc(target: Vector3) {
	app.render_ctx.centre = target
}

start_render :: proc() {
	ctx := &app.render_ctx
	ctx.commands = make([dynamic]Render_Command, 0, ctx.previous_cmd_count, context.temp_allocator)
	set_viewport(ctx.render_width, ctx.render_height)
}

end_render :: proc() {
	ctx := &app.render_ctx
	ctx.view = linalg.matrix4_look_at_f32(ctx.eye, ctx.centre, ctx.up)
	current_shader: u32 = 0
	for command in &ctx.commands {
		switch c in &command {
		case Render_Mesh_Command:
			if c.material.shader.handle != current_shader {
				bind_shader(c.material.shader)
				current_shader = c.material.shader.handle
			}
			model_mat := linalg.matrix4_from_trs_f32(
				c.transform.translation,
				c.transform.rotation,
				c.transform.scale,
			)
			mvp := linalg.matrix_mul(linalg.matrix_mul(ctx.projection, ctx.view), model_mat)
			set_shader_uniform(c.material.shader, "mvp", &mvp[0][0])

			unit_index: u32
			for kind in Material_Map {
				if kind in c.material.maps {
					texture_uniform_name := fmt.tprintf("texture%d", unit_index)
					bind_texture(&c.material.textures[kind], unit_index)
					set_shader_uniform(c.material.shader, texture_uniform_name, &unit_index)
					unit_index += 1
				}
			}

			bind_attributes_state(c.mesh.state)
			defer unbind_attributes_state()
			link_attributes_state_vertices(&c.mesh.state, c.mesh.vertices)
			link_attributes_state_indices(&c.mesh.state, c.mesh.indices)
			draw_triangles(c.mesh.indices.cap)

			for kind in Material_Map {
				if kind in c.material.maps {
					unbind_texture(&c.material.textures[kind])
				}
			}
		}
	}
	ctx.previous_cmd_count = len(ctx.commands)
}

@(private)
get_ctx_attribute_state :: proc(layout: Vertex_Layout) -> Attributes_State {
	ctx := &app.render_ctx
	for state in ctx.states {
		if vertex_layout_equal(layout, state.layout) {
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
