package iris

import "core:mem"
import "core:thread"

Task :: thread.Task
Task_Proc :: thread.Task_Proc
THREAD_COUNT :: 4

DEFAULT_TASK_MEMORY :: mem.Megabyte * 4

Task_Options :: struct {
	owns_memory: bool,
	memory_size: int,
	index:       int,
}

init_threads :: proc(app: ^App) {
	context = app.ctx

	mem.arena_init(&app.pool_arena, make([]byte, mem.Megabyte * 10))
	app.pool_allocator = mem.arena_allocator(&app.pool_arena)

	thread.pool_init(&app.threads, app.pool_allocator, THREAD_COUNT)
	thread.pool_start(&app.threads)
}

destroy_threads :: proc(app: ^App) {
	thread.pool_destroy(&app.threads)
	free_all(app.pool_allocator)
	delete(app.arena.data)
}

add_task :: proc(task_proc: Task_Proc, data: rawptr, opt: Task_Options) {
	allocator := context.temp_allocator
	if (opt.owns_memory) {
		a := new(mem.Arena, allocator)
		mem.arena_init(a, make([]byte, opt.memory_size, allocator))
		allocator = mem.arena_allocator(a)
	}

	thread.pool_add_task(&app.threads, allocator, task_proc, data, opt.index)
}

wait_for_tasks :: proc() {
	thread.pool_finish(&app.threads)
}
