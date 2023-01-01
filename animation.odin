package iris

import "core:math"
import "core:math/linalg"
import "core:strings"
import "gltf"

Animation :: struct {
	name:     string,
	loop:     bool,
	duration: f32,
	channels: []Animation_Channel,
}

Animation_Channel :: struct {
	target_id:       uint,
	kind:            Animation_Channel_Kind,
	mode:            Interpolation_Mode,
	frame_durations: []f32,
	frame_outputs:   []Animation_Value,
}

Animation_Value :: union {
	f32,
	Vector2,
	Vector3,
	Quaternion,
}


Animation_Channel_Kind :: enum {
	Translation,
	Rotation,
	Scale,
}

Interpolation_Mode :: enum uint {
	Linear,
	Step,
	Cubispline,
}

Animation_Player :: struct {
	using ptr:           ^Animation,
	playing:             bool,
	timer:               f32,
	channels_info:       []Animation_Channel_Info,
	targets:             []Animation_Target,
	targets_start_value: []Animation_Value,
}

Animation_Channel_Info :: struct {
	complete:    bool,
	delta_timer: f32,
	index:       uint,
	start_value: Animation_Value,
}

Animation_Target :: union {
	^f32,
	^Vector2,
	^Vector3,
	^Quaternion,
}

Animation_Loader :: struct {
	name: string,
	loop: bool,
}

reset_animation :: proc(player: ^Animation_Player) {
	for info, i in &player.channels_info {
		info.complete = false
		info.index = 0
		info.delta_timer = 0

		start_value := player.targets_start_value[i]
		// target := player.targets[i]
		info.start_value = start_value
		// animation_target_value(target, start_value)
	}
}

advance_animation :: proc(player: ^Animation_Player, dt: f32) -> (complete: bool) {
	player.timer += dt
	for channel, i in &player.channels {
		info := &player.channels_info[i]
		target := player.targets[i]
		if !info.complete {
			info.delta_timer += dt
			frame_duration := channel.frame_durations[info.index]
			if info.delta_timer >= frame_duration {
				info.delta_timer = 0
				info.start_value = channel.frame_outputs[info.index]
				info.index += 1
				if info.index >= len(channel.frame_durations) {
					info.complete = true
					continue
				}
				animation_target_value(target, channel.frame_outputs[info.index])
			}

			input := info.start_value
			output := channel.frame_outputs[info.index]
			t := info.delta_timer / frame_duration
			result := lerp_values(input, output, t)
			animation_target_value(target, result)
		}
	}

	for info in player.channels_info {
		complete |= info.complete
		if !complete {
			break
		}
	}
	if complete {
		if !player.loop {
			player.playing = false
		}
		reset_animation(player)
	}
	return
}

animation_target_value :: proc(target: Animation_Target, value: Animation_Value) {
	switch t in target {
	case ^f32:
		t^ = value.(f32)
	case ^Vector2:
		t^ = value.(Vector2)
	case ^Vector3:
		t^ = value.(Vector3)
	case ^Quaternion:
		t^ = value.(Quaternion)
	}
}

compute_animation_start_value :: proc(channel: Animation_Channel) -> (result: Animation_Value) {
	result = lerp_values(
		channel.frame_outputs[len(channel.frame_outputs) - 1],
		channel.frame_outputs[0],
		0.0,
	)
	return
}

@(private)
lerp_values :: proc(start, end: Animation_Value, t: f32) -> (result: Animation_Value) {
	switch s in start {
	case f32:
		e := end.(f32)
		result = linalg.lerp(s, e, t)
	case Vector2:
		e := end.(Vector2)
		result = linalg.lerp(s, e, t)
	case Vector3:
		e := end.(Vector3)
		result = linalg.lerp(s, e, t)
	case Quaternion:
		e := end.(Quaternion)
		result = linalg.quaternion_slerp_f32(s, e, t)
	}
	return
}

@(private)
internal_load_empty_animation :: proc(loader: Animation_Loader) -> Animation {
	animation := Animation {
		name = strings.clone(loader.name),
		loop = loader.loop,
	}
	return animation
}

load_animation_from_gltf :: proc(name: string, a: gltf.Animation) {
	resource := animation_resource(Animation_Loader{name = name, loop = true})
	animation := resource.data.(^Animation)
	length := len(a.samplers)
	animation.channels = make([]Animation_Channel, length)
	for i in 0 ..< length {
		s := a.samplers[i]
		c := a.channels[i]
		timings := s.input.data.([]f32)

		channel: Animation_Channel
		channel.target_id = c.target.node_index
		channel.mode = Interpolation_Mode(s.interpolation)
		channel.frame_durations = make([]f32, len(timings))
		channel.frame_outputs = make([]Animation_Value, len(timings))

		#partial switch c.target.path {
		case .Translation:
			channel.kind = .Translation
		case .Rotation:
			channel.kind = .Rotation
		case .Scale:
			channel.kind = .Scale
		}

		previous_t: f32
		for t, j in timings {
			channel.frame_durations[j] = t - previous_t
			previous_t = t
		}

		#partial switch data in s.output.data {
		case []gltf.Vector2f32:
			for value, j in data {
				channel.frame_outputs[j] = Vector2(value)
			}
		case []gltf.Vector3f32:
			for value, j in data {
				channel.frame_outputs[j] = Vector3(value)
			}
		case []gltf.Vector4f32:
			for value, j in data {
				q: Quaternion
				q.x = value.x
				q.y = value.y
				q.z = value.z
				q.w = value.w
				channel.frame_outputs[j] = q
			}
		case:
			assert(false)
		}

		animation.channels[i] = channel
	}
}

make_animation_player :: proc(
	animation: ^Animation,
	allocator := context.allocator,
) -> Animation_Player {
	context.allocator = allocator
	player := Animation_Player {
		ptr                 = animation,
		channels_info       = make([]Animation_Channel_Info, len(animation.channels)),
		targets             = make([]Animation_Target, len(animation.channels)),
		targets_start_value = make([]Animation_Value, len(animation.channels)),
	}
	return player
}

destroy_animation_player :: proc(player: ^Animation_Player) {
	delete(player.channels_info)
	delete(player.targets)
	delete(player.targets_start_value)
}

destroy_animation :: proc(animation: ^Animation) {
	delete(animation.name)
	for channel in animation.channels {
		delete(channel.frame_durations)
		delete(channel.frame_outputs)
	}
	delete(animation.channels)
}


Tween :: struct {
	using timer:   Timer,
	interpolation: enum {
		Linear,
		In,
		Out,
		In_Out,
	},
	start:         Animation_Value,
	end:           Animation_Value,
}

advance_tween :: proc(tween: ^Tween, dt: f32) -> (result: Animation_Value, done: bool) {
	done = advance_timer(tween, dt)

	t := tween.time / tween.duration

	switch tween.interpolation {
	case .Linear:
	case .In:
		t = t * t
	case .Out:
		t = math.sqrt(t)
	case .In_Out:
		t = -(math.cos(math.PI * t) - 1) / 2
	}

	result = lerp_values(tween.start, tween.end, t)
	return
}

reset_tween :: proc(tween: ^Tween) {
	tween.time = 0
}
