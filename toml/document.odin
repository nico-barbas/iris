package toml

Document :: distinct Table

Node :: union {
	Nil,
	Float,
	String,
	Boolean,
	Array,
	Table,
}

Nil :: struct {}
String :: string
Float :: f64
Boolean :: bool
Array :: distinct [dynamic]Node
Table :: distinct map[string]Node
