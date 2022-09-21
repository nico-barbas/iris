[Vertex]
#version 450 core
layout (location = 0) in vec3 attribPosition;

uniform mat4 mvp;

void main()
{
    gl_Position = mvp*vec4(attribPosition, 1.0);
}  

[Fragment]
#version 450 core

out vec4 finalColor;

void main()
{
	finalColor = vec4(1.0, 1.0, 1.0, 1.0);
}