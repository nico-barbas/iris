package iris

import "core:os"
import "core:log"
import "core:fmt"
import "core:mem"
import "core:time"
import "core:dynlib"
import "core:strings"
import "core:path/filepath"
import win32 "core:sys/windows"
foreign import libc "system:c"

Plugin_Desc :: struct {
	source_dir:    string,
	dll_path:      string,
	load_symbol:   string,
	reload_symbol: string,
	unload_symbol: string,
	update_symbol: string,
}

Plugin_Flag :: enum {
	Build_On_Load,
	Dirty,
	Force_Reload,
	Unload_Dll,
}

Plugin_Flags :: distinct bit_set[Plugin_Flag]

Plugin :: struct {
	using desc:        Plugin_Desc,
	dll:               dynlib.Library,
	user_ptr:          rawptr,
	refresh_rate:      f64,
	last_reload:       time.Time,
	modification_time: time.Time,
	flags:             Plugin_Flags,
	load:              Plugin_Load_Proc,
	reload:            Plugin_Load_Proc,
	unload:            Plugin_Proc,
	update:            Plugin_Proc,
}

Plugin_Proc :: #type proc(ptr: rawptr)
Plugin_Load_Proc :: #type proc(app: rawptr, ptr: rawptr)

load_plugin :: proc(plugin: ^Plugin) -> (ok: bool) {
	if .Build_On_Load in plugin.flags {
		buf: [512]byte
		stdout := buf[:]

		build_cmd := fmt.tprintf(
			"odin build %s -out:%s -build-mode:dll -debug -strict-style -vet -collection:lib=%s",
			plugin.source_dir,
			plugin.dll_path,
			"../../lib",
		)
		_, build_ok, output_msg := build_plugin(build_cmd, &stdout)
		assert(build_ok)
		if len(output_msg) > 0 {
			log.debugf("[%s]: Plugin build output: %s\n", App_Module.IO, string(output_msg))
		}
	}

	plugin.dll = dynlib.load_library(plugin.dll_path, true) or_return
	load_plugin_symbols(plugin) or_return

	// FIXME: could probably do better here, but this will have to do 
	// for now to remember not to touch OpenGL from the dll side
	log.debugf(
		"[%s]: Successfully loaded custom plugin\n%s\n",
		App_Module.IO,
		"=> Be careful not to use any GPU allocation procs across DLL boundaries..",
	)

	plugin.modification_time = time.now()
	plugin.last_reload = time.now()
	plugin.load(get_app_ptr(), plugin.user_ptr)

	ok = true
	return
}

update_plugin :: proc(plugin: ^Plugin) {
	if .Force_Reload in plugin.flags {
		plugin.flags += {.Dirty, .Unload_Dll}
		plugin.flags -= {.Force_Reload}
	}

	time_since := time.since(plugin.last_reload)

	if time.duration_seconds(time_since) > plugin.refresh_rate {
		plugin.last_reload = time.now()

		files, _ := filepath.glob(fmt.tprintf("%v/*", plugin.source_dir), context.temp_allocator)
		for file in files {
			if !strings.has_suffix(file, ".odin") {
				continue
			}

			f, err := os.stat(file, context.temp_allocator)
			assert(err == os.ERROR_NONE)
			if time.diff(plugin.modification_time, f.modification_time) > 0 {
				plugin.modification_time = f.modification_time
				plugin.flags += {.Dirty, .Unload_Dll}
			}
		}
	}

	if .Dirty in plugin.flags {
		if .Unload_Dll in plugin.flags {
			dynlib.unload_library(plugin.dll)

			buf: [512]byte
			stdout := buf[:]

			build_cmd := fmt.tprintf(
				"odin build %s -out:%s -build-mode:dll -debug -strict-style -vet -collection:lib=%s",
				plugin.source_dir,
				plugin.dll_path,
				"../../lib",
			)

			_, ok, output_msg := build_plugin(build_cmd, &stdout)
			assert(ok)
			log.debugf("[%s]: Plugin build output: %s\n", App_Module.IO, string(output_msg))
		}
		lib_found: bool
		plugin.dll, lib_found = dynlib.load_library(plugin.dll_path, true)
		assert(lib_found)
		plugin.flags -= {.Dirty, .Unload_Dll}

		load_ok := load_plugin_symbols(plugin)
		assert(load_ok)

		log.debugf("[%s]: Successfully recompiled and loaded plugin\n")
		plugin.reload(get_app_ptr(), plugin.user_ptr)
	}

	plugin.update(plugin.user_ptr)
}

