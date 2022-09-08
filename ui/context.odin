package ui

import "core:mem"

@(private)
ctx: ^Context

Context :: struct {
	roots:           [dynamic]Widget,
	allocator:       mem.Allocator,
	command_buf:     Command_Buffer,
	previous_m_pos:  Point,
	m_pos:           Point,
	m_left:          bool,
	previous_m_left: bool,
	hovered:         bool,
	dirty:           bool,
	force_draw:      bool,
}

Init_Callback :: #type proc(data: rawptr)

init_context :: proc(
	data: rawptr,
	init_cb: Init_Callback,
	allocator := context.allocator,
) {
	ctx = new(Context, allocator)
	ctx.allocator = allocator
	ctx.roots = make([dynamic]Widget, allocator)
	ctx.command_buf = make(Command_Buffer, allocator)
	ctx.force_draw = true
	init_cb(data)
}

add_root :: proc(proto: $T) -> ^T {
	context.allocator = ctx.allocator
	root := new_widget(proto)
	append(&ctx.roots, root)
	return root
}

update_ui :: proc(m_pos: Point, m_left: bool) {
	ctx.previous_m_left = ctx.m_left
	ctx.m_left = m_left
	ctx.previous_m_pos = ctx.m_pos
	ctx.m_pos = m_pos
	ctx.dirty = false
	for root in ctx.roots {
		update_widget(root)
	}
	if ctx.previous_m_pos != ctx.m_pos {
		ctx.hovered = false
		for root in ctx.roots {
			if ctx.hovered = is_over_widget(root); ctx.hovered {
				break
			}
		}
	}
}

draw_ui :: proc() -> (commands: []Draw_Command, dirty: bool) {
	if ctx.dirty || ctx.force_draw {
		dirty = true
		clear(&ctx.command_buf)
		if ctx.force_draw {
			ctx.force_draw = false
		}
		for root in ctx.roots {
			draw_widget(&ctx.command_buf, root)
		}
	}
	commands = ctx.command_buf[:]
	return
}

is_mouse_over_ui :: proc() -> bool {
	return ctx.hovered
}

@(private)
is_mouse_just_pressed :: proc() -> bool {
	return ctx.m_left && !ctx.previous_m_left
}

@(private)
set_dirty :: proc() {
	ctx.dirty = true
}
