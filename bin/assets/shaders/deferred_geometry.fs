#version 450 core
layout (location = 0) out vec4 bufferedPosition;
layout (location = 1) out vec4 bufferedNormal;
layout (location = 2) out vec4 bufferedAlbedo;

in VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
    vec4 color;
	mat3 matTBN;
} frag;

subroutine vec3 subSampleAlbedo();

layout (location = 0) uniform sampler2D mapDiffuse0;
layout (location = 1) uniform sampler2D mapNormal0;
layout (location = 2) uniform bool useTangentSpace;

layout (location = 0) subroutine uniform subSampleAlbedo sampleAlbedo;

void main() {
	if (useTangentSpace) {
		vec3 sampledNormal = texture(mapNormal0, frag.texCoord).rgb;
		sampledNormal = sampledNormal * 2.0 - 1.0;
		sampledNormal = normalize(frag.matTBN * sampledNormal);

		bufferedNormal = vec4(sampledNormal, 1.0);
	} else {
		bufferedNormal = vec4(normalize(frag.normal), 1.0);
	}

	bufferedPosition = vec4(frag.position, 1.0);
	bufferedAlbedo.rgb = sampleAlbedo();
	bufferedAlbedo.a = 1.0;
}

////////////////////////////////////
// Sample albedo subroutines

layout (index = 0) subroutine(subSampleAlbedo)
vec3 sampleDefaultAlbedo() {
    vec3 result = texture(mapDiffuse0, frag.texCoord).rgb;
    return result;
}

layout (index = 1) subroutine(subSampleAlbedo)
vec3 sampleTerrainAlbedo() {
    const float heightTreshold = 3;
    const float tileCount = 2;
    const float tileSize = 0.5;

    float baseOffset = clamp(floor(frag.position.y / heightTreshold), 0.0, tileCount - 1.0);
    vec2 baseCoord = vec2(frag.texCoord.x, frag.texCoord.y + (baseOffset * tileSize));
    vec3 baseSample1 = texture(mapDiffuse0, baseCoord).rgb;
    vec3 baseSample2 = texture(mapDiffuse0, vec2(baseCoord.x + tileSize, baseCoord.y)).rgb;

    vec3 result = (baseSample1);
    float blend = smoothstep(0.45, 0.6, frag.color.r);
    // if (blend > 0.5) {
    //     result = vec3(blend, 0, 0);
    // } 
    result = mix(result, baseSample2, blend);

    // if (frag.color.r > 0.3) {

    // }
    // vec3 result = mix(baseSample1, baseSample2, frag.color.g);

    float blendValue = smoothstep(heightTreshold - 1, heightTreshold + 1, frag.position.y);
    result = mix(result, vec3(1, 0, 0), blendValue);
    // if (blendValue > 0.0) {
        // float blendOffset = clamp(ceil(frag.position.y / heightTreshold), 0.0, tileCount - 1.0);
        // vec2 blendCoord = vec2(frag.texCoord.x, frag.texCoord.y + (blendOffset * tileSize));
        // vec3 blendClr = texture(mapDiffuse0, blendCoord).rgb;
        // result = (result * (1 - blendValue)) + (blendClr * blendValue);
    //     result = vec3(1, 0, 0);
    // }
    return result;

    // float r = clamp(frag.color.g, 0.0,)
    // return vec3(frag.color.g, 0.0, 0.0);
}

layout (index = 2) subroutine(subSampleAlbedo)
vec3 sampleHighlightTileAlbedo() {
    const vec2 center = vec2(0.5, 0.5);
    const vec2 toCenter = center - frag.texCoord;
    const float highlightValue = smoothstep(0.45, 0.6, length(toCenter));
    return vec3(highlightValue, highlightValue, highlightValue);
}

////////////////////////////////////
////////////////////////////////////
