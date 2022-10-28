package iris

import "core:time"
// import "core:fmt"
import "core:math/linalg"


RENDER_CTX_MAX_LIGHTS :: 128
RENDER_CTX_DEFAULT_FAR :: 100
RENDER_CTX_DEFAULT_NEAR :: 0.1
RENDER_CTX_DEFAULT_FOVY :: 45
RENDER_CTX_DEFAULT_AMBIENT :: Color{0.45, 0.45, 0.75, 0.4}
RENDER_QUEUE_DEFAULT_CAP :: 500

Render_Context :: struct {
	render_width:                int,
	render_height:               int,
	aspect_ratio:                f32,
	projection:                  Matrix4,
	view:                        Matrix4,
	projection_view:             Matrix4,
	context_uniform_buffer:      ^Buffer,
	context_uniform_memory:      Buffer_Memory,

	// Camera context
	view_dirty:                  bool,
	eye:                         Vector3,
	centre:                      Vector3,
	up:                          Vector3,

	// Lighting context
	lighting_context:            Lighting_Context,

	// Deferred context
	deferred_framebuffer:        ^Framebuffer,
	deferred_geometry_shader:    ^Shader,
	deferred_composite_shader:   ^Shader,
	deferred_vertices:           Buffer_Memory,
	deferred_indices:            Buffer_Memory,

	//
	hdr_framebuffer:             ^Framebuffer,
	hdr_shader:                  ^Shader,

	// Pass through blit shader
	framebuffer_blit_shader:     ^Shader,
	framebuffer_blit_attributes: ^Attributes,

	// Command buffer
	states:                      [dynamic]^Attributes,
	queues:                      [len(Render_Queue_Kind)]Render_Queue,
}

Render_Uniform_Kind :: enum u32 {
	Context_Data  = 0,
	Lighting_Data = 1,
}

@(private)
Context_Uniform_Data :: struct {
	projection_view: Matrix4,
	projection:      Matrix4,
	view:            Matrix4,
	view_position:   Vector3,
	time:            f32,
	dt:              f32,
}

Render_Queue :: struct {
	commands: [RENDER_QUEUE_DEFAULT_CAP]Render_Command,
	count:    int,
}

Render_Queue_Kind :: enum {
	Deferred_Geometry_Static,
	Deferred_Geometry_Dynamic,
	Forward_Geometry,
	Other,
}

// Render_Command_Buffer :: distinct [RENDER_QUEUE_DEFAULT_CAP]Render_Command

Render_Command :: union {
	Render_Mesh_Command,
	Render_Custom_Command,
}

Render_Mesh_Command :: struct {
	mesh:             ^Mesh,
	local_transform:  Matrix4,
	global_transform: Matrix4,
	joints:           []Matrix4,
	material:         ^Material,
	options:          Rendering_Options,
	instancing_info:  Maybe(Instancing_Info),
}

@(private)
Instancing_Info :: struct {
	count:  int,
	memory: Buffer_Memory,
}

Render_Custom_Command :: struct {
	data:        rawptr,
	render_proc: proc(data: rawptr),
	options:     Rendering_Options,
}

Rendering_Options :: distinct bit_set[Rendering_Option]

Rendering_Option :: enum {
	Enable_Culling,
	Disable_Culling,
	Static,
	Transparent,
	Use_Joints,
	Cast_Shadows,
	Instancing,
}

