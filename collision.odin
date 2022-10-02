package iris

// import "core:fmt"
import "core:math"
import "core:intrinsics"
import "core:math/linalg"

Collision_Result :: enum {
	Outside,
	Partial_In,
	Full_In,
}

BONDING_BOX_POINT_LEN :: 8
BONDING_BOX_EDGE_LEN :: 12

Bounding_Box :: struct {
	points: [8]Vector3,
}

Bounding_Point :: enum {
	Near_Bottom_Left,
	Near_Bottom_Right,
	Near_Up_Right,
	Near_Up_Left,
	Far_Bottom_Left,
	Far_Bottom_Right,
	Far_Up_Right,
	Far_Up_Left,
}

BOUNDING_BOX_ZERO :: Bounding_Box {
	points = {
		VECTOR_ZERO,
		VECTOR_ZERO,
		VECTOR_ZERO,
		VECTOR_ZERO,
		VECTOR_ZERO,
		VECTOR_ZERO,
		VECTOR_ZERO,
		VECTOR_ZERO,
	},
}

bounding_box_from_min_max :: proc(p_min, p_max: Vector3) -> (result: Bounding_Box) {
	b := Bounding_Box {
		points = {
			{p_min.x, p_min.y, p_min.z},
			{p_max.x, p_min.y, p_min.z},
			{p_max.x, p_max.y, p_min.z},
			{p_min.x, p_max.y, p_min.z},
			{p_min.x, p_min.y, p_max.z},
			{p_max.x, p_min.y, p_max.z},
			{p_max.x, p_max.y, p_max.z},
			{p_min.x, p_max.y, p_max.z},
		},
	}

	return b
}

bounding_box_from_bounds_slice :: proc(slice: []Bounding_Box) -> (result: Bounding_Box) {
	min_x := math.INF_F32
	max_x := -math.INF_F32
	min_y := math.INF_F32
	max_y := -math.INF_F32
	min_z := math.INF_F32
	max_z := -math.INF_F32

	for bounds in slice {
		for point in bounds.points {
			min_x = min(min_x, point.x)
			max_x = max(max_x, point.x)
			min_y = min(min_y, point.y)
			max_y = max(max_y, point.y)
			min_z = min(min_z, point.z)
			max_z = max(max_z, point.z)
		}
	}


	b := Bounding_Box {
		points = {
			{min_x, min_y, min_z},
			{max_x, min_y, min_z},
			{max_x, max_y, min_z},
			{min_x, max_y, min_z},
			{min_x, min_y, max_z},
			{max_x, min_y, max_z},
			{max_x, max_y, max_z},
			{min_x, max_y, max_z},
		},
	}

	return b
}

bounding_box_from_vertex_slice :: proc(
	v: $T/[]$E,
) -> Bounding_Box where intrinsics.type_is_numeric(E) {

	min_x := math.INF_F32
	max_x := -math.INF_F32
	min_y := math.INF_F32
	max_y := -math.INF_F32
	min_z := math.INF_F32
	max_z := -math.INF_F32

	for vertex in v {
		min_x = min(min_x, vertex.x)
		max_x = max(max_x, vertex.x)
		min_y = min(min_y, vertex.y)
		max_y = max(max_y, vertex.y)
		min_z = min(min_z, vertex.z)
		max_z = max(max_z, vertex.z)
	}


	b := Bounding_Box {
		points = {
			{min_x, min_y, min_z},
			{max_x, min_y, min_z},
			{max_x, max_y, min_z},
			{min_x, max_y, min_z},
			{min_x, min_y, max_z},
			{max_x, min_y, max_z},
			{max_x, max_y, max_z},
			{min_x, max_y, max_z},
		},
	}

	return b
}

Plane :: struct {
	normal: Vector3,
	d:      f32,
}

plane :: proc(normal: Vector3, from_to: Vector3) -> Plane {
	p: Plane
	p.normal = linalg.vector_normalize(normal)
	p.d = linalg.vector_dot(p.normal, from_to)
	return p
}

Frustum :: distinct [6]Plane

Frustum_Planes :: enum {
	Near,
	Far,
	Left,
	Right,
	Up,
	Down,
}

frustum :: proc(
	eye,
	centre: Vector3,
	near,
	far,
	fovy: f32,
	aspect: f32 = (16 / 9),
) -> (
	frustum: Frustum,
) {
	f := linalg.vector_normalize(centre - eye)
	r := linalg.vector_normalize(linalg.vector_cross(f, VECTOR_UP))
	u := linalg.vector_cross(r, f)

	half_v_size := far * math.tan(fovy * 0.5)
	half_h_size := half_v_size * aspect

	// fn := eye + f * near
	// fe := eye + f * far

	f_vec := f * far

	frustum[Frustum_Planes.Near] = plane(normal = f, from_to = eye + f * near)
	frustum[Frustum_Planes.Far] = plane(normal = -f, from_to = f_vec)
	frustum[Frustum_Planes.Left] = plane(
		normal = linalg.vector_cross(f_vec - r * half_h_size, u),
		from_to = eye,
	)
	frustum[Frustum_Planes.Right] = plane(
		normal = linalg.vector_cross(u, f_vec + r * half_h_size),
		from_to = eye,
	)
	frustum[Frustum_Planes.Up] = plane(
		normal = linalg.vector_cross(f_vec + u * half_v_size, r),
		from_to = eye,
	)
	frustum[Frustum_Planes.Down] = plane(
		normal = linalg.vector_cross(r, f_vec - u * half_v_size),
		from_to = eye,
	)

	return
}

bounding_box_in_frustum :: proc(f: Frustum, b: Bounding_Box) -> (result: Collision_Result) {
	points_in := len(b.points)
	loop: for point in b.points {
		for plane, i in f {
			c := linalg.vector_dot(plane.normal, point)
			if c - plane.d <= 0 {
				points_in -= 1
				// fmt.printf("%v failed intersection with plane %s\n", point, Frustum_Planes(i))
				// fmt.printf("Projected length: %0.4f, Plane Distance: %0.4f\n", c, plane.d)
				continue loop
			}
		}
	}

	switch points_in {
	case 0:
		result = .Outside
	case 0 ..< 8:
		result = .Partial_In
	case 8:
		result = .Full_In
	}
	// fmt.printf("%d points inside frustum\n", points_in)
	return
}
