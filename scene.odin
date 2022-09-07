package iris

import "core:log"
import "core:mem"
import "core:slice"
import "core:math/linalg"

import "gltf"
import "allocators"

Scene :: struct {
	free_list: allocators.Free_List_Allocator,
	allocator: mem.Allocator,
	name:      string,
	nodes:     [dynamic]^Node,
	roots:     [dynamic]^Node,
}

Node :: struct {
	scene:            ^Scene,
	flags:            Node_Flags,
	local_transform:  Matrix4,
	global_transform: Matrix4,
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
	Rendered,
}

Any_Node :: union {
	^Empty_Node,
	^Model_Node,
	^Skin_Node,
}

Empty_Node :: struct {
	using base: Node,
}

Model_Node :: struct {
	using base:     Node,
	mesh_transform: Matrix4,
	meshes:         [dynamic]^Mesh,
	materials:      [dynamic]^Material,
}

init_scene :: proc(scene: ^Scene, allocator := context.allocator) {
	DEFAULT_SCENE_ALLOCATOR_SIZE :: mem.Megabyte * 50
	DEFAULT_SCENE_CAPACITY :: 20

	buf := make([]byte, DEFAULT_SCENE_ALLOCATOR_SIZE, allocator)
	allocators.init_free_list_allocator(&scene.free_list, buf, .Find_Best, 8)
	scene.allocator = allocators.free_list_allocator(&scene.free_list)

	context.allocator = scene.allocator
	scene.nodes = make([dynamic]^Node, 0, DEFAULT_SCENE_CAPACITY)
	scene.roots = make([dynamic]^Node, 0, DEFAULT_SCENE_CAPACITY)
}

destroy_scene :: proc(scene: ^Scene) {
	free_all(scene.allocator)
	delete(scene.free_list.data)
	delete(scene.name)
}

update_scene :: proc(scene: ^Scene, dt: f32) {
	traverse_node :: proc(node: ^Node, parent_transform: Matrix4, dt: f32) {
		if .Dirty_Transform in node.flags {
			node.flags -= {.Dirty_Transform}
		}
		node.global_transform = linalg.matrix_mul(node.local_transform, parent_transform)
		switch n in node.derived {
		case ^Empty_Node:

		case ^Model_Node:

		case ^Skin_Node:
			update_skin_node(n, dt)
		}
		for child in node.children {
			traverse_node(child, node.global_transform, dt)
		}
	}
	for root in scene.roots {
		traverse_node(root, linalg.MATRIX4F32_IDENTITY, dt)
	}
}

render_scene :: proc(scene: ^Scene) {
	traverse_node :: proc(node: ^Node) {
		#partial switch n in node.derived {
		case ^Model_Node:
			if .Rendered in n.flags {
				mat_model := linalg.matrix_mul(n.global_transform, n.mesh_transform)
				for mesh, i in n.meshes {
					push_draw_command(
						Render_Mesh_Command{
							mesh = mesh,
							global_transform = mat_model,
							material = n.materials[i],
							cast_shadows = true,
						},
					)
				}
			}
		case ^Skin_Node:
			if .Rendered in n.flags {
				mat_model := linalg.matrix_mul(n.target.global_transform, n.target.mesh_transform)
				for mesh, i in n.target.meshes {
					model_shader := n.target.materials[i].shader
					if _, exist := model_shader.uniforms["matJoints"]; exist {
						joint_matrices := skin_node_joint_matrices(n)
						set_shader_uniform(model_shader, "matJoints", &joint_matrices[0])
					}
					push_draw_command(
						Render_Mesh_Command{
							mesh = mesh,
							global_transform = mat_model,
							local_transform = n.target.local_transform,
							material = n.target.materials[i],
							cast_shadows = true,
						},
					)
				}
			}
		}
		for child in node.children {
			traverse_node(child)
		}
	}
	for root in scene.roots {
		traverse_node(root)
	}
}

