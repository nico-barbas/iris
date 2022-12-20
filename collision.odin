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
	min:    Vector3,
	max:    Vector3,
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
		min = p_min,
		max = p_max,
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
		min = Vector3{min_x, min_y, min_z},
		max = Vector3{max_x, max_y, max_z},
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
		min = Vector3{min_x, min_y, min_z},
		max = Vector3{max_x, max_y, max_z},
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
	eye, centre: Vector3,
	near, far, fovy: f32,
	aspect: f32 = (16 / 9),
) -> (
	frustum: Frustum,
) {
	f := linalg.vector_normalize(centre - eye)
	r := linalg.vector_normalize(linalg.vector_cross(f, VECTOR_UP))
	u := linalg.vector_cross(r, f)

	half_v_size := far * math.tan(fovy * 0.5)
	half_h_size := half_v_size * aspect

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

frustum_corners :: proc(inverse_pv: Matrix4) -> (result: [8]Vector3) {
	m := inverse_pv

	result = {
		Bounding_Point.Near_Bottom_Left = Vector3{-1, -1, -1},
		Bounding_Point.Near_Bottom_Right = Vector3{1, -1, -1},
		Bounding_Point.Near_Up_Right = Vector3{1, 1, -1},
		Bounding_Point.Near_Up_Left = Vector3{-1, 1, -1},
		Bounding_Point.Far_Bottom_Left = Vector3{-1, -1, 1},
		Bounding_Point.Far_Bottom_Right = Vector3{1, -1, 1},
		Bounding_Point.Far_Up_Right = Vector3{1, 1, 1},
		Bounding_Point.Far_Up_Left = Vector3{-1, 1, 1},
	}

	for point in &result {
		p := Vector4(1)
		p.xyz = point.xyz
		p = m * p
		point = (p / p.w).xyz
	}

	return
}

froxel_plane :: proc {
	froxel_plane_from_matrix,
	froxel_plane_from_near_far_plane,
}

froxel_plane_from_matrix :: proc(im: Matrix4, fz: f32) -> (result: [4]Vector3) {
	z := (fz * 2) - 1
	result = {
		Bounding_Point.Near_Bottom_Left = Vector3{-1, -1, z},
		Bounding_Point.Near_Bottom_Right = Vector3{1, -1, z},
		Bounding_Point.Near_Up_Right = Vector3{1, 1, z},
		Bounding_Point.Near_Up_Left = Vector3{-1, 1, z},
	}

	for point in &result {
		p := im * Vector4{point.x, point.y, point.z, 1}
		point = (p / p.w).xyz
	}
	return
}

froxel_plane_from_near_far_plane :: proc(
	near_plane, far_plane: [4]Vector3,
	z: f32,
) -> (
	result: [4]Vector3,
) {
	l := linalg.vector_length(far_plane[0] - near_plane[0]) * z

	result[0] = near_plane[0]
	result[0] += linalg.vector_normalize(far_plane[0] - near_plane[0]) * l

	result[1] = near_plane[1]
	result[1] += linalg.vector_normalize(far_plane[1] - near_plane[1]) * l

	result[2] = near_plane[2]
	result[2] += linalg.vector_normalize(far_plane[2] - near_plane[2]) * l

	result[3] = near_plane[3]
	result[3] += linalg.vector_normalize(far_plane[3] - near_plane[3]) * l

	return
}


bounding_box_in_frustum :: proc(f: Frustum, b: Bounding_Box) -> (result: Collision_Result) {
	points_in := len(b.points)
	loop: for point in b.points {
		for plane, i in f {
			c := linalg.vector_dot(plane.normal, point)
			if c - plane.d <= 0 {
				points_in -= 1
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
	return
}

Ray :: struct {
	origin:            Vector3,
	direction:         Vector3,
	inverse_direction: Vector3,
}

Ray_Collision_Result :: struct {
	hit:      bool,
	distance: f32,
	position: Vector3,
	normal:   Vector3,
}

Ray_Collision_Policies :: distinct bit_set[Ray_Collision_Result_Kind]

Ray_Collision_Result_Kind :: enum {
	Hit,
	Distance,
	World_Position,
	Normal,
}

ray :: proc(origin, direction: Vector3) -> Ray {
	result := Ray {
		origin = origin,
		direction = direction,
		inverse_direction = Vector3{1 / direction.x, 1 / direction.y, 1 / direction.z},
	}
	return result
}

ray_bounding_box_intersection :: proc(
	ray: Ray,
	b: Bounding_Box,
	policies := Ray_Collision_Policies{.Hit},
) -> (
	result: Ray_Collision_Result,
) {
	t: [8]f32

	t[0] = (b.min.x - ray.origin.x) * ray.inverse_direction.x
	t[1] = (b.max.x - ray.origin.x) * ray.inverse_direction.x
	t[2] = (b.min.y - ray.origin.y) * ray.inverse_direction.y
	t[3] = (b.max.y - ray.origin.y) * ray.inverse_direction.y
	t[4] = (b.min.z - ray.origin.z) * ray.inverse_direction.z
	t[5] = (b.max.z - ray.origin.z) * ray.inverse_direction.z

	// Get the min-max values
	t[6] = max(max(min(t[0], t[1]), min(t[2], t[3])), min(t[4], t[5]))
	t[7] = min(min(max(t[0], t[1]), max(t[2], t[3])), max(t[4], t[5]))

	if .Hit in policies {
		result.hit = !(t[7] < 0 || t[6] > t[7])
	}

	if result.hit {
		if .Distance in policies {
			result.distance = t[6]
		}
	}
	return
}

point_in_aabb_bounding_box :: proc(b: Bounding_Box, p: Vector3) -> bool {
	ok := true
	ok &= p.x >= b.min.x && p.x <= b.max.x
	ok &= p.y >= b.min.y && p.y <= b.max.y
	ok &= p.z >= b.min.z && p.z <= b.max.z

	return ok
}
