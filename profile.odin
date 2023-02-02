package iris

import "core:fmt"
import "core:time"
import "core:runtime"
import "core:strings"

Profiler :: struct {
	procs: map[string]Proc_Profile,
}

Proc_Profile :: struct {
	loc:              runtime.Source_Code_Location,
	run_count:        int,
	start_time:       time.Time,
	end_time:         time.Time,
	frame_duration:   f64,
	average_duration: f64,
}

init_profiler :: proc(profiler: ^Profiler, allocator := context.allocator) {
	profiler.procs = make(map[string]Proc_Profile, 32, allocator)
}

destroy_profiler :: proc(profiler: ^Profiler) {

}

start_proc_profile :: proc(loc := #caller_location) {
	when ODIN_DEBUG {
		profiler := &app.profiler
		if loc.procedure not_in profiler.procs {
			profiler.procs[strings.clone(loc.procedure)] = Proc_Profile {
				loc = loc,
			}
		}

		profile := &profiler.procs[loc.procedure]
		profile.start_time = time.now()
		profile.run_count += 1
	}
}

end_proc_profile :: proc(loc := #caller_location) {
	when ODIN_DEBUG {
		profiler := &app.profiler
		if loc.procedure not_in profiler.procs {
			// FIXME: log it
			return
		}

		profile := &profiler.procs[loc.procedure]
		profile.end_time = time.now()

		duration := time.diff(profile.start_time, profile.end_time)
		profile.frame_duration = time.duration_microseconds(duration)

		ad := (profile.average_duration * f64(profile.run_count - 1) + profile.frame_duration)
		profile.average_duration = ad / f64(profile.run_count)
	}
}

print_profile :: proc() {
	profiler := &app.profiler
	builder: strings.Builder
	strings.builder_init_len_cap(&builder, 0, 512, context.temp_allocator)
	defer strings.builder_destroy(&builder)

	fmt.sbprintf(&builder, "Program Profile:\n")

	for procedure, profile in profiler.procs {
		fmt.sbprintf(&builder, "\t*%s() [line %d]:\n", procedure, profile.loc.line)
		fmt.sbprintf(
			&builder,
			"\t\tAverage time: %0.6f us(%0.6f ms)\n",
			profile.average_duration,
			profile.average_duration / 1000,
		)
		fmt.sbprintf(&builder, "\t\tRun count: %d\n", profile.run_count)
	}

	fmt.println(strings.to_string(builder))
}
