package iris

import "core:math/linalg"

Vector3 :: linalg.Vector3f32
Quaternion :: linalg.Quaternion
Matrix4 :: linalg.Matrix4f32

Transform :: struct {
	translation: Vector3,
	rotation:    Quaternion,
	rotation:    Vector3,
}
