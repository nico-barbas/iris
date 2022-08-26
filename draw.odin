package iris

import gl "vendor:OpenGL"

draw_elements :: proc(count: int) {
	gl.DrawElements(gl.TRIANGLES, i32(count), gl.UNSIGNED_INT, nil)
}
