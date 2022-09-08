package ui

Widget_List :: struct {
	data:            [dynamic]Widget,
	pattern:         Layout_Pattern,
	direction:       Direction,
	next:            Point,
	margin:          f32,
	padding:         f32,
	iteration_index: int,
}

Layout_Pattern :: enum {
	Row,
	Column,
}

Layout_Desc :: struct {
	pattern:   Layout_Pattern,
	direction: Direction,
	margin:    f32,
	padding:   f32,
}

list :: proc(
	desc: Layout_Desc,
	widgets: ..Widget,
	allocator := context.allocator,
) -> Widget_List {
	list := Widget_List {
		data = make([dynamic]Widget, allocator),
		pattern = desc.pattern,
		direction = desc.direction,
		next = Point{desc.margin, desc.margin},
		margin = desc.margin,
		padding = desc.padding,
	}
	append(&list.data, ..widgets)
	return list
}

append_list_widget :: proc(
	l: ^Widget_List,
	proto: $T,
	parent_rect: Rectangle,
	dim: f32,
) -> ^T {
	widget := new_widget(proto, false)
	switch l.pattern {
	case .Row:
		offset := l.next.y if l.direction == .Down else -(l.next.y + dim)
		widget.rect = Rectangle {
			x      = parent_rect.x + l.next.x,
			y      = parent_rect.y + offset,
			width  = parent_rect.width - (l.margin * 2),
			height = dim,
		}
		l.next.y += dim + l.padding
	case .Column:
		offset := l.next.x if l.direction == .Right else -(l.next.x + dim)
		widget.rect = Rectangle {
			x      = parent_rect.x + offset,
			y      = parent_rect.y + l.next.y,
			width  = dim,
			height = parent_rect.height - (l.margin * 2),
		}
		l.next.x += dim + l.padding
	}
	init_widget(widget)
	append(&l.data, widget)
	return widget
}

list_iterator :: proc(l: ^Widget_List) -> (val: Widget, idx: int, ok: bool) {
	if ok = l.iteration_index < len(l.data); ok {
		val = l.data[l.iteration_index]
		idx = l.iteration_index
		l.iteration_index += 1
	} else {
		l.iteration_index = 0
	}
	return
}

reset_list_iterator :: proc(l: ^Widget_List) {
	l.iteration_index = 0
}

Widget_ID :: distinct int

Widget :: struct {
	id:         Widget_ID,
	active:     bool,
	rect:       Rectangle,
	background: Background,
	derived:    Any_Widget,
}

Any_Widget :: union {
	^Layout,
	^Dummy_Widget,
	^Button,
	^Drop_Panel,
}

new_widget :: proc(proto: $T, init := true) -> ^T {
	w := new_clone(proto, ctx.allocator)
	w.derived = w
	if init {
		init_widget(w.base)
	}
	return w
}

Layout :: struct {
	using base: Widget,
	elements:   Widget_List,
}


Dummy_Widget :: struct {
	using base: Widget,
}

init_widget :: proc(widget: Widget) {
	switch w in widget.derived {
	case ^Dummy_Widget:
	case ^Button:
		w.background.clr = w.clr
		if w.text != nil {
			text := w.text.?
			init_text(&text, w.text_style, w.rect)
			w.text = text
		}

	case ^Layout:
	case ^Drop_Panel:
		w.background.clr = w.clr
		if w.text != nil {
			text := w.text.?
			init_text(&text, w.text_style, w.rect)
			w.text = text
		}
	}
}

update_widget :: proc(widget: Widget) {
	if !widget.active {
		return
	}

	switch w in widget.derived {
	case ^Dummy_Widget:
	case ^Button:
		update_button(w)
	case ^Layout:
		for elem in list_iterator(&w.elements) {
			update_widget(elem)
		}
	case ^Drop_Panel:
		update_drop_panel(w)
	}
}

move_widget :: proc(w: Widget, offset: Point) {
	widget := w
	base := (cast(^^Widget)&widget.derived)^
	base.rect.x += offset.x
	base.rect.y += offset.y
	switch d in widget.derived {
	case ^Dummy_Widget, ^Button:

	case ^Layout:
		for elem in list_iterator(&d.elements) {
			move_widget(elem, offset)
		}
	case ^Drop_Panel:
		for elem in list_iterator(&d.panel_elements) {
			move_widget(elem, offset)
		}
	}
}

draw_widget :: proc(buf: ^Command_Buffer, widget: Widget) {
	if !widget.active {
		return
	}

	switch w in widget.derived {
	case ^Dummy_Widget:
		draw_background(buf, w.background, w.rect)

	case ^Button:
		draw_background(buf, w.background, w.rect)
		if w.text != nil {
			append(buf, Text_Command(w.text.?))
		}

	case ^Layout:
		draw_background(buf, w.background, w.rect)
		for elem, i in list_iterator(&w.elements) {
			draw_widget(buf, elem)
		}

	case ^Drop_Panel:
		draw_drop_panel(buf, w)
	}
}

is_over_widget :: proc(widget: Widget) -> (on: bool) {
	if !widget.active {
		on = false
		return
	}

	switch w in widget.derived {
	case ^Dummy_Widget:
		on = in_rect_bounds(w.rect, ctx.m_pos)

	case ^Button:
		on = in_rect_bounds(w.rect, ctx.m_pos)

	case ^Layout:
		if on = in_rect_bounds(w.rect, ctx.m_pos); !on {
			defer reset_list_iterator(&w.elements)
			for elem in list_iterator(&w.elements) {
				if on = is_over_widget(elem); on {
					return
				}
			}
		}

	case ^Drop_Panel:
		on = in_rect_bounds(w.rect, ctx.m_pos)
		if !on && w.expanded {
			on = in_rect_bounds(w.panel_rect, ctx.m_pos)
			if !on {
				defer reset_list_iterator(&w.panel_elements)
				for elem in list_iterator(&w.panel_elements) {
					if on = is_over_widget(elem); on {
						return
					}
				}
			}
		}
	}
	return
}
