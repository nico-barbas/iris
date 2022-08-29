package iris

import gl "vendor:OpenGL"

@(private)
draw_triangles :: proc(count: int) {
	gl.DrawElements(gl.TRIANGLES, i32(count), gl.UNSIGNED_INT, nil)
}
