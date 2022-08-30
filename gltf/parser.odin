package gltf

import "core:os"
import "core:encoding/json"
import "core:slice"
import "core:strings"
import "core:path/filepath"
import "core:image"

Format :: enum {
	Gltf_Embed,
	Gltf_External,
	Glb,
}

Error :: enum {
	None,
	Unsupported_Format,
	Json_Parsing_Error,
	Failed_To_Read_External_File,
	Invalid_Buffer_Uri,
	Invalid_Buffer_View_Length,
	Invalid_Accessor_Count,
	Invalid_Accessor_Type,
	Invalid_Accessor_Component_Type,
	Invalid_Image_Reference,
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

	if format != .Gltf_External {
		err = .Unsupported_Format
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
				end = view.byte_length
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
				img.reference = strings.clone(image_uri.(string))
				image_err: image.Error
				img.data, image_err = image.load_from_file(image_uri.(string))

				if image_err != nil {
					err = .Failed_To_Read_External_File
					return
				}
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

				image_err: image.Error
				img.data, image_err = image.load_from_bytes(ref.view.byte_slice)
				if image_err != nil {
					err = .Failed_To_Read_External_File
					return
				}
				img.reference = ref
			} else {
				err = .Invalid_Image_Reference
				return
			}
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
			if texture_source, has_source := texture_info["sampler"]; has_source {
				texture.source_index = uint(texture_source.(json.Float))
				texture.source = &document.images[texture.source_index]
			} else {
				assert(false)
			}

			document.textures[i] = texture
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
					}
				}
			}

			// TODO: Mesh weights
		}
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
		image.destroy(img.data)
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

	// Free scenes
	delete(d.scenes)

	// Free nodes
	delete(d.nodes)

	// Free meshes
	delete(d.meshes)

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
