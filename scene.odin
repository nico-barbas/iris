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
}

Any_Node :: union {
	^Empty_Node,
	^Model_Node,
	^Skin_Node,
}

Empty_Node :: struct {
	using base: Node,
}

Skin_Node :: struct {
	using base: Node,
	target:     ^Model_Node,
	joints:     []Transform,
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
	update_node_transform :: proc(node: ^Node, parent_transform: Matrix4) {
		if .Dirty_Transform in node.flags {
			node.flags -= {.Dirty_Transform}
		}
		node.global_transform = linalg.matrix_mul(node.local_transform, parent_transform)
		for child in node.children {
			update_node_transform(child, node.global_transform)
		}
	}
	for node in scene.nodes {
		if .Dirty_Transform in node.flags {
			parent_transform: Matrix4
			if .Root_Node in node.flags {
				parent_transform = linalg.MATRIX4F32_IDENTITY
			} else {
				parent_transform = node.parent.global_transform
			}
			update_node_transform(node, parent_transform)
		}
	}
}

render_scene :: proc(scene: ^Scene) {
	traverse_node :: proc(node: ^Node) {
		#partial switch n in node.derived {
		case ^Model_Node:
			mat_model := linalg.matrix_mul(n.global_transform, n.mesh_transform)
			for mesh, i in n.meshes {
				push_draw_command(
					Render_Mesh_Command{
						mesh = mesh,
						transform = mat_model,
						material = n.materials[i],
						cast_shadows = true,
					},
				)
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

	node.local_transform = local
	init_node(scene, node)
	append(&scene.nodes, node)
	return node
}

init_node :: proc(scene: ^Scene, node: ^Node) {
	node.children.allocator = scene.allocator
	node.local_transform = linalg.MATRIX4F32_IDENTITY
	node.global_transform = linalg.MATRIX4F32_IDENTITY
	switch n in node.derived {
	case ^Empty_Node:

	case ^Model_Node:
		n.meshes.allocator = scene.allocator
		n.materials.allocator = scene.allocator

	case ^Skin_Node:

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
	node.local_transform = linalg.matrix_mul(node.local_transform, transform)
	node.flags += {.Dirty_Transform}
}

node_local_transform :: proc(node: ^Node, t: Transform) {
	node.local_transform = linalg.matrix4_from_trs_f32(t = t.translation, r = t.rotation, s = t.scale)
	node.flags += {.Dirty_Transform}
}

Model_Loader :: struct {
	flags:  Model_Loader_Flags,
	shader: ^Shader,
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
		model.mesh_transform = node.global_transform
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

// model_node_from_mesh


// Model :: struct {
// 	nodes: [dynamic]_Model_Node,
// }

// _Model_Node :: struct {
// 	mesh:      ^Mesh,
// 	transform: Matrix4,
// 	material:  ^Material,
// }

// Model_Bone :: struct {
// 	id:           uint,
// 	transform:    Matrix4,
// 	inverse_bind: Matrix4,
// }

// Model_Loader :: struct {
// 	flags:          Model_Loader_Flags,
// 	shader:         ^Shader,
// 	model:          ^Model,
// 	document:       ^gltf.Document,
// 	allocator:      mem.Allocator,
// 	temp_allocator: mem.Allocator,
// }

// Model_Loader_Flags :: distinct bit_set[Model_Loader_Flag]

// Model_Loader_Flag :: enum {
// 	Flip_Normals,
// 	Load_Position,
// 	Load_Normal,
// 	Load_Tangent,
// 	Load_Joints0,
// 	Load_Weights0,
// 	Load_TexCoord0,

// 	// Specific data
// 	Load_Bones,
// }

// Model_Loading_Error :: enum {
// 	None,
// 	Missing_Mesh_Indices,
// 	Missing_Mesh_Attribute,
// }

// load_model_from_gltf_node :: proc(loader: ^Model_Loader, node: ^gltf.Node) -> Model {
// 	traverse_node_tree :: proc(loader: ^Model_Loader, node: ^gltf.Node) {
// 		if node.mesh != nil {
// 			data := node.mesh.?
// 			for _, i in data.primitives {
// 				begin_temp_allocation()
// 				mesh_node: _Model_Node

// 				mesh_res, err := load_mesh_from_gltf(loader = loader, p = &data.primitives[i])
// 				assert(err == nil)

// 				mesh_node.mesh = mesh_res.data.(^Mesh)
// 				mesh_node.transform = node.global_transform

// 				material, exist := material_from_name(data.primitives[0].material.name)
// 				if !exist {
// 					material = load_material_from_gltf(data.primitives[0].material^)
// 				}
// 				mesh_node.material = material
// 				mesh_node.material.shader = loader.shader
// 				end_temp_allocation()
// 				append(&loader.model.nodes, mesh_node)
// 			}
// 		}

// 		if node.skin != nil && .Load_Bones in loader.flags {
// 			data := node.skin.?
// 			ibm: []Matrix4
// 			switch gltf_ibm in data.inverse_bind_matrices {
// 			case gltf.Skin_Accessor_Inverse_Bind_Matrices:
// 				ibm = slice.reinterpret([]Matrix4, gltf_ibm.data.([]gltf.Mat4f32))
// 			case gltf.Skin_Identity_Inverse_Bind_Matrices:
// 				ibm = slice.reinterpret([]Matrix4, gltf_ibm)
// 			}
// 			for joint, i in data.joints {
// 				bone := Model_Bone {
// 					id           = uint(i),
// 					transform    = joint.global_transform,
// 					inverse_bind = ibm[i],
// 				}
// 				append(&loader.model.bones, bone)
// 			}
// 		}

// 		for child in node.children {
// 			begin_temp_allocation()
// 			traverse_node_tree(loader, child)
// 			end_temp_allocation()
// 		}
// 	}

// 	model: Model
// 	if loader.model == nil {
// 		model.nodes.allocator = loader.allocator
// 		loader.model = &model
// 	} else {
// 		loader.model.nodes.allocator = loader.allocator
// 	}
// 	traverse_node_tree(loader, node)
// 	return loader.model^
// }

// draw_model :: proc(model: Model, t: Transform) {
// 	for node in model.nodes {
// 		model_mat := linalg.matrix4_from_trs_f32(t.translation, t.rotation, t.scale)
// 		model_mat = linalg.matrix_mul(model_mat, node.transform)
// 		push_draw_command(
// 			Render_Mesh_Command{mesh = node.mesh, transform = model_mat, material = node.material},
// 		)
// 	}
// }


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
