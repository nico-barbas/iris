package gltf

Vector2u8 :: [2]u8
Vector2i16 :: [2]i16
Vector2u16 :: [2]u16
Vector2u32 :: [2]u32
Vector2f32 :: [2]f32

Vector3u8 :: [3]u8
Vector3i16 :: [3]i16
Vector3u16 :: [3]u16
Vector3u32 :: [3]u32
Vector3f32 :: [3]f32

Vector4u8 :: [4]u8
Vector4i16 :: [4]i16
Vector4u16 :: [4]u16
Vector4u32 :: [4]u32
Vector4f32 :: [4]f32

Mat2u8 :: matrix[2, 2]u8
Mat2i16 :: matrix[2, 2]i16
Mat2u16 :: matrix[2, 2]u16
Mat2u32 :: matrix[2, 2]u32
Mat2f32 :: matrix[2, 2]f32

Mat3u8 :: matrix[3, 3]u8
Mat3i16 :: matrix[3, 3]i16
Mat3u16 :: matrix[3, 3]u16
Mat3u32 :: matrix[3, 3]u32
Mat3f32 :: matrix[3, 3]f32

Mat4u8 :: matrix[4, 4]u8
Mat4i16 :: matrix[4, 4]i16
Mat4u16 :: matrix[4, 4]u16
Mat4u32 :: matrix[4, 4]u32
Mat4f32 :: matrix[4, 4]f32

Quaternion :: quaternion128

Translate_Rotate_Scale :: struct {
	translation: Vector3f32,
	rotation:    Quaternion,
	scale:       Vector3f32,
}
