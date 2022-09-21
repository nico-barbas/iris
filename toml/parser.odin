package toml

import "core:strconv"

Parser :: struct {
	lexer:    Lexer,
	current:  Token,
	previous: Token,
	root:     ^Table,
	table:    ^Table,
}

Error :: union {
	Invalid_Token_Error,
	Lexing_Error,
}

Error_Info :: struct {
	kind:     Error_Kind,
	position: Position,
}

Error_Kind :: enum {
	None,
	Malformed_String,
	Malformed_Number,
	Invalid_Token,
}

Invalid_Token_Error :: struct {
	using base: Error_Info,
	allowed:    Token_Kind_Set,
	actual:     Token_Kind,
}

Lexing_Error :: struct {
	using base: Error_Info,
}

@(private)
consume_token :: proc(p: ^Parser) -> Token {
	p.previous = p.current
	p.current, _ = scan_token(&p.lexer)
	return p.current
}

expect_one_of :: proc(p: ^Parser, allowed: Token_Kind_Set) -> (err: Error) {
	if p.current.kind not_in allowed {
		err = Invalid_Token_Error {
			base = {kind = .Invalid_Token, position = p.current.start},
			allowed = allowed,
			actual = p.current.kind,
		}
	}
	return
}

expect_one_of_next :: proc(
	p: ^Parser,
	allowed: Token_Kind_Set,
) -> (
	actual: Token_Kind,
	err: Error,
) {
	consume_token(p)
	return p.current.kind, expect_one_of(p, allowed)
}

parse :: proc(data: []byte, allocator := context.allocator) -> (document: Document) {
	context.allocator = allocator
	return
}

parse_node :: proc(p: ^Parser) -> (result: Node, err: Error) {
	next := expect_one_of_next(p, {.Equal, .Dot}) or_return
	#partial switch next {
	case .Open_Bracket:
		expect_one_of_next(p, {.Identifier}) or_return
		p.table[p.current.text] = make(Table)
		p.table = cast(^Table)&p.table[p.current.text]
	case .Double_Open_Bracket:
		assert(false)
	case .Identifier:
		key, value := parse_pair(p) or_return
	}
	return
}

parse_pair :: proc(p: ^Parser) -> (key: Node, value: Node, err: Error) {
	key = p.current.text
	next := expect_one_of_next(p, {.Equal, .Dot}) or_return
	#partial switch next {
	case .Equal:
		value = parse_value(p) or_return
	case .Dot:
	}
	return
}

parse_value :: proc(p: ^Parser) -> (result: Node, err: Error) {
	next := expect_one_of_next(p, {.Float, .String, .True, .False}) or_return
	#partial switch next {
	case .Float:
		// ok: bool
		result, _ = strconv.parse_f64(p.current.text)
	// if !ok {}
	case .String:
		result = p.current.text
	case .True:
		result = true
	case .False:
		result = false
	}
	return
}

// parse_key_value :: proc(p: ^Parser) -> (result: Node, err: Error) {

// 	return
// }
