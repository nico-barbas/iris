package iris

import "core:log"
import "core:math/linalg"

MAX_SHADOW_MAPS :: 1
MAX_LIGHTS :: 32

Lighting_Context :: struct {
	projection:         Matrix4,
	ambient:            Color,
	ambient_strength:   f32,
	lights:             [MAX_LIGHTS]^Light_Node,
	light_count:        int,
	shadow_map_count:   int,
	shadow_map_ids:     [MAX_SHADOW_MAPS]Light_ID,
	shadow_map_shader:  ^Shader,
	global_dirty_cache: bool,
	uniform_memory:     Buffer_Memory,
	dirty_uniform_data: bool,
}

Light_Uniform_Data :: struct {
	lights:           [MAX_LIGHTS]Light_Uniform_Info,
	shadow_maps:      [MAX_SHADOW_MAPS][4]u32,
	projections:      [MAX_SHADOW_MAPS]Matrix4,
	ambient:          Color,
	light_count:      u32,
	shadow_map_count: u32,
	sizes:            [MAX_SHADOW_MAPS]Vector2,
}

Light_Uniform_Info :: struct {
	position:  Vector4,
	color:     Color,
	linear:    f32,
	quadratic: f32,
	_kind:     u32,
	_padding:  u32,
}

Light_ID :: distinct uint

Light_Node :: struct {
	using base: Node,
	id:         Light_ID,
	projection: Matrix4,
	color:      Color,
	options:    Light_Options,
	shadow_map: Maybe(Shadow_Map),
}

Light_Option :: enum {
	Shadow_Map,
}

Light_Options :: distinct bit_set[Light_Option]

Shadow_Map :: struct {
	scale:       f32,
	cache_dirty: bool,
	data_dirty:  bool,
	cache:       ^Framebuffer,
	data:        ^Framebuffer,
	shader:      ^Shader,
}

init_lighting_context :: proc(ctx: ^Lighting_Context) {
	ctx.ambient = RENDER_CTX_DEFAULT_AMBIENT
	ctx.projection = linalg.matrix_ortho3d_f32(
		-8.75,
		8.75,
		-5,
		5,
		f32(RENDER_CTX_DEFAULT_NEAR),
		f32(20),
	)

	uniform_res := raw_buffer_resource(size_of(Light_Uniform_Data))
	ctx.uniform_memory = buffer_memory_from_buffer_resource(uniform_res)
	set_uniform_buffer_binding(ctx.uniform_memory.buf, u32(Render_Uniform_Kind.Lighting_Data))

}

update_lighting_context :: proc(ctx: ^Lighting_Context) {
	if ctx.dirty_uniform_data {
		lights: [MAX_LIGHTS]Light_Uniform_Info
		shadow_maps_ids: [MAX_SHADOW_MAPS][4]u32
		projections: [MAX_SHADOW_MAPS]Matrix4
		sizes: [MAX_SHADOW_MAPS]Vector2

		for node, i in ctx.lights[:ctx.light_count] {
			light_position := translation_from_matrix(node.global_transform)
			lights[i] = Light_Uniform_Info {
				position = Vector4{light_position.x, light_position.y, light_position.z, 0},
				color = node.color,
				_kind = 0,
			}
		}
		for id, i in ctx.shadow_map_ids {
			shadow_maps_ids[i] = {
				0 = u32(id),
			}
			projections[i] = ctx.lights[id].projection
			shadow_map := ctx.lights[id].shadow_map.?
			sizes[i] = Vector2{f32(shadow_map.data.width), f32(shadow_map.data.height)}
		}

		send_buffer_data(
			&ctx.uniform_memory,
			Buffer_Source{
				data = &Light_Uniform_Data{
					ambient = ctx.ambient,
					light_count = u32(ctx.light_count),
					lights = lights,
					shadow_map_count = u32(ctx.shadow_map_count),
					shadow_maps = shadow_maps_ids,
					projections = projections,
					sizes = sizes,
				},
				byte_size = size_of(Light_Uniform_Data),
				accessor = Buffer_Data_Type{kind = .Byte, format = .Unspecified},
			},
		)
	}
}

set_lighting_context_dirty :: proc(ctx: ^Lighting_Context) {
	ctx.dirty_uniform_data = true
}

