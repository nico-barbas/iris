[Vertex]
#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 1) in vec3 attribNormal;
layout (location = 2) in vec2 attribTexCoord;

out VS_OUT {
	vec4 position;
	vec3 normal;
	vec2 texCoord;
	vec4 lightSpacePosition;
} frag;

uniform mat4 mvp;
uniform mat4 matModel;
uniform mat3 matNormal;

layout (std140, binding = 0) uniform ProjectionData {
	mat4 projView;
    mat4 matProj;
    mat4 matView;
	vec3 viewPosition;
};

struct Light {
	uint on;
	vec3 position;
	vec3 color;
};
layout (std140, binding = 1) uniform Lights {
	Light lights[4];
	mat4 matLightSpace;
	vec3 ambientClr;
	float ambientStrength;
};

void main()
{
	frag.position = projView * matModel * vec4(attribPosition, 1.0);
	frag.normal = matNormal * attribNormal; 
	frag.texCoord = attribTexCoord;
	frag.lightSpacePosition = matLightSpace * matModel * vec4(attribPosition, 1.0);

    gl_Position = mvp*vec4(attribPosition, 1.0);
} 

[Fragment]
#version 450 core
in VS_OUT {
	vec4 position;
	vec3 normal;
	vec2 texCoord;
	vec4 lightSpacePosition;
} frag;

out vec4 finalColor;

// builtin uniforms;
// uniform sampler2D texture0;
// uniform sampler2D mapShadow;
uniform sampler2D mapViewDepth;

layout (std140, binding = 0) uniform ProjectionData {
	mat4 projView;
    mat4 matProj;
    mat4 matView;
	vec3 viewPosition;
};

struct Light {
	uint on;
	vec3 position;
	vec3 color;
};
layout (std140, binding = 1) uniform Lights {
	Light lights[4];
	mat4 matLightSpace;
	vec3 ambientClr;
	float ambientStrength;
};

float linearDepthValue(float near, float far, float depth);

void main()
{
	const float near = 0.1;
	const float far = 100;

	// vec4 texelClr = texture(texture0, frag.texCoord);
	const vec3 waterClr = vec3(0.325, 0.658, 0.84);


	// vec3 normal = normalize(frag.normal);
	// vec3 lightDir = normalize(lights[0].position);
	// float diffuseValue = max(dot(lightDir, normal), 0.0);
	// vec3 diffuse = diffuseValue * lights[0].color.rgb;

	// vec3 ambient = ambientStrength * ambientClr;

	// float bias = 0.05 * (1.0 - dot(normal, lightDir));
	// bias = max(bias, 0.005);

	// vec3 result = (ambient + (diffuse)) * ;

	vec3 depthCoord  = frag.position.xyz / frag.position.w;
	depthCoord = (depthCoord * 0.5) + 0.5;
	float result = texture(mapViewDepth, depthCoord.xy).r;
	float linearDepth = linearDepthValue(near, far, result);

	float viewWaterDepth = linearDepthValue(near, far, gl_FragCoord.z);
	float waterDepth = linearDepth - viewWaterDepth;
	waterDepth = waterDepth;

	// finalColor = vec4(0.0, 0.0, 0.0, 1.0);
	vec3 depthClr = waterClr * waterDepth + vec3(1.0) * (1.0 - waterDepth);
	depthClr.r = clamp(depthClr.r, waterClr.r, 1.0);
	depthClr.g = clamp(depthClr.g, waterClr.g, 1.0);
	depthClr.b = clamp(depthClr.b, waterClr.b, 1.0);
	finalColor = vec4(depthClr, 1.0);
	// finalColor = vec4(waterDepth, waterDepth, waterDepth, 1.0);
}

float linearDepthValue(float near, float far, float depth) {
    float result = 2.0 * near * far / (far + near - (2.0 * depth - 1.0) * (far - near));
    return result;
}
