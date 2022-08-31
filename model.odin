package iris

import "core:mem"
import "core:math/linalg"
import "gltf"

Model_Loader :: struct {
	flags:          Model_Loader_Flags,
	shader:         Shader,
	model:          ^Model,
	document:       ^gltf.Document,
	allocator:      mem.Allocator,
	temp_allocator: mem.Allocator,
}

Model_Loader_Flags :: distinct bit_set[Model_Loader_Flag]

Model_Loader_Flag :: enum {
	Flip_Normals,
}

Model :: struct {
	nodes: [dynamic]Model_Node,
}

Model_Node :: struct {
	mesh:      Mesh,
	transform: Matrix4,
	material:  Material,
}

load_model_from_gltf_node :: proc(loader: ^Model_Loader, node: ^gltf.Node) -> Model {
	traverse_node_tree :: proc(
		loader: ^Model_Loader,
		node: ^gltf.Node,
		parent_mat := linalg.MATRIX4F32_IDENTITY,
	) {
		node_matrix: Matrix4
		switch t in node.transform {
		case gltf.Translate_Rotate_Scale:
			node_matrix = linalg.matrix4_from_trs_f32(
				Vector3(t.translation),
				Quaternion(t.rotation),
				Vector3(t.scale),
			)
		case gltf.Mat4f32:
			node_matrix = t
		}
		node_matrix = linalg.matrix_mul(parent_mat, node_matrix)

		if data, ok := node.data.(gltf.Node_Mesh_Data); ok {
			begin_temp_allocation()
			mesh_node := Model_Node {
				mesh      = load_mesh_from_gltf_node(
					document = loader.document,
					node = node,
					geometry_allocator = loader.temp_allocator,
					layout_allocator = loader.allocator,
					flip_normals = .Flip_Normals in loader.flags,
				),
				transform = node_matrix,
				material  = get_material(data.mesh.primitives[0].material.name),
			}
			mesh_node.material.shader = loader.shader
			end_temp_allocation()
			append(&loader.model.nodes, mesh_node)
		}

		for child in node.children {
			begin_temp_allocation()
			traverse_node_tree(loader, child, node_matrix)
			end_temp_allocation()
		}
	}

	model: Model
	if loader.model == nil {
		model.nodes.allocator = loader.allocator
		loader.model = &model
	} else {
		loader.model.nodes.allocator = loader.allocator
	}
	traverse_node_tree(loader, node)
	return loader.model^
}

draw_model :: proc(model: Model, t: Transform) {
	for node in model.nodes {
		model_mat := linalg.matrix4_from_trs_f32(t.translation, t.rotation, t.scale)
		model_mat = linalg.matrix_mul(model_mat, node.transform)
		push_draw_command(
			Render_Mesh_Command{mesh = node.mesh, transform = model_mat, material = node.material},
		)
	}
}
