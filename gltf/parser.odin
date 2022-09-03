package gltf

import "core:os"
import "core:encoding/json"
import "core:slice"
import "core:strings"
import "core:strconv"
import "core:path/filepath"

Format :: enum {
	Gltf_Embed,
	Gltf_External,
	Glb,
}

Error :: enum {
	None,
	Unsupported_Format,
	Json_Parsing_Error,
	Failed_To_Read_Gltf_File,
	Failed_To_Read_External_File,
	Invalid_Buffer_Uri,
	Invalid_Buffer_View_Length,
	Invalid_Accessor_Count,
	Invalid_Accessor_Type,
	Invalid_Accessor_Component_Type,
	Invalid_Image_Reference,
	Invalid_Mesh_Primitives,
	Invalid_Primitive_Attributes,
	Invalid_Texture_Info_Index,
}

parse_from_file :: proc(
	path: string,
	format: Format,
	allocator := context.allocator,
	temp_allocator := context.temp_allocator,
) -> (
	document: Document,
	err: Error,
) {
	context.allocator = allocator
	context.temp_allocator = temp_allocator

	dir := filepath.dir(path, context.temp_allocator)
	source, file_ok := os.read_entire_file(path, context.temp_allocator)

	if !file_ok {
		err = .Failed_To_Read_Gltf_File
		return
	}
	if format != .Gltf_External {
		err = .Unsupported_Format
		return
	}

	json_data, json_success := json.parse(data = source, allocator = context.temp_allocator)
	defer json.destroy_value(json_data)

	if json_success != nil {
		err = .Json_Parsing_Error
		return
	}

	json_doc, is_object := json_data.(json.Object)
	if !is_object {
		err = .Json_Parsing_Error
		return
	}

	// Buffers
	if json_buffers, has_buffer := json_doc["buffers"]; has_buffer {
		buffers := json_buffers.(json.Array) or_else {}
		document.buffers = make([]Buffer, len(buffers))

		for buffer, i in buffers {
			buffer_data := buffer.(json.Object) or_else {}

			buffer: Buffer
			buffer.name = strings.clone(buffer_data["name"].(string) or_else "")
			buffer.uri = strings.clone(buffer_data["uri"].(string))

			switch format {
			case .Gltf_Embed, .Glb:
			case .Gltf_External:
				uri_ok: bool
				buffer_path := filepath.join({dir, buffer.uri}, context.temp_allocator)
				buffer.data, uri_ok = os.read_entire_file(buffer_path)
				if !uri_ok {
					err = .Failed_To_Read_External_File
					return
				}
			}
			document.buffers[i] = Buffer(buffer)
		}
	}

	// Buffer views
	if json_buffer_views, had_views := json_doc["bufferViews"]; had_views {
		buffer_views := json_buffer_views.(json.Array) or_else {}
		document.views = make([]Buffer_View, len(buffer_views))

		for json_view, i in buffer_views {
			view_data := json_view.(json.Object) or_else {}

			start: uint
			end: uint

			view: Buffer_View
			view.name = strings.clone(view_data["name"].(string) or_else "")

			if buffer_index, has_index := view_data["buffer"]; has_index {
				view.buffer_index = uint(buffer_index.(json.Float))
			} else {
				err = .Invalid_Buffer_View_Length
				return
			}

			view.byte_offset = uint(view_data["byteOffset"].(json.Float) or_else 0)
			start = view.byte_offset

			if view_length, has_length := view_data["byteLength"]; has_length {
				view.byte_length = uint(view_length.(json.Float))
				end = view.byte_length + view.byte_offset
			} else {
				err = .Invalid_Buffer_View_Length
				return
			}

			if view_stride, has_stride := view_data["byteStride"]; has_stride {
				view.byte_stride = uint(view_stride.(json.Float))
				view.byte_stride = min(view.byte_stride, BUFFER_VIEW_MAX_BYTE_STRIDE)
				view.byte_stride = max(view.byte_stride, BUFFER_VIEW_MIN_BYTE_STRIDE)
			}

			if view_target, has_target := view_data["target"]; has_target {
				view.target = Buffer_View_Target(uint(view_target.(json.Float)))
			}

			view.byte_slice = cast([]byte)document.buffers[view.buffer_index].data[start:end]
			document.views[i] = view
		}
	}

	// Accessors
	if json_accessors, has_accessors := json_doc["accessors"]; has_accessors {
		accessors := json_accessors.(json.Array) or_else {}
		document.accessors = make([]Accessor, len(accessors))

		for json_accessor, i in accessors {
			accessor_data := json_accessor.(json.Object) or_else {}

			accessor: Accessor
			accessor.name = strings.clone(accessor_data["name"].(string) or_else "")

			if view_index, has_index := accessor_data["bufferView"]; has_index {
				accessor.view_index = uint(view_index.(json.Float))
				accessor.view = &document.views[accessor.view_index]
			}

			if accessor_count, has_count := accessor_data["count"]; has_count {
				accessor.count = uint(accessor_count.(json.Float))
			} else {
				err = .Invalid_Accessor_Count
				return
			}

			if accessor_offset, has_offset := accessor_data["offset"]; has_offset {
				accessor.byte_offset = uint(accessor_offset.(json.Float))
			}

			if normalized, has_norm := accessor_data["normalized"]; has_norm {
				accessor.normalized = normalized.(bool)
			}

			if kind, has_kind := accessor_data["type"]; has_kind {
				accessor.kind = to_accesor_kind(kind.(string))
			} else {
				err = .Invalid_Accessor_Type
				return
			}

			if component_kind, has_kind := accessor_data["componentType"]; has_kind {
				k := uint(component_kind.(json.Float))
				accessor.component_kind = Accessor_Component_Kind(k)
			} else {
				err = .Invalid_Accessor_Type
				return
			}

			data := accessor.view.byte_slice[accessor.byte_offset:]
			accessor.data = byte_slice_to_accessor_data(
				data,
				accessor.component_kind,
				accessor.kind,
			)
			document.accessors[i] = accessor
		}
	}

	// Images
	if json_images, has_images := json_doc["images"]; has_images {
		images := json_images.(json.Array)
		document.images = make([]Image, len(images))

		for json_image, i in images {
			image_data := json_image.(json.Object)

			img: Image
			img.name = strings.clone(image_data["name"].(string) or_else "")

			if image_uri, has_uri := image_data["uri"]; has_uri {
				img.reference = filepath.join({dir, image_uri.(string)})
			} else if image_view, has_view := image_data["bufferView"]; has_view {
				ref: Image_Embedded_Reference
				ref.view_index = uint(image_view.(json.Float))
				ref.view = &document.views[ref.view_index]

				if image_mime, has_mime := image_data["mimeType"]; has_mime {
					switch image_mime.(string) {
					case "image/jpeg":
						ref.mime_type = .Jpeg
					case "image/png":
						ref.mime_type = .Png
					}
				} else {
					err = .Invalid_Image_Reference
					return
				}
				img.reference = ref
			} else {
				err = .Invalid_Image_Reference
				return
			}
			document.images[i] = img
		}
	}

	// Texture samplers
	if json_samplers, has_samplers := json_doc["samplers"]; has_samplers {
		samplers := json_samplers.(json.Array)
		document.samplers = make([]Texture_Sampler, len(samplers))

		for json_sampler, i in samplers {
			sampler_info := json_sampler.(json.Object)

			sampler: Texture_Sampler
			sampler.name = strings.clone(sampler_info["name"].(string) or_else "")

			if sampler_mag, has_mag := sampler_info["magFilter"]; has_mag {
				sampler.mag_filter = Texture_Filter_Mode(uint(sampler_mag.(json.Float)))
			}

			if sampler_min, has_min := sampler_info["magFilter"]; has_min {
				sampler.min_filter = Texture_Filter_Mode(uint(sampler_min.(json.Float)))
			}

			if sampler_wrap_s, has_wrap_s := sampler_info["wrapS"]; has_wrap_s {
				sampler.wrap_s = Texture_Wrap_Mode(uint(sampler_wrap_s.(json.Float)))
			} else {
				sampler.wrap_s = .Repeat
			}

			if sampler_wrap_t, has_wrap_t := sampler_info["wrapT"]; has_wrap_t {
				sampler.wrap_t = Texture_Wrap_Mode(uint(sampler_wrap_t.(json.Float)))
			} else {
				sampler.wrap_s = .Repeat
			}

			document.samplers[i] = sampler
		}
	}

	// Textures
	if json_textures, has_textures := json_doc["textures"]; has_textures {
		textures := json_textures.(json.Array)
		document.textures = make([]Texture, len(textures))

		for json_texture, i in textures {
			texture_info := json_texture.(json.Object)

			texture: Texture
			texture.name = strings.clone(texture_info["name"].(string) or_else "")

			if texture_sampler, has_sampler := texture_info["sampler"]; has_sampler {
				texture.sampler_index = uint(texture_sampler.(json.Float))
				texture.sampler = &document.samplers[texture.sampler_index]
			}
			if texture_source, has_source := texture_info["source"]; has_source {
				texture.source_index = uint(texture_source.(json.Float))
				texture.source = &document.images[texture.source_index]
			} else {
				assert(false)
			}

			document.textures[i] = texture
		}
	}

	// Materials
	if json_materials, has_materials := json_doc["materials"]; has_materials {
		materials := json_materials.(json.Array)
		document.materials = make([]Material, len(materials))

		for json_material, i in materials {
			material_info := json_material.(json.Object)

			material: Material
			material.name = strings.clone(material_info["name"].(string) or_else "")

			if json_pbr_info, has_pbr := material_info["pbrMetallicRoughness"]; has_pbr {
				pbr_info := json_pbr_info.(json.Object)

				if base_clr_f, has_base_clr_f := pbr_info["baseColorFactor"]; has_base_clr_f {
					base_color_factor := base_clr_f.(json.Array)
					material.base_color_factor = {
						0 = f32(base_color_factor[0].(json.Float)),
						1 = f32(base_color_factor[1].(json.Float)),
						2 = f32(base_color_factor[2].(json.Float)),
						3 = f32(base_color_factor[3].(json.Float)),
					}
				} else {
					material.base_color_factor = {1, 1, 1, 1}
				}

				if base_clr_t, has_base_t := pbr_info["baseColorTexture"]; has_base_t {
					base_color_texture := base_clr_t.(json.Object)

					material.base_color_texture = parse_texture_info(
						&document,
						base_color_texture,
					) or_return
				} else {
					material.base_color_texture.present = false
				}

				if metallic_factor, has_m_factor := pbr_info["metallicFactor"]; has_m_factor {
					material.metallic_factor = f32(metallic_factor.(json.Float))
				} else {
					material.metallic_factor = 1
				}

				if roughness_factor, has_r_factor := pbr_info["roughnessFactor"]; has_r_factor {
					material.roughness_factor = f32(roughness_factor.(json.Float))
				} else {
					material.roughness_factor = 1
				}

				if mr_t, has_mr_t := pbr_info["metallicRoughnessTexture"]; has_mr_t {
					metallic_roughness_texture := mr_t.(json.Object)

					material.metallic_roughness_texture = parse_texture_info(
						&document,
						metallic_roughness_texture,
					) or_return
				} else {
					material.metallic_roughness_texture.present = false
				}
			}

			if normal_t, has_normal_t := material_info["normalTexture"]; has_normal_t {
				normal_texture := normal_t.(json.Object)

				n_texture_info: Normal_Texture_Info
				n_texture_info.info = parse_texture_info(&document, normal_texture) or_return

				if scale, has_scale := normal_texture["scale"]; has_scale {
					n_texture_info.scale = f32(scale.(json.Float))
				} else {
					n_texture_info.scale = 1
				}
				material.normal_texture = n_texture_info
			} else {
				material.normal_texture.present = false
			}

			if occ_t, has_occ_t := material_info["occlusionTexture"]; has_occ_t {
				occlusion_texture := occ_t.(json.Object)

				occ_texture_info: Occlusion_Texture_Info
				occ_texture_info.info = parse_texture_info(&document, occlusion_texture) or_return

				if strength, has_strength := occlusion_texture["strength"]; has_strength {
					occ_texture_info.strength = f32(strength.(json.Float))
				} else {
					occ_texture_info.strength = 1
				}
				material.occlusion_texture = occ_texture_info
			} else {
				material.occlusion_texture.present = false
			}

			if emissive_t, has_emissive_t := material_info["emissiveTexture"]; has_emissive_t {
				emissive_texture := emissive_t.(json.Object)

				material.emissive_texture = parse_texture_info(
					&document,
					emissive_texture,
				) or_return
			} else {
				material.emissive_texture.present = false
			}

			if emissive_f, has_emissive_factor := material_info["emissiveFactor"];
			   has_emissive_factor {
				emissive_factor := emissive_f.(json.Array)

				material.emissive_factor = {
					0 = f32(emissive_factor[0].(json.Float)),
					1 = f32(emissive_factor[1].(json.Float)),
					2 = f32(emissive_factor[2].(json.Float)),
				}
			} else {
				material.emissive_factor = {}
			}

			if alpha_mode, has_alpha_mode := material_info["alphaMode"]; has_alpha_mode {
				switch alpha_mode.(string) {
				case "OPAQUE":
					material.alpha_mode = .Opaque
				case "MASK":
					material.alpha_mode = .Mask
				case "BLEND":
					material.alpha_mode = .Blend
				}
			} else {
				material.alpha_mode = .Opaque
			}

			if alpha_cutoff, has_alpha_cutoff := material_info["alphaCutoff"]; has_alpha_cutoff {
				material.alpha_cutoff = f32(alpha_cutoff.(json.Float))
			} else {
				material.alpha_cutoff = 0.5
			}

			if double_sided, has_double_sided := material_info["doubleSided"]; has_double_sided {
				material.double_sided = double_sided.(json.Boolean)
			} else {
				material.double_sided = false
			}

			document.materials[i] = material
		}
	}

	// Meshes
	if json_meshes, has_meshes := json_doc["meshes"]; has_meshes {
		meshes := json_meshes.(json.Array)
		document.meshes = make([]Mesh, len(meshes))

		for json_mesh, i in meshes {
			mesh_info := json_mesh.(json.Object)

			mesh: Mesh
			mesh.name = strings.clone(mesh_info["name"].(string) or_else "")

			if json_primitives, has_primitives := mesh_info["primitives"]; has_primitives {
				primitives := json_primitives.(json.Array)
				mesh.primitives = make([]Primitive, len(primitives))

				for json_prim, j in primitives {
					prim_info := json_prim.(json.Object)

					primitive: Primitive
					if prim_mode, has_mode := prim_info["mode"]; has_mode {
						primitive.mode = Primitive_Render_Mode(uint(prim_mode.(json.Float)))
					} else {
						primitive.mode = .Triangles
					}

					if prim_indices, has_indices := prim_info["indices"]; has_indices {
						primitive.indices_index = uint(prim_indices.(json.Float))
						primitive.indices = &document.accessors[primitive.indices_index]
					}

					if prim_material, has_material := prim_info["material"]; has_material {
						primitive.material_index = uint(prim_material.(json.Float))
						primitive.material = &document.materials[primitive.material_index]
					}

					if prim_attributes, has_attributes := prim_info["attributes"]; has_attributes {
						attributes := prim_attributes.(json.Object)

						for attrib_name, attrib_index in attributes {
							index := uint(attrib_index.(json.Float))
							name := strings.clone(attrib_name)

							primitive.attributes[name] = {
								data  = &document.accessors[index],
								index = index,
							}
						}
					} else {
						err = .Invalid_Primitive_Attributes
						return
					}

					mesh.primitives[j] = primitive
				}
			} else {
				err = .Invalid_Mesh_Primitives
				return
			}

			// TODO: Mesh weights

			document.meshes[i] = mesh
		}
	}

	// Nodes
	if json_nodes, has_nodes := json_doc["nodes"]; has_nodes {
		nodes := json_nodes.(json.Array)
		document.nodes = make([]Node, len(nodes))

		for json_node, i in nodes {
			node_info := json_node.(json.Object)

			node: Node
			node.name = strings.clone(node_info["name"].(string) or_else "")

			if n_children, has_children := node_info["children"]; has_children {
				node_children := n_children.(json.Array)
				node.children = make([]^Node, len(node_children))
				node.children_indices = make([]uint, len(node_children))

				for child, j in node_children {
					node.children_indices[j] = uint(child.(json.Float))
				}
			}

			if m, has_matrix := node_info["matrix"]; has_matrix {
				mat := m.(json.Array)

				node_matrix: Mat4f32
				node_matrix[0][0] = f32(mat[0].(json.Float))
				node_matrix[0][1] = f32(mat[1].(json.Float))
				node_matrix[0][2] = f32(mat[2].(json.Float))
				node_matrix[0][3] = f32(mat[3].(json.Float))
				node_matrix[1][0] = f32(mat[4].(json.Float))
				node_matrix[1][1] = f32(mat[5].(json.Float))
				node_matrix[1][2] = f32(mat[6].(json.Float))
				node_matrix[1][3] = f32(mat[7].(json.Float))
				node_matrix[2][0] = f32(mat[8].(json.Float))
				node_matrix[2][1] = f32(mat[9].(json.Float))
				node_matrix[2][2] = f32(mat[10].(json.Float))
				node_matrix[2][3] = f32(mat[11].(json.Float))
				node_matrix[3][0] = f32(mat[12].(json.Float))
				node_matrix[3][1] = f32(mat[13].(json.Float))
				node_matrix[3][2] = f32(mat[14].(json.Float))
				node_matrix[3][3] = f32(mat[15].(json.Float))

				node.transform = node_matrix
			} else {
				node_trs: Translate_Rotate_Scale
				if node_trans, has_trans := node_info["translation"]; has_trans {
					node_translation := node_trans.(json.Array)

					node_trs.translation = {
						0 = f32(node_translation[0].(json.Float)),
						1 = f32(node_translation[1].(json.Float)),
						2 = f32(node_translation[2].(json.Float)),
					}
				} else {
					node_trs.translation = {}
				}

				if node_rot, has_rot := node_info["rotation"]; has_rot {
					node_rotation := node_rot.(json.Array)

					node_trs.rotation.x = f32(node_rotation[0].(json.Float))
					node_trs.rotation.y = f32(node_rotation[1].(json.Float))
					node_trs.rotation.z = f32(node_rotation[2].(json.Float))
					node_trs.rotation.w = f32(node_rotation[3].(json.Float))
				} else {
					node_trs.rotation = Quaternion(1)
				}
				if node_scale, has_scale := node_info["scale"]; has_scale {
					node_scale := node_scale.(json.Array)

					node_trs.scale = {
						0 = f32(node_scale[0].(json.Float)),
						1 = f32(node_scale[1].(json.Float)),
						2 = f32(node_scale[2].(json.Float)),
					}
				} else {
					node_trs.scale = {1, 1, 1}
				}
				node.transform = node_trs
			}

			node.data = nil
			if node_mesh, has_mesh := node_info["mesh"]; has_mesh {
				node.data = Node_Mesh_Data {
					mesh       = &document.meshes[uint(node_mesh.(json.Float))],
					mesh_index = uint(node_mesh.(json.Float)),
				}
			} else {

			}

			document.nodes[i] = node
		}

		for node in &document.nodes {
			if node.children_indices != nil {
				for index, j in node.children_indices {
					node.children[j] = &document.nodes[index]
				}
			}
		}
	}

	if json_scenes, has_scenes := json_doc["scenes"]; has_scenes {
		scenes := json_scenes.(json.Array)
		document.scenes = make([]Scene, len(scenes))

		for json_scene, i in scenes {
			scene_info := json_scene.(json.Object)

			scene: Scene
			scene.name = strings.clone(scene_info["name"].(string) or_else "")

			if scene_nodes, has_nodes := scene_info["nodes"]; has_nodes {
				nodes := scene_nodes.(json.Array)
				scene.nodes = make([]^Node, len(nodes))
				scene.node_indices = make([]uint, len(nodes))

				for node, j in nodes {
					scene.node_indices[j] = uint(node.(json.Float))
					scene.nodes[j] = &document.nodes[uint(node.(json.Float))]
				}
			}

			document.scenes[i] = scene
		}
	}

	if json_scene, has_root := json_doc["scene"]; has_root {
		document.root = &document.scenes[uint(json_scene.(json.Float))]
	}

	return
}

