package iris

import "core:log"
import "core:mem"
import "core:slice"
import "core:math"
import "core:math/linalg"

import "gltf"
import "allocators"

Scene :: struct {
	free_list:          allocators.Free_List_Allocator,
	allocator:          mem.Allocator,
	name:               string,
	nodes:              [dynamic]^Node,
	roots:              [dynamic]^Node,

	// Specific states
	flags:              Scene_Flags,
	main_camera:        ^Camera_Node,
	lighting:           Lighting_Context,

	// Debug states
	debug_shader:       ^Shader,
	debug_attributes:   ^Attributes,
	debug_vertices:     Buffer_Memory,
	debug_indices:      Buffer_Memory,
	debug_vertex_slice: []f32,
	debug_index_slice:  []u32,
	d_v_count:          int,
	d_i_count:          int,
	d_i_offset:         int,
}

Scene_Flags :: distinct bit_set[Scene_Flag]

Scene_Flag :: enum {
	Draw_Debug_Collisions,
}

Node :: struct {
	name:             string,
	scene:            ^Scene,
	flags:            Node_Flags,
	local_transform:  Matrix4,
	global_transform: Matrix4,
	local_bounds:     Bounding_Box,
	global_bounds:    Bounding_Box,
	children_bounds:  Bounding_Box,
	visibility:       Collision_Result,
	parent:           ^Node,
	children:         [dynamic]^Node,
	user_data:        rawptr,
	derived:          Any_Node,
}

Node_Flags :: distinct bit_set[Node_Flag]

Node_Flag :: enum {
	Active,
	Root_Node,
	Dirty_Transform,
	Dirty_Bounds,
	Rendered,
	Ignore_Culling,
}

Any_Node :: union {
	^Empty_Node,
	^Camera_Node,
	^Light_Node,
	^Model_Node,
	^Model_Group_Node,
	^Skin_Node,
	^Canvas_Node,
	^User_Interface_Node,
}

Empty_Node :: struct {
	using base: Node,
}

init_scene :: proc(scene: ^Scene, allocator := context.allocator) {
	DEFAULT_SCENE_ALLOCATOR_SIZE :: mem.Megabyte * 50
	DEFAULT_SCENE_CAPACITY :: 20

	DEBUG_BATCH_CAP :: 1000
	DEBUG_VERTEX_SIZE :: size_of(Vector3) + size_of(Color)

	buf := make([]byte, DEFAULT_SCENE_ALLOCATOR_SIZE, allocator)
	allocators.init_free_list_allocator(&scene.free_list, buf, .Find_Best, 8)
	scene.allocator = allocators.free_list_allocator(&scene.free_list)

	context.allocator = scene.allocator
	scene.nodes = make([dynamic]^Node, 0, DEFAULT_SCENE_CAPACITY)
	scene.roots = make([dynamic]^Node, 0, DEFAULT_SCENE_CAPACITY)

	init_lighting_context(&scene.lighting)

	if .Draw_Debug_Collisions in scene.flags {
		scene.debug_vertex_slice = make([]f32, DEBUG_BATCH_CAP * 5)
		scene.debug_index_slice = make([]u32, DEBUG_BATCH_CAP)

		debug_vertices_res := raw_buffer_resource(DEBUG_BATCH_CAP * DEBUG_VERTEX_SIZE)
		scene.debug_vertices = buffer_memory_from_buffer_resource(debug_vertices_res)

		debug_indices_res := raw_buffer_resource(DEBUG_BATCH_CAP * size_of(u32))
		scene.debug_indices = buffer_memory_from_buffer_resource(debug_indices_res)

		scene.debug_attributes = attributes_from_layout(
			Attribute_Layout{
				enabled = {.Position, .Color},
				accessors = {
					Attribute_Kind.Position = Buffer_Data_Type{
						kind = .Float_32,
						format = .Vector3,
					},
					Attribute_Kind.Color = Buffer_Data_Type{kind = .Float_32, format = .Vector4},
				},
			},
			.Interleaved,
		)


		// FIXME: Check if shader has already been loaded
		debug_shader_res := shader_resource(
			Shader_Loader{
				name = "debug_scene",
				kind = .Byte,
				stages = {
					Shader_Stage.Vertex = Shader_Stage_Loader{source = DEBUG_VERTEX_SHADER},
					Shader_Stage.Fragment = Shader_Stage_Loader{source = DEBUG_FRAGMENT_SHADER},
				},
			},
		)
		scene.debug_shader = debug_shader_res.data.(^Shader)
	}
}

destroy_scene :: proc(scene: ^Scene) {
	free_all(scene.allocator)
	delete(scene.free_list.data)
	delete(scene.name)
}

set_scene_main_camera :: proc(scene: ^Scene, camera: ^Camera_Node) {
	traverse_node :: proc(node: ^Node, camera: ^Camera_Node) {
		if n, ok := node.derived.(^Light_Node); ok {
			n.camera = camera
		}

		for child in node.children {
			traverse_node(child, camera)
		}
	}

	if scene.main_camera != nil {
		scene.main_camera.derived_flags -= {.Main_Camera}
	}
	scene.main_camera = camera
	camera.derived_flags += {.Main_Camera}
	for root in scene.roots {
		traverse_node(root, camera)
	}
}

update_scene :: proc(scene: ^Scene, dt: f32) {
	traverse_node :: proc(node: ^Node, parent_transform: Matrix4, dt: f32) {
		dirty := .Dirty_Transform in node.flags
		if dirty {
			node.global_transform = parent_transform * node.local_transform
			node.flags -= {.Dirty_Transform}
			node.flags += {.Dirty_Bounds}
		}
		switch n in node.derived {
		case ^Empty_Node:

		case ^Camera_Node:
			update_camera_node(n, false)

		case ^Light_Node:
			// if dirty {
			update_light_node(&n.scene.lighting, n)
			set_lighting_context_dirty(&n.scene.lighting)
		// if .Shadow_Map in n.options {
		// 	shadow_map := n.shadow_map.?
		// 	shadow_map.dirty = true
		// 	n.shadow_map = shadow_map
		// }
		// }

		case ^Model_Node:
			if dirty && .Cast_Shadows in n.options {
				// TODO: set shadow map dirty
				n.scene.lighting.dirty_shadow_maps = true
			}

		case ^Model_Group_Node:

		case ^Skin_Node:
			update_skin_node(n, dt)

		case ^Canvas_Node:
			prepare_canvas_node_render(n)

		case ^User_Interface_Node:
			render_ui_node(n)
		}
		for child in node.children {
			if dirty {
				child.flags += {.Dirty_Transform}
			}
			traverse_node(child, node.global_transform, dt)
		}
	}

	compute_node_bounds :: proc(node: ^Node) -> (bounds: Bounding_Box) {
		if len(node.children) > 0 {
			bounds := make([]Bounding_Box, len(node.children) + 1, context.temp_allocator)
			for child, i in node.children {
				bounds[i] = compute_node_bounds(child)
			}
			node_bounds: Bounding_Box
			for point, j in node.local_bounds.points {
				p: Vector4
				p.xyz = point.xyz
				p.w = 1
				result := node.global_transform * p
				node_bounds.points[j] = result.xyz
			}
			bounds[len(bounds) - 1] = node_bounds

			node.global_bounds = bounding_box_from_bounds_slice(bounds)
		} else {
			for point, i in node.local_bounds.points {
				p: Vector4
				p.xyz = point.xyz
				p.w = 1
				result := node.global_transform * p
				node.global_bounds.points[i] = result.xyz

			}
			min: Vector4
			min.xyz = node.local_bounds.min.xyz
			min.w = 1
			node.global_bounds.min = (node.global_transform * min).xyz

			max: Vector4
			max.xyz = node.local_bounds.max.xyz
			max.w = 1
			node.global_bounds.max = (node.global_transform * max).xyz
		}
		node.flags -= {.Dirty_Bounds}
		bounds = node.global_bounds
		return
	}

	for root in scene.roots {
		traverse_node(root, linalg.MATRIX4F32_IDENTITY, dt)
		compute_node_bounds(root)
		if scene.main_camera != nil {
			camera_cull_nodes(scene.main_camera, scene.roots[:])
		}
	}
}

