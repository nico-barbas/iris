package iris

import "core:log"
import "core:math/linalg"

MAX_LIGHT_CASTERS :: 4
SHADOW_MAP_PADDING :: 0

Lighting_Context :: struct {
	dirty:              bool,
	count:              u32,
	projection:         Matrix4,
	lights:             [RENDER_CTX_MAX_LIGHTS]Light_Info,
	lights_projection:  [RENDER_CTX_MAX_LIGHTS]Matrix4,
	ambient:            Color,
	light_casters:      [MAX_LIGHT_CASTERS]struct {
		id:          Light_ID,
		cache_dirty: bool,
		map_dirty:   bool,
	},
	light_caster_count: int,
	shadow_map_atlas:   ^Framebuffer,
	shadow_map_slices:  [MAX_LIGHT_CASTERS][2]Texture_Slice,
	shadow_map_shader:  ^Shader,
	uniform_memory:     Buffer_Memory,
}

Light_Info :: struct {
	position:  Vector4,
	color:     Color,
	linear:    f32,
	quadratic: f32,
	kind:      Light_Kind,
	dirty:     enum u32 {
		True,
		False,
	},
}

Light_ID :: distinct u32

Light_Kind :: enum u32 {
	Directional,
	Point,
}

@(private)
Lighting_Uniform_Data :: struct {
	lights:             [RENDER_CTX_MAX_LIGHTS]Light_Info,
	light_casters:      [4][4]u32,
	projections:        [4]Matrix4,
	ambient:            Color,
	light_count:        u32,
	light_caster_count: u32,
	shadow_map_size:    Vector2,
}

init_lighting_ctx :: proc(ctx: ^Lighting_Context, render_w, render_h: int) {
	ctx.ambient = RENDER_CTX_DEFAULT_AMBIENT
	ctx.projection = linalg.matrix_ortho3d_f32(
		-17.5,
		17.5,
		-10,
		10,
		f32(RENDER_CTX_DEFAULT_NEAR),
		f32(20),
	)

	map_res := framebuffer_resource(
		Framebuffer_Loader{
			attachments = {.Depth},
			width = 2 * render_w + SHADOW_MAP_PADDING,
			height = 4 * render_h + (3 * SHADOW_MAP_PADDING),
		},
	)
	ctx.shadow_map_atlas = map_res.data.(^Framebuffer)

	for slices, y in &ctx.shadow_map_slices {
		slices[0] = Texture_Slice {
			atlas_width  = f32(ctx.shadow_map_atlas.width),
			atlas_height = f32(ctx.shadow_map_atlas.height),
			x            = 0,
			y            = f32(y * (render_h + SHADOW_MAP_PADDING)),
			width        = f32(render_w),
			height       = f32(render_h),
		}
		slices[1] = Texture_Slice {
			atlas_width  = f32(ctx.shadow_map_atlas.width),
			atlas_height = f32(ctx.shadow_map_atlas.height),
			x            = f32(render_w + SHADOW_MAP_PADDING),
			y            = f32(y * (render_h + SHADOW_MAP_PADDING)),
			width        = f32(render_w),
			height       = f32(render_h),
		}
	}

	shader_res := shader_resource(
		Raw_Shader_Loader{
			name = "shadow_map",
			kind = .Byte,
			stages = {
				Shader_Stage.Vertex = Shader_Stage_Loader{source = SHADOW_MAP_VERTEX_SHADER},
				Shader_Stage.Fragment = Shader_Stage_Loader{source = EMPTY_FRAGMENT_SHADER},
			},
		},
	)
	ctx.shadow_map_shader = shader_res.data.(^Shader)

	light_buffer_res := raw_buffer_resource(size_of(Lighting_Uniform_Data))
	ctx.uniform_memory = buffer_memory_from_buffer_resource(light_buffer_res)
	set_uniform_buffer_binding(ctx.uniform_memory.buf, u32(Render_Uniform_Kind.Lighting_Data))
}

// @(private)
// compute_light_projection :: proc(ctx: ^Lighting_Context, index: int, view_target: Vector3) {
// 	light := ctx.lights[index]
// 	light_view := linalg.matrix4_look_at_f32(light.position.xyz, view_target, VECTOR_UP)
// 	ctx.lights_projection[index] = linalg.matrix_mul(ctx.projection, light_view)
// }

