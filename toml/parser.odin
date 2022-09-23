package toml

import "core:strings"
import "core:strconv"

DEFAULT_KEY_BUFFER_CAP :: 64

Parser :: struct {
	lexer:       Lexer,
	current:     Token,
	previous:    Token,
	root:        Table,
	table_path:  Key,
	table:       ^Table,
	key_buffer:  [DEFAULT_KEY_BUFFER_CAP]Key,
	key_count:   int,
	path_buffer: [DEFAULT_KEY_BUFFER_CAP]Key,
	path_count:  int,
	key_pool:    map[string]string,
}

Error :: union {
	Lexing_Error,
	Invalid_Token_Error,
	Key_Redeclaration_Error,
}

Error_Info :: struct {
	kind:     Error_Kind,
	position: Position,
}

Error_Kind :: enum {
	None,
	Malformed_String,
	Malformed_Multiline_String,
	Malformed_Number,
	Invalid_Token,
	Key_Redeclaration,
}

Invalid_Token_Error :: struct {
	using base: Error_Info,
	allowed:    Token_Kind_Set,
	actual:     Token_Kind,
}

// TODO: For better usability, this error should 
// return the absolute path of the parent table
Key_Redeclaration_Error :: struct {
	using base: Error_Info,
	parent:     Key,
	key:        Key,
}

Lexing_Error :: struct {
	using base: Error_Info,
}

@(private)
get_bare_key :: proc(p: ^Parser, input: Bare_Key) -> Bare_Key {
	if pooled_key, exist := p.key_pool[input]; exist {
		return pooled_key
	} else {
		new_key := strings.clone(input)
		p.key_pool[new_key] = new_key
		return new_key
	}
}

@(private)
store_temp_key :: proc(p: ^Parser, key: Key) -> ^Key {
	p.key_buffer[p.key_count] = key
	p.key_count += 1
	return &p.key_buffer[p.key_count - 1]
}

@(private)
reset_key_buffer :: proc(p: ^Parser) {
	p.key_count = 0
}

@(private)
store_table_path :: proc(p: ^Parser, key: Key) {
	p.path_count = 0
	switch k in key {
	case Bare_Key:
		p.table_path = k
	case Dotted_Key:
		p.path_buffer[0] = k
		p.path_count += 1
		current := p.path_buffer[0].(Dotted_Key)
		loop: for current.next != nil {
			switch next in current.next {
			case Bare_Key:
				p.path_buffer[p.path_count] = next
				p.path_count += 1
				break loop
			case Dotted_Key:
				p.path_buffer[p.path_count] = next
				p.path_count += 1
				current.next = &p.path_buffer[p.path_count - 1]
				current = next
			}
		}
		p.table_path = p.path_buffer[0]
	}
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

parse_string :: proc(
	data: string,
	allocator := context.allocator,
) -> (
	document: Document,
	err: Error,
) {
	return parse(transmute([]byte)data, allocator)
}

parse :: proc(data: []byte, allocator := context.allocator) -> (document: Document, err: Error) {
	context.allocator = allocator
	parser := Parser {
		root = make(Table),
		lexer = Lexer{current = {line = 1}, data = string(data)},
	}
	parser.table = &parser.root
	parser.key_pool.allocator = context.allocator

	loop: for {
		token := consume_token(&parser)
		#partial switch token.kind {
		case .Eof:
			break loop
		case .Newline:
			continue loop
		case:
			parse_next(&parser) or_return
		}
	}
	document.root = parser.root
	document.keys = parser.key_pool
	return
}

parse_next :: proc(p: ^Parser) -> (err: Error) {
	#partial switch p.current.kind {
	case .Open_Bracket:
		expect_one_of_next(p, {.Identifier}) or_return
		table_path := parse_key(p, .Close_Bracket) or_return
		table := make(Table)
		t := insert_key_value(p, &p.root, table_path, table) or_return
		p.table = cast(^Table)t
		store_table_path(p, table_path)
	case .Double_Open_Bracket:
		expect_one_of_next(p, {.Identifier}) or_return
		aot_path := parse_key(p, .Double_Close_Bracket) or_return
		aot: ^Array
		if v, exist := value_from_key(&p.root, aot_path); exist {
			aot = cast(^Array)v
		} else {
			value := make(Array)
			v := insert_key_value(p, &p.root, aot_path, value) or_return
			aot = cast(^Array)v
		}
		table := make(Table)
		append(aot, table)
		store_table_path(p, aot_path)
		p.table = cast(^Table)&aot[len(aot) - 1]
	case .Identifier:
		key := parse_key(p, .Equal) or_return
		value := parse_value(p) or_return

		insert_key_value(p, p.table, key, value) or_return
	}
	reset_key_buffer(p)
	return
}