render_scene :: proc(scene: ^Scene) {
	render_debug_node_info :: proc(data: rawptr) {
		scene := cast(^Scene)data
		bind_shader(scene.debug_shader)
		bind_attributes(scene.debug_attributes)
		defer {
			default_shader()
			default_attributes()
		}

		link_interleaved_attributes_vertices(scene.debug_attributes, scene.debug_vertices.buf)
		link_attributes_indices(scene.debug_attributes, scene.debug_indices.buf)

		if scene.d_i_count > 0 {
			send_buffer_data(
				&scene.debug_vertices,
				Buffer_Source{
					data = &scene.debug_vertex_slice[0],
					byte_size = scene.d_v_count * size_of(f32),
				},
			)
			send_buffer_data(
				&scene.debug_indices,
				Buffer_Source{
					data = &scene.debug_index_slice[0],
					byte_size = scene.d_i_count * size_of(u32),
				},
			)
			draw_lines(scene.d_i_count)
		}
		scene.d_v_count = 0
		scene.d_i_count = 0
		scene.d_i_offset = 0
	}

	traverse_node :: proc(scene: ^Scene, node: ^Node) {
		if .Ignore_Culling in node.flags || node.visibility != .Outside {
			if .Rendered in node.flags {
				switch n in node.derived {
				case ^Empty_Node, ^Camera_Node:

				case ^Light_Node:
					if .Shadow_Map in n.options {
						// unimplemented("TODO: send the light to the renderer to do a shadow pass")
						push_draw_command(n, .Shadow_Pass)
					}

				case ^Model_Node:
					for mesh, i in n.meshes {
						push_draw_command(
							Render_Mesh_Command{
								mesh = mesh,
								global_transform = n.global_transform,
								material = n.materials[i],
								options = n.options,
							},
							queue_kind_from_rendering_options(n.options),
						)
						if .Geomtry_Modified in n.derived_flags {
							n.derived_flags -= {.Geomtry_Modified}
						}
					}

				case ^Model_Group_Node:
					for mesh, i in n.meshes {
						push_draw_command(
							Render_Mesh_Command{
								mesh = mesh,
								global_transform = n.global_transform,
								material = n.materials[i],
								options = n.options + {.Instancing},
								instancing_info = Instancing_Info{
									memory = n.transform_buf,
									count = n.count,
								},
							},
							queue_kind_from_rendering_options(n.options),
						)
						if .Geomtry_Modified in n.derived_flags {
							n.derived_flags -= {.Geomtry_Modified}
						}
					}

				case ^Skin_Node:
					if n.target.visibility != .Outside {
						for mesh, i in n.target.meshes {
							joint_matrices := skin_node_joint_matrices(n)
							def := .Transparent not_in n.target.options
							push_draw_command(
								Render_Mesh_Command{
									mesh = mesh,
									global_transform = n.target.global_transform,
									local_transform = n.target.local_transform,
									joints = joint_matrices,
									material = n.target.materials[i],
									options = n.target.options,
								},
								queue_kind_from_rendering_options(n.target.options),
							)
						}
					}

				case ^Canvas_Node:
					push_draw_command(
						Render_Custom_Command{
							data = n,
							render_proc = flush_canvas_node_buffers,
							options = {},
						},
						.Other,
					)

				case ^User_Interface_Node:
				}
			}

			for child in node.children {
				traverse_node(scene, child)
			}
		}


		if .Draw_Debug_Collisions in scene.flags {
			debug_line :: proc(scene: ^Scene, p1, p2: Bounding_Point) {
				i_off := scene.d_i_offset
				start := scene.d_i_count

				scene.debug_index_slice[start] = u32(i_off) + u32(p1)
				scene.debug_index_slice[start + 1] = u32(i_off) + u32(p2)
				scene.d_i_count += 2
			}
			for point in node.global_bounds.points {
				OUT_COLOR :: Color{100, 0, 0, 100}
				PARTIAL_COLOR :: Color{100, 0, 100, 100}
				IN_COLOR :: Color{100, 100, 100, 100}

				clr: Color
				switch node.visibility {
				case .Outside:
					clr = OUT_COLOR
				case .Partial_In:
					clr = PARTIAL_COLOR
				case .Full_In:
					clr = IN_COLOR
				}

				index := scene.d_v_count
				scene.debug_vertex_slice[index] = point.x
				scene.debug_vertex_slice[index + 1] = point.y
				scene.debug_vertex_slice[index + 2] = point.z
				scene.debug_vertex_slice[index + 3] = clr.r
				scene.debug_vertex_slice[index + 4] = clr.g
				scene.debug_vertex_slice[index + 5] = clr.b
				scene.debug_vertex_slice[index + 6] = clr.a

				scene.d_v_count += 7
			}

			debug_line(scene, Bounding_Point.Near_Bottom_Left, Bounding_Point.Near_Bottom_Right)
			debug_line(scene, Bounding_Point.Near_Bottom_Right, Bounding_Point.Near_Up_Right)
			debug_line(scene, Bounding_Point.Near_Up_Right, Bounding_Point.Near_Up_Left)
			debug_line(scene, Bounding_Point.Near_Up_Left, Bounding_Point.Near_Bottom_Left)


			debug_line(scene, Bounding_Point.Far_Bottom_Left, Bounding_Point.Far_Bottom_Right)
			debug_line(scene, Bounding_Point.Far_Bottom_Right, Bounding_Point.Far_Up_Right)
			debug_line(scene, Bounding_Point.Far_Up_Right, Bounding_Point.Far_Up_Left)
			debug_line(scene, Bounding_Point.Far_Up_Left, Bounding_Point.Far_Bottom_Left)

			debug_line(scene, Bounding_Point.Near_Bottom_Left, Bounding_Point.Far_Bottom_Left)
			debug_line(scene, Bounding_Point.Near_Bottom_Right, Bounding_Point.Far_Bottom_Right)
			debug_line(scene, Bounding_Point.Near_Up_Right, Bounding_Point.Far_Up_Right)
			debug_line(scene, Bounding_Point.Near_Up_Left, Bounding_Point.Far_Up_Left)
			scene.d_i_offset += BONDING_BOX_POINT_LEN
		}

	}

	for root in scene.roots {
		traverse_node(scene, root)
	}
	update_lighting_context(&scene.lighting)
	if .Draw_Debug_Collisions in scene.flags {
		push_draw_command(
			Render_Custom_Command{
				data = scene,
				render_proc = render_debug_node_info,
				options = {},
			},
			.Forward_Geometry,
		)
	}
}

new_node :: proc(scene: ^Scene, $T: typeid, local := linalg.MATRIX4F32_IDENTITY) -> ^T {
	node := new(T, scene.allocator)
	node.derived = node
	node.scene = scene

	node.local_transform = local
	init_node(scene, node)
	append(&scene.nodes, node)
	return node
}

new_node_from :: proc(scene: ^Scene, from: $T, local := linalg.MATRIX4F32_IDENTITY) -> ^T {
	node := new_clone(from, scene.allocator)
	node.derived = node
	node.scene = scene

	node.local_transform = local
	init_node(scene, node)
	append(&scene.nodes, node)
	return node
}

init_node :: proc(scene: ^Scene, node: ^Node) {
	node.children.allocator = scene.allocator
	switch n in node.derived {
	case ^Empty_Node:
		node.name = "Node"
		node.local_bounds = BOUNDING_BOX_ZERO
	case ^Camera_Node:
		node.name = "Camera"
		node.local_bounds = BOUNDING_BOX_ZERO
		node.flags += {.Ignore_Culling}
		n.max_pitch = 190 if n.max_pitch == 0 else n.max_pitch
		if n.rotation_proc == nil {
			n.rotation_proc = proc() -> (bool, Vector2) {return false, 0}
		}
		if n.distance_proc == nil {
			n.distance_proc = proc() -> (bool, f32) {return false, 0}
		}
		if n.position_proc == nil {
			n.position_proc = proc() -> (bool, f32, f32) {return false, 0, 0}
		}

		if .Main_Camera in n.derived_flags {
			set_scene_main_camera(scene, n)
		}
		update_camera_node(n, true)

	case ^Light_Node:
		init_light_node(&scene.lighting, n, scene.main_camera)

	case ^Model_Node:
		node.name = "Model"
		n.meshes.allocator = scene.allocator
		n.materials.allocator = scene.allocator
		n.flags += {.Rendered}
		if .Dynamic not_in n.options {
			n.options += {.Static}
		}

	case ^Model_Group_Node:
		node.name = "Model_Group"
		node.local_bounds = BOUNDING_BOX_ZERO
		n.flags += {.Rendered}

	case ^Skin_Node:
		node.name = "Skin"
		node.local_bounds = BOUNDING_BOX_ZERO
		n.flags -= {.Rendered}
		n.flags += {.Ignore_Culling}
		n.joint_roots.allocator = scene.allocator
		n.joint_lookup.allocator = scene.allocator
		n.animations.allocator = scene.allocator

	case ^Canvas_Node:
		node.name = "Canvas"
		node.local_bounds = BOUNDING_BOX_ZERO
		n.flags += {.Rendered, .Ignore_Culling}
		init_canvas_node(n)

	case ^User_Interface_Node:
		node.name = "User Interface"
		node.local_bounds = BOUNDING_BOX_ZERO
		n.flags += {.Rendered, .Ignore_Culling}
		n.commands.allocator = scene.allocator
		n.roots.allocator = scene.allocator
		init_ui_node(n, scene.allocator)
	}
}

insert_node :: proc(scene: ^Scene, node: ^Node, parent: ^Node = nil) {
	if parent == nil {
		node.flags += {.Root_Node}
		append(&scene.roots, node)
	} else {
		append(&parent.children, node)
	}
	node.flags += {.Dirty_Transform}
}

destroy_node :: proc(scene: ^Scene, node: ^Node) {
	for child in node.children {
		destroy_node(scene, child)
	}
	if len(node.children) > 0 {
		delete(node.children)
	}
	delete(node.name)

	for scene_node, i in scene.nodes {
		if node == scene_node {
			ordered_remove(&scene.nodes, i)
		}
	}

	if .Root_Node in node.flags {
		for root, i in scene.roots {
			if node == root {
				ordered_remove(&scene.roots, i)
			}
		}
	}

	switch n in node.derived {
	case ^Empty_Node:
		free(n)

	case ^Camera_Node:
		free(n)

	case ^Light_Node:
		free(n)

	case ^Model_Node:
		free(n)

	case ^Model_Group_Node:
		free_resource(n.transform_res, true)
		free(n)

	case ^Skin_Node:
		delete(n.joints)
		delete(n.joint_roots)
		delete(n.joint_lookup)
		delete(n.joint_matrices)
		for key in n.animations {
			destroy_animation_player(&n.animations[key])
		}
		delete(n.animations)
		free(n)

	case ^Canvas_Node:
		unimplemented()
	// free(n)

	case ^User_Interface_Node:
		unimplemented()
	// free(n)

	}
}

node_offset_transform :: proc(node: ^Node, t: Transform) {
	transform := linalg.matrix4_from_trs_f32(t = t.translation, r = t.rotation, s = t.scale)
	node.local_transform = linalg.matrix_mul(transform, node.local_transform)
	node.flags += {.Dirty_Transform}
}

node_local_transform :: proc(node: ^Node, t: Transform) {
	node.local_transform = linalg.matrix4_from_trs_f32(
		t = t.translation,
		r = t.rotation,
		s = t.scale,
	)
	node.flags += {.Dirty_Transform}
}

Camera_Node :: struct {
	using base:        Node,
	derived_flags:     Camera_Flags,
	pitch:             f32,
	yaw:               f32,
	position:          Vector3,
	target:            Vector3,
	target_distance:   f32,
	target_rotation:   f32,

	// Pre-computed view matrices
	view:              Matrix4,
	inverse_proj_view: Matrix4,

	// Input states
	min_pitch:         f32,
	max_pitch:         f32,
	min_distance:      f32,
	distance_speed:    f32,
	position_speed:    f32,
	rotation_proc:     proc() -> (trigger: bool, delta: Vector2),
	distance_proc:     proc() -> (trigger: bool, displacement: f32),
	position_proc:     proc() -> (trigger: bool, fb: f32, lr: f32),
}

Camera_Flags :: distinct bit_set[Camera_Flag]

Camera_Flag :: enum {
	Main_Camera,
	Frustum_Cull,
}