update_lighting_context :: proc(ctx: ^Lighting_Context) {
	ctx_dirty := false
	for light, i in ctx.lights[:ctx.count] {
		// TODO: Learn how to deal with directional light's view position
		if light.dirty == .True {
			light_view := linalg.matrix4_look_at_f32(light.position.xyz, VECTOR_ZERO, VECTOR_UP)
			ctx.lights_projection[i] = ctx.projection * light_view
			ctx.lights[i].dirty = .False
			ctx_dirty = true
		}
	}

	if ctx_dirty {
		casters_id := [4][4]u32{
			{0 = u32(ctx.light_casters[0].id)},
			{0 = u32(ctx.light_casters[1].id)},
			{0 = u32(ctx.light_casters[2].id)},
			{0 = u32(ctx.light_casters[3].id)},
		}
		slice0 := ctx.shadow_map_slices[0][1]
		slice1 := ctx.shadow_map_slices[1][1]
		slice2 := ctx.shadow_map_slices[2][1]
		slice3 := ctx.shadow_map_slices[3][1]
		send_buffer_data(
			&ctx.uniform_memory,
			Buffer_Source{
				data = &Lighting_Uniform_Data{
					ambient = ctx.ambient,
					light_count = ctx.count,
					lights = ctx.lights,
					light_caster_count = u32(ctx.light_caster_count),
					light_casters = casters_id,
					projections = {
						0 = ctx.lights_projection[casters_id[0].x],
						1 = ctx.lights_projection[casters_id[1].x],
						2 = ctx.lights_projection[casters_id[2].x],
						3 = ctx.lights_projection[casters_id[3].x],
					},
					shadow_map_size = Vector2{
						f32(ctx.shadow_map_atlas.width),
						f32(ctx.shadow_map_atlas.height),
					},
				},
				byte_size = size_of(Lighting_Uniform_Data),
				accessor = Buffer_Data_Type{kind = .Byte, format = .Unspecified},
			},
		)
	}
	// shadow_map_slices = {
	// 	{slice0.x, slice0.y, slice0.width, slice0.height},
	// 	{slice1.x, slice1.y, slice1.width, slice1.height},
	// 	{slice2.x, slice2.y, slice2.width, slice2.height},
	// 	{slice3.x, slice3.y, slice3.width, slice3.height},
	// },
}

add_light :: proc(kind: Light_Kind, p: Vector3, clr: Color, map_shadows: bool) -> (id: Light_ID) {
	ctx := &app.render_ctx.lighting_context
	id = Light_ID(ctx.count)
	ctx.lights[id] = Light_Info {
		kind = kind,
		position = {p.x, p.y, p.z, 1.0},
		color = clr,
		dirty = .True,
	}
	ctx.count += 1
	if map_shadows {
		if ctx.light_caster_count >= MAX_LIGHT_CASTERS {
			log.errorf(
				"[%s]: Max light casters reached. Failed to add light [%d]",
				App_Module.Shader,
				id,
			)
			return
		}
		ctx.light_casters[ctx.light_caster_count] = {
			id          = id,
			cache_dirty = true,
		}
		ctx.light_caster_count += 1
	}
	return
}

light_position :: proc(id: Light_ID, position: Vector3) {
	ctx := &app.render_ctx.lighting_context
	ctx.lights[id].position = {position.x, position.y, position.z, 1.0}
	ctx.lights[id].dirty = .True
}

light_ambient :: proc(strength: f32, color: Vector3) {
	app.render_ctx.lighting_context.ambient.rbg = color.rgb
	app.render_ctx.lighting_context.ambient.a = strength
}

shadow_map_pass :: proc(ctx: ^Lighting_Context, st_geo, dyn_geo: []Render_Command) {
	render_commands :: proc(shader: ^Shader, cmds: []Render_Command) {
		for cmd in cmds {
			c := cmd.(Render_Mesh_Command)
			set_shader_uniform(shader, "matModel", &c.global_transform[0][0])

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

	bind_framebuffer(ctx.shadow_map_atlas)
	bind_shader(ctx.shadow_map_shader)
	defer {
		default_framebuffer()
		default_shader()
	}
	for lc, i in &ctx.light_casters {
		light_proj := ctx.lights_projection[lc.id]
		cache := ctx.shadow_map_slices[i][0]
		if lc.cache_dirty {
			set_viewport({cache.x, cache.y, cache.width, cache.height})
			clear_framebuffer(ctx.shadow_map_atlas)

			set_shader_uniform(ctx.shadow_map_shader, "matLightSpace", &light_proj[0][0])
			render_commands(ctx.shadow_map_shader, st_geo)
			// lc.cache_dirty = false
			lc.map_dirty = true
		}
		if lc.map_dirty {
			s_map := ctx.shadow_map_slices[i][1]
			// set_viewport(framebuffer_bounding_rect(ctx.shadow_map_atlas))
			blit_framebuffer_depth(
				ctx.shadow_map_atlas,
				ctx.shadow_map_atlas,
				Rectangle{cache.x, cache.y + cache.height, cache.width, cache.y},
				Rectangle{s_map.x, s_map.y + s_map.height, s_map.x + s_map.width, s_map.y},
			)
			set_viewport({s_map.x, s_map.y, s_map.width, s_map.height})

			set_shader_uniform(ctx.shadow_map_shader, "matLightSpace", &light_proj[0][0])
			render_commands(ctx.shadow_map_shader, dyn_geo)
			lc.map_dirty = false
		}
	}
}

@(private)
SHADOW_MAP_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec3 attribPosition;

uniform mat4 matLightSpace;
uniform mat4 matModel;

void main() {
	gl_Position = matLightSpace * matModel * vec4(attribPosition, 1.0);
}
`