destroy_document :: proc(d: ^Document) {
	// Free buffers
	for buffer in d.buffers {
		delete(buffer.name)
		delete(buffer.uri)
		delete(buffer.data)
	}
	delete(d.buffers)

	// Free buffer views
	for view in d.views {
		delete(view.name)
	}
	delete(d.views)

	// Free accessors
	for accessor in d.accessors {
		delete(accessor.name)
	}
	delete(d.accessors)

	// Free images
	for img in d.images {
		delete(img.name)
		if uri, uri_ok := img.reference.(string); uri_ok {
			delete(uri)
		}
	}
	delete(d.images)

	// Free textures
	for texture in d.textures {
		delete(texture.name)
	}
	delete(d.textures)

	// Free texture samplers
	for sampler in d.samplers {
		delete(sampler.name)
	}
	delete(d.samplers)

	// Free materials
	for material in d.materials {
		delete(material.name)
		if material.base_color_texture.present {
			delete(material.base_color_texture.tex_coord_name)
		}
		if material.base_color_texture.present {
			delete(material.base_color_texture.tex_coord_name)
		}
		if material.metallic_roughness_texture.present {
			delete(material.metallic_roughness_texture.tex_coord_name)
		}
		if material.normal_texture.present {
			delete(material.normal_texture.tex_coord_name)
		}
		if material.occlusion_texture.present {
			delete(material.occlusion_texture.tex_coord_name)
		}
		if material.emissive_texture.present {
			delete(material.emissive_texture.tex_coord_name)
		}
	}
	delete(d.materials)

	// Free meshes
	for mesh in d.meshes {
		delete(mesh.name)
		for primitive in mesh.primitives {
			for name, _ in primitive.attributes {
				delete(name)
			}
		}
		delete(mesh.primitives)
		delete(mesh.weights)
	}
	delete(d.meshes)


	// Free nodes
	for node in d.nodes {
		delete(node.name)
		delete(node.children)
		delete(node.children_indices)
	}
	delete(d.nodes)

	// Free nodes
	for scene in d.scenes {
		delete(scene.name)
		delete(scene.nodes)
		delete(scene.node_indices)
	}
	delete(d.scenes)
}

