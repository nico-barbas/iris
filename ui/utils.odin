package ui

Point :: distinct [2]f32

Direction :: enum {
	Up,
	Right,
	Down,
	Left,
}

Color :: distinct [4]u8

Rectangle :: struct {
	x, y:   f32,
	width:  f32,
	height: f32,
}

in_rect_bounds :: proc(rect: Rectangle, p: Point) -> bool {
	ok :=
		(p.x >= rect.x && p.x <= rect.x + rect.width) &&
		(p.y >= rect.y && p.y <= rect.y + rect.height)
	return ok
}

Font :: struct {
	data:         rawptr,
	measure_text: proc(f: ^Font, text: string, size: f32) -> Point,
	ascent:       proc(f: ^Font) -> f32,
}

Text :: struct {
	position: Point,
	str:      string,
	font:     Font,
	clr:      Color,
	size:     f32,
}

Text_Style :: enum {
	Center,
	// Right,
	// Left,
}

init_text :: proc(t: ^Text, style: Text_Style, rect: Rectangle) {
	text_size := t.font->measure_text(t.str, t.size)
	switch style {
	case .Center:
		t.position = Point{
			rect.x + (rect.width - text_size.x) / 2,
			rect.y + (rect.height - text_size.y) / 2,
		}
	}
}

Background :: struct {
	style: Background_Style,
	clr:   Color,
}

Background_Style :: enum {
	Solid,
	Image_Slice,
}

draw_background :: proc(buf: ^Command_Buffer, bg: Background, rect: Rectangle) {
	switch bg.style {
	case .Solid:
		append(buf, Rect_Command{rect, bg.clr})
	case .Image_Slice:
		assert(false)
	}
}

Command_Buffer :: distinct [dynamic]Draw_Command

Draw_Command :: union {
	Rect_Command,
	Text_Command,
}

Rect_Command :: struct {
	rect: Rectangle,
	clr:  Color,
}

Text_Command :: distinct Text