new_default_camera :: proc(scene: ^Scene) -> ^Camera_Node {
	camera := new_node_from(scene, Camera_Node {
			derived_flags = {.Main_Camera, .Frustum_Cull},
			pitch = 45,
			target = {0, 0.5, 0},
			target_distance = 10,
			target_rotation = 90,
			min_pitch = 10,
			max_pitch = 170,
			min_distance = 2,
			distance_speed = 1,
			position_speed = 12,
			rotation_proc = proc() -> (trigger: bool, delta: Vector2) {
				m_right := mouse_button_state(.Right)
				if .Pressed in m_right {
					trigger = true
					delta = mouse_delta()
				} else {
					KEY_CAMERA_PAN_SPEED :: 2
					left_state := key_state(.Q)
					right_state := key_state(.E)
					if .Pressed in left_state {
						trigger = true
						delta = {KEY_CAMERA_PAN_SPEED, 0}
					} else if .Pressed in right_state {
						trigger = true
						delta = {-KEY_CAMERA_PAN_SPEED, 0}
					}
				}
				return
			},
			distance_proc = proc() -> (trigger: bool, displacement: f32) {
				displacement = f32(mouse_scroll())
				trigger = displacement != 0
				return
			},
			position_proc = proc() -> (trigger: bool, fb: f32, lr: f32) {
				if .Pressed in key_state(.W) {
					trigger = true
					fb = 1
				} else if .Pressed in key_state(.S) {
					trigger = true
					fb = -1
				}

				if .Pressed in key_state(.A) {
					trigger = true
					lr = -1
				} else if .Pressed in key_state(.D) {
					trigger = true
					lr = 1
				}
				return
			},
		})
	return camera
}

update_camera_node :: proc(camera: ^Camera_Node, force_refresh: bool) {
	dirty: bool
	r_delta: Vector2
	d_delta: f32
	fb_delta: f32
	lr_delta: f32

	d: bool
	d, r_delta = camera.rotation_proc()
	dirty |= d
	d, d_delta = camera.distance_proc()
	dirty |= d
	d, fb_delta, lr_delta = camera.position_proc()
	dirty |= d

	displacement := Vector2{fb_delta, lr_delta}
	if dirty || force_refresh {
		if displacement != 0 {
			dt := f32(elapsed_time())
			displacement = linalg.vector_normalize(displacement)
			forward := camera.target - camera.position
			forward.y = 0
			forward = linalg.vector_normalize(forward)
			camera.target += forward * (displacement.x * dt * camera.position_speed)

			right := linalg.vector_cross3(forward, VECTOR_UP)
			camera.target += right * (displacement.y * dt * camera.position_speed)
		}
		camera.target_distance = max(camera.target_distance - d_delta, camera.min_distance)
		camera.target_rotation += (r_delta.x * 0.5)
		camera.pitch -= (r_delta.y * 0.5)
		camera.pitch = clamp(camera.pitch, camera.min_pitch, camera.max_pitch)

		pitch_in_rad := math.to_radians(camera.pitch)
		target_rot_in_rad := math.to_radians(camera.target_rotation)
		h_dist := camera.target_distance * math.sin(pitch_in_rad)
		v_dist := camera.target_distance * math.cos(pitch_in_rad)
		camera.position = {
			camera.target.x - (h_dist * math.cos(target_rot_in_rad)),
			camera.target.y + (v_dist),
			camera.target.z - (h_dist * math.sin(target_rot_in_rad)),
		}

		camera.view = linalg.matrix4_look_at_f32(camera.position, camera.target, VECTOR_UP)
		camera.inverse_proj_view = linalg.matrix4_inverse_f32(projection_matrix() * camera.view)
		if .Main_Camera in camera.derived_flags {
			view_position(camera.position)
			view_target(camera.target)
		}
	}
}

camera_mouse_ray :: proc(camera: ^Camera_Node) -> (result: Ray) {
	m_pos := mouse_position()
	r_size := render_size()
	proj := projection_matrix()
	view := view_matrix()
	inverse_proj := linalg.matrix4_inverse_f32(proj)
	inverse_view := linalg.matrix4_inverse_f32(view)

	ndc := Vector4{(m_pos.x / r_size.x) * 2.0 - 1.0, 1.0 - (m_pos.y / r_size.y) * 2.0, -1.0, 1.0}
	ray_eye := inverse_proj * ndc
	ray_eye.z = -1
	ray_eye.w = 0

	ray_world := linalg.vector_normalize(inverse_view * ray_eye).xyz

	result = ray(camera.position, Vector3(ray_world))
	return
}

camera_cull_nodes :: proc(camera: ^Camera_Node, roots: []^Node) {
	cull_node :: proc(frustum: Frustum, node: ^Node) {
		cull_children := true
		if .Ignore_Culling not_in node.flags {
			node.visibility = bounding_box_in_frustum(frustum, node.global_bounds)

			switch node.visibility {
			case .Outside, .Full_In:
				cull_children = false
				for child in node.children {
					child.visibility = node.visibility
				}
			case .Partial_In:
			}
		}

		if cull_children {
			for child in node.children {
				cull_node(frustum, child)
			}
		}
	}

	FRUSTUM_FLAGS :: Camera_Flags{.Main_Camera, .Frustum_Cull}
	if FRUSTUM_FLAGS <= camera.derived_flags {
		camera_frustum := frustum(
			camera.position,
			camera.target,
			RENDER_CTX_DEFAULT_NEAR,
			RENDER_CTX_DEFAULT_FAR,
			RENDER_CTX_DEFAULT_FOVY,
			app.render_ctx.aspect_ratio,
		)

		for root in roots {
			cull_node(camera_frustum, root)
		}
	}
}

Model_Node :: struct {
	using base:    Node,
	options:       Rendering_Options,
	derived_flags: Model_Node_Flags,
	meshes:        [dynamic]^Mesh,
	materials:     [dynamic]^Material,
}

Model_Node_Flags :: distinct bit_set[Model_Node_Flag]

Model_Node_Flag :: enum {
	Geomtry_Modified,
}

Model_Loader :: struct {
	shader_ref:  union {
		string,
		^Shader,
	},
	shader_spec: ^Shader_Specialization,
	flags:       Model_Loader_Flags,
	options:     Rendering_Options,
	rigged:      bool,
}

Model_Loader_Flags :: distinct bit_set[Model_Loader_Flag]

Model_Loader_Flag :: enum {
	Flip_Normals,
	Load_Position,
	Load_Normal,
	Load_Tangent,
	Load_Joints0,
	Load_Weights0,
	Load_TexCoord0,

	// Specific data
	Load_Bones,
	Load_Children,
}

Model_Loading_Error :: enum {
	None,
	Invalid_Node,
	Missing_Mesh_Indices,
	Missing_Mesh_Attribute,
}

model_node_from_gltf :: proc(
	model: ^Model_Node,
	loader: Model_Loader,
	node: ^gltf.Node,
) -> (
	err: Model_Loading_Error,
) {
	if node.mesh != nil {
		data := node.mesh.?
		model.local_transform = node.local_transform

		shader: ^Shader
		switch ref in loader.shader_ref {
		case string:
			exist: bool
			shader, exist = shader_from_name(ref)
		case ^Shader:
			shader = ref
		}

		meshes_bounds := make([]Bounding_Box, len(data.primitives), context.temp_allocator)
		for _, i in data.primitives {
			begin_temp_allocation()

			mesh_res, mesh_bounds, err := load_mesh_from_gltf(
				loader = loader,
				p = &data.primitives[i],
			)
			assert(err == nil)
			mesh := mesh_res.data.(^Mesh)

			material, exist := material_from_name(data.primitives[i].material.name)
			if !exist {
				material = load_material_from_gltf(data.primitives[i].material^)
			}
			material.shader = shader
			material.specialization = loader.shader_spec

			end_temp_allocation()
			append(&model.meshes, mesh)
			append(&model.materials, material)
			meshes_bounds[i] = mesh_bounds
		}

		model.options += loader.options
		model.local_bounds = bounding_box_from_bounds_slice(meshes_bounds)
		node_local_transform(model, transform_from_matrix(node.local_transform))

		// FIXME: Not the prettiest way to handle that
		// Should recursively check the children for deep mesh nodes
		if .Load_Children in loader.flags {
			for child in node.children {
				if child.mesh != nil {
					child_model := new_node(model.scene, Model_Node)
					model_node_from_gltf(child_model, loader, child)
					insert_node(model.scene, child_model, model)
				}
			}
		}
	} else {
		err = .Invalid_Node
	}
	return
}