init_light_node :: proc(ctx: ^Lighting_Context, node: ^Light_Node) {
	node.name = "Light"
	node.id = Light_ID(ctx.light_count)
	node.local_bounds = BOUNDING_BOX_ZERO
	node.flags += {.Rendered, .Ignore_Culling, .Dirty_Transform}

	ctx.lights[node.id] = node
	ctx.light_count += 1

	if .Shadow_Map in node.options {
		if ctx.shadow_map_count >= MAX_SHADOW_MAPS {
			log.errorf(
				"[%s]: Too many active shadow maps, Light[%d] couldn't be initialized as a shadow source",
				App_Module.GPU_Memory,
				node.id,
			)
			return
		}

		shadow_map := node.shadow_map.?
		size := render_size() * shadow_map.scale

		cache_res := framebuffer_resource(
			Framebuffer_Loader{attachments = {.Depth}, width = int(size.x), height = int(size.y)},
		)
		map_res := framebuffer_resource(
			Framebuffer_Loader{attachments = {.Depth}, width = int(size.x), height = int(size.y)},
		)

		shadow_map.cache_dirty = true
		shadow_map.data_dirty = true
		shadow_map.cache = cache_res.data.(^Framebuffer)
		shadow_map.data = map_res.data.(^Framebuffer)
		shadow_map.shader = shadow_map_shader()

		node.shadow_map = shadow_map
		ctx.shadow_map_ids[ctx.shadow_map_count] = node.id
		ctx.shadow_map_count += 1
	}
}

update_light_node :: proc(ctx: ^Lighting_Context, node: ^Light_Node) {
	node_position := translation_from_matrix(node.global_transform)
	light_view := linalg.matrix4_look_at_f32(node_position, VECTOR_ZERO, VECTOR_ONE)
	node.projection = ctx.projection * light_view
}

shadow_map_pass :: proc(node: ^Light_Node, geometry: [2][]Render_Command) -> ^Texture {
	STATIC_INDEX :: 0
	DYNAMIC_INDEX :: 1

	shadow_map := node.shadow_map.?
	if shadow_map.cache_dirty {
		static_shadow_map_pass(node, geometry[STATIC_INDEX])
		shadow_map.cache_dirty = false
	}

	if shadow_map.data_dirty {
		dynamic_shadow_map_pass(node, geometry[DYNAMIC_INDEX])
		shadow_map.data_dirty = false
	}

	node.shadow_map = shadow_map
	return framebuffer_texture(shadow_map.data, .Depth)
}

static_shadow_map_pass :: proc(node: ^Light_Node, geometry: []Render_Command) {
	shadow_map := node.shadow_map.?
	bind_framebuffer(shadow_map.cache)
	bind_shader(shadow_map.shader)
	defer {
		default_framebuffer()
		default_shader()
	}

	clear_framebuffer(shadow_map.cache)
	set_viewport(Rectangle{0, 0, f32(shadow_map.cache.width), f32(shadow_map.cache.height)})

	b := false
	set_shader_uniform(shadow_map.shader, "matLightSpace", &node.projection[0][0])
	set_shader_uniform(shadow_map.shader, "dynamicGeometry", &b)
	render_statics(shadow_map.shader, geometry)
}

dynamic_shadow_map_pass :: proc(node: ^Light_Node, geometry: []Render_Command) {
	shadow_map := node.shadow_map.?
	bind_framebuffer(shadow_map.data)
	bind_shader(shadow_map.shader)
	defer {
		default_framebuffer()
		default_shader()
	}

	blit_framebuffer_depth(
		shadow_map.cache,
		shadow_map.data,
		Rectangle{0, 0, f32(shadow_map.cache.width), f32(shadow_map.cache.height)},
		Rectangle{0, 0, f32(shadow_map.data.width), f32(shadow_map.data.height)},
	)
	set_viewport(Rectangle{0, 0, f32(shadow_map.data.width), f32(shadow_map.data.height)})
	set_shader_uniform(shadow_map.shader, "matLightSpace", &node.projection[0][0])
	render_dynamics(shadow_map.shader, geometry)
}

@(private)
render_dynamics :: proc(shader: ^Shader, geometry: []Render_Command) {
	for cmd in geometry {
		c := cmd.(Render_Mesh_Command)
		rigged := .Skinned in c.options
		set_shader_uniform(shader, "dynamicGeometry", &rigged)
		if rigged {
			set_shader_uniform(shader, "matModelLocal", &c.local_transform[0][0])
			set_shader_uniform(shader, "matJoints", &c.joints[0])
		}
		render(shader, &c)
	}
}

@(private)
render_statics :: proc(shader: ^Shader, geometry: []Render_Command) {
	for cmd in geometry {
		c := cmd.(Render_Mesh_Command)
		render(shader, &c)
	}
}

