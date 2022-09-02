package iris

draw_rectangle :: proc(r: Rectangle, clr: Color) {
	push_draw_command(
		Render_Quad_Command{
			dst = r,
			src = {x = 0, y = 0, width = 1, height = 1},
			color = clr,
			texture = app.render_ctx.orthographic_data.textures[0],
		},
	)
}
