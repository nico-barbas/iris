package gltf

Document :: struct {
	buffers:    []Buffer,
	views:      []Buffer_View,
	accessors:  []Accessor,
	root:       ^Scene,
	scenes:     []Scene,
	nodes:      []Node,
	meshes:     []Mesh,
	materials:  []Material,
	images:     []Image,
	textures:   []Texture,
	samplers:   []Texture_Sampler,
	animations: []Animation,
	skins:      []Skin,
}

Scene :: struct {
	name:         string,
	nodes:        []^Node,
	node_indices: []uint,
}

Node :: struct {
	name:             string,
	transform:        union {
		Translate_Rotate_Scale,
		Mat4f32,
	},
	children:         []^Node,
	children_indices: []uint,
	data:             Node_Data,
}

Node_Data :: union {
	Node_Mesh_Data,
	Node_Mesh_Weights_Data,
	Node_Skin_Data,
	Node_Camera_Data,
}

Node_Mesh_Data :: struct {
	mesh:       ^Mesh,
	mesh_index: uint,
}

Node_Mesh_Weights_Data :: struct {
	mesh:       ^Mesh,
	mesh_index: uint,
	weigths:    []f32,
}

Node_Skin_Data :: struct {}
Node_Camera_Data :: struct {}

Animation :: struct {
	name:     string,
	samplers: []Animation_Sampler,
	channels: []Animation_Channel,
}

Animation_Sampler :: struct {
	interpolation: Animation_Interpolation,
	input:         ^Accessor,
	input_index:   uint,
	output:        ^Accessor,
	output_index:  uint,
}

Animation_Interpolation :: enum uint {
	Linear,
	Step,
	Cubispline,
}

Animation_Channel :: struct {
	sampler:       ^Animation_Sampler,
	sampler_index: uint,
	target:        Animation_Channel_Target,
}

Animation_Channel_Target :: struct {
	node:       ^Node,
	node_index: uint,
	path:       Animation_Channel_Path,
}

Animation_Channel_Path :: enum {
	Translation,
	Rotation,
	Scale,
	Weights,
}

Skin :: struct {
	name:                  string,
	skeleton:              ^Node,
	skeleton_index:        uint,
	joints:                []^Node,
	joint_indices:         []uint,
	inverse_bind_matrices: Skin_Inverse_Bind_Matrices,
}

Skin_Inverse_Bind_Matrices :: union {
	Skin_Accessor_Inverse_Bind_Matrices,
	Skin_Identity_Inverse_Bind_Matrices,
}

Skin_Accessor_Inverse_Bind_Matrices :: struct {
	data:  ^Accessor,
	index: uint,
}

Skin_Identity_Inverse_Bind_Matrices :: distinct []Mat4f32

Mesh :: struct {
	name:       string,
	primitives: []Primitive,
	weights:    []f32,
}

Primitive :: struct {
	mode:           Primitive_Render_Mode,
	attributes:     map[string]struct {
		data:  ^Accessor,
		index: uint,
	},
	indices:        ^Accessor,
	indices_index:  uint,
	material:       ^Material,
	material_index: uint,
	// TODO: targets
}

Primitive_Render_Mode :: enum uint {
	Points         = 0,
	Lines          = 1,
	Line_Loop      = 2,
	Line_Strip     = 3,
	Triangles      = 4,
	Triangle_Strip = 5,
	Triangle_Fan   = 6,
}

Material :: struct {
	name:                       string,
	base_color_factor:          [4]f32,
	base_color_texture:         Texture_Info,
	metallic_factor:            f32,
	roughness_factor:           f32,
	metallic_roughness_texture: Texture_Info,
	normal_texture:             Normal_Texture_Info,
	occlusion_texture:          Occlusion_Texture_Info,
	emissive_texture:           Texture_Info,
	emissive_factor:            [3]f32,
	alpha_mode:                 Material_Alpha_Mode,
	alpha_cutoff:               f32,
	double_sided:               bool,
}

Material_Alpha_Mode :: enum uint {
	Opaque,
	Mask,
	Blend,
}

Normal_Texture_Info :: struct {
	using info: Texture_Info,
	scale:      f32,
}

