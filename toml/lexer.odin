package toml

Lexer :: struct {
	using current: Position,
	data:          string,
}

Position :: struct {
	offset: int,
	line:   int,
	column: int,
}

Span :: struct {
	start: Position,
	end:   Position,
}

Token :: struct {
	using span: Span,
	kind:       Token_Kind,
	text:       string,
}

Token_Kind_Set :: distinct bit_set[Token_Kind]

Token_Kind :: enum {
	Invalid,
	Eof,
	Newline,
	Comment,

	// 
	Identifier,
	Float,
	String,
	False,
	True,

	// Punctuation
	Dot,
	Comma,
	Equal,
	Open_Brace,
	Close_Brace,
	Open_Bracket,
	Close_Bracket,
	Double_Open_Bracket,
	Double_Close_Bracket,
}

@(private)
scan_token :: proc(l: ^Lexer) -> (token: Token, err: Error) {
	if is_eof(l) {
		return
	}
	skip_whitespace(l)

	token.span.start = l.current
	c := advance(l)
	switch c {
	case '\n':
		l.line += 1
		token.kind = .Newline
	case '.':
		token.kind = .Dot
	case ',':
		token.kind = .Comma
	case '=':
		token.kind = .Equal
	case '{':
		token.kind = .Open_Brace
	case '}':
		token.kind = .Close_Brace
	case '[':
		if !is_eof(l) && peek(l) == '[' {
			token.kind = .Double_Open_Bracket
		} else {
			token.kind = .Open_Bracket
		}
	case ']':
		if !is_eof(l) && peek(l) == ']' {
			token.kind = .Double_Close_Bracket
		} else {
			token.kind = .Close_Bracket
		}
	case '"':
		token.kind = .String
		lex_string: for {
			if is_eof(l) {
				err = Lexing_Error {
					base = {kind = .Malformed_String, position = l.current},
				}
				return
			}

			if advance(l) == '"' {
				break lex_string
			}
		}
	case:
		if is_number(c) {
			has_decimal := false
			lex_number: for {
				if is_eof(l) {
					break lex_number
				}

				next := peek(l)
				if next == '.' {
					if has_decimal {
						err = Lexing_Error {
							base = {kind = .Malformed_Number, position = l.current},
						}
						return
					}
					has_decimal = true
					advance(l)
				} else if is_number(next) {
					advance(l)
				} else {
					break lex_number
				}
			}
			token.kind = .Float
		} else if is_letter(c) {
			lex_identifier: for {
				if is_eof(l) {
					break lex_identifier
				}

				if is_letter(peek(l)) {
					advance(l)
				} else {
					break lex_identifier
				}
			}

			text := l.data[token.start.offset:l.current.offset]
			if text == "false" {
				token.kind = .False
			} else if text == "true" {
				token.kind = .True
			} else {
				token.kind = .Identifier
			}
		}
	}

	token.end = l.current
	token.text = l.data[token.start.offset:token.end.offset]
	return
}

@(private)
is_eof :: proc(l: ^Lexer) -> bool {
	return l.offset >= len(l.data)
}

@(private)
is_number :: proc(c: byte) -> bool {
	return c >= '0' && c <= '9'
}

@(private)
is_letter :: proc(c: byte) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

@(private)
advance :: proc(l: ^Lexer) -> byte {
	l.offset += 1
	l.column += 1
	return l.data[l.offset - 1]
}

@(private)
peek :: proc(l: ^Lexer) -> byte {
	return l.data[l.offset]
}

skip_whitespace :: proc(l: ^Lexer) {
	for {
		c := peek(l)
		if c == ' ' || c == '\r' || c == '\t' {
			advance(l)
		} else {
			break
		}
	}
}
