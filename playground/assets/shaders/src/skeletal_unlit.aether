[Vertex]
#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 1) in vec3 attribNormal;
layout (location = 2) in vec4 attribJoints;
layout (location = 3) in vec4 attribWeights;
layout (location = 4) in vec2 attribTexCoord;

layout (std140, binding = 0) uniform ProjectionData {
	mat4 projView;
    mat4 matProj;
    mat4 matView;
	vec3 viewPosition;
};

out VS_OUT {
	vec3 normal;
	vec4 joints;
	vec4 weights;
	vec2 texCoord;
} frag;

uniform mat4 matJoints[19];
uniform mat4 matModelLocal;

void main()
{
	frag.normal = attribNormal;
	frag.joints = attribJoints;
	frag.weights = attribWeights;
	frag.texCoord = attribTexCoord;

	mat4 matSkin = 
		attribWeights.x * matJoints[int(attribJoints.x)] +
		attribWeights.y * matJoints[int(attribJoints.y)] +
		attribWeights.z * matJoints[int(attribJoints.z)] +
		attribWeights.w * matJoints[int(attribJoints.w)];
	mat4 mvp = projView * matModelLocal * matSkin;
    gl_Position = mvp*vec4(attribPosition, 1.0);
} 

[Fragment]
#version 450 core
in VS_OUT {
	vec3 normal;
	vec4 joints;
	vec4 weights;
	vec2 texCoord;
} frag;

out vec4 finalColor;

uniform sampler2D texture0;

void main()
{
	finalColor = texture(texture0, frag.texCoord);
}