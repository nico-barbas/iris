package ui

// import "core:fmt"

Button :: struct {
	using base:     Widget,
	state:          Button_State,
	previous_state: Button_State,
	clr:            Color,
	hover_clr:      Color,
	press_clr:      Color,
	text:           Maybe(Text),
	text_style:     Text_Style,

	//
	data:           rawptr,
	callback:       proc(data: rawptr, id: Widget_ID),
	notify_parent:  ^bool,
}

Button_State :: enum {
	Idle,
	Hovered,
	Pressed,
}

button :: proc(colors: [3]Color) -> ^Button {
	btn := new(Button, ctx.allocator)
	btn.clr = colors[0]
	btn.hover_clr = colors[1]
	btn.press_clr = colors[2]
	return btn
}

update_button :: proc(btn: ^Button) {
	btn.previous_state = btn.state
	if in_rect_bounds(btn.rect, ctx.m_pos) {
		if ctx.m_left {
			if !ctx.previous_m_left {
				btn.state = .Pressed
			}
		} else {
			if ctx.previous_m_left {
				if btn.state == .Pressed {
					btn.state = .Idle
					if btn.callback != nil {
						btn.callback(btn.data, btn.id)
					}
					if btn.notify_parent != nil {
						btn.notify_parent^ = true
					}
				}
			} else {
				btn.state = .Hovered
			}
		}
	} else {
		btn.state = .Idle
	}
	if btn.state != btn.previous_state {
		set_dirty()
		switch btn.state {
		case .Idle:
			btn.background.clr = btn.clr
		case .Hovered:
			btn.background.clr = btn.hover_clr
		case .Pressed:
			btn.background.clr = btn.press_clr
		}
	}
}

Drop_Panel :: struct {
	using base:          Widget,
	state:               Button_State,
	previous_state:      Button_State,
	clr:                 Color,
	hover_clr:           Color,
	press_clr:           Color,
	close_on_notify:     bool,
	text:                Maybe(Text),
	text_style:          Text_Style,

	// Expand panel data
	expanded:            bool,
	expand_should_close: bool,
	expand_direction:    Direction,
	panel_rect:          Rectangle,
	panel_origin:        Point,
	panel_background:    Background,
	panel_elements:      Widget_List,
}

set_drop_panel_expand :: proc(d: ^Drop_Panel, dir: Direction, bg: Background, w: f32) {
	MIN_HEIGHT :: 15

	if len(d.panel_elements.data) > 0 {
		assert(false)
	}
	d.panel_background = bg
	d.panel_rect.width = w
	d.panel_rect.height = MIN_HEIGHT
	switch dir {
	case .Up:
		d.panel_rect.x = d.rect.x
		d.panel_rect.y = d.rect.y
	case .Right:
		d.panel_rect.x = d.rect.x + d.rect.width
		d.panel_rect.y = d.rect.y
	case .Left:
		d.panel_rect.x = d.rect.x + d.rect.width
		d.panel_rect.y = d.rect.y
	case .Down:
		d.panel_rect.x = d.rect.x
		d.panel_rect.y = d.rect.y + d.rect.height
	}
	d.expand_direction = dir
	d.panel_origin = Point{d.panel_rect.x, d.panel_rect.y}
}

append_drop_panel_element :: proc(d: ^Drop_Panel, proto: $T, dim: f32) -> ^T {
	if len(d.panel_elements.data) == 0 {
		if d.expand_direction == .Up {
			d.panel_rect.y = d.rect.y - d.panel_elements.margin
		}
		d.panel_rect.height = d.panel_elements.margin
	}

	widget := append_list_widget(
		&d.panel_elements,
		proto,
		Rectangle{d.panel_origin.x, d.panel_origin.y, d.panel_rect.width, 0},
		dim,
	)
	if d.close_on_notify {
		#partial switch w in widget.derived {
		case ^Button:
			w.notify_parent = &d.expand_should_close
		}
	}
	added := dim + d.panel_elements.padding
	#partial switch d.expand_direction {
	case .Up:
		d.panel_rect.y -= added
		fallthrough
	case:
		d.panel_rect.height += added
	}
	return widget
}

update_drop_panel :: proc(d: ^Drop_Panel) {
	d.previous_state = d.state
	if in_rect_bounds(d.rect, ctx.m_pos) {
		if ctx.m_left {
			if !ctx.previous_m_left {
				d.state = .Pressed
			}
		} else {
			if ctx.previous_m_left {
				if d.state == .Pressed {
					d.state = .Idle
					d.expanded = !d.expanded
				}
			} else {
				d.state = .Hovered
			}
		}
	} else {
		d.state = .Idle
	}
	if d.state != d.previous_state {
		set_dirty()
		switch d.state {
		case .Idle:
			d.background.clr = d.clr
		case .Hovered:
			d.background.clr = d.hover_clr
		case .Pressed:
			d.background.clr = d.press_clr
		}
	}
	if d.expanded {
		for elem in list_iterator(&d.panel_elements) {
			update_widget(elem)
		}
	}
	if d.expand_should_close {
		set_dirty()
		d.expanded = false
		d.expand_should_close = false
	}
}

draw_drop_panel :: proc(buf: ^Command_Buffer, d: ^Drop_Panel) {
	draw_background(buf, d.background, d.rect)
	if d.text != nil {
		append(buf, Text_Command(d.text.?))
	}

	if d.expanded {
		draw_background(buf, d.panel_background, d.panel_rect)
		for elem in list_iterator(&d.panel_elements) {
			draw_widget(buf, elem)
		}
	}
}