init_render_ctx :: proc(ctx: ^Render_Context, w, h: int) {

	// load_shaders_from_dir("shaders/build")
	// load_shader_document("shaders/lib.helios")

	set_backface_culling(true)
	ctx.render_width = w
	ctx.render_height = h
	ctx.aspect_ratio = f32(w) / f32(h)
	ctx.projection = linalg.matrix4_perspective_f32(
		f32(RENDER_CTX_DEFAULT_FOVY),
		f32(w) / f32(h),
		f32(RENDER_CTX_DEFAULT_NEAR),
		f32(RENDER_CTX_DEFAULT_FAR),
	)
	ctx.eye = {}
	ctx.centre = {}
	ctx.up = VECTOR_UP

	init_lighting_ctx(&ctx.lighting_context, w, h)

	deferred_framebuffer_res := framebuffer_resource(
		Framebuffer_Loader{
			attachments = {.Color0, .Color1, .Color2, .Depth},
			precision = {
				Framebuffer_Attachment.Color0 = 16,
				Framebuffer_Attachment.Color1 = 16,
				Framebuffer_Attachment.Color2 = 8,
			},
			width = ctx.render_width,
			height = ctx.render_height,
		},
	)
	ctx.deferred_framebuffer = deferred_framebuffer_res.data.(^Framebuffer)

	// shader_resource(
	// 	Shader_Builder{
	// 		info = {
	// 			build_name = "forward_geometry_default",
	// 			prototype_name = "forward_geometry",
	// 			stages = {.Vertex, .Fragment},
	// 			stages_info = {
	// 				Shader_Stage.Vertex = {with_extension = true, name = "default"},
	// 				Shader_Stage.Fragment = {with_extension = false},
	// 			},
	// 		},
	// 		document_name = "shaders/lib.helios",
	// 	},
	// )
	shader_resource(
		Shader_Loader{
			name = "forward_geometry",
			kind = .File,
			stages = {
				Shader_Stage.Vertex = Shader_Stage_Loader{
					file_path = "shaders/forward_geometry.vs",
				},
				Shader_Stage.Fragment = Shader_Stage_Loader{
					file_path = "shaders/forward_geometry.fs",
				},
			},
		},
	)

	// deferred_geo_res := shader_resource(
	// 	Shader_Builder{
	// 		info = {
	// 			build_name = "deferred_geometry_default",
	// 			prototype_name = "deferred_geometry",
	// 			stages = {.Vertex, .Fragment},
	// 			stages_info = {
	// 				Shader_Stage.Vertex = {with_extension = false},
	// 				Shader_Stage.Fragment = {with_extension = true, name = "default"},
	// 			},
	// 		},
	// 		document_name = "shaders/lib.helios",
	// 	},
	// )
	deferred_geo_res := shader_resource(
		Shader_Loader{
			name = "deferred_geometry",
			kind = .File,
			stages = {
				Shader_Stage.Vertex = Shader_Stage_Loader{
					file_path = "shaders/deferred_geometry.vs",
				},
				Shader_Stage.Fragment = Shader_Stage_Loader{
					file_path = "shaders/deferred_geometry.fs",
				},
			},
		},
	)
	ctx.deferred_geometry_shader = deferred_geo_res.data.(^Shader)
	// set_shader_default_subroutine(
	// 	ctx.deferred_geometry_shader,
	// 	.Vertex,
	// 	"computeModelMat",
	// 	"computeStaticModelMat",
	// )
	// set_shader_default_subroutine(
	// 	ctx.deferred_geometry_shader,
	// 	.Fragment,
	// 	"sampleAlbedo",
	// 	"sampleDefaultAlbedo",
	// )

	// deferred_shading_res := shader_resource(
	// 	Shader_Builder{
	// 		info = {
	// 			build_name = "deferred_shading",
	// 			prototype_name = "deferred_shading",
	// 			stages = {.Vertex, .Fragment},
	// 			stages_info = {
	// 				Shader_Stage.Vertex = {with_extension = false},
	// 				Shader_Stage.Fragment = {with_extension = false},
	// 			},
	// 		},
	// 		document_name = "shaders/lib.helios",
	// 	},
	// )
	deferred_shading_res := shader_resource(
		Shader_Loader{
			name = "deferred_shading",
			kind = .File,
			stages = {
				Shader_Stage.Vertex = Shader_Stage_Loader{
					file_path = "shaders/deferred_shading.vs",
				},
				Shader_Stage.Fragment = Shader_Stage_Loader{
					file_path = "shaders/deferred_shading.fs",
				},
			},
		},
	)
	ctx.deferred_composite_shader = deferred_shading_res.data.(^Shader)

	// TEMP
	deferred_vertices_res := raw_buffer_resource(size_of(f32) * 4 * 4)
	ctx.deferred_vertices = buffer_memory_from_buffer_resource(deferred_vertices_res)
	deferred_indices_res := raw_buffer_resource(size_of(u32) * 6)
	ctx.deferred_indices = buffer_memory_from_buffer_resource(deferred_indices_res)

	context_buffer_res := raw_buffer_resource(size_of(Context_Uniform_Data))
	ctx.context_uniform_buffer = context_buffer_res.data.(^Buffer)
	ctx.context_uniform_memory = Buffer_Memory {
		buf    = ctx.context_uniform_buffer,
		size   = size_of(Context_Uniform_Data),
		offset = 0,
	}
	set_uniform_buffer_binding(ctx.context_uniform_buffer, u32(Render_Uniform_Kind.Context_Data))

	// Framebuffer blitting states
	hdr_framebuffer_res := framebuffer_resource(
		Framebuffer_Loader{
			attachments = {.Color0, .Depth},
			precision = {Framebuffer_Attachment.Color0 = 16},
			clear_colors = {Framebuffer_Attachment.Color0 = Color{0.6, 0.6, 0.6, 1.0}},
			width = ctx.render_width,
			height = ctx.render_height,
		},
	)
	ctx.hdr_framebuffer = hdr_framebuffer_res.data.(^Framebuffer)

	hdr_shader_res := shader_resource(
		Shader_Loader{
			name = "hdr_tonemapping",
			kind = .Byte,
			stages = {
				Shader_Stage.Vertex = Shader_Stage_Loader{source = BLIT_FRAMEBUFFER_VERTEX_SHADER},
				Shader_Stage.Fragment = Shader_Stage_Loader{source = HDR_FRAGMENT_SHADER},
			},
		},
	)
	ctx.hdr_shader = hdr_shader_res.data.(^Shader)

	blit_shader_res := shader_resource(
		Shader_Loader{
			name = "hdr_tonemapping",
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

close_render_ctx :: proc(ctx: ^Render_Context) {
}

@(private)
set_view_dirty :: proc() {
	app.render_ctx.view_dirty = true
}

view_position :: proc(position: Vector3) {
	app.render_ctx.eye = position
	app.render_ctx.view_dirty = true
}

view_target :: proc(target: Vector3) {
	app.render_ctx.centre = target
	app.render_ctx.view_dirty = true
}

start_render :: proc() {
	ctx := &app.render_ctx
	for queue in &ctx.queues {
		queue.count = 0
	}
}

end_render :: proc() {
	ctx := &app.render_ctx

	blend(true)

	// Update light values
	if ctx.view_dirty {
		ctx.view_dirty = false
	}
	compute_projection(ctx)

	d_static_queue := &ctx.queues[Render_Queue_Kind.Deferred_Geometry_Static]
	ds_cmds := d_static_queue.commands[:d_static_queue.count]

	d_dynamic_queue := &ctx.queues[Render_Queue_Kind.Deferred_Geometry_Dynamic]
	dd_cmds := d_dynamic_queue.commands[:d_dynamic_queue.count]

	if d_dynamic_queue.count > 0 {
		invalidate_shadow_map()
	}
	update_lighting_context(&ctx.lighting_context)
	shadow_map_pass(&ctx.lighting_context, ds_cmds, dd_cmds)

	set_viewport({0, 0, f32(ctx.render_width), f32(ctx.render_height)})
	clear_framebuffer(ctx.deferred_framebuffer)
	render_deferred_geometry(ctx, ds_cmds)
	render_deferred_geometry(ctx, dd_cmds)

	// Composite the deferred geometry
	bind_shader(ctx.deferred_composite_shader)
	bind_framebuffer(ctx.hdr_framebuffer)
	clear_framebuffer(ctx.hdr_framebuffer)
	{
	// set_backface_culling(false)
				//odinfmt: disable
			quad_vertices := [?]f32{
				-1.0,  1.0, 0.0, 1.0,
				1.0,  1.0, 1.0, 1.0,
				-1.0, -1.0, 0.0, 0.0,
				1.0, -1.0, 1.0, 0.0,
			}
			quad_indices := [?]u32{
				2, 1, 0,
				2, 3, 1,
			}
			//odinfmt: enable


		position_buffer_index: u32 = 0
		normal_buffer_index: u32 = 1
		albedo_buffer_index: u32 = 2
		shadow_map_index: u32 = 3

		set_shader_uniform(
			ctx.deferred_composite_shader,
			"bufferedPosition",
			&position_buffer_index,
		)
		bind_texture(framebuffer_texture(ctx.deferred_framebuffer, .Color0), position_buffer_index)
		set_shader_uniform(ctx.deferred_composite_shader, "bufferedNormal", &normal_buffer_index)
		bind_texture(framebuffer_texture(ctx.deferred_framebuffer, .Color1), normal_buffer_index)
		set_shader_uniform(ctx.deferred_composite_shader, "bufferedAlbedo", &albedo_buffer_index)
		bind_texture(framebuffer_texture(ctx.deferred_framebuffer, .Color2), albedo_buffer_index)
		set_shader_uniform(ctx.deferred_composite_shader, "mapShadow", &shadow_map_index)
		bind_texture(
			framebuffer_texture(ctx.lighting_context.shadow_map_atlas, .Depth),
			shadow_map_index,
		)


		send_buffer_data(
			&ctx.deferred_vertices,
			Buffer_Source{
				data = &quad_vertices[0],
				byte_size = len(quad_vertices) * size_of(f32),
				accessor = Buffer_Data_Type{kind = .Float_32, format = .Scalar},
			},
		)
		send_buffer_data(
			&ctx.deferred_indices,
			Buffer_Source{
				data = &quad_indices[0],
				byte_size = len(quad_indices) * size_of(u32),
				accessor = Buffer_Data_Type{kind = .Unsigned_32, format = .Scalar},
			},
		)

		// prepare attributes
		bind_attributes(ctx.framebuffer_blit_attributes)
		defer {
			default_attributes()
			default_shader()
			unbind_texture(framebuffer_texture(ctx.deferred_framebuffer, .Color0))
			unbind_texture(framebuffer_texture(ctx.deferred_framebuffer, .Color1))
			unbind_texture(framebuffer_texture(ctx.deferred_framebuffer, .Color2))
		}

		link_interleaved_attributes_vertices(
			ctx.framebuffer_blit_attributes,
			ctx.deferred_vertices.buf,
		)
		link_attributes_indices(ctx.framebuffer_blit_attributes, ctx.deferred_indices.buf)

		draw_triangles(len(quad_indices))
		blit_framebuffer_depth(
			ctx.deferred_framebuffer,
			ctx.hdr_framebuffer,
			framebuffer_bounding_rect(ctx.deferred_framebuffer),
			framebuffer_bounding_rect(ctx.hdr_framebuffer),
		)
		// set_backface_culling(true)
	}

	render_forward_geometry(ctx)

	// Tone mapping pass
	bind_shader(ctx.hdr_shader)
	default_framebuffer()
	{
			//odinfmt: disable
		quad_vertices := [?]f32{
			-1.0,  1.0, 0.0, 1.0,
			1.0,  1.0, 1.0, 1.0,
			-1.0, -1.0, 0.0, 0.0,
			1.0, -1.0, 1.0, 0.0,
		}
		quad_indices := [?]u32{
			2, 1, 0,
			2, 3, 1,
		}
		//odinfmt: enable


		hdr_buffer_index: u32 = 0
		default_exposure: f32 = 0.05

		set_shader_uniform(ctx.hdr_shader, "hdrBuffer", &hdr_buffer_index)
		bind_texture(framebuffer_texture(ctx.hdr_framebuffer, .Color0), hdr_buffer_index)
		set_shader_uniform(ctx.hdr_shader, "exposureValue", &default_exposure)


		send_buffer_data(
			&ctx.deferred_vertices,
			Buffer_Source{
				data = &quad_vertices[0],
				byte_size = len(quad_vertices) * size_of(f32),
				accessor = Buffer_Data_Type{kind = .Float_32, format = .Scalar},
			},
		)
		send_buffer_data(
			&ctx.deferred_indices,
			Buffer_Source{
				data = &quad_indices[0],
				byte_size = len(quad_indices) * size_of(u32),
				accessor = Buffer_Data_Type{kind = .Unsigned_32, format = .Scalar},
			},
		)

		// prepare attributes
		bind_attributes(ctx.framebuffer_blit_attributes)
		defer {
			default_attributes()
			default_shader()
			unbind_texture(framebuffer_texture(ctx.deferred_framebuffer, .Color0))
		}

		link_interleaved_attributes_vertices(
			ctx.framebuffer_blit_attributes,
			ctx.deferred_vertices.buf,
		)
		link_attributes_indices(ctx.framebuffer_blit_attributes, ctx.deferred_indices.buf)

		draw_triangles(len(quad_indices))
	}

	render_other_geometry(ctx)
}

render_deferred_geometry :: proc(ctx: ^Render_Context, cmds: []Render_Command) {
	bind_framebuffer(ctx.deferred_framebuffer)
	for command in cmds {
		#partial switch c in command {
		case Render_Mesh_Command:
			shader := ctx.deferred_geometry_shader
			spec := c.material.specialization

			if .Transparent in c.options {
				assert(false, "No transparent geometry allowed in the deferred pass")
			}
			// mvp := linalg.matrix_mul(ctx.projection_view, c.global_transform)
			// set_shader_uniform(shader, "mvp", &mvp[0][0])

			local := c.local_transform
			global := c.global_transform
			set_shader_uniform(shader, "matModel", &global[0][0])
			set_shader_uniform(shader, "matModelLocal", &local[0][0])


			inverse_transpose_mat := linalg.matrix4_inverse_transpose_f32(c.global_transform)
			normal_mat := linalg.matrix3_from_matrix4_f32(inverse_transpose_mat)
			set_shader_uniform(shader, "matNormal", &normal_mat[0][0])

			local_inverse_transpose_mat := linalg.matrix4_inverse_transpose_f32(c.local_transform)
			local_normal_mat := linalg.matrix3_from_matrix4_f32(local_inverse_transpose_mat)
			set_shader_uniform(shader, "matNormalLocal", &local_normal_mat[0][0])

			calculate_tangent_space := .Normal0 in c.material.maps
			set_shader_uniform(shader, "useTangentSpace", &calculate_tangent_space)

			dyn_geometry := .Use_Joints in c.options
			// set_shader_uniform(shader, "useJointSpace", &calculate_joint_deform)
			if dyn_geometry {
				set_shader_uniform(shader, "matJoints", &c.joints[0])
			}

			for kind in Material_Map {
				if kind in c.material.maps {
					map_uniform_value := u32(kind)
					texture := c.material.textures[kind]
					map_uniform_name := material_map_name[kind]
					bind_texture(c.material.textures[kind], map_uniform_value)
					if _, exist := shader.uniforms[map_uniform_name]; exist {
						set_shader_uniform(shader, map_uniform_name, &map_uniform_value)
					}
				}
			}

			bind_attributes(c.mesh.attributes)
			defer default_attributes()
			link_packed_attributes_vertices(
				c.mesh.attributes,
				c.mesh.vertices.buf,
				c.mesh.attributes_info,
			)
			link_attributes_indices(c.mesh.attributes, c.mesh.indices.buf)

			// TODO: Only need to be done once?
			instancing := .Instancing in c.options
			model_mat_subroutine: Subroutine_Location
			stage_subroutines := shader.stages_info[Shader_Stage.Vertex].subroutines
			switch {
			case !dyn_geometry && !instancing:
				model_mat_subroutine = stage_subroutines["computeStaticModelMat"]
			case dyn_geometry && !instancing:
				model_mat_subroutine = stage_subroutines["computeDynamicModelMat"]
			case !dyn_geometry && instancing:
				model_mat_subroutine = stage_subroutines["computeInstancedStaticModelMat"]
			case dyn_geometry && instancing:
				model_mat_subroutine = stage_subroutines["computeInstancedDynamicModelMat"]
			}
			spec[Shader_Stage.Vertex]["computeModelMat"] = model_mat_subroutine

			set_shader_subroutines(shader, spec^)
			// set_shader_uniform(shader, "instanced", &instancing)
			if instancing {
				info := c.instancing_info.?
				link_packed_attributes_vertices_list(
					c.mesh.attributes,
					info.memory.buf,
					{.Instance_Transform},
					Packed_Attributes{offsets = {Attribute_Kind.Instance_Transform = 0}},
				)
				draw_instanced_triangles(c.mesh.index_count, info.count)
			} else {
				draw_triangles(c.mesh.index_count)
			}

			for kind in Material_Map {
				if kind in c.material.maps {
					unbind_texture(c.material.textures[kind])
				}
			}
		}
	}
	default_shader()
	default_framebuffer()
}

@(private)
render_forward_geometry :: proc(ctx: ^Render_Context) {
	fq := &ctx.queues[Render_Queue_Kind.Forward_Geometry]
	forward_commands := fq.commands[:fq.count]
	blend(true)
	for command in &forward_commands {
		#partial switch c in &command {
		case Render_Mesh_Command:
			bind_shader(c.material.shader)
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

			for kind in Material_Map {
				if kind in c.material.maps {
					map_uniform_value := u32(kind)
					texture := c.material.textures[kind]
					map_uniform_name := material_map_name[kind]
					bind_texture(c.material.textures[kind], map_uniform_value)
					if _, exist := c.material.shader.uniforms[map_uniform_name]; exist {
						set_shader_uniform(c.material.shader, map_uniform_name, &map_uniform_value)
					}
				}
			}

			depth_map_index := u32(max(Material_Map)) + 1
			if _, exist := c.material.shader.uniforms["mapViewDepth"]; exist {
				bind_texture(
					&ctx.deferred_framebuffer.maps[Framebuffer_Attachment.Depth],
					depth_map_index,
				)
				set_shader_uniform(c.material.shader, "mapViewDepth", &depth_map_index)
			}

			bind_attributes(c.mesh.attributes)
			defer default_attributes()
			link_packed_attributes_vertices(
				c.mesh.attributes,
				c.mesh.vertices.buf,
				c.mesh.attributes_info,
			)
			link_attributes_indices(c.mesh.attributes, c.mesh.indices.buf)

			instancing := .Instancing in c.options
			set_shader_uniform(c.material.shader, "instanced", &instancing)
			if instancing {
				info := c.instancing_info.?
				link_packed_attributes_vertices_list(
					c.mesh.attributes,
					info.memory.buf,
					{.Instance_Transform},
					Packed_Attributes{offsets = {Attribute_Kind.Instance_Transform = 0}},
				)
				draw_instanced_triangles(c.mesh.index_count, info.count)
			} else {
				draw_triangles(c.mesh.index_count)
			}

			for kind in Material_Map {
				if kind in c.material.maps {
					unbind_texture(c.material.textures[kind])
				}
			}

			if c.material.double_face {
				set_backface_culling(true)
				depth_mode(.Less)
			}

			for kind in Material_Map {
				if kind in c.material.maps {
					unbind_texture(c.material.textures[kind])
				}
			}

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
}

render_other_geometry :: proc(ctx: ^Render_Context) {
	oq := ctx.queues[Render_Queue_Kind.Other]
	other_commands := oq.commands[:oq.count]
	for command in other_commands {
		#partial switch c in command {
		case Render_Custom_Command:
			if .Disable_Culling in c.options {
				set_backface_culling(false)
				c.render_proc(c.data)
				set_backface_culling(true)
			} else {
				c.render_proc(c.data)
			}

		case:
			unreachable()
		}
	}
}

@(private)
compute_projection :: proc(ctx: ^Render_Context) {
	ctx.view = linalg.matrix4_look_at_f32(ctx.eye, ctx.centre, ctx.up)
	ctx.projection_view = linalg.matrix_mul(ctx.projection, ctx.view)
	send_buffer_data(
		&ctx.context_uniform_memory,
		Buffer_Source{
			data = &Context_Uniform_Data{
				projection_view = ctx.projection_view,
				projection = ctx.projection,
				view = ctx.view,
				view_position = ctx.eye,
				time = f32(time.duration_seconds(time.since(app.start_time))),
				dt = f32(elapsed_time()),
			},
			byte_size = size_of(Context_Uniform_Data),
			accessor = Buffer_Data_Type{kind = .Byte, format = .Unspecified},
		},
	)
}

@(private)
push_draw_command :: proc(cmd: Render_Command, kind: Render_Queue_Kind) {
	queue := &app.render_ctx.queues[kind]
	queue.commands[queue.count] = cmd
	queue.count += 1
}

g_buffer_texture :: proc(a: Framebuffer_Attachment) -> ^Texture {
	return framebuffer_texture(app.render_ctx.deferred_framebuffer, a)
}

render_size :: proc() -> Vector2 {
	return {f32(app.render_ctx.render_width), f32(app.render_ctx.render_height)}
}

// The returned matrix is from frame n-1
projection_view_matrix :: proc() -> Matrix4 {
	return app.render_ctx.projection_view
}

projection_matrix :: proc() -> Matrix4 {
	return app.render_ctx.projection
}

view_matrix :: proc() -> Matrix4 {
	return app.render_ctx.view
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

@(private)
HDR_FRAGMENT_SHADER :: `
#version 450 core
in VS_OUT {
	vec2 texCoord;
} frag;

out vec4 finalColor;

uniform sampler2D hdrBuffer;
uniform float exposureValue;

void main() {
	const float gamma = 2.2;
	vec3 hdrClr = texture(hdrBuffer, frag.texCoord).rgb;

	// Tone mapping
	vec3 ldrClr = vec3(1.0) - exp(-hdrClr * exposureValue);
	ldrClr = pow(ldrClr, vec3(1.0 / gamma));

	finalColor = vec4(ldrClr, 1.0);
}
`
