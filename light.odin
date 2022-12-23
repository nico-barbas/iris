package iris

import "core:log"
import "core:math"
import "core:math/linalg"

MAX_SHADOW_MAPS :: 1
MAX_LIGHTS :: 32
MAX_CASCADES :: 3
SHADOW_MAP_BOUNDS_PADDING :: 0

Lighting_Context :: struct {
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
	lights:            [MAX_LIGHTS]Light_Uniform_Info,
	shadow_maps:       [MAX_SHADOW_MAPS][4]u32,
	projections:       [MAX_SHADOW_MAPS][MAX_CASCADES]Matrix4,
	cascades_distance: [MAX_SHADOW_MAPS][4]f32,
	ambient:           Color,
	light_count:       u32,
	shadow_map_count:  u32,
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
	camera:     ^Camera_Node,
	direction:  Vector3,
	color:      Color,
	options:    Light_Options,
	shadow_map: Shadow_Map,
}

Light_Option :: enum {
	Shadow_Map,
}

Light_Options :: distinct bit_set[Light_Option]

Shadow_Map :: struct {
	scale:             f32,
	distance:          f32,
	projection:        Matrix4,
	bounds:            Bounding_Box,
	dirty:             bool,
	cascade_count:     int,
	cascade_planes:    [MAX_CASCADES + 1][4]Vector3,
	cascades_distance: [MAX_CASCADES]f32,
	projections:       [MAX_CASCADES]Matrix4,
	views:             [MAX_CASCADES]Matrix4,
	view_projections:  [MAX_CASCADES]Matrix4,
	cascades:          [MAX_CASCADES]^Framebuffer,
	shader:            ^Shader,
}

init_lighting_context :: proc(ctx: ^Lighting_Context) {
	ctx.ambient = RENDER_CTX_DEFAULT_AMBIENT

	uniform_res := raw_buffer_resource(size_of(Light_Uniform_Data))
	ctx.uniform_memory = buffer_memory_from_buffer_resource(uniform_res)
	set_uniform_buffer_binding(ctx.uniform_memory.buf, u32(Render_Uniform_Kind.Lighting_Data))

}