@(private)
render :: proc(shader: ^Shader, c: ^Render_Mesh_Command) {
	set_shader_uniform(shader, "matModel", &c.global_transform[0][0])
	bind_attributes(c.mesh.attributes)
	defer default_attributes()
	link_packed_attributes_vertices(c.mesh.attributes, c.mesh.vertices.buf, c.mesh.attributes_info)
	link_attributes_indices(c.mesh.attributes, c.mesh.indices.buf)
	draw_triangles(c.mesh.index_count)
}

@(private)
shadow_map_shader :: proc() -> ^Shader {
	if shader, exist := shader_from_name("shadow_map"); exist {
		return shader
	} else {
		shader_res := shader_resource(
			Shader_Loader{
				name = "shadow_map",
				kind = .Byte,
				stages = {
					Shader_Stage.Vertex = Shader_Stage_Loader{source = SHADOW_MAP_VERTEX_SHADER},
					Shader_Stage.Fragment = Shader_Stage_Loader{source = EMPTY_FRAGMENT_SHADER},
				},
			},
		)

		return shader_res.data.(^Shader)
	}
}

// MAX_LIGHT_CASTERS :: 4
// SHADOW_MAP_PADDING :: 0

// Lighting_Context :: struct {
// 	count:              u32,
// 	projection:         Matrix4,
// 	lights:             [RENDER_CTX_MAX_LIGHTS]Light_Info,
// 	lights_projection:  [RENDER_CTX_MAX_LIGHTS]Matrix4,
// 	ambient:            Color,
// 	light_casters:      [MAX_LIGHT_CASTERS]struct {
// 		id:          Light_ID,
// 		cache_dirty: bool,
// 		map_dirty:   bool,
// 	},
// 	light_caster_count: int,
// 	shadow_map_atlas:   ^Framebuffer,
// 	shadow_map_slices:  [MAX_LIGHT_CASTERS][2]Texture_Slice,
// 	shadow_map_shader:  ^Shader,
// 	uniform_memory:     Buffer_Memory,
// }

// Light_Info :: struct {
// 	position:  Vector4,
// 	color:     Color,
// 	linear:    f32,
// 	quadratic: f32,
// 	kind:      Light_Kind,
// 	dirty:     enum u32 {
// 		True,
// 		False,
// 	},
// }

// Light_ID :: distinct u32

// Light_Kind :: enum u32 {
// 	Directional,
// 	Point,
// }

// @(private)
// Lighting_Uniform_Data :: struct {
// 	lights:             [RENDER_CTX_MAX_LIGHTS]Light_Info,
// 	light_casters:      [4][4]u32,
// 	projections:        [4]Matrix4,
// 	ambient:            Color,
// 	light_count:        u32,
// 	light_caster_count: u32,
// 	shadow_map_size:    Vector2,
// }

// init_lighting_ctx :: proc(ctx: ^Lighting_Context, render_w, render_h: int) {
// 	ctx.ambient = RENDER_CTX_DEFAULT_AMBIENT
// 	ctx.projection = linalg.matrix_ortho3d_f32(
// 		-17.5,
// 		17.5,
// 		-10,
// 		10,
// 		f32(RENDER_CTX_DEFAULT_NEAR),
// 		f32(20),
// 	)

// 	map_res := framebuffer_resource(
// 		Framebuffer_Loader{
// 			attachments = {.Depth},
// 			width = 2 * render_w + SHADOW_MAP_PADDING,
// 			height = 4 * render_h + (3 * SHADOW_MAP_PADDING),
// 		},
// 	)
// 	ctx.shadow_map_atlas = map_res.data.(^Framebuffer)

// 	for slices, y in &ctx.shadow_map_slices {
// 		slices[0] = Texture_Slice {
// 			atlas_width  = f32(ctx.shadow_map_atlas.width),
// 			atlas_height = f32(ctx.shadow_map_atlas.height),
// 			x            = 0,
// 			y            = f32(y * (render_h + SHADOW_MAP_PADDING)),
// 			width        = f32(render_w),
// 			height       = f32(render_h),
// 		}
// 		slices[1] = Texture_Slice {
// 			atlas_width  = f32(ctx.shadow_map_atlas.width),
// 			atlas_height = f32(ctx.shadow_map_atlas.height),
// 			x            = f32(render_w + SHADOW_MAP_PADDING),
// 			y            = f32(y * (render_h + SHADOW_MAP_PADDING)),
// 			width        = f32(render_w),
// 			height       = f32(render_h),
// 		}
// 	}