Occlusion_Texture_Info :: struct {
	using info: Texture_Info,
	strength:   f32,
}

Texture_Info :: struct {
	present:         bool,
	texture:         ^Texture,
	texture_index:   uint,
	tex_coord_name:  string,
	tex_coord_index: uint,
}

Texture :: struct {
	name:          string,
	sampler:       ^Texture_Sampler,
	sampler_index: uint,
	source:        ^Image,
	source_index:  uint,
}

Texture_Sampler :: struct {
	name:       string,
	mag_filter: Texture_Filter_Mode,
	min_filter: Texture_Filter_Mode,
	wrap_s:     Texture_Wrap_Mode,
	wrap_t:     Texture_Wrap_Mode,
}

Texture_Filter_Mode :: enum uint {
	Nearest                = 9728,
	Linear                 = 9729,
	Nearest_Mipmap_Nearest = 9984,
	Linear_Mipmap_Nearest  = 9985,
	Nearest_Mipmap_Linear  = 9986,
	Linear_Mipmap_Linear   = 9987,
}

Texture_Wrap_Mode :: enum uint {
	Clamp_To_Edge   = 33071,
	Mirrored_Repeat = 33648,
	Repeat          = 10497,
}

Image :: struct {
	name:      string,
	reference: Image_Reference,
}

Image_Reference :: union {
	Image_Embedded_Reference,
	string,
}

Image_Embedded_Reference :: struct {
	view:       ^Buffer_View,
	view_index: uint,
	mime_type:  enum {
		Jpeg,
		Png,
	},
}

Buffer :: struct {
	name:        string, // Owned
	uri:         string, // Owned
	data:        []byte, // Owned
	byte_length: uint,
}

Buffer_View :: struct {
	name:         string, // Owned
	buffer_index: uint,
	byte_offset:  uint,
	byte_length:  uint,
	byte_stride:  uint,
	byte_slice:   []byte, // Borrowed
	target:       Buffer_View_Target,
}

Buffer_View_Target :: enum uint {
	Array_Buffer         = 34962,
	Element_Array_Buffer = 34963,
}

BUFFER_VIEW_MIN_BYTE_STRIDE :: 4
BUFFER_VIEW_MAX_BYTE_STRIDE :: 252


Accessor :: struct {
	name:           string, // Owned
	view:           ^Buffer_View, // Borrowed
	view_index:     uint,
	count:          uint,
	byte_offset:    uint,
	normalized:     bool,
	data:           Accessor_Data, // Borrowed
	kind:           Accessor_Kind,
	component_kind: Accessor_Component_Kind,
}

Accessor_Kind :: enum uint {
	Scalar,
	Vector2,
	Vector3,
	Vector4,
	Mat2,
	Mat3,
	Mat4,
}

Accessor_Component_Kind :: enum uint {
	Byte           = 5120,
	Unsigned_Byte  = 5121,
	Short          = 5122,
	Unsigned_Short = 5123,
	Unsigned_Int   = 5125,
	Float          = 5126,
}

Accessor_Data :: union {
	// Scalar
	[]u8,
	[]i16,
	[]u16,
	[]u32,
	[]f32,

	// Vector2
	[]Vector2u8,
	[]Vector2i16,
	[]Vector2u16,
	[]Vector2u32,
	[]Vector2f32,

	// Vector3
	[]Vector3u8,
	[]Vector3i16,
	[]Vector3u16,
	[]Vector3u32,
	[]Vector3f32,

	// Vector4
	[]Vector4u8,
	[]Vector4i16,
	[]Vector4u16,
	[]Vector4u32,
	[]Vector4f32,

	// Matrix2
	[]Mat2u8,
	[]Mat2i16,
	[]Mat2u16,
	[]Mat2u32,
	[]Mat2f32,

	// Matrix3
	[]Mat3u8,
	[]Mat3i16,
	[]Mat3u16,
	[]Mat3u32,
	[]Mat3f32,

	// Matrix4
	[]Mat4u8,
	[]Mat4i16,
	[]Mat4u16,
	[]Mat4u32,
	[]Mat4f32,
}