parse_key :: proc(p: ^Parser, end_token: Token_Kind) -> (key: Key, err: Error) {
	first_key := p.current.text
	next := expect_one_of_next(p, {.Dot, end_token}) or_return
	#partial switch next {
	case .Dot:
		dotted_key: Dotted_Key
		dotted_key.data = get_bare_key(p, first_key)
		expect_one_of_next(p, {.Identifier}) or_return
		next_key := parse_key(p, end_token) or_return
		dotted_key.next = store_temp_key(p, next_key)
		key = dotted_key
	case end_token:
		key = get_bare_key(p, first_key)
	}
	return
}

parse_value :: proc(p: ^Parser) -> (value: Value, err: Error) {
	ALLOWED_VALUE_OPENING_TOKEN :: Token_Kind_Set{
		.Float,
		.String,
		.True,
		.False,
		.Open_Bracket,
		.Open_Brace,
	}
	next := expect_one_of_next(p, ALLOWED_VALUE_OPENING_TOKEN) or_return
	#partial switch next {
	case .Float:
		value, _ = strconv.parse_f64(p.current.text)
	case .String:
		value = strings.clone(p.current.text)
	case .True:
		value = true
	case .False:
		value = false
	case .Open_Bracket:
		array := make(Array)
		array_loop: for {
			element := parse_value(p) or_return
			append(&array, element)
			sep := expect_one_of_next(p, {.Comma, .Close_Bracket}) or_return
			if sep == .Close_Bracket {
				break array_loop
			}
		}
		value = array
	case .Open_Brace:
		table := make(Table)
		table_loop: for {
			expect_one_of_next(p, {.Identifier}) or_return
			inline_key := parse_key(p, .Equal) or_return
			inline_value := parse_value(p) or_return
			insert_key_value(p, &table, inline_key, inline_value) or_return

			sep := expect_one_of_next(p, {.Comma, .Close_Brace}) or_return
			if sep == .Close_Brace {
				break table_loop
			}
		}
		value = table
	}
	return
}

insert_key_value :: proc(
	p: ^Parser,
	table: ^Table,
	key: Key,
	value: Value,
) -> (
	result: ^Value,
	err: Error,
) {
	switch k in key {
	case Bare_Key:
		if k in table {
			err = Key_Redeclaration_Error {
				base = Error_Info{kind = .Key_Redeclaration, position = p.current.start},
				parent = p.table_path,
				key = k,
			}
		}
		table[k] = value
		result = &table[k]
	case Dotted_Key:
		if k.data not_in table {
			table[k.data] = make(Table)
		}
		t: ^Table
		#partial switch entry in table[k.data] {
		case Table:
			t = cast(^Table)&table[k.data]
		case Array:
			last_elemt := &entry[len(entry) - 1]
			t = cast(^Table)last_elemt
		case:
			assert(false)
		}
		result = insert_key_value(p, t, k.next^, value) or_return
	}
	return
}

@(private)
value_from_key :: proc(table: ^Table, key: Key) -> (result: ^Value, exist: bool) {
	switch k in key {
	case Bare_Key:
		if k in table {
			exist = true
			result = &table[k]
		}
	case Dotted_Key:
		if k.data not_in table {
			return
		}
		t: ^Table
		#partial switch entry in table[k.data] {
		case Table:
			t = cast(^Table)&table[k.data]
		case Array:
			last_elemt := &entry[len(entry) - 1]
			t = cast(^Table)last_elemt
		case:
			assert(false)
		}
		result, exist = value_from_key(t, k.next^)
	}
	return
}

destroy :: proc(document: Document) {
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
			for _, _v in v {
				destroy_value(_v)
			}
			delete(v)
		}
	}
	destroy_value(document.root)
	for key in document.keys {
		delete(key)
	}
	delete(document.keys)
}