update_lighting_context :: proc(ctx: ^Lighting_Context) {
	if ctx.dirty_uniform_data {
		lights: [MAX_LIGHTS]Light_Uniform_Info
		shadow_maps_ids: [MAX_SHADOW_MAPS][4]u32
		projections: [MAX_SHADOW_MAPS][MAX_CASCADES]Matrix4
		distances: [MAX_SHADOW_MAPS][4]f32

		for node, i in ctx.lights[:ctx.light_count] {
			light_position := translation_from_matrix(node.global_transform)
			lights[i] = Light_Uniform_Info {
				position = Vector4{light_position.x, light_position.y, light_position.z, 0},
				color = node.color,
				_kind = 0,
			}
		}
		for id, i in ctx.shadow_map_ids {
			light := ctx.lights[id]
			shadow_maps_ids[i] = {
				0 = u32(id),
				1 = u32(light.shadow_map.cascade_count),
			}

			for j in 0 ..< light.shadow_map.cascade_count {
				projections[i][j] = light.shadow_map.view_projections[j]
				distances[i][j] = light.shadow_map.cascades_distance[j]
			}
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
					cascades_distance = distances,
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

init_light_node :: proc(ctx: ^Lighting_Context, node: ^Light_Node, camera: ^Camera_Node) {
	node.name = "Light"
	node.id = Light_ID(ctx.light_count)
	node.local_bounds = BOUNDING_BOX_ZERO
	node.flags += {.Rendered, .Ignore_Culling, .Dirty_Transform}
	node.camera = camera
	node.direction = linalg.vector_normalize(node.direction)

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
		DEFAULT_SHADOW_MAP_FAR :: 10


		size := render_size()
		framebuffer_size := size * node.shadow_map.scale
		for i in 0 ..< node.shadow_map.cascade_count {
			map_res := framebuffer_resource(
				Framebuffer_Loader{
					attachments = {.Depth},
					width = int(framebuffer_size.x),
					height = int(framebuffer_size.y),
				},
			)
			node.shadow_map.cascades[i] = map_res.data.(^Framebuffer)
		}


		node.shadow_map.dirty = true
		node.shadow_map.shader = shadow_map_shader()


		if node.shadow_map.distance == 0 {
			node.shadow_map.distance = DEFAULT_SHADOW_MAP_FAR
		}
		node.shadow_map.projection = linalg.matrix4_perspective_f32(
			f32(RENDER_CTX_DEFAULT_FOVY),
			size.x / size.y,
			f32(RENDER_CTX_DEFAULT_NEAR),
			node.shadow_map.distance,
		)

		ctx.shadow_map_ids[ctx.shadow_map_count] = node.id
		ctx.shadow_map_count += 1
	}
}

// FIXME: Right now the shadow map is using the global projection matrix
update_light_node :: proc(ctx: ^Lighting_Context, node: ^Light_Node) {
	if .Shadow_Map in node.options {
		shadow_map := &node.shadow_map
		last := shadow_map.cascade_count
		shadow_map.cascade_planes[0] = froxel_plane(node.camera.inverse_proj_view, 0)
		shadow_map.cascade_planes[last] = froxel_plane(node.camera.inverse_proj_view, 1)
		out_of_bounds := false
		for i in 0 ..< 4 {
			corner_near := shadow_map.cascade_planes[0][i]
			corner_far := shadow_map.cascade_planes[last][i]
			out_of_bounds |= !point_in_aabb_bounding_box(shadow_map.bounds, corner_near)
			out_of_bounds |= !point_in_aabb_bounding_box(shadow_map.bounds, corner_far)
		}
		if out_of_bounds {
			log.debug("Out of shadow map bounds")

			shadow_map.dirty = true
			outer_corners: [8]Vector3
			for i in 0 ..< 4 {
				outer_corners[i] = shadow_map.cascade_planes[0][i]
				outer_corners[4 + i] = shadow_map.cascade_planes[last][i]
			}
			shadow_map.bounds = bounding_box_from_vertex_slice(outer_corners[:])
			shadow_map.bounds.min -= SHADOW_MAP_BOUNDS_PADDING
			shadow_map.bounds.max += SHADOW_MAP_BOUNDS_PADDING
			// node.view = linalg.matrix4_look_at_f32(center - node.direction, center, VECTOR_ONE)

			for i in 1 ..< shadow_map.cascade_count {
				t := f32(i) / f32(shadow_map.cascade_count)
				t *= t
				shadow_map.cascade_planes[i] = froxel_plane(
					shadow_map.cascade_planes[0],
					shadow_map.cascade_planes[last],
					t,
				)
				shadow_map.cascades_distance[i - 1] = t * RENDER_CTX_DEFAULT_FAR
			}
			for i in 0 ..< shadow_map.cascade_count {
				near_plane := shadow_map.cascade_planes[1]
				far_plane := shadow_map.cascade_planes[i + 1]
				froxel_center := Vector3{}
				for j in 0 ..< 4 {
					froxel_center += near_plane[j]
					froxel_center += far_plane[j]
				}
				froxel_center /= 8

				shadow_map.views[i] = linalg.matrix4_look_at_f32(
					froxel_center - node.direction,
					froxel_center,
					VECTOR_ONE,
				)
				min_x := math.INF_F32
				max_x := -math.INF_F32
				min_y := math.INF_F32
				max_y := -math.INF_F32
				min_z := math.INF_F32
				max_z := -math.INF_F32
				for j in 0 ..< 4 {
					corners := [2]Vector3{near_plane[j], far_plane[j]}
					for corner in corners {
						c := Vector4{corner.x, corner.y, corner.z, 1}
						c = shadow_map.views[i] * c
						min_x = min(min_x, c.x)
						max_x = max(max_x, c.x)
						min_y = min(min_y, c.y)
						max_y = max(max_y, c.y)
						min_z = min(min_z, c.z)
						max_z = max(max_z, c.z)
					}
				}

				min_x = min(min_x, min_y) - SHADOW_MAP_BOUNDS_PADDING
				max_x = max(max_x, max_y) + SHADOW_MAP_BOUNDS_PADDING
				min_y = min_x
				max_y = max_x
				min_z -= 20
				max_z += 20
				shadow_map.projections[i] = linalg.matrix_ortho3d_f32(
					min_x,
					max_x,
					min_y,
					max_y,
					min_z,
					max_z,
				)
				shadow_map.view_projections[i] = shadow_map.projections[i] * shadow_map.views[i]
			}
		}
	}
}

shadow_map_pass :: proc(
	node: ^Light_Node,
	geometry: [2][]Render_Command,
) -> [MAX_CASCADES]^Texture {
	STATIC_INDEX :: 0
	DYNAMIC_INDEX :: 1

	if node.shadow_map.dirty {
		log.debug("Redraw shadow map")
		static_shadow_map_pass(node, geometry[STATIC_INDEX])
		dynamic_shadow_map_pass(node, geometry[DYNAMIC_INDEX])
	}

	cascaded_maps: [MAX_CASCADES]^Texture
	for i in 0 ..< node.shadow_map.cascade_count {
		cascaded_maps[i] = framebuffer_texture(node.shadow_map.cascades[i], .Depth)
	}
	return cascaded_maps
}

static_shadow_map_pass :: proc(node: ^Light_Node, geometry: []Render_Command) {
	for i in 0 ..< node.shadow_map.cascade_count {
		cascade := node.shadow_map.cascades[i]
		bind_framebuffer(cascade)
		bind_shader(node.shadow_map.shader)
		defer {
			default_framebuffer()
			default_shader()
		}

		clear_framebuffer(cascade)
		set_viewport(Rectangle{0, 0, f32(cascade.width), f32(cascade.height)})

		b := false
		set_shader_uniform(
			node.shadow_map.shader,
			"matLightSpace",
			&node.shadow_map.view_projections[i][0][0],
		)
		set_shader_uniform(node.shadow_map.shader, "dynamicGeometry", &b)
		render_statics(node.shadow_map.shader, geometry)
	}
}

dynamic_shadow_map_pass :: proc(node: ^Light_Node, geometry: []Render_Command) {
	for i in 0 ..< node.shadow_map.cascade_count {
		cascade := node.shadow_map.cascades[i]
		bind_framebuffer(cascade)
		bind_shader(node.shadow_map.shader)
		defer {
			default_framebuffer()
			default_shader()
		}

		set_viewport(Rectangle{0, 0, f32(cascade.width), f32(cascade.height)})
		set_shader_uniform(
			node.shadow_map.shader,
			"matLightSpace",
			&node.shadow_map.view_projections[i][0][0],
		)
		render_dynamics(node.shadow_map.shader, geometry)
	}
}

@(private)
render_dynamics :: proc(shader: ^Shader, geometry: []Render_Command) {
	for cmd in geometry {
		c := cmd.(Render_Mesh_Command)
		if .Cast_Shadows not_in c.options {
			continue
		}
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
		if .Cast_Shadows not_in c.options {
			continue
		}
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
