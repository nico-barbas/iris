package iris

import "core:os"
import "core:mem"
import "core:log"
import "core:time"
import "core:slice"
import "core:runtime"
import "core:math/rand"
import "core:path/filepath"

import "vendor:glfw"
import gl "vendor:OpenGL"

@(private)
app: ^App

App :: struct {
	using config:      App_Config,
	ctx:               runtime.Context,
	arena:             mem.Arena,
	frame_arena:       mem.Arena,
	frame_temp_memory: mem.Arena_Temp_Memory,
	win_handle:        glfw.WindowHandle,
	is_running:        bool,
	start_time:        time.Time,
	last_time:         time.Time,
	elapsed_time:      f64,
	input:             Input_Buffer,

	// Rendering states
	viewport_width:    int,
	viewport_height:   int,
	render_ctx:        Render_Context,

	// Resource library
	library:           Resource_Library,
}

App_Config :: struct {
	width:     int,
	height:    int,
	title:     string,
	decorated: bool,
	asset_dir: string,
	data:      App_Data,
	init:      proc(data: App_Data),
	update:    proc(data: App_Data),
	draw:      proc(data: App_Data),
	close:     proc(data: App_Data),
}

App_Data :: distinct rawptr

App_Module :: enum u8 {
	Window,
	IO,
	Input,
	Shader,
	Texture,
	GPU_Memory,
	Mesh,
	Skin,
	Text,
}

init_app :: proc(config: ^App_Config, allocator := context.allocator) {
	DEFAULT_ALLOCATOR_SIZE :: mem.Megabyte * 500
	DEFAULT_FRAME_ALLOCATOR_SIZE :: mem.Megabyte * 1000
	DEFAULT_GL_MAJOR_VERSION :: 4
	DEFAULT_GL_MINOR_VERSION :: 6

	app = new(App, allocator)
	app.config = config^
	app.ctx = context
	app.ctx.allocator = allocator

	mem.arena_init(&app.arena, make([]byte, DEFAULT_ALLOCATOR_SIZE, allocator))
	mem.arena_init(&app.frame_arena, make([]byte, DEFAULT_FRAME_ALLOCATOR_SIZE, allocator))
	app.ctx.allocator = mem.arena_allocator(&app.arena)
	app.ctx.temp_allocator = mem.arena_allocator(&app.frame_arena)
	app.ctx.logger = log.create_console_logger()

	dir := filepath.dir(os.args[0], app.ctx.temp_allocator)
	app.asset_dir = filepath.join(elems = {dir, app.asset_dir}, allocator = app.ctx.allocator)
	if err := os.set_current_directory(app.asset_dir); err != 0 {
		log.fatalf("%s: Could not set the app directory: %s\n", App_Module.IO, app.asset_dir)
		return
	}
	if glfw.Init() == 0 {
		log.fatalf("Could not initialize GLFW..\n")
		return
	}

	monitor := glfw.GetPrimaryMonitor()
	video_mode := glfw.GetVideoMode(monitor)
	m_x, m_y := glfw.GetMonitorPos(monitor)

	glfw.WindowHint(glfw.DECORATED, 1 if config.decorated else 0)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, DEFAULT_GL_MAJOR_VERSION)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, DEFAULT_GL_MINOR_VERSION)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, 1)
	glfw.WindowHint(glfw.SAMPLES, 4)
	glfw.WindowHint(glfw.VISIBLE, 0)

	app.win_handle = glfw.CreateWindow(
		i32(app.width),
		i32(app.height),
		cstring(raw_data(app.title)),
		nil,
		nil,
	)
	if app.win_handle == nil {
		log.fatalf("Could not initialize GLFW Window..")
		return
	}

	glfw.SetWindowPos(
		app.win_handle,
		m_x + (video_mode.width - i32(app.width)) / 2,
		m_y + (video_mode.height - i32(app.height)) / 2,
	)
	glfw.ShowWindow(app.win_handle)

	glfw.MakeContextCurrent(app.win_handle)
	gl.load_up_to(
		DEFAULT_GL_MAJOR_VERSION,
		DEFAULT_GL_MINOR_VERSION,
		proc(p: rawptr, name: cstring) {(cast(^rawptr)p)^ = glfw.GetProcAddress(name)},
	)
	gl.Enable(gl.DEBUG_OUTPUT)
	gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS)
	gl.DebugMessageCallback(gl_debug_cb, nil)
	gl.Enable(gl.MULTISAMPLE)
	gl.Enable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
	gl.BlendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE)

	app.viewport_width = app.width
	app.viewport_height = app.height
	gl.Viewport(0, 0, i32(app.width), i32(app.height))
	glfw.SwapInterval(1)

	default_callback :: proc(data: App_Data) {}
	if app.init == nil {
		app.init = default_callback
	}
	if app.update == nil {
		app.update = default_callback
	}
	if app.draw == nil {
		app.draw = default_callback
	}
	if app.close == nil {
		app.close = default_callback
	}
	app.input.registered_key_proc.allocator = app.ctx.allocator

	char_buf := make([]rune, 50, app.ctx.allocator)
	app.input.char_buf = slice.to_dynamic(char_buf)
	glfw.SetKeyCallback(app.win_handle, key_callback)
	glfw.SetCharCallback(app.win_handle, char_callback)
	glfw.SetMouseButtonCallback(app.win_handle, mouse_button_callback)
	glfw.SetScrollCallback(app.win_handle, mouse_scroll_callback)
}