@(private)
to_accesor_kind :: proc(t: string) -> (k: Accessor_Kind) {
	switch t {
	case "SCALAR":
		k = .Scalar
	case "VEC2":
		k = .Vector2
	case "VEC3":
		k = .Vector3
	case "VEC4":
		k = .Vector4
	case "MAT2":
		k = .Mat2
	case "MAT3":
		k = .Mat3
	case "MAT4":
		k = .Mat4
	}
	return
}

byte_slice_to_accessor_data :: proc(
	raw: []byte,
	c_kind: Accessor_Component_Kind,
	kind: Accessor_Kind,
) -> (
	result: Accessor_Data,
) {
	switch kind {
	case .Scalar:
		switch c_kind {
		case .Byte, .Unsigned_Byte:
			result = raw
		case .Short:
			result = slice.reinterpret([]i16, raw)
		case .Unsigned_Short:
			result = slice.reinterpret([]u16, raw)
		case .Unsigned_Int:
			result = slice.reinterpret([]u32, raw)
		case .Float:
			result = slice.reinterpret([]f32, raw)
		}
	case .Vector2:
		switch c_kind {
		case .Byte, .Unsigned_Byte:
			result = slice.reinterpret([]Vector2u8, raw)
		case .Short:
			result = slice.reinterpret([]Vector2i16, raw)
		case .Unsigned_Short:
			result = slice.reinterpret([]Vector2u16, raw)
		case .Unsigned_Int:
			result = slice.reinterpret([]Vector2u32, raw)
		case .Float:
			result = slice.reinterpret([]Vector2f32, raw)
		}
	case .Vector3:
		switch c_kind {
		case .Byte, .Unsigned_Byte:
			result = slice.reinterpret([]Vector3u8, raw)
		case .Short:
			result = slice.reinterpret([]Vector3i16, raw)
		case .Unsigned_Short:
			result = slice.reinterpret([]Vector3u16, raw)
		case .Unsigned_Int:
			result = slice.reinterpret([]Vector3u32, raw)
		case .Float:
			result = slice.reinterpret([]Vector3f32, raw)
		}
	case .Vector4:
		switch c_kind {
		case .Byte, .Unsigned_Byte:
			result = slice.reinterpret([]Vector4u8, raw)
		case .Short:
			result = slice.reinterpret([]Vector4i16, raw)
		case .Unsigned_Short:
			result = slice.reinterpret([]Vector4u16, raw)
		case .Unsigned_Int:
			result = slice.reinterpret([]Vector4u32, raw)
		case .Float:
			result = slice.reinterpret([]Vector4f32, raw)
		}
	case .Mat2:
		switch c_kind {
		case .Byte, .Unsigned_Byte:
			result = slice.reinterpret([]Mat2u8, raw)
		case .Short:
			result = slice.reinterpret([]Mat2i16, raw)
		case .Unsigned_Short:
			result = slice.reinterpret([]Mat2u16, raw)
		case .Unsigned_Int:
			result = slice.reinterpret([]Mat2u32, raw)
		case .Float:
			result = slice.reinterpret([]Mat2f32, raw)
		}
	case .Mat3:
		switch c_kind {
		case .Byte, .Unsigned_Byte:
			result = slice.reinterpret([]Mat3u8, raw)
		case .Short:
			result = slice.reinterpret([]Mat3i16, raw)
		case .Unsigned_Short:
			result = slice.reinterpret([]Mat3u16, raw)
		case .Unsigned_Int:
			result = slice.reinterpret([]Mat3u32, raw)
		case .Float:
			result = slice.reinterpret([]Mat3f32, raw)
		}
	case .Mat4:
		switch c_kind {
		case .Byte, .Unsigned_Byte:
			result = slice.reinterpret([]Mat4u8, raw)
		case .Short:
			result = slice.reinterpret([]Mat4i16, raw)
		case .Unsigned_Short:
			result = slice.reinterpret([]Mat4u16, raw)
		case .Unsigned_Int:
			result = slice.reinterpret([]Mat4u32, raw)
		case .Float:
			result = slice.reinterpret([]Mat4f32, raw)
		}
	}
	return
}

// FIXME: pass the max texcoord
@(private)
parse_texture_info :: proc(
	doc: ^Document,
	t_info: json.Object,
	max_coord := 1,
) -> (
	info: Texture_Info,
	err: Error,
) {
	info.present = true
	if texture_index, has_index := t_info["index"]; has_index {
		info.texture_index = uint(texture_index.(json.Float))
		info.texture = &doc.textures[info.texture_index]
	} else {
		err = .Invalid_Texture_Info_Index
		return
	}

	if tex_coord_index, has_tex_coord := t_info["texCoord"]; has_tex_coord {
		info.tex_coord_index = uint(tex_coord_index.(json.Float))
	}

	tex_coord_prefix := "TEXCOORD_"
	name_buf := make([]byte, len(tex_coord_prefix) + max_coord)
	copy(name_buf[:], tex_coord_prefix[:])
	info.tex_coord_name = strconv.append_uint(
		name_buf[len(tex_coord_prefix):],
		u64(info.tex_coord_index),
		10,
	)
	return
}
