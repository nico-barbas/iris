package zoe

import "core:mem"
import "core:log"
import "core:runtime"
import "vendor:glfw"
import gl "vendor:OpenGL"

@(private)
app: ^App

App :: struct {
	using config:    App_Config,
	ctx:             runtime.Context,
	frame_arena:     mem.Arena,
	win_handle:      glfw.WindowHandle,
	is_running:      bool,
	viewport_width:  int,
	viewport_height: int,
}

App_Config :: struct {
	width:     int,
	height:    int,
	title:     string,
	decorated: bool,
	data:      App_Data,
	init:      proc(data: App_Data),
	update:    proc(data: App_Data),
	draw:      proc(data: App_Data),
	close:     proc(data: App_Data),
}

App_Data :: distinct rawptr

App_Module :: enum u8 {
	Window,
	Input,
	Shader,
	Texture,
	Buffer,
}

init_app :: proc(config: App_Config, allocator := context.allocator) {
	DEFAULT_FRAME_ALLOCATOR_SIZE :: mem.Megabyte * 100

	app = new(App, allocator)
	app.config = config
	app.ctx = runtime.default_context()
	app.ctx.allocator = allocator

	mem.arena_init(
		&app.frame_arena,
		make([]byte, DEFAULT_FRAME_ALLOCATOR_SIZE, allocator),
	)
	app.ctx.temp_allocator = mem.arena_allocator(&app.frame_arena)
	app.ctx.logger = log.create_console_logger()

	if glfw.Init() == 0 {
		log.fatalf("Could not initialize GLFW..")
		return
	}
	glfw.WindowHint(glfw.DECORATED, 1 if config.decorated else 0)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	glfw.WindowHint(glfw.OPENGL_DEBUG_CONTEXT, 1)

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

	glfw.MakeContextCurrent(app.win_handle)
	gl.load_up_to(
		3,
		3,
		proc(p: rawptr, name: cstring) {(cast(^rawptr)p)^ = glfw.GetProcAddress(name)},
	)
	gl.Enable(gl.DEBUG_OUTPUT)
	gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

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
}

run_app :: proc() {
	context = app.ctx
	app.is_running = true
	app.init(app.data)
	for app.is_running {
		app.is_running = bool(!glfw.WindowShouldClose(app.win_handle))
		app.update(app.data)

		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		app.draw(app.data)

		glfw.PollEvents()
		glfw.SwapBuffers(app.win_handle)
	}
}

close_app :: proc() {
	context = app.ctx
	app.close(app.data)
	glfw.DestroyWindow(app.win_handle)
	glfw.Terminate()
	log.destroy_console_logger(app.ctx.logger)
	free_all(app.ctx.temp_allocator)
}