run_app :: proc() {
	context = app.ctx
	app.is_running = true
	app.start_time = time.now()
	app.last_time = time.now()

	rand.set_global_seed(u64(app.last_time._nsec))
	init_library(&app.library)
	init_render_ctx(&app.render_ctx, app.width, app.height)
	app.init(app.data)
	for app.is_running {
		app.is_running = bool(!glfw.WindowShouldClose(app.win_handle))
		app.frame_arena.offset = 0
		app.elapsed_time = time.duration_seconds(time.since(app.last_time))
		app.last_time = time.now()

		refresh_library(&app.library)
		app.update(app.data)

		gl.ClearColor(0.6, 0.6, 0.6, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		app.draw(app.data)

		update_input_buffer(&app.input)
		glfw.SwapBuffers(app.win_handle)
		glfw.PollEvents()
		m_x, m_y := glfw.GetCursorPos(app.win_handle)
		update_input_buffer_mouse_position(&app.input, {f32(m_x), f32(m_y)})
	}
}

close_app :: proc() {
	app.close(app.data)
	close_render_ctx(&app.render_ctx)
	close_library(&app.library)
	glfw.DestroyWindow(app.win_handle)
	glfw.Terminate()
	log.destroy_console_logger(app.ctx.logger)
	free_all(app.ctx.allocator)
	free_all(app.ctx.temp_allocator)
	delete(app.arena.data)
	delete(app.frame_arena.data)
	free(app)
}

close_app_on_next_frame :: proc() {
	app.is_running = false
}

elapsed_time :: proc() -> f64 {
	return app.elapsed_time
}

begin_temp_allocation :: proc() {
	app.frame_temp_memory = mem.begin_arena_temp_memory(&app.frame_arena)
}

end_temp_allocation :: proc() {
	mem.end_arena_temp_memory(app.frame_temp_memory)
}

@(private)
frame_allocator_offset :: proc() -> int {
	return app.frame_arena.offset
}

get_app :: proc() -> ^App {
	return app
}

set_app :: proc(ptr: rawptr) {
	app = cast(^App)ptr
}

@(private)
gl_debug_cb :: proc "c" (
	source: u32,
	type: u32,
	id: u32,
	severity: u32,
	length: i32,
	message: cstring,
	userParam: rawptr,
) {
	context = app.ctx
	// log.debug(message)
}