unload_plugin :: proc(plugin: ^Plugin) {
	plugin.unload(plugin.user_ptr)
	dynlib.unload_library(plugin.dll)
}

@(private)
load_plugin_symbols :: proc(plugin: ^Plugin) -> (ok: bool) {
	load_symbol := dynlib.symbol_address(plugin.dll, plugin.load_symbol) or_return
	plugin.load = cast(Plugin_Load_Proc)load_symbol

	reload_symbol := dynlib.symbol_address(plugin.dll, plugin.reload_symbol) or_return
	plugin.reload = cast(Plugin_Load_Proc)reload_symbol

	unload_symbol := dynlib.symbol_address(plugin.dll, plugin.unload_symbol) or_return
	plugin.unload = cast(Plugin_Proc)unload_symbol

	update_symbol := dynlib.symbol_address(plugin.dll, plugin.update_symbol) or_return
	plugin.update = cast(Plugin_Proc)update_symbol

	ok = true
	return
}

@(private)
build_plugin :: proc(command: string, stdout: ^[]byte) -> (u32, bool, []byte) {
	when ODIN_OS == .Windows {
		stdout_read: win32.HANDLE
		stdout_write: win32.HANDLE

		attributes: win32.SECURITY_ATTRIBUTES
		attributes.nLength = size_of(win32.SECURITY_ATTRIBUTES)
		attributes.bInheritHandle = true
		attributes.lpSecurityDescriptor = nil

		if win32.CreatePipe(&stdout_read, &stdout_write, &attributes, 0) == false {
			return 0, false, stdout[0:]
		}

		if !win32.SetHandleInformation(stdout_read, win32.HANDLE_FLAG_INHERIT, 0) {
			return 0, false, stdout[0:]
		}

		startup_info: win32.STARTUPINFO
		process_info: win32.PROCESS_INFORMATION

		startup_info.cb = size_of(win32.STARTUPINFO)

		startup_info.hStdError = stdout_write
		startup_info.hStdOutput = stdout_write
		startup_info.dwFlags |= win32.STARTF_USESTDHANDLES

		if !win32.CreateProcessW(
			   nil,
			   &win32.utf8_to_utf16(command)[0],
			   nil,
			   nil,
			   true,
			   0,
			   nil,
			   nil,
			   &startup_info,
			   &process_info,
		   ) {
			return 0, false, stdout[0:]
		}

		win32.CloseHandle(stdout_write)

		index: int
		read: u32

		read_buffer: [50]byte

		success: win32.BOOL = true

		for success {
			success = win32.ReadFile(stdout_read, &read_buffer[0], len(read_buffer), &read, nil)

			if read > 0 && index + cast(int)read <= len(stdout) {
				mem.copy(&stdout[index], &read_buffer[0], cast(int)read)
			}

			index += cast(int)read
		}

		stdout[index + 1] = 0

		exit_code: u32

		win32.WaitForSingleObject(process_info.hProcess, win32.INFINITE)

		win32.GetExitCodeProcess(process_info.hProcess, &exit_code)

		win32.CloseHandle(stdout_read)

		return exit_code, true, stdout[0:index]
	} else when ODIN_OS == .Linux {
		fp := popen(strings.clone_to_cstring(command, context.temp_allocator), "r")
		if fp == nil {
			return 0, false, stdout[0:]
		}
		defer pclose(fp)

		read_buffer: [50]byte
		index: int

		for fgets(&read_buffer[0], size_of(read_buffer), fp) != nil {
			read := bytes.index_byte(read_buffer[:], 0)
			defer index += cast(int)read

			if read > 0 && index + cast(int)read <= len(stdout) {
				mem.copy(&stdout[index], &read_buffer[0], cast(int)read)
			}
		}


		return 0, true, stdout[0:index]
	}
}


when ODIN_OS == .Linux {
	foreign libc {
		popen :: proc(command: cstring, type: cstring) -> ^FILE ---
		pclose :: proc(stream: ^FILE) -> i32 ---
		fgets :: proc "cdecl" (s: [^]byte, n: i32, stream: ^FILE) -> [^]u8 ---
		fgetc :: proc "cdecl" (stream: ^FILE) -> i32 ---
	}
}
