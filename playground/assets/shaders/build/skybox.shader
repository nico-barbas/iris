[Vertex]
#version 450 core
layout (location = 0) in vec3 attribPosition;

layout (std140, binding = 0) uniform ProjectionData {
	mat4 projView;
    mat4 matProj;
    mat4 matView;
	vec3 viewPosition;
};

out VS_OUT {
    vec3 texCoord;
} frag;

uniform mat4 mvp;

void main() {
    frag.texCoord = attribPosition;
    gl_Position = mvp * vec4(attribPosition, 1.0);
}

[Fragment]
#version 450 core
in VS_OUT {
    vec3 texCoord;
} frag;

out vec4 finalColor;

uniform samplerCube cubemap0;

void main() {
    vec3 texCoord = normalize(frag.texCoord);
    finalColor = texture(cubemap0, texCoord);    
}