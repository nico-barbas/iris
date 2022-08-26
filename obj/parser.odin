package obj

import "core:strconv"

Vertex_Data :: distinct []f32
Index_Data :: distinct []u32

Vertex :: struct {
	position: [3]f32,
	uv:       [2]f32,
	normal:   [3]f32,
}

Intermediate_Index :: struct {
	data: [3]int,
	kind: enum {
		Pos,
		PosTex,
		PosNormal,
		PosTexNormal,
	},
}

Parser :: struct {
	source:  string,
	current: int,
}

Obj_Error :: enum {
	OK,
	Malformed_Number,
}

parse_obj :: proc(source: string, allocator := context.allocator) -> (err: Obj_Error) {
	positions: [dynamic][3]f32
	positions.allocator = context.temp_allocator
	uvs: [dynamic][2]f32
	uvs.allocator = context.temp_allocator
	normals: [dynamic][3]f32
	normals.allocator = context.temp_allocator

	indexes: [dynamic]Intermediate_Index
	indexes.allocator = context.temp_allocator
	p := Parser {
		source = source,
	}
	parse: for {
		c := advance(&p)
		if c == EOF {
			break parse
		}

		switch c {
		case 'v':
			n := peek(&p)
			switch n {
			case 't':
				uv := [2]f32{}
				for i in 0 ..< 2 {
					skip_whitespaces(&p)
					uv[i] = parse_float(&p) or_return
				}
				append(&uvs, uv)
				skip(&p, '\n')
			case 'n':
				normal := [3]f32{}
				for i in 0 ..< 3 {
					skip_whitespaces(&p)
					normal[i] = parse_float(&p) or_return
				}
				append(&normals, normal)
				skip(&p, '\n')
			case ' ':
				pos := [3]f32{}
				for i in 0 ..< 3 {
					skip_whitespaces(&p)
					pos[i] = parse_float(&p) or_return
				}
				append(&positions, pos)
			case:
				assert(false)
			}

		case 'f':
            for i in 
		}
	}
	return
}

EOF: byte : 0

@(private)
advance :: proc(p: ^Parser) -> byte {
	p.current += 1
	if p.current >= len(p.source) {
		return EOF
	}
	return p.source[p.current - 1]
}

@(private)
peek :: proc(p: ^Parser) -> byte {
	if p.current >= len(p.source) {
		return EOF
	}
	return p.source[p.current]
}

@(private)
skip :: proc(p: ^Parser, to: byte) {
	if peek(p) == to {
		return
	}
	loop: for {
		c := advance(p)
		if c == EOF || c == to {
			break loop
		}
	}
}

@(private)
skip_whitespaces :: proc(p: ^Parser) {
	for {
		c := peek(p)
		if c != EOF && (c == ' ' || c == '\r' || c == '\t') {
			advance(p)
		} else {
			break
		}
	}
}

@(private)
parse_float :: proc(p: ^Parser) -> (n: f32, err: Obj_Error) {
	has_decimal := false
	start := p.current
	signed: bool
	sign := peek(p)
	if sign == '-' {
		signed = true
		advance(p)
	}
	parse: for {
		c := peek(p)
		if c != EOF {
			switch c {
			case '0' ..= '9':
				advance(p)
			case '.':
				if !has_decimal {
					has_decimal = true
					advance(p)
				} else {
					assert(false)
				}
			case ' ':
				break parse
			case:
				assert(false)
			}
		} else {
			break parse
		}
	}
	ok: bool
	n, ok = strconv.parse_f32(p.source[start:p.current])
	if !ok {
		err = .Malformed_Number
	}
	if signed {
		n = -n
	}
	return
}

@(private)
parse_int :: proc(p: ^Parser) -> (n: int, err: Obj_Error) {
	start := p.current
	signed: bool
	sign := peek(p)
	if sign == '-' {
		signed = true
		advance(p)
	}
	parse: for {
		c := peek(p)
		if c != EOF {
			switch c {
			case '0' ..= '9':
				advance(p)
			case ' ':
				break parse
			case:
				assert(false)
			}
		} else {
			break parse
		}
	}
	ok: bool
	n, ok = strconv.parse_int(p.source[start:p.current])
	if !ok {
		err = .Malformed_Number
	}
	if signed {
		n = -n
	}
	return
}

@(private)
parse_index :: proc(p: ^Parser) -> (i: Intermediate_Index, err: Obj_Error) {
	n := parse_int(p) or_return

	next := advance(p)
	switch next {
	case '/':
		if peek(p) == '/' {
			advance(p)
			n2 := parse_int(p) or_return
			i = Intermediate_Index {
				data = [3]int{n, n2, 0},
				kind = .PosNormal,
			}
		} else {
			n2 := parse_int(p) or_return
			if advance(p) == '/' {
				n3 := parse_int(p) or_return
				i = Intermediate_Index {
					data = [3]int{n, n2, n3},
					kind = .PosTexNormal,
				}
			} else {
				i = Intermediate_Index {
					data = [3]int{n, n2, 0},
					kind = .PosTex,
				}
			}
		}
	case ' ':
		i = Intermediate_Index {
			data = [3]int{n, 0, 0},
			kind = .Pos,
		}
	case:
		assert(false)
	}

	return
}
