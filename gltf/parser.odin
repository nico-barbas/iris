package gltf

import "core:os"
import "core:json"
import "core:slice"
import "core:strings"
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
    Invalid_Buffer_Uri,
    Invalid_Buffer_View_Length,
    Invalid_Accessor_Count,
    Invalid_Accessor_Type,
    Invalid_Accessor_Component_Type,
}

parse_from_file :: proc(path: string, format: Format, allocator := context.allocator, temp_allocator := context.temp_allocator) -> Error {
	context.allocator = allocator
    context.temp_allocator = temp_allocator

    dir := filepath.dir(path, context.temp_allocator)
    source := os.read_entire_file(path, context.temp_allocator)

    if format != .Gltf_External {
		return .Unsupported_Format
	}
    json_data, json_success := json.parse(source, context.temp_allocator)
    defer json.destroy_value(json_data, context.temp_allocator)
    if json_success != nil {
        return .Json_Parsing_Error
    }

    document: Document

    read_files: map[string][]byte
    buffers_views: [dynamic]Buffer
    accessors: [dynamic]Accessor

    if json_buffers, has_buffer := json_data["buffers"]; has_buffer {
        buffers := json_buffers.(json.Array) or_else {}
        document.buffers = make([]Buffer, len(buffers))
        
        for buffer, i in buffers {
            buffer_data := buffer.(json.Object) or_else {} 
            uri := buffer_data["uri"].(string)
            data: []byte
            
            switch format {
            case .Gltf_Embed, .Glb:
            case .Gltf_External:
                buffer_path := filepath.join({dir, uri}, context.temp_allocator)
                data = os.read_entire_file(buffer_path)
            }
            read_files[uri] = data
            document.buffers[i] = Buffer(data)
        }
    }

    if json_buffer_views, had_views := json_data["bufferViews"]; had_views {
        buffer_views := json_buffer_views.(json.Array) or_else {}

        for json_view in buffer_views {
            view_data := json_view.(json.Object) or_else {}

            start: uint
            end: uint

            view: Buffer_View
            view.byte_offset = uint(view_data["byteOffset"].(json.Float)) or_else 0
            start = view.byte_offset
            if view_length, has_length := view_data["byteLength"]; has_length {
                view.byte_length = uint(view_length.(json.Float))
                end = view.byte_length
            } else {
                return .Invalid_Buffer_View_Length
            }
            if buffer_index, has_index := view_data["buffer"]; has_index {
                view.buffer_index = uint(buffer_index.(json.Float))
            } else {
                return .Invalid_Buffer_View_Length
            }

            view.byte_slice = document.buffers[view.buffer_index][start:end]
            append(&buffer_views, view)
        }
    }

    // Accessor parsing
    if json_accessors, has_accessors := json_data["accessors"]; has_accessors {
        accessors := json_accessors.(json.Array) or_else {}

        for json_accessor in accessors {
            accessor_data := json_accessor.(json.Object) or_else {}

            accessor: Accessor
            if accesor_name, has_name := accessor_data["name"]; has_name {
                accessor.name = strings.clone(accesor_name.(string))
            }

            if view_index, has_index := accessor_data["bufferView"]; has_index {
                accessor.view_index = uint(view_index.(json.Float)
                accessor.view = &buffer_views[accessor.view_index]
            }

            if accessor_count, has_count := accessor_data["count"]; has_count {
                accessor.count = uint(accessor_count.(json.Float)
            } else {
                return .Invalid_Accessor_Count
            }

            if accessor_offset, has_offset := accessor_data["offset"]; has_offset {
                accessor.offset = uint(accessor_offset.(json.Float)
            }

            if normalized, has_norm := accessor_data["normalized"]; has_norm {
                accessor.normalized = normalized.(bool)
            }

            if kind, has_kind := accessor_data["type"]; has_kind {
                accessor.kind = to_accesor_kind(kind.(string))
            } else {
                return .Invalid_Accessor_Type
            }

            if component_kind, has_kind := accessor_data["componentType"]; has_kind {
                k := uint(kind.(json.Float))
                accessor.component_kind = Accessor_Component_Kind(k) 
            } else {
                return .Invalid_Accessor_Type
            }

            data := accessor.view.byte_slice[accessor.byte_offset:]
            accessor.data = slice.reinterpret([])
        }
    }
}

destroy_document :: proc(d: ^Document) {
    // Free buffers
    for buffer in d.buffers {
        delete(buffer)
    }
    delete(d.buffers)

    // Free buffer views
    delete(d.views)

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

byte_slice_to_accessor_data :: proc(raw: []byte, c_kind: Accessor_Component_Kind, kind: Accessor_Kind) -> (result: Accessor) {
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
        
        }
    case .Vector3:
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
    case .Vector4:
        switch c_kind {
        
        }
    case .Mat2:
        switch c_kind {
        
        }
    case .Mat3:
        switch c_kind {
        
        }
    case .Mat4:
        switch c_kind {
        
        }
    }
}