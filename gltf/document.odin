package gltf

Document :: struct {
    buffers: []Buffer,
    views: []Buffer_View,
    accessors: []Accessor,
	entry:  ^Scene,
	scenes: []Scene,
	nodes:  []Node,
	meshes: []Mesh,
}

Buffer :: distinct []byte

Buffer_View :: struct {
    buffer_index: uint,
    byte_offset: uint,
    byte_length: uint,
    byte_slice: []byte,
}

Scene :: struct {}

Node :: struct {}

Mesh :: struct {}

Primitive :: struct {
	position: []Vector3,
	normal:   []Vector3,
	tangent:  []Vector3,
}

Accessor :: struct {
    name: string,
    view: ^Buffer_View,
    view_index: uint,
    count: uint,
    offset: uint,
    normalized: bool,
    data: Accessor_Data,
    kind: Accessor_Kind,
    component_kind: Accessor_Component_Kind,
    min: Accessor_Data,
    max: Accessor_Data,

}

Accessor_Kind :: enum u8 {
    Scalar,
    Vector2,
    Vector3,
    Vector4,
    Mat2,
    Mat3,
    Mat4,
}

Accessor_Component_Kind :: enum u8 {
    Byte = 5120,
    Unsigned_Byte = 5121,
    Short = 5122,
    Unsigned_Short = 5123,
    Unsigned_Int = 5125,
    Float = 5126,
}

Accessor_Data :: union {
    []u8,
    []i16,
    []u16,
    []u32,
    []f32,

    []Vector2u8,
    []Vector2i16,
    []Vector2u16,
    []Vector2u32,
    []Vector2f32,

    []Vector3u8,
    []Vector3i16,
    []Vector3u16,
    []Vector3u32,
    []Vector3f32,
}