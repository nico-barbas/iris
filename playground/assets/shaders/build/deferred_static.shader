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
uniform bool useTangentSpace;

void main()
{
	frag.position = vec3(matModel * vec4(attribPosition, 1.0));
	frag.normal = matNormal * attribNormal;
	frag.texCoord = attribTexCoord;

	if (useTangentSpace) {
		vec3 t = normalize(matNormal * vec3(attribTangent));
		vec3 n = normalize(matNormal * attribNormal);
		t =  normalize(t - dot(t, n) * n);
		vec3 b = cross(n, t);

		frag.matTBN = inverse(transpose(mat3(t, b, n)));
	}

    gl_Position = mvp * vec4(attribPosition, 1.0);
}

[Fragment]
#version 450 core
layout (location = 0) out vec4 bufferedPosition;
layout (location = 1) out vec4 bufferedNormal;
layout (location = 2) out vec4 bufferedAlbedo;

in VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
	mat3 matTBN;
} frag;

uniform sampler2D texture0;
uniform sampler2D texture1;
uniform bool useTangentSpace;

void main() {
	if (useTangentSpace) {
		vec3 sampledNormal = texture(texture1, frag.texCoord).rgb;
		sampledNormal = sampledNormal * 2.0 - 1.0;
		sampledNormal = normalize(frag.matTBN * sampledNormal);

		bufferedNormal = vec4(sampledNormal, 1.0);
	} else {
		bufferedNormal = vec4(normalize(frag.normal), 1.0);
	}

	bufferedPosition = vec4(frag.position, 1.0);
	bufferedAlbedo.rgb = texture(texture0, frag.texCoord).rgb;
	bufferedAlbedo.a = 1.0;
}