// 	shader_res := shader_resource(
// 		Shader_Loader{
// 			name = "shadow_map",
// 			kind = .Byte,
// 			stages = {
// 				Shader_Stage.Vertex = Shader_Stage_Loader{source = SHADOW_MAP_VERTEX_SHADER},
// 				Shader_Stage.Fragment = Shader_Stage_Loader{source = EMPTY_FRAGMENT_SHADER},
// 			},
// 		},
// 	)
// 	ctx.shadow_map_shader = shader_res.data.(^Shader)

// 	light_buffer_res := raw_buffer_resource(size_of(Lighting_Uniform_Data))
// 	ctx.uniform_memory = buffer_memory_from_buffer_resource(light_buffer_res)
// 	set_uniform_buffer_binding(ctx.uniform_memory.buf, u32(Render_Uniform_Kind.Lighting_Data))
// }

// update_lighting_context :: proc(ctx: ^Lighting_Context) {
// 	ctx_dirty := false
// 	for light, i in ctx.lights[:ctx.count] {
// 		// TODO: Learn how to deal with directional light's view position
// 		if light.dirty == .True {
// 			light_view := linalg.matrix4_look_at_f32(light.position.xyz, VECTOR_ZERO, VECTOR_UP)
// 			ctx.lights_projection[i] = ctx.projection * light_view
// 			ctx.lights[i].dirty = .False
// 			ctx_dirty = true
// 		}
// 	}

// 	if ctx_dirty {
// 		casters_id := [4][4]u32{
// 			{0 = u32(ctx.light_casters[0].id)},
// 			{0 = u32(ctx.light_casters[1].id)},
// 			{0 = u32(ctx.light_casters[2].id)},
// 			{0 = u32(ctx.light_casters[3].id)},
// 		}
// 		send_buffer_data(
// 			&ctx.uniform_memory,
// 			Buffer_Source{
// 				data = &Lighting_Uniform_Data{
// 					ambient = ctx.ambient,
// 					light_count = ctx.count,
// 					lights = ctx.lights,
// 					light_caster_count = u32(ctx.light_caster_count),
// 					light_casters = casters_id,
// 					projections = {
// 						0 = ctx.lights_projection[casters_id[0].x],
// 						1 = ctx.lights_projection[casters_id[1].x],
// 						2 = ctx.lights_projection[casters_id[2].x],
// 						3 = ctx.lights_projection[casters_id[3].x],
// 					},
// 					shadow_map_size = Vector2{
// 						f32(ctx.shadow_map_atlas.width),
// 						f32(ctx.shadow_map_atlas.height),
// 					},
// 				},
// 				byte_size = size_of(Lighting_Uniform_Data),
// 				accessor = Buffer_Data_Type{kind = .Byte, format = .Unspecified},
// 			},
// 		)
// 	}
// }

// add_light :: proc(kind: Light_Kind, p: Vector3, clr: Color, map_shadows: bool) -> (id: Light_ID) {
// 	ctx := &app.render_ctx.lighting_context
// 	id = Light_ID(ctx.count)
// 	ctx.lights[id] = Light_Info {
// 		kind = kind,
// 		position = {p.x, p.y, p.z, 1.0},
// 		color = clr,
// 		dirty = .True,
// 	}
// 	ctx.count += 1
// 	if map_shadows {
// 		if ctx.light_caster_count >= MAX_LIGHT_CASTERS {
// 			log.errorf(
// 				"[%s]: Max light casters reached. Failed to add light [%d]",
// 				App_Module.Shader,
// 				id,
// 			)
// 			return
// 		}
// 		ctx.light_casters[ctx.light_caster_count] = {
// 			id          = id,
// 			cache_dirty = true,
// 		}
// 		ctx.light_caster_count += 1
// 	}
// 	return
// }

// @(private)
// invalidate_shadow_map_cache :: proc() {
// 	ctx := &app.render_ctx.lighting_context
// 	for i in 0 ..< ctx.light_caster_count {
// 		ctx.light_casters[i].cache_dirty = true
// 	}
// }

// @(private)
// invalidate_shadow_map :: proc() {
// 	ctx := &app.render_ctx.lighting_context
// 	for i in 0 ..< ctx.light_caster_count {
// 		ctx.light_casters[i].map_dirty = true
// 	}
// }

