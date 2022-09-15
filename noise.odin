package iris

import "core:math"
import "core:math/rand"
import "core:math/linalg"

Noise_Generator :: struct {
	seed:        ^rand.Rand,
	seed_buf:    []f32,
	octaves:     uint,
	width:       int,
	height:      int,
	persistance: f32,
	lacunarity:  f32,
}

noise :: proc(input: ^Noise_Generator, allocator := context.allocator) -> (result: []f32) {
	length := len(input.seed_buf)
	result = make([]f32, length, allocator)


	for seed_value in &input.seed_buf {
		seed_value = rand.float32_range(-1, 1, input.seed)
	}

	min_value := math.INF_F32
	max_value := -math.INF_F32

	for y in 0 ..< input.height {
		for x in 0 ..< input.width {
			noise_value: f32
			accumulator: f32
			scale := f32(1)
			frequency := input.width

			for octave in 0 ..< input.octaves {
				sample_x1 := (x / frequency) * frequency
				sample_y1 := (y / frequency) * frequency

				sample_x2 := (sample_x1 + frequency) % input.width
				sample_y2 := (sample_y1 + frequency) % input.width

				blendx := f32(x - sample_x1) / f32(frequency)
				blendy := f32(y - sample_y1) / f32(frequency)

				in_value_s1 := input.seed_buf[sample_y1 * input.width + sample_x1]
				in_value_s2 := input.seed_buf[sample_y1 * input.width + sample_x2]
				in_value_t1 := input.seed_buf[sample_y2 * input.width + sample_x1]
				in_value_t2 := input.seed_buf[sample_y2 * input.width + sample_x2]
				sample_s := linalg.lerp(in_value_s1, in_value_s2, blendx)
				sample_t := linalg.lerp(in_value_t1, in_value_t2, blendx)

				accumulator += scale
				noise_value += (blendy * (sample_t - sample_s) + sample_s) * scale
				scale *= input.persistance
				frequency = max(int(f32(frequency) / input.lacunarity), 1)
			}

			output_value := noise_value / accumulator
			min_value = min(min_value, output_value)
			max_value = max(max_value, output_value)

			result[y * input.width + x] = output_value
		}
	}

	range := max_value - min_value
	for output_value in &result {
		output_value = (output_value - min_value) / range
		output_value = (output_value * 2) - 1
	}

	return
}
