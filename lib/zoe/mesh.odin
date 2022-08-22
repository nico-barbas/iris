package zoe

Mesh :: struct {
	state:    Vertex_State,
	vertices: Buffer,
	indices:  Buffer,
}

Material :: struct {
	shader: Shader_Program,
	maps:   [4]Texture,
}
