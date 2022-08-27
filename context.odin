package iris

Rendering_Context :: struct {
	projection: Matrix4,
	view:       Matrix4,

	// Camera state
	eye:        Transform,
	center:     Vector3,
	up:         Vector3,
}

view_transform :: proc(t: Transform) {

}

view_center :: proc(center: Vector3) {

}
