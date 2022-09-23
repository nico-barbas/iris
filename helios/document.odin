package helios

Document :: struct {
	name:       string,
	includes:   map[string]Include,
	prototypes: map[string]Shader_Prototype,
}

Include :: struct {
	kind: enum {
		Uniform,
		Procedure,
	},
	name: string,
	decl: string,
	body: string,
}

Shader_Prototype :: struct {
	name:             string,
	stages:           Stages,
	stage_prototypes: [len(Stage)]Stage_Prototype,
}

Stage_Prototype :: struct {
	template:     bool,
	includes:     []^Include,
	include_line: int,
	source:       string,
	extensions:   map[string]string,
}

Stages :: distinct bit_set[Stage]

Stage :: enum i32 {
	Invalid,
	Fragment,
	Vertex,
	Geometry,
	Compute,
	Tessalation_Eval,
	Tessalation_Control,
}

COMPUTE_REQUIRED_STAGE :: Stages{.Compute}
DEFAULT_REQUIRED_STAGE :: Stages{.Vertex, .Fragment}

@(private)
stage_str := map[Stage]string {
	.Invalid  = "",
	.Vertex   = "vertex",
	.Fragment = "fragment",
	.Compute  = "compute",
}
