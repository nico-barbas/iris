package toml

import "core:strconv"

Parser :: struct {
	lexer:    Lexer,
	current:  Token,
	previous: Token,
	root:     Table,
	table:    ^Table,

	key_buffer: []Key,
	key_count: int,
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
store_temp_key :: proc(p: ^Parser, key: Key) -> ^Key {
	p.key_buffer[p.key_count] = key
	return &p.key_buffer[p.key_count]
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
	#partial switch next {
	case .Open_Bracket:
		expect_one_of_next(p, {.Identifier}) or_return
		p.root[p.current.text] = make(Table)
		p.table = cast(^Table)&p.table[p.current.text]
	case .Double_Open_Bracket:
		assert(false)
	case .Identifier:
		key := parse_key(p) or_return
		value := pase_value(p) or_return

		insert_key_value(p, key, value) or_return
	}
	return
}

parse_key :: proc(p: ^Parser) -> (key: Key, err: Error) {
	first_key := p.current.text
	next := expect_one_of_next(p, {.Dot, .Equal}) or_return
	#partial switch next {
	case .Dot:
		dotted_key: Dotted_Key
		dotted_key = first_key
		next_key := parse_key(p) or_return
		dotted_key.next = store_temp_key(p, next_key)
	case .Equal:
		key = first_key
	}
	return
}

parse_value :: proc(p: ^Parser) -> (value: Value, err: Error) {
	next := expect_one_of_next(p, {.Float, .String, .True, .False}) or_return
	#partial switch next {
	case .Float:
		result, _ = strconv.parse_f64(p.current.text)
	case .String:
		result = p.current.text
	case .True:
		result = true
	case .False:
		result = false
	}
	return
}

insert_key_value :: proc(table: ^Table, key: Key, value: Value) -> (err: Error) {
	switch k in key {
	case Bare_Key:
		p.table[k] = value
	case Dotted_Key:
		if k not_in table {
			table[k] = make(Table) 
		}
		insert_key_value(&table[k], k.next^, value)
	}
}