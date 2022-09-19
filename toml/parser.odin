package toml

Parser :: struct {
	lexer:    Lexer,
	current:  Token,
	previous: Token,
}

Error :: struct {
	kind:     Error_Kind,
	position: Position,
}

Error_Kind :: enum {
	None,
	Malformed_String,
	Malformed_Number,
}

parse :: proc(data: []byte, allocator := context.allocator) -> (document: Document) {

	return
}
