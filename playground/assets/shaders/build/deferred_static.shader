[Vertex]
#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 1) in vec3 attribNormal;
layout (location = 2) in vec4 attribTangent;
layout (location = 5) in vec2 attribTexCoord;

out VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
	mat3 matTBN;
} frag;

layout (std140, binding = 0) uniform ContextData {
    mat4 projView;
    mat4 matProj;
    mat4 matView;
    vec3 viewPosition;
    float time;
    float dt;
};


// builtin uniforms
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat3 matNormal;

void main()
{
	frag.position = vec3(matModel * vec4(attribPosition, 1.0));
	frag.texCoord = attribTexCoord;

	vec3 t = normalize(matNormal * vec3(attribTangent));
	vec3 n = normalize(matNormal * attribNormal);
	t =  normalize(t - dot(t, n) * n);
	vec3 b = cross(n, t);

	frag.matTBN = transpose(mat3(t, b, n));

    gl_Position = mvp * vec4(attribPosition, 1.0);
}

[Fragment]
#version 450 core
layout (location = 0) out vec3 bufferedPosition;
layout (location = 1) out vec3 bufferedNormal;
layout (location = 2) out vec4 bufferedAlbedo;

in VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
	mat3 matTBN;
} frag;

uniform sampler2D texture0;
uniform sampler2D texture1;

void main() {
	vec3 sampledNormal = texture(texture1, frag.texCoord).rgb;
	if (length(sampledNormal) != 0) {
		sampledNormal = sampledNormal * 2.0 - 1.0;
		sampledNormal = normalize(frag.matTBN * sampledNormal);

		bufferedNormal = sampledNormal;
	} else {
		bufferedNormal = frag.normal;
	}

	bufferedPosition = frag.position;
	bufferedAlbedo.rbg = texture(texture0, frag.texCoord).rgb;
}