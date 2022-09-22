package toml

import "core:strings"
import "core:strconv"

DEFAULT_KEY_BUFFER_CAP :: 64

Parser :: struct {
	lexer:      Lexer,
	current:    Token,
	previous:   Token,
	root:       Table,
	table:      ^Table,
	key_buffer: [DEFAULT_KEY_BUFFER_CAP]Key,
	key_count:  int,
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

parse_string :: proc(data: string, allocator := context.allocator) -> (root: Value) {
	return parse(transmute([]byte)data, allocator)
}

parse :: proc(data: []byte, allocator := context.allocator) -> (root: Value) {
	context.allocator = allocator
	parser := Parser {
		root = make(Table),
		lexer = Lexer{current = {line = 1}, data = string(data)},
	}
	for {
		token := consume_token(&parser)
		if token.kind == .Eof {
			break
		} else {
			parse_next(&parser)
		}
	}
	return
}

parse_next :: proc(p: ^Parser) -> (err: Error) {
	#partial switch p.current.kind {
	case .Open_Bracket:
		expect_one_of_next(p, {.Identifier}) or_return
		p.root[p.current.text] = make(Table)
		p.table = cast(^Table)&p.table[p.current.text]
	case .Double_Open_Bracket:
		assert(false)
	case .Identifier:
		key := parse_key(p) or_return
		value := parse_value(p) or_return

		insert_key_value(p.table, key, value) or_return
	}
	return
}

parse_key :: proc(p: ^Parser) -> (key: Key, err: Error) {
	first_key := p.current.text
	next := expect_one_of_next(p, {.Dot, .Equal}) or_return
	#partial switch next {
	case .Dot:
		dotted_key: Dotted_Key
		dotted_key.data = first_key
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
		value, _ = strconv.parse_f64(p.current.text)
	case .String:
		value = strings.clone(p.current.text)
	case .True:
		value = true
	case .False:
		value = false
	}
	return
}

insert_key_value :: proc(table: ^Table, key: Key, value: Value) -> (err: Error) {
	switch k in key {
	case Bare_Key:
		table[k] = value
	case Dotted_Key:
		if k.data not_in table {
			table[k.data] = make(Table)
		}
		t := cast(^Table)&table[k.data]
		insert_key_value(t, k.next^, value) or_return
	}
	return
}

destroy :: proc(table: Table) {
	destroy_value :: proc(value: Value) {
		switch v in value {
		case Nil:
		case Float:
		case String:
			delete(v)
		case Boolean:
		case Array:
			for _v in v {
				destroy_value(_v)
			}
			delete(v)
		case Table:
			for key, _v in v {
				destroy_value(_v)
				delete(key)
			}
			delete(v)
		}
	}
	destroy_value(table)
}
