package iris

import "core:os"
import "core:log"
import "core:math"
import "core:strings"
import "core:path/filepath"
import stbtt "vendor:stb/truetype"

Font :: struct {
	name:  string,
	faces: map[int]Font_Face,
}

Font_Loader :: struct {
	path:  string,
	sizes: []int,
}

Font_Face :: struct {
	name:     string,
	size:     int,
	scale:    f64,
	glyphs:   []Font_Glyph,
	offset:   int,
	texture:  ^Texture,
	ascent:   f64,
	descent:  f64,
	line_gap: f64,
}

Font_Glyph :: struct {
	codepoint:     rune,
	advance:       f64,
	left_bearing:  f64,
	right_bearing: f64,
	kernings:      []f64,
	x, y:          f64,
	width, height: f64,
	y_offset:      f64,
}

@(private)
internal_load_font :: proc(loader: Font_Loader, allocator := context.allocator) -> Font {
	context.allocator = allocator
	font := Font {
		name  = strings.clone(filepath.base(loader.path)),
		faces = make(map[int]Font_Face, len(loader.sizes)),
	}

	data, ok := os.read_entire_file(loader.path, context.temp_allocator)
	if !ok {
		log.fatalf("%s: Failed to read font file: %s", App_Module.Text, loader.path)
		return font
	}
	for size in loader.sizes {
		font.faces[size] = make_face_from_slice(data, size, 0, 128)
	}
	return font
}

destroy_font :: proc(f: ^Font) {
	for size in f.faces {
		face := &f.faces[size]
		delete(face.glyphs)
	}
	delete(f.faces)
	delete(f.name)
}

@(private)
make_face_from_slice :: proc(font: []byte, pixel_size: int, start, end: rune) -> Font_Face {
	face := Font_Face {
		size   = pixel_size,
		glyphs = make([]Font_Glyph, end - start),
		offset = int(start),
	}
	info := stbtt.fontinfo{}
	if !stbtt.InitFont(&info, &font[0], 0) {
		assert(false, "failed to init font")
	}
	ascent, descent, line_gap: i32
	face.scale = f64(stbtt.ScaleForPixelHeight(&info, f32(pixel_size)))
	stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
	face.ascent = math.round_f64(f64(ascent) * face.scale)
	face.descent = math.round_f64(f64(descent) * face.scale)
	face.line_gap = math.round_f64(f64(line_gap) * face.scale)

	for _, i in face.glyphs {
		r := start + rune(i)
		glyph := &face.glyphs[i]
		glyph.codepoint = r

		adv, lsb: i32
		stbtt.GetCodepointHMetrics(&info, r, &adv, &lsb)
		glyph.advance = math.round_f64(f64(adv) * face.scale)
		glyph.left_bearing = math.round_f64(f64(lsb) * face.scale)

		glyph.kernings = make([]f64, end - start)
		for _, j in face.glyphs {
			r2 := start + rune(j)

			k := stbtt.GetCodepointKernAdvance(&info, r, r2)
			glyph.kernings[j] = f64(k) * face.scale
		}
	}

	bitmap: []byte
	bitmap_width :: 1024
	bitmap_height := pixel_size
	x := 0
	for glyph in face.glyphs {
		next_x := x + int(glyph.advance)
		if next_x > bitmap_width {
			bitmap_height += pixel_size
			x = int(glyph.advance)
		} else {
			x = next_x
		}
	}

	bitmap_height += 10
	bitmap = make([]byte, bitmap_width * bitmap_height, context.temp_allocator)

	x = 0
	row_y := 10
	for _, i in face.glyphs {
		r := start + rune(i)
		glyph := &face.glyphs[i]

		next_x := x + int(glyph.advance)
		if next_x > bitmap_width {
			row_y += pixel_size
			x = 0
		}

		x1, y1, x2, y2: i32
		stbtt.GetCodepointBitmapBox(&info, r, f32(face.scale), f32(face.scale), &x1, &y1, &x2, &y2)

		glyph.width = f64(x2 - x1)
		glyph.height = f64(y2 - y1)
		glyph.right_bearing = (glyph.left_bearing + glyph.width) - glyph.advance


		y := int(face.ascent) + int(y1)
		offset := x + int(glyph.left_bearing) + ((row_y + y) * bitmap_width)
		stbtt.MakeCodepointBitmap(
			&info,
			&bitmap[offset],
			i32(glyph.width),
			i32(glyph.height),
			bitmap_width,
			f32(face.scale),
			f32(face.scale),
			r,
		)
		glyph.x = f64(x) + glyph.left_bearing
		glyph.y = f64(row_y + y)
		glyph.y_offset = f64(y1)

		x += int(glyph.advance) + 2
	}

	// FIXME: temp

	rgba_bmp := make([]byte, len(bitmap) * 4)
	for b, i in bitmap {
		offset := i * 4
		rgba_bmp[offset] = 255
		rgba_bmp[offset + 1] = 255
		rgba_bmp[offset + 2] = 255
		rgba_bmp[offset + 3] = b
	}
	texture_res := texture_resource(
		loader = Texture_Loader{
			filter = .Nearest,
			wrap = .Repeat,
			space = .Linear,
			width = bitmap_width,
			height = bitmap_height,
			info = Byte_Texture_Info{data = rgba_bmp, channels = 4, bitmap = true},
		},
	)
	face.texture = texture_res.data.(^Texture)
	return face
}

Text :: struct {
	options: Text_Options,
	bounds:  Text_Position,
	origin:  Vector2,
	style:   Text_Style,
	data:    string,
	font:    ^Font,
	color:   Color,
	size:    int,
}

Text_Options :: distinct bit_set[Text_Option]

Text_Option :: enum {
	Multiline,
}

Text_Position :: union {
	Vector2,
	Rectangle,
}

Text_Style :: enum {
	Origin,
	Center,
	Center_Right,
	Center_Left,
}

measure_text :: proc(t: ^Text) -> (width: f32, height: f32) {
	face := t.font.faces[t.size]
	if .Multiline in t.options {
		line_w: f32
		line_count := 1
		for c in t.data {
			if c == '\n' {
				line_count += 1
				width = max(width, line_w)
			}
			glyph := face.glyphs[c]
			line_w += f32(glyph.advance)
		}
		height = f32(line_count) * f32(face.ascent)
	} else {
		for c in t.data {
			glyph := face.glyphs[c]
			width += f32(glyph.advance)
			height = max(height, f32(glyph.height))
		}
	}
	return
}

text_position :: proc(t: ^Text, p: Text_Position) {
	t.bounds = p
	update_text_position(t)
}

@(private)
update_text_position :: proc(t: ^Text) {
	switch p in t.bounds {
	case Vector2:
		if t.style != .Origin {
			log.warnf(
				"%s: Incompatible Text position and style [Vector2|%s]",
				App_Module.Text,
				t.style,
			)
			return
		}
		t.origin = p
	case Rectangle:
		w, h := measure_text(t)
		switch t.style {
		case .Origin:
			t.origin = {p.x, p.y}
		case .Center:
			t.origin = Vector2{p.x + (p.width - w) / 2, p.y + (p.height - h) / 2}
		case .Center_Right:
			t.origin = Vector2{p.x + (p.width - w) - 1, p.y + (p.height - h) / 2}
		case .Center_Left:
			t.origin = Vector2{p.x + 1, p.y + (p.height - h) / 2}
		}
		t.origin.y += h
		t.origin.x = math.round(t.origin.x)
		t.origin.y = math.round(t.origin.y)
	}
}

Text_Cursor :: struct {
	offset: int,
	line:   int,
}