// light_position :: proc(id: Light_ID, position: Vector3) {
// 	ctx := &app.render_ctx.lighting_context
// 	ctx.lights[id].position = {position.x, position.y, position.z, 1.0}
// 	ctx.lights[id].dirty = .True
// }

// light_ambient :: proc(strength: f32, color: Vector3) {
// 	app.render_ctx.lighting_context.ambient.rbg = color.rgb
// 	app.render_ctx.lighting_context.ambient.a = strength
// }

// shadow_map_pass :: proc(ctx: ^Lighting_Context, st_geo, dyn_geo: []Render_Command) {
// 	render_commands :: proc(shader: ^Shader, cmds: []Render_Command, is_dynamic: bool) {
// 		for cmd in cmds {
// 			c := cmd.(Render_Mesh_Command)
// 			rigged := is_dynamic && .Skinned in c.options
// 			set_shader_uniform(shader, "dynamicGeometry", &rigged)
// 			set_shader_uniform(shader, "matModel", &c.global_transform[0][0])
// 			if rigged {
// 				set_shader_uniform(shader, "matModelLocal", &c.local_transform[0][0])
// 				set_shader_uniform(shader, "matJoints", &c.joints[0])
// 			}

// 			bind_attributes(c.mesh.attributes)
// 			defer default_attributes()
// 			link_packed_attributes_vertices(
// 				c.mesh.attributes,
// 				c.mesh.vertices.buf,
// 				c.mesh.attributes_info,
// 			)
// 			link_attributes_indices(c.mesh.attributes, c.mesh.indices.buf)
// 			draw_triangles(c.mesh.index_count)
// 		}
// 	}

// 	bind_framebuffer(ctx.shadow_map_atlas)
// 	bind_shader(ctx.shadow_map_shader)
// 	defer {
// 		default_framebuffer()
// 		default_shader()
// 	}
// 	for lc, i in &ctx.light_casters {
// 		light_proj := ctx.lights_projection[lc.id]
// 		cache := ctx.shadow_map_slices[i][0]
// 		if lc.cache_dirty {
// 			clear_framebuffer_region(
// 				ctx.shadow_map_atlas,
// 				Rectangle{cache.x, cache.y, cache.width, cache.height},
// 			)
// 			set_viewport({cache.x, cache.y, cache.width, cache.height})

// 			b := false
// 			set_shader_uniform(ctx.shadow_map_shader, "matLightSpace", &light_proj[0][0])
// 			set_shader_uniform(ctx.shadow_map_shader, "dynamicGeometry", &b)

// 			render_commands(ctx.shadow_map_shader, st_geo, false)
// 			lc.cache_dirty = false
// 			lc.map_dirty = true
// 		}
// 		if lc.map_dirty {
// 			s_map := ctx.shadow_map_slices[i][1]
// 			blit_framebuffer_depth(
// 				ctx.shadow_map_atlas,
// 				ctx.shadow_map_atlas,
// 				Rectangle{cache.x, cache.y + cache.height, cache.width, cache.y},
// 				Rectangle{s_map.x, s_map.y + s_map.height, s_map.x + s_map.width, s_map.y},
// 			)
// 			set_viewport({s_map.x, s_map.y, s_map.width, s_map.height})

// 			// log.debug(ctx.shadow_map_shader.uniforms)
// 			set_shader_uniform(ctx.shadow_map_shader, "matLightSpace", &light_proj[0][0])

// 			render_commands(ctx.shadow_map_shader, dyn_geo, true)
// 			lc.map_dirty = false
// 		}
// 	}
// }

@(private)
SHADOW_MAP_VERTEX_SHADER :: `
#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 3) in vec4 attribJoints;
layout (location = 4) in vec4 attribWeights;

uniform mat4 matLightSpace;
uniform mat4 matModel;
uniform mat4 matModelLocal;
uniform mat4 matJoints[19];

uniform bool dynamicGeometry;

void main() {
	mat4 finalMatModel = mat4(1);
	if (dynamicGeometry) {
		mat4 matSkin = 
		attribWeights.x * matJoints[int(attribJoints.x)] +
		attribWeights.y * matJoints[int(attribJoints.y)] +
		attribWeights.z * matJoints[int(attribJoints.z)] +
		attribWeights.w * matJoints[int(attribJoints.w)];

		finalMatModel = matModelLocal * matSkin;
	} else {
		finalMatModel = matModel;
	}

	gl_Position = matLightSpace * finalMatModel * vec4(attribPosition, 1.0);
}
`