new_node :: proc(scene: ^Scene, $T: typeid, local := linalg.MATRIX4F32_IDENTITY) -> ^T {
	node := new(T)
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

	case ^Model_Node:
		n.meshes.allocator = scene.allocator
		n.materials.allocator = scene.allocator
		n.flags += {.Rendered}

	case ^Skin_Node:
		n.flags -= {.Rendered}
		n.joint_roots.allocator = scene.allocator
		n.joint_lookup.allocator = scene.allocator
		n.animations.allocator = scene.allocator
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

Model_Loader :: struct {
	flags:  Model_Loader_Flags,
	shader: ^Shader,
}

Model_Loader_Flags :: distinct bit_set[Model_Loader_Flag]

Model_Loader_Flag :: enum {
	Flip_Normals,
	Use_Global_Transform,
	Use_Local_Transform,
	Use_Identity,
	Load_Position,
	Load_Normal,
	Load_Tangent,
	Load_Joints0,
	Load_Weights0,
	Load_TexCoord0,

	// Specific data
	Load_Bones,
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
		if .Use_Global_Transform in loader.flags {
			model.mesh_transform = node.global_transform
		} else if .Use_Local_Transform in loader.flags {
			model.mesh_transform = node.local_transform
		} else {
			model.mesh_transform = linalg.MATRIX4F32_IDENTITY
		}
		for _, i in data.primitives {
			begin_temp_allocation()

			mesh_res, err := load_mesh_from_gltf(loader = loader, p = &data.primitives[i])
			assert(err == nil)
			mesh := mesh_res.data.(^Mesh)

			material, exist := material_from_name(data.primitives[0].material.name)
			if !exist {
				material = load_material_from_gltf(data.primitives[0].material^)
			}
			material.shader = loader.shader

			end_temp_allocation()
			append(&model.meshes, mesh)
			append(&model.materials, material)
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
	err: Model_Loading_Error,
) {
	kind_to_float_count :: proc(kind: gltf.Accessor_Kind) -> uint {
		#partial switch kind {
		case .Vector2:
			return 2
		case .Vector3:
			return 3
		case .Vector4:
			return 4
		case .Scalar:
			return 1
		}
		unreachable()
	}
	MIN_ATTRIB_FLAG :: Model_Loader_Flag.Load_Position
	MAX_ATTRIB_FLAG :: Model_Loader_Flag.Load_TexCoord0

	if p.indices == nil {
		log.fatalf("%s: Only support indexed primitive", App_Module.Mesh)
		err = .Missing_Mesh_Indices
		return
	}
	indices: []u32
	vertices := make([dynamic]f32, 0, len(p.attributes) * 2 * 1000, context.temp_allocator)
	layout := make([dynamic]Vertex_Format, 0, len(p.attributes), context.temp_allocator)
	offsets := make([dynamic]int, 0, len(p.attributes), context.temp_allocator)

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

	count: uint
	offset: int
	if .Load_Position in loader.flags {
		if gltf_position, has_position := p.attributes[gltf.POSITION]; has_position {
			offset = int(count) * size_of(f32)
			count += gltf_position.data.count * kind_to_float_count(gltf_position.data.kind)
			data := gltf_position.data.data.([]gltf.Vector3f32)
			position := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float3)
			append(&offsets, offset)
			append(&vertices, ..position)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Normal in loader.flags {
		if gltf_normal, has_normal := p.attributes[gltf.NORMAL]; has_normal {
			offset = int(count) * size_of(f32)
			count += gltf_normal.data.count * kind_to_float_count(gltf_normal.data.kind)
			data := gltf_normal.data.data.([]gltf.Vector3f32)
			normal := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float3)
			append(&offsets, offset)
			append(&vertices, ..normal)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Tangent in loader.flags {
		if gltf_tangent, has_tangent := p.attributes[gltf.TANGENT]; has_tangent {
			offset = int(count) * size_of(f32)
			count += gltf_tangent.data.count * kind_to_float_count(gltf_tangent.data.kind)
			data := gltf_tangent.data.data.([]gltf.Vector4f32)
			tangent := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float4)
			append(&offsets, offset)
			append(&vertices, ..tangent)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Joints0 in loader.flags {
		if gltf_joints, has_joints := p.attributes[gltf.JOINTS_0]; has_joints {
			offset = int(count) * size_of(f32)
			temp_count := count
			count += gltf_joints.data.count * kind_to_float_count(gltf_joints.data.kind)
			data := gltf_joints.data.data.([]gltf.Vector4u16)
			joints := make([]f32, len(data) * 4, context.temp_allocator)
			for joint_ids, i in data {
				joints[i * 4] = f32(joint_ids.x)
				joints[i * 4 + 1] = f32(joint_ids.y)
				joints[i * 4 + 2] = f32(joint_ids.z)
				joints[i * 4 + 3] = f32(joint_ids.w)
			}
			append(&layout, Vertex_Format.Float4)
			append(&offsets, offset)
			append(&vertices, ..joints)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Weights0 in loader.flags {
		if gltf_weights, has_weights := p.attributes[gltf.WEIGHTS_0]; has_weights {
			offset = int(count) * size_of(f32)
			count += gltf_weights.data.count * kind_to_float_count(gltf_weights.data.kind)
			data := gltf_weights.data.data.([]gltf.Vector4f32)
			weights := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float4)
			append(&offsets, offset)
			append(&vertices, ..weights)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_TexCoord0 in loader.flags {
		if gltf_texcoord, has_texcoord := p.attributes[gltf.TEXCOORD_0]; has_texcoord {
			offset = int(count) * size_of(f32)
			count += gltf_texcoord.data.count * kind_to_float_count(gltf_texcoord.data.kind)
			data := gltf_texcoord.data.data.([]gltf.Vector2f32)
			texcoord := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float2)
			append(&offsets, offset)
			append(&vertices, ..texcoord)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	resource = mesh_resource(
		Mesh_Loader{
			vertices = vertices[:],
			indices = indices,
			format = .Packed_Blocks,
			layout = Vertex_Layout(layout[:]),
			offsets = offsets[:],
		},
	)
	return
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
			skin.joint_matrices[i] = skin.global_transform * joint.root_space_transform
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
				player.targets_start_value[i] = joint.local_transform.translation
			case .Rotation:
				player.targets[i] = &joint.local_transform.rotation
				player.targets_start_value[i] = joint.local_transform.rotation
			case .Scale:
				player.targets[i] = &joint.local_transform.scale
				player.targets_start_value[i] = joint.local_transform.scale
			}
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
