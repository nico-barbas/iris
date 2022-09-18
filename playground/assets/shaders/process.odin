package main

import "core:os"
import "core:mem"
import "core:fmt"
import "core:path/filepath"
import aether "../../../aether"

builtins := map[string]aether.Procedure_Include {
	"computeShadowValue" = {
		decl = "float computeShadowValue(vec4 lightSpacePosition, float bias);",
		body = `
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
}`,
	},
	"linearDepthValue" = {
		decl = "float linearDepthValue(float near, float far, float depth);",
		body = `
float linearDepthValue(float near, float far, float depth) {
    float result = 2.0 * near * far / (far + near - (2.0 * depth - 1.0) * (far - near));
    return result;
}
`,
	},
}

main :: proc() {
	init_global_temporary_allocator(mem.Megabyte * 20)
	dir := filepath.dir(os.args[0], context.temp_allocator)
	src := filepath.join(elems = {dir, "src"}, allocator = context.temp_allocator)
	build := filepath.join(elems = {dir, "build"}, allocator = context.temp_allocator)
	err := aether.build_shaders(src, build, builtins, context.temp_allocator)

	if err != .None {
		fmt.println(err)
	}
}
