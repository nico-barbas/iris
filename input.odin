package iris

import "core:log"
import "vendor:glfw"

Input_Buffer :: struct {
	keys:                          Keyboard_State,
	previous_keys:                 Keyboard_State,
	registered_key_proc:           map[Key]Input_Proc,
	char_buf:                      [dynamic]rune,

	// mouse buttons
	mouse_buttons:                 Mouse_State,
	previous_mouse_buttons:        Mouse_State,
	registered_mouse_buttons_proc: map[Mouse_Button]Input_Proc,

	// mouse position
	mouse_pos:                     Vector2,
	previous_mouse_pos:            Vector2,
	mouse_scroll:                  f64,
	previous_mouse_scroll:         f64,
}

Input_State :: distinct bit_set[Input_State_Kind]

Input_State_Kind :: enum {
	Just_Pressed,
	Pressed,
	Just_Released,
	Released,
}

Input_Proc :: #type proc(data: App_Data, state: Input_State)

@(private)
update_input_buffer :: proc(i: ^Input_Buffer) {
	i.previous_keys = i.keys
	i.previous_mouse_buttons = i.mouse_buttons
	i.previous_mouse_scroll = i.mouse_scroll
	i.mouse_scroll = 0

	clear(&i.char_buf)
}

@(private)
update_input_buffer_mouse_position :: proc(i: ^Input_Buffer, m_pos: Vector2) {
	i.previous_mouse_pos = i.mouse_pos
	i.mouse_pos = m_pos
}

Mouse_State :: distinct [len(Mouse_Button)]bool

Mouse_Button :: enum {
	Left   = 0,
	Right  = 1,
	Middle = 2,
}

mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
	context = app.ctx
	if button >= 0 && button < i32(max(Mouse_Button)) {
		btn := Mouse_Button(button)
		app.input.mouse_buttons[btn] = action == glfw.PRESS

		if p, exist := app.input.registered_mouse_buttons_proc[btn]; exist {
			p(app.data, mouse_button_state(btn))
		}
	}
}

set_mouse_button_proc :: proc(btn: Mouse_Button, p: Input_Proc) {
	if _, exist := app.input.registered_mouse_buttons_proc[btn]; exist {
		log.errorf("%s: Key proc already associated with key %s", App_Module.Input, btn)
	}
	app.input.registered_mouse_buttons_proc[btn] = p
}

mouse_position :: proc() -> Vector2 {
	return app.input.mouse_pos
}

mouse_delta :: proc() -> Vector2 {
	return app.input.mouse_pos - app.input.previous_mouse_pos
}

mouse_button_state :: proc(btn: Mouse_Button) -> (state: Input_State) {
	current := app.input.mouse_buttons[btn]
	previous := app.input.previous_mouse_buttons[btn]
	switch {
	case current && !previous:
		state = {.Just_Pressed, .Pressed}
	case current && previous:
		state = {.Pressed}
	case !current && previous:
		state = {.Just_Released, .Released}
	case !current && !previous:
		state = {.Released}
	}
	return
}

mouse_scroll_callback :: proc "c" (window: glfw.WindowHandle, x_offset: f64, y_offset: f64) {
	context = app.ctx
	app.input.mouse_scroll = y_offset
}

mouse_scroll :: proc() -> f64 {
	return app.input.previous_mouse_scroll
}

Keyboard_State :: distinct [max(Key)]bool

set_key_proc :: proc(key: Key, p: Input_Proc) {
	if _, exist := app.input.registered_key_proc[key]; exist {
		log.errorf("%s: Key proc already associated with key %s", App_Module.Input, key)
	}
	app.input.registered_key_proc[key] = p
}

key_state :: proc(key: Key) -> (state: Input_State) {
	current := app.input.keys[key]
	previous := app.input.keys[key]
	switch {
	case current && !previous:
		state = {.Just_Pressed, .Pressed}
	case current && previous:
		state = {.Pressed}
	case !current && previous:
		state = {.Just_Released, .Released}
	case !current && !previous:
		state = {.Released}
	}
	return
}

pressed_char :: proc() -> []rune {
	return app.input.char_buf[:]
}

key_callback :: proc "c" (window: glfw.WindowHandle, k, scancode, action, mods: i32) {
	context = app.ctx
	key := Key(k)
	app.input.keys[key] = action == glfw.PRESS || action == glfw.REPEAT

	if p, exist := app.input.registered_key_proc[key]; exist {
		p(app.data, key_state(key))
	}
}

char_callback :: proc "c" (window: glfw.WindowHandle, r: rune) {
	context = app.ctx
	append(&app.input.char_buf, r)
}


Key :: enum i32 {
	Space         = 32,
	Apostrophe    = 39,
	Comma         = 44,
	Minus         = 45,
	Period        = 46,
	Slash         = 47,
	Semicolon     = 59,
	Equal         = 61,
	Left_bracket  = 91,
	Backslash     = 92,
	Right_bracket = 93,
	Grave_accent  = 96,
	World_1       = 161,
	World_2       = 162,
	Zero          = 48,
	One           = 49,
	Two           = 50,
	Three         = 51,
	Four          = 52,
	Five          = 53,
	Six           = 54,
	Seven         = 55,
	Height        = 56,
	Nine          = 57,
	A             = 65,
	B             = 66,
	C             = 67,
	D             = 68,
	E             = 69,
	F             = 70,
	G             = 71,
	H             = 72,
	I             = 73,
	J             = 74,
	K             = 75,
	L             = 76,
	M             = 77,
	N             = 78,
	O             = 79,
	P             = 80,
	Q             = 81,
	R             = 82,
	S             = 83,
	T             = 84,
	U             = 85,
	V             = 86,
	W             = 87,
	X             = 88,
	Y             = 89,
	Z             = 90,
	Escape        = 256,
	Enter         = 257,
	Tab           = 258,
	Backspace     = 259,
	Insert        = 260,
	Delete        = 261,
	Right         = 262,
	Left          = 263,
	Down          = 264,
	Up            = 265,
	Page_up       = 266,
	Page_down     = 267,
	Home          = 268,
	End           = 269,
	Caps_lock     = 280,
	Scroll_lock   = 281,
	Num_lock      = 282,
	Print_screen  = 283,
	Pause         = 284,
	F1            = 290,
	F2            = 291,
	F3            = 292,
	F4            = 293,
	F5            = 294,
	F6            = 295,
	F7            = 296,
	F8            = 297,
	F9            = 298,
	F10           = 299,
	F11           = 300,
	F12           = 301,
	F13           = 302,
	F14           = 303,
	F15           = 304,
	F16           = 305,
	F17           = 306,
	F18           = 307,
	F19           = 308,
	F20           = 309,
	F21           = 310,
	F22           = 311,
	F23           = 312,
	F24           = 313,
	F25           = 314,
	Kp_0          = 320,
	Kp_1          = 321,
	Kp_2          = 322,
	Kp_3          = 323,
	Kp_4          = 324,
	Kp_5          = 325,
	Kp_6          = 326,
	Kp_7          = 327,
	Kp_8          = 328,
	Kp_9          = 329,
	Kp_decimal    = 330,
	Kp_divide     = 331,
	Kp_multiply   = 332,
	Kp_subtract   = 333,
	Kp_add        = 334,
	Kp_enter      = 335,
	Kp_equal      = 336,
	Left_shift    = 340,
	Left_control  = 341,
	Left_alt      = 342,
	Left_super    = 343,
	Right_shift   = 344,
	Right_control = 345,
	Right_alt     = 346,
	Right_super   = 347,
	Menu          = 348,
}
