[Vertex]
#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 1) in vec3 attribNormal;
layout (location = 2) in vec3 attribTexCoord;

out VS_OUT {
	vec3 position;
	vec3 normal;
	vec3 texCoord;
	vec4 lightSpacePosition;
} frag;

uniform mat4 mvp;
uniform mat4 matModel;
uniform mat3 matNormal;

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
	frag.position = vec3(matModel * vec4(attribPosition, 1.0));
	frag.normal = matNormal * attribNormal; 
	frag.texCoord = attribTexCoord;
	frag.lightSpacePosition = matLightSpace * matModel * vec4(attribPosition, 1.0);

    gl_Position = mvp*vec4(attribPosition, 1.0);
} 

[Fragment]
#version 450 core
in VS_OUT {
	vec3 position;
	vec3 normal;
	vec3 texCoord;
	vec4 lightSpacePosition;
} frag;

out vec4 finalColor;

// builtin uniforms;
uniform sampler2D textures[2];
uniform sampler2D mapShadow;

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

float computeShadowValue(vec4 lightSpacePosition, float bias);

void main()
{
	int baseIndex = int(frag.texCoord.z);
	vec4 texelClr = texture(textures[baseIndex], frag.texCoord.xy);
	float blend = fract(frag.texCoord.z);
	if (blend > 0.0) {
		int blendIndex = int(ceil(frag.texCoord.z));
		vec4 blendClr = texture(textures[blendIndex], frag.texCoord.xy);
		texelClr = (texelClr * (1 - blend)) + (blendClr * blend);
	} 

	vec3 normal = normalize(frag.normal);
	vec3 lightDir = normalize(lights[0].position);
	float diffuseValue = max(dot(lightDir, normal), 0.0);
	vec3 diffuse = diffuseValue * lights[0].color.rgb;

	vec3 ambient = ambientStrength * ambientClr;

	float bias = 0.05 * (1.0 - dot(normal, lightDir));
	bias = max(bias, 0.005);
	float shadowValue = computeShadowValue(frag.lightSpacePosition, bias);

	vec3 result = (ambient + ((1.0 - shadowValue) * diffuse)) * texelClr.rgb;

	finalColor = vec4(result, 1.0);
}

float computeShadowValue(vec4 lightSpacePosition, float bias) {
    vec3 projCoord = lightSpacePosition.xyz / lightSpacePosition.w;
    if (projCoord.z > 1.0) {
        return 0.0;
    }
    projCoord = projCoord * 0.5 + 0.5;
    float currentDepth = projCoord.z;

    float result = 0.0;
    vec2 texelSize = 1.0 / textureSize(mapShadow, 0);
    for (int x = -1; x <= 1; x += 1) {
        for (int y = -1; y <= 1; y += 1) {
            vec2 pcfCoord = projCoord.xy + vec2(x, y) * texelSize;
            float pcfDepth = texture(mapShadow, pcfCoord).r;
            result += currentDepth - bias > pcfDepth ? 1.0 : 0.0;
        }
    }
    result /= 9.0;
    return result;
}