load_mesh_from_gltf :: proc(
	loader: Model_Loader,
	p: ^gltf.Primitive,
) -> (
	resource: ^Resource,
	bounds: Bounding_Box,
	err: Model_Loading_Error,
) {
	if p.indices == nil {
		log.fatalf("%s: Only support indexed primitive", App_Module.Mesh)
		err = .Missing_Mesh_Indices
		return
	}
	indices: []u32
	mesh_loader: Mesh_Loader
	mesh_loader.format = .Packed_Blocks

	#partial switch data in p.indices.data {
	case []u16:
		indices = make([]u32, len(data), context.temp_allocator)
		for index, i in data {
			indices[i] = u32(index)
		}
	case []u32:
		indices = data
	case:
		unreachable()
	}

	mesh_loader.indices = Buffer_Source {
		data = &indices[0],
		byte_size = size_of(u32) * len(indices),
		accessor = Buffer_Data_Type{kind = .Unsigned_32, format = .Scalar},
	}
	mesh_loader.index_count = len(indices)

	if .Load_Position in loader.flags {
		if gltf_position, has_position := p.attributes[gltf.POSITION]; has_position {
			data := gltf_position.data.data.([]gltf.Vector3f32)
			size := size_of(gltf.Vector3f32) * int(gltf_position.data.count)
			mesh_loader.enabled += {.Position}
			mesh_loader.sources[Attribute_Kind.Position] = Buffer_Source {
				data = &data[0],
				byte_size = size,
				accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector3},
			}
			mesh_loader.byte_size += size

			bounds = bounding_box_from_vertex_slice(data)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Normal in loader.flags {
		if gltf_normal, has_normal := p.attributes[gltf.NORMAL]; has_normal {
			data := gltf_normal.data.data.([]gltf.Vector3f32)
			size := size_of(gltf.Vector3f32) * int(gltf_normal.data.count)
			mesh_loader.enabled += {.Normal}
			mesh_loader.sources[Attribute_Kind.Normal] = Buffer_Source {
				data = &data[0],
				byte_size = size,
				accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector3},
			}
			mesh_loader.byte_size += size
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Tangent in loader.flags {
		if gltf_tangent, has_tangent := p.attributes[gltf.TANGENT]; has_tangent {
			data := gltf_tangent.data.data.([]gltf.Vector4f32)
			size := size_of(gltf.Vector4f32) * int(gltf_tangent.data.count)
			mesh_loader.enabled += {.Tangent}
			mesh_loader.sources[Attribute_Kind.Tangent] = Buffer_Source {
				data = &data[0],
				byte_size = size,
				accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector4},
			}
			mesh_loader.byte_size += size
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Joints0 in loader.flags {
		if gltf_joints, has_joints := p.attributes[gltf.JOINTS_0]; has_joints {
			data := gltf_joints.data.data.([]gltf.Vector4u16)
			joints := make([]Vector4, len(data), context.temp_allocator)
			for joint_ids, i in data {
				joints[i].x = f32(joint_ids.x)
				joints[i].y = f32(joint_ids.y)
				joints[i].z = f32(joint_ids.z)
				joints[i].w = f32(joint_ids.w)
			}
			size := size_of(Vector4) * len(joints)
			mesh_loader.enabled += {.Joint}
			mesh_loader.sources[Attribute_Kind.Joint] = Buffer_Source {
				data = &joints[0],
				byte_size = size,
				accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector4},
			}
			mesh_loader.byte_size += size
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Weights0 in loader.flags {
		if gltf_weights, has_weights := p.attributes[gltf.WEIGHTS_0]; has_weights {
			data := gltf_weights.data.data.([]gltf.Vector4f32)
			size := size_of(gltf.Vector4f32) * int(gltf_weights.data.count)
			mesh_loader.enabled += {.Weight}
			mesh_loader.sources[Attribute_Kind.Weight] = Buffer_Source {
				data = &data[0],
				byte_size = size,
				accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector4},
			}
			mesh_loader.byte_size += size
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_TexCoord0 in loader.flags {
		if gltf_texcoord, has_texcoord := p.attributes[gltf.TEXCOORD_0]; has_texcoord {
			data := gltf_texcoord.data.data.([]gltf.Vector2f32)
			size := size_of(gltf.Vector2f32) * int(gltf_texcoord.data.count)
			mesh_loader.enabled += {.Tex_Coord}
			mesh_loader.sources[Attribute_Kind.Tex_Coord] = Buffer_Source {
				data = &data[0],
				byte_size = size,
				accessor = Buffer_Data_Type{kind = .Float_32, format = .Vector2},
			}
			mesh_loader.byte_size += size
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	resource = mesh_resource(mesh_loader)
	return
}

model_node_from_mesh :: proc(scene: ^Scene, mesh: ^Mesh, material: ^Material) -> ^Model_Node { 	// transform: Transform,
	model := new_node(scene, Model_Node)
	append(&model.meshes, mesh)
	append(&model.materials, material)
	return model
}

// flag_model_node_as_dynamic :: proc(model: ^Model_Node) {
// 	model.options -= {.Static}
// 	model.options += {.Dynamic}
// }

// flag_model_node_as_static :: proc(model: ^Model_Node) {
// 	model.options += {.Static}
// 	model.options -= {.Dynamic}
// }

Model_Group_Node :: struct {
	using model:   Model_Node,
	count:         int,
	transform_res: ^Resource,
	transform_buf: Buffer_Memory,
}

resize_group_node_transforms :: proc(group: ^Model_Group_Node, count: int) {
	if group.transform_res != nil {
		free_resource(group.transform_res)
		group.transform_res = nil
	}
	group.count = count
	begin_temp_allocation()
	instance_identity := make([]Matrix4, count, context.temp_allocator)
	for i in 0 ..< count {
		instance_identity[i] = linalg.MATRIX4F32_IDENTITY
	}
	group.transform_res = raw_buffer_resource(size_of(Matrix4) * count)
	group.transform_buf = buffer_memory_from_buffer_resource(group.transform_res)
	send_buffer_data(
		&group.transform_buf,
		Buffer_Source{
			data = &instance_identity[0][0][0],
			byte_size = count * size_of(Matrix4),
			accessor = Buffer_Data_Type{kind = .Float_32, format = .Mat4},
		},
	)
	end_temp_allocation()
}

init_group_node :: proc(
	group: ^Model_Group_Node,
	meshes: []^Mesh,
	materials: []^Material,
	count: int,
) {
	resize_group_node_transforms(group, count)

	for mesh, i in meshes {
		new_mesh := clone_mesh_resource(mesh).data.(^Mesh)

		layout := mesh.attributes.layout
		layout.enabled += {.Instance_Transform}
		layout.accessors[Attribute_Kind.Instance_Transform] = Buffer_Data_Type {
			kind   = .Float_32,
			format = .Mat4,
		}

		new_mesh.attributes = attributes_from_layout(layout, mesh.attributes.format)
		append(&group.meshes, new_mesh)
		append(&group.materials, materials[i])
	}
}

group_node_instance_transform :: proc(group: ^Model_Group_Node, index: int, t: Transform) {
	instance_mat := linalg.matrix4_from_trs_f32(t.translation, t.rotation, t.scale)
	send_buffer_data(
		&group.transform_buf,
		Buffer_Source{
			data = &instance_mat[0][0],
			byte_size = size_of(Matrix4),
			accessor = Buffer_Data_Type{kind = .Float_32, format = .Mat4},
		},
		index * size_of(Matrix4),
	)
}

Skin_Node :: struct {
	using base:     Node,
	derived_flags:  Skin_Flags,
	target:         ^Model_Node,
	joints:         []Skin_Joint,
	joint_roots:    [dynamic]^Skin_Joint,
	joint_lookup:   map[uint]^Skin_Joint,
	joint_matrices: []Matrix4,

	// Animation data
	animations:     map[string]Animation_Player,
	player:         ^Animation_Player,
}

Skin_Joint :: struct {
	parent:               Maybe(^Skin_Joint),
	children:             []^Skin_Joint,
	local_transform:      Transform,
	root_space_transform: Matrix4,
	inverse_bind:         Matrix4,
}

Skin_Flags :: distinct bit_set[Skin_Flag]

Skin_Flag :: enum {
	Dirty_Joints,
	Dirty_Animation_Start_Values,
	Playing,
}

Skin_Loading_Error :: enum {
	None,
	Invalid_Node,
}

skin_node_from_gltf :: proc(skin: ^Skin_Node, node: ^gltf.Node) -> (err: Skin_Loading_Error) {
	if node.skin != nil {
		skin_info := node.skin.?
		inverse_binds: []Matrix4
		switch ibm in skin_info.inverse_bind_matrices {
		case gltf.Skin_Accessor_Inverse_Bind_Matrices:
			inverse_binds = slice.reinterpret([]Matrix4, ibm.data.([]gltf.Mat4f32))
		case gltf.Skin_Identity_Inverse_Bind_Matrices:
			inverse_binds = slice.reinterpret([]Matrix4, ibm)
		}

		skin.joints = make([]Skin_Joint, len(skin_info.joints), skin.scene.allocator)
		skin.joint_matrices = make([]Matrix4, len(skin_info.joints), skin.scene.allocator)
		for joint, i in skin_info.joints {
			skin.joints[i] = Skin_Joint {
				local_transform = transform_from_matrix(joint.local_transform),
				inverse_bind    = inverse_binds[i],
			}
			if len(joint.children) > 0 {
				skin.joints[i].children = make(
					[]^Skin_Joint,
					len(joint.children),
					skin.scene.allocator,
				)
			}
			skin.joint_lookup[skin_info.joint_indices[i]] = &skin.joints[i]
		}
		for joint_info, i in skin_info.joints {
			joint := &skin.joints[i]
			for child_index, j in joint_info.children_indices {
				joint.children[j] = skin.joint_lookup[child_index]
				skin.joint_lookup[child_index].parent = joint.children[j]
			}
		}

		for joint, i in skin.joints {
			if joint.parent == nil {
				append(&skin.joint_roots, &skin.joints[i])
			}
		}
		skin.derived_flags += {.Dirty_Joints}
	} else {
		err = .Invalid_Node
	}
	return
}

skin_node_target :: proc(skin: ^Skin_Node, model: ^Model_Node) {
	skin.target = model
	skin.flags += {.Rendered}
	skin.target.flags -= {.Rendered}
	skin.target.options -= {.Static}
	skin.target.options += {.Dynamic}
}

skin_node_joint_matrices :: proc(skin: ^Skin_Node) -> []Matrix4 {
	traverse_joint :: proc(j: ^Skin_Joint, parent_transform: Matrix4) {
		local := linalg.matrix4_from_trs_f32(
			j.local_transform.translation,
			j.local_transform.rotation,
			j.local_transform.scale,
		)
		j.root_space_transform = parent_transform * local
		for child in j.children {
			traverse_joint(child, j.root_space_transform)
		}
	}
	if .Dirty_Joints in skin.derived_flags {
		for root in skin.joint_roots {
			traverse_joint(root, linalg.MATRIX4F32_IDENTITY)
		}
		for joint, i in skin.joints {
			skin.joint_matrices[i] =
				skin.global_transform * joint.root_space_transform * joint.inverse_bind
		}
		skin.derived_flags -= {.Dirty_Joints}
	}
	return skin.joint_matrices
}

skin_node_add_animation :: proc(skin: ^Skin_Node, a: ^Animation) {
	player := Animation_Player {
		ptr                 = a,
		channels_info       = make(
			[]Animation_Channel_Info,
			len(a.channels),
			skin.scene.allocator,
		),
		targets             = make([]Animation_Target, len(a.channels), skin.scene.allocator),
		targets_start_value = make([]Animation_Value, len(a.channels), skin.scene.allocator),
	}
	for channel, i in a.channels {
		if joint, exist := skin.joint_lookup[channel.target_id]; exist {
			switch channel.kind {
			case .Translation:
				player.targets[i] = &joint.local_transform.translation
			case .Rotation:
				player.targets[i] = &joint.local_transform.rotation
			case .Scale:
				player.targets[i] = &joint.local_transform.scale
			}
			player.targets_start_value[i] = compute_animation_start_value(channel)
		}
	}
	skin.animations[a.name] = player
}

skin_node_play_animation :: proc(skin: ^Skin_Node, name: string) {
	if _, exist := skin.animations[name]; exist {
		skin.player = &skin.animations[name]
		reset_animation(skin.player)
		skin.derived_flags += {.Playing}
	} else {
		log.warnf("%s: Invalid animation name: %s", App_Module.Skin, name)
	}
}

update_skin_node :: proc(skin: ^Skin_Node, dt: f32) {
	if .Playing in skin.derived_flags {
		complete := advance_animation(skin.player, dt)
		skin.derived_flags += {.Dirty_Joints}
		if complete && !skin.player.loop {
			skin.derived_flags -= {.Playing}
		}
	}
}


// User Interface

User_Interface_Node :: struct {
	using base:     Node,
	arena:          mem.Arena,
	allocator:      mem.Allocator,
	dirty:          bool,
	m_pos:          Vector2,
	previous_m_pos: Vector2,
	m_delta:        Vector2,
	theme:          User_Interface_Theme,
	canvas:         ^Canvas_Node,
	roots:          [dynamic]^Widget,
	commands:       [dynamic]User_Interface_Command,
}

User_Interface_Theme :: struct {
	borders:         bool,
	border_color:    Color,
	contrast_values: [len(Contrast_Level)]f32,
	base_color:      Color,
	highlight_color: Color,
	text_color:      Color,
	text_size:       int,
	font:            ^Font,

	// Miscelleanous configs
	title_style:     Text_Style,
}

Contrast_Level :: enum {
	Level_Minus_2 = 0,
	Level_Minus_1 = 1,
	Level_0       = 2,
	Level_Plus_1  = 3,
	Level_Plus_2  = 4,
}

User_Interface_Command :: union {
	User_Interface_Clip_Command,
	User_Interface_Rect_Command,
	User_Interface_Text_Command,
	User_Interface_Line_Command,
	User_Interface_Image_Command,
}

User_Interface_Clip_Command :: Rectangle

User_Interface_Rect_Command :: struct {
	outline: bool,
	rect:    Rectangle,
	color:   Color,
}

User_Interface_Text_Command :: struct {
	text:     string,
	font:     ^Font,
	position: Vector2,
	size:     int,
	color:    Color,
}

User_Interface_Line_Command :: distinct Canvas_Line_Options

User_Interface_Image_Command :: struct {
	texture: ^Texture,
	rect:    Rectangle,
	tint:    Color,
	flip_y:  bool,
}

init_ui_node :: proc(node: ^User_Interface_Node, allocator: mem.Allocator) {
	mem.arena_init(&node.arena, make([]byte, mem.Megabyte * 1, allocator))
	node.allocator = mem.arena_allocator(&node.arena)
	node.dirty = true
}

ui_node_theme :: proc(node: ^User_Interface_Node, theme: User_Interface_Theme) {
	node.theme = theme
}

ui_node_dirty :: proc(node: ^User_Interface_Node) {
	node.dirty = true
}

render_ui_node :: proc(node: ^User_Interface_Node) {
	update_widget_slice(node.roots[:])
	if node.dirty {
		clear(&node.commands)
		draw_widget_slice(node.roots[:])

		for command in node.commands {
			switch c in command {
			case User_Interface_Clip_Command:
				push_canvas_clip(node.canvas, Rectangle(c))

			case User_Interface_Rect_Command:
				if c.outline {
					x := c.rect.x + 1
					y := c.rect.y
					width := c.rect.width - 1
					height := c.rect.height - 1
					draw_line(node.canvas, {x, y}, {x, y + height}, c.color)
					draw_line(
						node.canvas,
						{x, y + height - 1},
						{x + width, y + height - 1},
						c.color,
					)
					draw_line(node.canvas, {x + width, y + height}, {x + width, y}, c.color)
					draw_line(node.canvas, {x + width, y}, {x, y}, c.color)
				} else {
					draw_rect(node.canvas, c.rect, c.color)
				}
			case User_Interface_Text_Command:
				draw_text(node.canvas, c.font, c.text, c.position, c.size, c.color)
			case User_Interface_Line_Command:
				push_canvas_line(node.canvas, Canvas_Line_Options(c))
			case User_Interface_Image_Command:
				src_rect := Rectangle{0, 0, c.texture.width, c.texture.height}
				if c.flip_y {
					src_rect.height *= -1
				}
				draw_sub_texture(node.canvas, c.texture, c.rect, src_rect, c.tint)
			}
		}
		node.dirty = false
	} else {
		node.canvas.derived_flags += {.Preserve_Last_Frame}
	}
}

scene_graph_to_list :: proc(parent: ^Widget, scene: ^Scene, node_size: f32) -> ^List_Widget {
	DEFAULT_BASE :: Widget {
		flags = DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
		background = Widget_Background{style = .Solid},
	}

	list := new_widget_from(
		parent.ui,
		List_Widget{
			base = DEFAULT_BASE,
			options = {.Named_Header, .Foldable, .Indent_Children, .Tree_View},
			optional_name = "scene",
			padding = 2,
			indent = 10,
		},
	)
	list.background.borders = true
	list.background.border_color = 1
	#partial switch p in parent.derived {
	case ^Layout_Widget:
		layout_add_widget(p, list, node_size)
	case ^List_Widget:
		list_add_widget(p, list, node_size)
	case:
		assert(false)
	}

	node_to_widget :: proc(parent: ^Widget, node: ^Node, node_size: f32, base := DEFAULT_BASE) {
		if len(node.children) > 0 {
			list := new_widget_from(
				parent.ui,
				List_Widget{
					base = base,
					options = {.Named_Header, .Foldable, .Indent_Children, .Tree_View},
					optional_name = node.name,
					padding = 2,
					indent = node_size,
				},
			)

			#partial switch p in parent.derived {
			case ^Layout_Widget:
				layout_add_widget(p, list, node_size)
			case ^List_Widget:
				list_add_widget(p, list, node_size)
			case:
				assert(false)
			}

			for child in node.children {
				node_to_widget(list, child, node_size)
			}
		} else {
			widget := new_widget_from(
				parent.ui,
				Label_Widget{base = base, text = Text{data = node.name}},
			)
			widget.background.style = .None
			#partial switch p in parent.derived {
			case ^Layout_Widget:
				layout_add_widget(p, widget, node_size)
			case ^List_Widget:
				list_add_widget(p, widget, node_size)
			case:
				assert(false)
			}
		}

		return
	}

	for root in scene.roots {
		node_to_widget(list, root, node_size)
	}
	return list
}

Widget :: struct {
	ui:           ^User_Interface_Node,
	id:           Widget_ID,
	flags:        Widget_Flags,
	parent_flags: ^Widget_Flags,
	rect:         Rectangle,
	background:   Widget_Background,
	derived:      Any_Widget,
}

Widget_ID :: distinct uint

Widget_Flags :: distinct bit_set[Widget_Flag]

Widget_Flag :: enum {
	Active,
	Dirty_Hierarchy,
	Root_Widget,
	Initialized_On_New,
	Initialized,
	Fit_Theme,
}

Widget_Background :: struct {
	style:        enum {
		None,
		Solid,
		Texture_Slice,
	},
	borders:      bool,
	border_color: Color,
	color:        Color,
	texture:      ^Texture,
}

Any_Widget :: union {
	^Layout_Widget,
	^List_Widget,
	^Tab_Viewer_Widget,
	^Button_Widget,
	^Label_Widget,
	^Image_Widget,
	^Text_Input_Widget,
	^Slider_Widget,
}

new_widget_from :: proc(node: ^User_Interface_Node, from: $T) -> ^T {
	widget := new_clone(from, node.allocator)
	widget.derived = widget
	widget.ui = node

	if .Root_Widget in widget.flags {
		append(&node.roots, widget)
	}
	if .Initialized_On_New in widget.flags {
		init_widget(widget)
	}
	return widget
}

init_widget :: proc(widget: ^Widget) {
	if .Fit_Theme in widget.flags {
		fit_theme(widget.ui.theme, widget)
	}
	switch w in widget.derived {
	case ^Layout_Widget:
		w.children.allocator = widget.ui.allocator
		init_layout(w)
	case ^List_Widget:
		w.children.allocator = widget.ui.allocator
		init_list(w)
	case ^Tab_Viewer_Widget:
		w.tabs.allocator = widget.ui.allocator
		init_tab_viewer(w)
	case ^Button_Widget:
		init_button(w)
	case ^Label_Widget:
		text_position(&w.text, w.rect)
	case ^Image_Widget:
		init_image(w)
	case ^Text_Input_Widget:
		w.char_buf.allocator = widget.ui.allocator
		init_text_input(w)
	case ^Slider_Widget:
		init_slider(w)
	}
	widget.flags += {.Initialized}
}

@(private)
fit_theme :: proc(theme: User_Interface_Theme, widget: ^Widget) {
	contrast: f32
	switch w in widget.derived {
	case ^Layout_Widget:
		if .Root_Widget in widget.flags {
			contrast = theme.contrast_values[Contrast_Level.Level_Minus_1]
		} else if .Child_Handle in w.options {
			contrast = theme.contrast_values[Contrast_Level.Level_Minus_2]
		} else {
			contrast = theme.contrast_values[Contrast_Level.Level_0]
		}
		w.background.borders = theme.borders

	case ^List_Widget:
		contrast = theme.contrast_values[Contrast_Level.Level_Minus_1]
		w.line_color.rgb =
			theme.base_color.rgb * theme.contrast_values[Contrast_Level.Level_Plus_1]
		w.line_color.a = 1

	case ^Tab_Viewer_Widget:
		contrast = theme.contrast_values[Contrast_Level.Level_Minus_1]

	case ^Button_Widget:
		w.color = theme.base_color * theme.contrast_values[Contrast_Level.Level_Plus_1]
		w.hover_color = theme.base_color * theme.contrast_values[Contrast_Level.Level_Plus_2]
		w.press_color = theme.highlight_color
		w.background.borders = theme.borders
		if w.text != nil {
			t := w.text.?
			t.font = theme.font
			t.size = theme.text_size
			t.color = theme.text_color
			w.text = t
		}

	case ^Label_Widget:
		contrast = theme.contrast_values[Contrast_Level.Level_0]
		w.text.font = theme.font
		w.text.size = theme.text_size
		w.text.color = theme.text_color

	case ^Image_Widget:
		contrast = theme.contrast_values[Contrast_Level.Level_0]

	case ^Text_Input_Widget:
		contrast = theme.contrast_values[Contrast_Level.Level_Minus_2]
		w.caret_color = theme.base_color * theme.contrast_values[Contrast_Level.Level_Plus_1]
		w.text.font = theme.font
		w.text.size = theme.text_size
		w.text.color = theme.text_color
	case ^Slider_Widget:
		contrast = theme.contrast_values[Contrast_Level.Level_Minus_2]
		w.progress_color = theme.base_color * theme.contrast_values[Contrast_Level.Level_Plus_2]
		if .With_Handle in w.derived_flags {
			w.handle_color = theme.base_color * theme.contrast_values[Contrast_Level.Level_0]
		}
	}
	widget.background.color.rbg = theme.base_color.rgb * contrast
	widget.background.border_color = theme.border_color
	widget.background.color.a = 1
}

update_widget_slice :: proc(widgets: []^Widget) {
	for widget in widgets {
		if .Active in widget.flags {
			update_widget(widget)
		}
	}
}

update_widget :: proc(widget: ^Widget) {
	switch w in widget.derived {
	case ^Layout_Widget:
		update_layout(w)
	case ^List_Widget:
		update_list(w)
	case ^Button_Widget:
		update_button(w)
	case ^Tab_Viewer_Widget:
		update_widget(w.tabs_selector)
		update_widget(w.tabs[w.active_tab])
	case ^Image_Widget:
		if w.display_option == .Stream {
			ui_node_dirty(w.ui)
		}
	case ^Label_Widget:
	case ^Text_Input_Widget:
		update_text_input(w)
	case ^Slider_Widget:
		update_slider(w)
	}
}

offset_widget_slice :: proc(widgets: []^Widget, offset: Vector2) {
	for widget in widgets {
		offset_widget(widget, offset)
	}
}

offset_widget :: proc(widget: ^Widget, offset: Vector2) {
	widget.rect.x += offset.x
	widget.rect.y += offset.y
	switch w in &widget.derived {
	case ^Layout_Widget:
		offset_widget_slice(w.children[:], offset)
	case ^List_Widget:
		offset_widget_slice(w.children[:], offset)
	case ^Tab_Viewer_Widget:
		offset_widget(w.tabs_selector, offset)
		for _, tab in w.tabs {
			offset_widget(tab, offset)
		}
	case ^Button_Widget:
		if w.text != nil {
			t := w.text.?
			text_position(
				&t,
				Rectangle{
					w.rect.x + w.left_padding,
					w.rect.y,
					w.rect.width - w.right_padding,
					w.rect.height,
				},
			)
			w.text = t
		}
	case ^Label_Widget:
		text_position(&w.text, w.rect)
	case ^Image_Widget:
		w.content_rect.x += offset.x
		w.content_rect.y += offset.y

	case ^Text_Input_Widget:
		text_position(&w.text, w.rect)
		w.caret_rect.x += offset.x
		w.caret_rect.y += offset.y
	case ^Slider_Widget:
		if .With_Handle in w.derived_flags {
			w.handle_rect.x += offset.x
			w.handle_rect.y += offset.y
		}
		w.progress_rect.x += offset.x
		w.progress_rect.y += offset.y
	}
}


draw_widget_slice :: proc(widgets: []^Widget) {
	for widget in widgets {
		if .Active in widget.flags {
			draw_widget(widget)
		}
	}
}

draw_widget :: proc(widget: ^Widget) {
	buf := &widget.ui.commands
	switch w in widget.derived {
	case ^Layout_Widget:
		draw_widget_background(buf, w.background, w.rect)
		if .Clip_Children in w.options {
			append(buf, User_Interface_Clip_Command(w.rect))
		}
		for child in w.children {
			draw_widget(child)
		}

	case ^List_Widget:
		draw_widget_background(buf, w.background, w.rect)
		if .Clip_Children in w.options {
			append(buf, User_Interface_Clip_Command(w.rect))
		}
		if .Folded not_in w.states {
			for child, i in w.children {
				draw_widget(child)
				if .Tree_View in w.options && i > 0 {
					p := Vector2{w.rect.x + w.next.x, child.rect.y + w.root.rect.height / 2}
					append(
						buf,
						User_Interface_Line_Command{
							p1 = p,
							p2 = p + Vector2{w.indent - 1, 0},
							color = w.line_color,
						},
					)
				}
			}
			if .Tree_View in w.options {
				line_padding := 2 + w.padding
				if w.background.borders {
					line_padding += 1
				}
				p := Vector2{w.root.rect.x + w.next.x, w.root.rect.y + w.root.rect.height}
				append(
					buf,
					User_Interface_Line_Command{
						p1 = p + Vector2{0, line_padding},
						p2 = p + Vector2{0, w.line_height},
						color = w.line_color,
					},
				)
			}
		} else {
			draw_widget(w.root)
		}

	case ^Tab_Viewer_Widget:
		draw_widget(w.tabs_selector)
		draw_widget(w.tabs[w.active_tab])
	case ^Button_Widget:
		draw_widget_background(buf, w.background, w.rect)
		if w.text != nil {
			t := w.text.?
			text_cmd := User_Interface_Text_Command {
				text     = t.data,
				font     = t.font,
				position = t.origin,
				size     = t.size,
				color    = t.color,
			}
			append(buf, text_cmd)
		}
	case ^Label_Widget:
		draw_widget_background(buf, w.background, w.rect)
		t := w.text
		text_cmd := User_Interface_Text_Command {
			text     = t.data,
			font     = t.font,
			position = t.origin,
			size     = t.size,
			color    = t.color,
		}
		append(buf, text_cmd)
	case ^Image_Widget:
		draw_widget_background(buf, w.background, w.rect)
		img_cmd := User_Interface_Image_Command {
			texture = w.content,
			rect    = w.content_rect,
			tint    = w.tint,
			flip_y  = w.flip_y,
		}
		append(buf, img_cmd)

	case ^Text_Input_Widget:
		draw_widget_background(buf, w.background, w.rect)
		t := w.text
		text_cmd := User_Interface_Text_Command {
			text     = t.data,
			font     = t.font,
			position = t.origin,
			size     = t.size,
			color    = t.color,
		}
		append(buf, text_cmd)

		if .In_Focus in w.derived_flags && .Show_Caret in w.derived_flags {
			append(
				buf,
				User_Interface_Rect_Command{
					outline = false,
					rect = w.caret_rect,
					color = w.caret_color,
				},
			)
		}

	case ^Slider_Widget:
		draw_widget_background(buf, w.background, w.rect)
		append(
			buf,
			User_Interface_Rect_Command{
				outline = false,
				rect = w.progress_rect,
				color = w.progress_color,
			},
		)
		if .With_Handle in w.derived_flags {
			append(
				buf,
				User_Interface_Rect_Command{
					outline = false,
					rect = w.handle_rect,
					color = w.handle_color,
				},
			)
		}
	}
}

widget_height :: proc(widget: ^Widget) -> (result: f32) {
	switch w in widget.derived {
	case ^Layout_Widget, ^Button_Widget, ^Label_Widget, ^Image_Widget:
		result = widget.rect.height

	case ^Tab_Viewer_Widget, ^Text_Input_Widget, ^Slider_Widget:
		result = widget.rect.height

	case ^List_Widget:
		if .Folded not_in w.states {
			result = w.margin
			for child in w.children {
				result += widget_height(child) + w.padding
			}
			w.rect.height = result
		} else {
			result = w.root.rect.height
			w.rect.height = result
		}
	}
	return
}

draw_widget_background :: proc(
	buf: ^[dynamic]User_Interface_Command,
	bg: Widget_Background,
	rect: Rectangle,
) {
	switch bg.style {
	case .None:
	case .Solid:
		append(buf, User_Interface_Rect_Command{false, rect, bg.color})
	case .Texture_Slice:
		assert(false)
	}
	if bg.borders {
		append(buf, User_Interface_Rect_Command{true, rect, bg.border_color})
	}
}

widget_active :: proc(widget: ^Widget, active: bool) {
	if active {
		widget.flags += {.Active}
	} else {
		widget.flags -= {.Active}
	}
	ui_node_dirty(widget.ui)
}

Layout_Widget :: struct {
	using base:     Widget,
	options:        Layout_Options,
	optional_title: string,
	handle:         ^Layout_Widget,
	children:       [dynamic]^Widget,
	format:         Layout_Format,
	origin:         Direction,
	next:           Vector2,
	margin:         f32,
	padding:        f32,
	default_size:   f32,
}

Layout_Format :: enum {
	Row,
	Column,
}

Layout_Options :: distinct bit_set[Layout_Option]

Layout_Option :: enum {
	Decorated,
	Titled,
	Close_Widget,
	Moveable,
	Moving,
	Child_Handle,
	Clip_Children,
}

DEFAULT_LAYOUT_FLAGS :: Widget_Flags{.Active, .Initialized_On_New}
DEFAULT_LAYOUT_CHILD_FLAGS :: Widget_Flags{.Active}
DEFAULT_LAYOUT_HANDLE_DIM :: 20
DEFAULT_LAYOUT_HANDLE_MARGIN :: 2
DEFAULT_LAYOUT_HANDLE_PADDING :: 2

layout_add_widget :: proc(layout: ^Layout_Widget, child: ^Widget, size: f32 = 0) {
	s := size if size > 0 else layout.default_size
	switch layout.format {
	case .Row:
		offset := layout.next.y if layout.origin == .Up else -(layout.next.y + s)
		child.rect = Rectangle {
			x      = layout.rect.x + layout.next.x,
			y      = layout.rect.y + offset,
			width  = layout.rect.width - (layout.margin * 2),
			height = s,
		}
		layout.next.y += s + layout.padding
	case .Column:
		offset := layout.next.x
		if layout.origin == .Right {
			offset = layout.rect.width - (layout.next.x + s)
		}
		child.rect = Rectangle {
			x      = layout.rect.x + offset,
			y      = layout.rect.y + layout.next.y,
			width  = s,
			height = layout.rect.height - (layout.margin * 2),
		}
		layout.next.x += s + layout.padding
	}
	append(&layout.children, child)
	child.parent_flags = &layout.flags
	if .Initialized not_in child.flags {
		init_widget(child)
	}
}

layout_remaining_size :: proc(layout: ^Layout_Widget) -> (rem: f32) {
	switch layout.format {
	case .Row:
		rem = layout.rect.height - layout.next.y - layout.margin
	case .Column:
		rem = layout.rect.width - layout.next.x - layout.margin
	}
	return
}

init_layout :: proc(layout: ^Layout_Widget) {
	if .Root_Widget in layout.flags && .Decorated in layout.options {
		margin := layout.margin
		padding := layout.padding
		layout.margin = 0
		layout.padding = 0

		if .Root_Widget in layout.flags {
			layout.options += {.Clip_Children}
		}

		flags := DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme}
		base := Widget {
			flags = flags,
			background = Widget_Background{style = .Solid},
		}
		layout.handle = new_widget_from(
			layout.ui,
			Layout_Widget{
				base = base,
				options = {.Child_Handle},
				format = .Column,
				origin = .Right,
				margin = DEFAULT_LAYOUT_HANDLE_MARGIN,
				padding = DEFAULT_LAYOUT_HANDLE_PADDING,
			},
		)
		layout_add_widget(layout, layout.handle, DEFAULT_LAYOUT_HANDLE_DIM)

		if .Close_Widget in layout.options {
			close_btn := new_widget_from(
				layout.ui,
				Button_Widget{base = base, text = Text{data = "X", style = .Center}},
			)
			layout_add_widget(
				layout.handle,
				close_btn,
				DEFAULT_LAYOUT_HANDLE_DIM - (DEFAULT_LAYOUT_HANDLE_MARGIN * 2),
			)
		}

		if .Titled in layout.options && layout.optional_title != "" {
			base.background.style = .None
			title := new_widget_from(
				layout.ui,
				Label_Widget{
					base = base,
					text = Text{data = layout.optional_title, style = layout.ui.theme.title_style},
				},
			)
			title.background.style = .None
			layout_add_widget(layout.handle, title, layout_remaining_size(layout.handle))
		}

		layout.margin = margin
		layout.padding = padding
		layout.next += margin
	} else {
		layout.next = Vector2{layout.margin, layout.margin}
	}
}

update_layout :: proc(layout: ^Layout_Widget) {
	if .Root_Widget in layout.flags && .Decorated in layout.options {
		if .Moveable in layout.options {
			m_left := mouse_button_state(.Left)
			if .Moving in layout.options {
				if .Just_Released in m_left {
					layout.options -= {.Moving}
				} else {
					m_delta := mouse_delta()
					if m_delta != 0 {
						offset_widget(layout, m_delta)
						layout.ui.dirty = true
					}
				}
			} else {
				if in_rect_bounds(layout.handle.rect, mouse_position()) {
					if .Just_Pressed in m_left {
						layout.options += {.Moving}
					}
				}

			}
		}
	}
	if .Dirty_Hierarchy in layout.flags {
		if .Decorated in layout.options {
			layout.next = {layout.margin, layout.handle.rect.height + layout.margin}
			for child in layout.children[1:] {
				next := layout.next + Vector2{layout.rect.x, layout.rect.y}
				offset := next - Vector2{child.rect.x, child.rect.y}
				if offset != 0 {
					offset_widget(child, offset)
				}
				layout.next.y += widget_height(child) + layout.padding
			}
		} else {
			layout.next = {layout.rect.x + layout.margin, layout.rect.y + layout.margin}
			for child in layout.children {
				offset := layout.next - Vector2{child.rect.x, child.rect.y}
				offset_widget(child, offset)
				layout.next.y += widget_height(child) + layout.padding
			}
		}
		layout.flags -= {.Dirty_Hierarchy}
	}
	update_widget_slice(layout.children[:])
}

List_Widget :: struct {
	using base:     Widget,
	options:        List_Options,
	optional_name:  string,
	states:         List_States,
	root:           ^Button_Widget,
	children:       [dynamic]^Widget,
	next:           Vector2,
	margin:         f32,
	padding:        f32,
	indent:         f32,
	default_height: f32,
	line_height:    f32,
	line_color:     Color,
}

List_Options :: distinct bit_set[List_Option]

List_Option :: enum {
	Named_Header,
	Indent_Children,
	Clip_Children,
	Foldable,
	Tree_View,
}

List_States :: distinct bit_set[List_State]

List_State :: enum {
	Folded,
}

list_add_widget :: proc(list: ^List_Widget, child: ^Widget, height: f32 = 0) {
	h := height if height > 0 else list.default_height
	offset := list.next.x
	width := list.rect.width - (list.margin * 2)
	if .Indent_Children in list.options {
		offset += list.indent
		width -= list.indent
	}
	child.rect = Rectangle {
		x      = list.rect.x + offset,
		y      = list.rect.y + list.next.y,
		width  = width,
		height = h,
	}
	list.next.y += h + list.padding

	append(&list.children, child)
	child.parent_flags = &list.flags
	list.flags += {.Dirty_Hierarchy}
	if .Initialized_On_New not_in child.flags {
		init_widget(child)
	}
}

init_list :: proc(list: ^List_Widget) {
	DEFAULT_LIST_ROOT_HEIGHT :: 20
	named := .Named_Header in list.options && list.optional_name != ""
	if named || .Foldable in list.options {
		margin := list.margin
		padding := list.padding
		indent := list.indent
		list.padding = 0
		list.margin = 0
		list.indent = 0

		base := Widget {
			flags = DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
			background = Widget_Background{style = .Solid},
		}
		list.root = new_widget_from(
			list.ui,
			Button_Widget{base = base, data = list, callback = collapse_list},
		)
		if .Named_Header in list.options {
			list.root.text = Text {
				data  = list.optional_name,
				style = .Center_Left,
			}
		}
		list_add_widget(list, list.root, DEFAULT_LIST_ROOT_HEIGHT)

		list.margin = margin
		list.padding = padding
		list.indent = indent
		list.next += margin
	} else {
		list.next = Vector2{list.margin, list.margin}
	}
	if .Root_Widget not_in list.flags && list.parent_flags != nil {
		f := list.parent_flags^ + {.Dirty_Hierarchy}
		list.parent_flags^ = f
	}
}

update_list :: proc(list: ^List_Widget) {
	if .Dirty_Hierarchy in list.flags {
		if .Foldable in list.options {
			list.next = {list.margin, list.root.rect.height + list.margin}
			if list.margin == 0 {
				list.next.y += list.padding
			}
			list.line_height = 0
			for child, i in list.children[1:] {
				next := list.next + {list.rect.x, list.rect.y}
				if .Indent_Children in list.options {
					next.x += list.indent
				}

				offset := next - Vector2{child.rect.x, child.rect.y}
				offset_widget(child, offset)
				height := widget_height(child)
				list.next.y += height + list.padding
				if i == len(list.children) - 2 {
					LAST_CHILD_PADDING :: 3
					list.line_height += list.root.rect.height / 2
					list.line_height += LAST_CHILD_PADDING
				} else {
					list.line_height += height + list.padding
				}
			}
			list.rect.height = list.next.y
			list.flags -= {.Dirty_Hierarchy}
		}
	}
	update_widget_slice(list.children[:])
}

collapse_list :: proc(data: rawptr, id: Widget_ID) {
	list := cast(^List_Widget)data
	if .Foldable in list.options {
		list.states ~= {.Folded}
		if .Root_Widget not_in list.flags && list.parent_flags != nil {
			f := list.parent_flags^ + {.Dirty_Hierarchy}
			list.parent_flags^ = f
		}
		list.ui.dirty = true
	}
}

Tab_Viewer_Widget :: struct {
	using layout:  Layout_Widget,
	tabs_selector: ^Layout_Widget,
	tabs:          map[Widget_ID]^Layout_Widget,
	active_tab:    Widget_ID,
}

Tab_Config :: struct {
	name:          string,
	id:            Widget_ID,
	format:        Layout_Format,
	origin:        Direction,
	set_as_active: bool,
}

tab_viewer_add_tab :: proc(viewer: ^Tab_Viewer_Widget, cfg: Tab_Config) -> (tab: ^Layout_Widget) {
	tab_btn := new_widget_from(
		viewer.ui,
		Button_Widget{
			base = Widget{
				id = cfg.id,
				flags = DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = Widget_Background{style = .Solid},
			},
			text = Text{data = cfg.name, style = .Center},
			data = viewer,
			callback = switch_active_tab,
		},
	)
	layout_add_widget(viewer.tabs_selector, tab_btn, 75)

	tab = new_widget_from(
		viewer.ui,
		Layout_Widget{
			base = Widget{
				id = cfg.id,
				flags = DEFAULT_LAYOUT_FLAGS + {.Fit_Theme},
				rect = Rectangle{
					x = viewer.rect.x,
					y = viewer.rect.y + viewer.tabs_selector.rect.height,
					width = viewer.rect.width,
					height = viewer.rect.height - viewer.tabs_selector.rect.height,
				},
				background = Widget_Background{style = .Solid},
			},
			format = cfg.format,
			origin = cfg.origin,
			margin = 0,
			padding = 1,
		},
	)
	viewer.tabs[cfg.id] = tab
	if cfg.set_as_active {
		viewer.active_tab = cfg.id
	}
	return
}

switch_active_tab :: proc(data: rawptr, id: Widget_ID) {
	viewer := cast(^Tab_Viewer_Widget)data
	if id in viewer.tabs {
		viewer.active_tab = id
	}
}

init_tab_viewer :: proc(viewer: ^Tab_Viewer_Widget) {
	init_layout(viewer)

	base := Widget {
		flags = DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
		background = Widget_Background{style = .Solid},
	}
	viewer.tabs_selector = new_widget_from(
		viewer.ui,
		Layout_Widget{
			base = base,
			options = {.Child_Handle},
			format = .Column,
			origin = .Left,
			margin = 0,
			padding = 1,
		},
	)
	layout_add_widget(viewer, viewer.tabs_selector, 20)
}

Label_Widget :: struct {
	using base: Widget,
	text:       Text,
}

set_label_text :: proc(label: ^Label_Widget, str: string) {
	label.text.data = str
	text_position(&label.text, label.rect)
}

Image_Widget :: struct {
	using base:     Widget,
	constraint:     Image_Constraint,
	display_option: Image_Display_Option,
	flip_y:         bool,
	content:        ^Texture,
	content_rect:   Rectangle,
	tint:           Color,
}

Image_Constraint :: enum {
	Fit_Width,
	Fit_Height,
}

Image_Display_Option :: enum {
	Static,
	Stream,
}

init_image :: proc(image: ^Image_Widget) {
	i_w := image.content.width
	i_h := image.content.height
	switch image.constraint {
	case .Fit_Width:
		image.content_rect = Rectangle {
			x      = image.rect.x,
			y      = image.rect.y,
			width  = image.rect.width,
			height = (image.rect.width * i_h) / i_w,
		}
	case .Fit_Height:
		image.content_rect = Rectangle {
			x      = image.rect.x,
			y      = image.rect.y,
			width  = (image.rect.height * i_w) / i_h,
			height = image.rect.height,
		}
	}
	offset := Vector2{
		(image.rect.width - image.content_rect.width) / 2,
		(image.rect.height - image.content_rect.height) / 2,
	}
	image.content_rect.x += offset.x
	image.content_rect.y += offset.y
}

Button_Widget :: struct {
	using base:     Widget,
	state:          Button_Widget_State,
	previous_state: Button_Widget_State,
	color:          Color,
	hover_color:    Color,
	press_color:    Color,
	text:           Maybe(Text),
	left_padding:   f32,
	right_padding:  f32,

	//
	data:           rawptr,
	callback:       proc(data: rawptr, id: Widget_ID),
	notify_parent:  ^bool,
}

Button_Widget_State :: enum {
	Idle,
	Hovered,
	Pressed,
}

init_button :: proc(btn: ^Button_Widget) {
	btn.background.color = btn.color
	if btn.text != nil {
		t := btn.text.?
		text_position(
			&t,
			Rectangle{
				btn.rect.x + btn.left_padding,
				btn.rect.y,
				btn.rect.width - btn.right_padding,
				btn.rect.height,
			},
		)
		btn.text = t
	}
}

update_button :: proc(btn: ^Button_Widget) {
	btn.previous_state = btn.state
	m_left := mouse_button_state(.Left)
	if in_rect_bounds(btn.rect, mouse_position()) {
		if .Pressed in m_left {
			btn.state = .Pressed
		} else {
			if .Just_Released in m_left {
				if btn.state == .Pressed {
					btn.state = .Idle
					if btn.callback != nil {
						btn.callback(btn.data, btn.id)
					}
					if btn.notify_parent != nil {
						btn.notify_parent^ = true
					}
				}
			} else {
				btn.state = .Hovered
			}
		}
	} else {
		btn.state = .Idle
	}
	if btn.state != btn.previous_state {
		ui_node_dirty(btn.ui)
		switch btn.state {
		case .Idle:
			btn.background.color = btn.color
		case .Hovered:
			btn.background.color = btn.hover_color
		case .Pressed:
			btn.background.color = btn.press_color
		}
	}
}

Text_Input_Widget :: struct {
	using base:    Widget,
	text:          Text,
	derived_flags: Text_Input_Flags,
	caret_timer:   Timer,
	caret_rect:    Rectangle,
	caret_color:   Color,
	delete_timer:  Timer,

	// Input states
	char_buf:      [dynamic]byte,
	cursor:        Text_Cursor,
}

Text_Input_Flags :: distinct bit_set[Text_Input_Flag]

Text_Input_Flag :: enum {
	In_Focus,
	Show_Caret,
	Delete_Available,
}

text_input_add :: proc(input: ^Text_Input_Widget, c: byte) {
	if input.cursor.offset < len(input.char_buf) {
		inject_at(&input.char_buf, input.cursor.offset, c)
	} else {
		append(&input.char_buf, c)
	}
	glyph := input.text.font.faces[input.text.size].glyphs[c]
	if c == ' ' {
		input.caret_rect.x += f32(glyph.advance)
	} else {
		input.caret_rect.x += f32(glyph.width)
	}
}

text_input_remove :: proc(input: ^Text_Input_Widget) {
	c: byte
	if input.cursor.offset < len(input.char_buf) {
		c := input.char_buf[input.cursor.offset]
		ordered_remove(&input.char_buf, input.cursor.offset)
	} else {
		c = pop(&input.char_buf)
	}
	glyph := input.text.font.faces[input.text.size].glyphs[c]
	if c == ' ' {
		input.caret_rect.x -= f32(glyph.advance)
	} else {
		input.caret_rect.x -= f32(glyph.width)
	}
}

text_input_clear :: proc(input: ^Text_Input_Widget) {
	clear(&input.char_buf)
	init_text_input(input)
}

init_text_input :: proc(input: ^Text_Input_Widget) {
	text_position(&input.text, input.rect)
	char_width := input.text.font.faces[input.text.size].glyphs[' '].advance
	char_height := input.text.size
	input.caret_rect = Rectangle {
		x      = input.text.origin.x,
		y      = input.text.origin.y - f32(char_height) / 2,
		width  = f32(char_width),
		height = f32(char_height),
	}
	input.delete_timer = Timer {
		reset    = true,
		duration = 0.25,
	}
}

update_text_input :: proc(input: ^Text_Input_Widget) {
	m_left := mouse_button_state(.Left)
	if .Just_Pressed in m_left {
		previous := .In_Focus in input.derived_flags
		if in_rect_bounds(input.rect, mouse_position()) {
			input.derived_flags += {.In_Focus}
		} else {
			input.derived_flags -= {.In_Focus}
		}

		if .In_Focus in input.derived_flags != previous {
			ui_node_dirty(input.ui)
		}
	}

	if .In_Focus in input.derived_flags {
		dt := f32(elapsed_time())
		if advance_timer(&input.caret_timer, dt) {
			input.derived_flags ~= {.Show_Caret}
			ui_node_dirty(input.ui)
		}
		chars := pressed_char()

		for c in chars {
			text_input_add(input, byte(c))
			input.cursor.offset += 1
		}

		if len(chars) > 0 {
			input.text.data = string(input.char_buf[:])
			update_text_position(&input.text)

			ui_node_dirty(input.ui)
		}

		del_key := key_state(.Backspace)
		if .Pressed in del_key {
			if .Delete_Available in input.derived_flags && len(input.char_buf) > 0 {
				text_input_remove(input)
				input.derived_flags -= {.Delete_Available}
				input.cursor.offset -= 1
				input.text.data = string(input.char_buf[:])
				update_text_position(&input.text)
				ui_node_dirty(input.ui)
			}
		}

		if .Delete_Available not_in input.derived_flags {
			if advance_timer(&input.delete_timer, dt) {
				input.derived_flags += {.Delete_Available}
			}
		}
	}
}


Slider_Widget :: struct {
	using base:      Widget,
	derived_flags:   Slider_Flags,
	handle_rect:     Rectangle,
	handle_color:    Color,
	progress_origin: Direction,
	progress_rect:   Rectangle,
	progress_color:  Color,
	progress:        f32,
	data:            rawptr,
	callback:        proc(data: rawptr, id: Widget_ID, t: f32),
}

Slider_Flags :: distinct bit_set[Slider_Flag]

Slider_Flag :: enum {
	Interactive,
	Moving,
	With_Handle,
}

SLIDER_HANDLE_SIZE :: 15

init_slider :: proc(slider: ^Slider_Widget) {
	if .With_Handle in slider.derived_flags {
		switch slider.progress_origin {
		case .Up, .Down:
			slider.handle_rect.x = slider.rect.x
			slider.handle_rect.width = slider.rect.width
			slider.handle_rect.height = SLIDER_HANDLE_SIZE
		case .Left, .Right:
			slider.handle_rect.y = slider.rect.y
			slider.handle_rect.width = SLIDER_HANDLE_SIZE
			slider.handle_rect.height = slider.rect.height
		}
	}
	slider_progress_value(slider, slider.progress)
}

slider_progress_value :: proc(slider: ^Slider_Widget, t: f32) {
	slider.progress = clamp(t, 0, 1)
	switch slider.progress_origin {
	case .Up:
		slider.progress_rect = Rectangle {
			x      = slider.rect.x,
			y      = slider.rect.y,
			width  = slider.rect.width,
			height = slider.rect.height * slider.progress,
		}
		if .With_Handle in slider.derived_flags {
			slider.handle_rect.y = slider.rect.y + slider.progress_rect.height
			slider.handle_rect.y -= slider.handle_rect.height / 2
		}

	case .Left:
		slider.progress_rect = Rectangle {
			x      = slider.rect.x,
			y      = slider.rect.y,
			width  = slider.rect.width * slider.progress,
			height = slider.rect.height,
		}
		if .With_Handle in slider.derived_flags {
			slider.handle_rect.x = slider.rect.x + slider.progress_rect.width
			slider.handle_rect.x -= slider.handle_rect.width / 2
		}

	case .Down:
		slider.progress_rect = Rectangle {
			x      = slider.rect.x,
			y      = slider.rect.y + slider.rect.height * (1 - slider.progress),
			width  = slider.rect.width,
			height = slider.rect.height * slider.progress,
		}
		if .With_Handle in slider.derived_flags {
			slider.handle_rect.y = slider.progress_rect.y
			slider.handle_rect.y -= slider.handle_rect.height / 2
		}

	case .Right:
		slider.progress_rect = Rectangle {
			x      = slider.rect.x + slider.rect.width * (1 - slider.progress),
			y      = slider.rect.y,
			width  = slider.rect.width * slider.progress,
			height = slider.rect.height,
		}
		if .With_Handle in slider.derived_flags {
			slider.handle_rect.x = slider.progress_rect.x
			slider.handle_rect.x -= slider.handle_rect.width / 2
		}
	}
}

update_slider :: proc(slider: ^Slider_Widget) {
	if .Interactive in slider.derived_flags {
		m_left := mouse_button_state(.Left)
		m_pos := mouse_position()
		if .Moving in slider.derived_flags {
			p_vec := m_pos - Vector2{slider.rect.x, slider.rect.y}
			p_vec /= Vector2{slider.rect.width, slider.rect.height}
			t: f32
			switch slider.progress_origin {
			case .Up:
				t = p_vec.y
			case .Left:
				t = p_vec.x
			case .Down:
				t = 1 - p_vec.x
			case .Right:
				t = 1 - p_vec.x
			}

			if t != slider.progress {
				slider_progress_value(slider, t)
				ui_node_dirty(slider.ui)
			}
			if .Just_Released in m_left {
				slider.derived_flags -= {.Moving}
				if slider.callback != nil {
					slider.callback(slider.data, slider.id, slider.progress)
				}
			}
		} else if .Just_Pressed in m_left {
			if in_rect_bounds(slider.handle_rect, m_pos) {
				slider.derived_flags += {.Moving}
			}
		}
	}
}
