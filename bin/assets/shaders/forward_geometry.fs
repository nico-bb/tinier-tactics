#version 450 core
in VS_OUT {
    vec3 position;
    vec3 normal;
    vec2 texCoord;
    vec4 color;
    mat3 matTBN;
} frag;


out vec4 finalColor;

layout (std140, binding = 0) uniform ContextData {
    mat4 matProjView;
    mat4 matProj;
    mat4 matView;
    vec3 viewPosition;
    float time;
    float dt;
};

struct Light {
    vec4 position;
    vec4 color;

    float linear;
    float quadratic;
    
    uint mode;
    uint padding;
};
const uint DIRECTIONAL_LIGHT = 0;
const uint POINT_LIGHT = 1;
const int MAX_LIGHTS = 128;
const int MAX_SHADOW_MAPS = 4;
layout (std140, binding = 1) uniform LightingContext {
    Light lights[MAX_LIGHTS];
    uvec4 shadowCasters[MAX_SHADOW_MAPS];  // IDs of the lights used for shadow mapping
    mat4 matLightSpaces[MAX_SHADOW_MAPS];  // Space matrices of the lights used for shadow mapping
    vec4 ambient;                            // .rgb for the color and .a for the intensity
    uint lightCount;
    uint shadowCasterCount;
};

uniform sampler2D mapDiffuse0;
uniform sampler2D mapNormal0;
uniform sampler2D mapShadow;

vec3 computeDirectionalLighting( Light light, vec3 p, vec3 n );
vec3 computePointLighting( Light light, vec3 p, vec3 n );
float sampleShadowMap (int casterIndex, vec2 texCoord);
float computeShadowValue(int casterIndex, vec3 position, vec3 normal);
vec3 applyAtmosphericFog(in vec3 texelClr, float dist, vec3 viewDir, vec3 lightDir);

void main() {
    vec3 position = frag.position;
    vec3 normal = frag.normal;
    vec4 a = texture(mapDiffuse0, frag.texCoord);
    vec3 albedo = a.rgb;
    float distance = length(position - viewPosition);

    if (a.a <= 0.05) {
        discard;
    }

    vec3 ambient = ambient.xyz * ambient.a;

    float shadowValue = 0.0;
    for (int i = 0; i < shadowCasterCount; i += 1) {
        shadowValue += computeShadowValue(i, position, normal);
    }

    vec3 lightValue = vec3(0);
    for (int i = 0; i < lightCount; i += 1) {
        Light light = lights[i];

        if (light.mode == DIRECTIONAL_LIGHT) {
            lightValue += computeDirectionalLighting(light, position, normal);
        } else if (light.mode == POINT_LIGHT) {
            lightValue += computePointLighting(light, position, normal);
        }
    }

    vec3 result = (ambient + ((1.0 - shadowValue) * lightValue)) * albedo; 
    result = applyAtmosphericFog(result, distance, vec3(0), vec3(0));
    finalColor = vec4(result, 1.0);
}

vec3 computeDirectionalLighting( Light light, vec3 p, vec3 n ) {
    vec3 lightDir = normalize(light.position.xyz);
    float diffuseContribution = max(dot(lightDir, n), 0.0);
    vec3 diffuse = diffuseContribution * light.color.rgb;

    vec3 viewDir = normalize(viewPosition - p);
    vec3 reflectDir = reflect(-lightDir, n);
    float specContribution = max(dot(viewDir, reflectDir), 0.0);
    specContribution = pow(specContribution, 32.0);
    vec3 specular =  (specContribution * light.color.rgb);

    return (diffuse + specular);
}

vec3 computePointLighting( Light light, vec3 p, vec3 n ) {
    vec3 lightDir = normalize(light.position.xyz - p);
    float diffuseContribution = max(dot(lightDir, n), 0.0);
    vec3 diffuse = diffuseContribution * light.color.rgb;

    vec3 viewDir = normalize(viewPosition - p);
    vec3 reflectDir = reflect(-lightDir, n);
    float specContribution = max(dot(viewDir, reflectDir), 0.0);
    vec3 specular = 0.5 * (specContribution * light.color.rgb);

    float distance = length(light.position.xyz - p);
    float attenuation = 1.0 / (1.0 + light.linear * distance + light.quadratic * (pow(distance, 2)));
    return (diffuse * attenuation) + (specular * attenuation);
}

float sampleShadowMap (int casterIndex, vec2 texCoord) {
    // vec2 tileSize = vec2(
    //     shadowMapSize.x / 2,
    //     shadowMapSize.y / float(MAX_SHADOW_MAPS));
    // vec2 tileCoord = vec2(
    //     tileSize.x,
    //     tileSize.y * float(casterIndex));

    // vec2 pixelCoord = vec2(
    //     tileCoord.x + (tileSize.x * texCoord.x), 
    //     tileCoord.y + (tileSize.y * texCoord.y));
    // vec2 absUVCoord = vec2(
    //     pixelCoord.x / shadowMapSize.x,
    //     pixelCoord.y / shadowMapSize.y);

    // bvec2 inBoundsMin = greaterThanEqual(pixelCoord, tileCoord); 
    // bvec2 inBoundsMax = lessThanEqual(pixelCoord, tileCoord + tileSize);
    // float result = all(inBoundsMin) && all(inBoundsMax) ? texture(mapShadow, absUVCoord).r : 1.0;
    // return result;
    return 0.0;
}

float computeShadowValue(int casterIndex, vec3 position, vec3 normal) {
    // uint lightID = shadowCasters[casterIndex].x;
    // Light light = lights[lightID];
    // vec3 lightDir = normalize(light.position.xyz);
    // vec4 lightSpacePosition = matLightSpaces[lightID] * vec4(position, 1.0);
    // float bias = 0.05 * (1.0 - dot(normal, lightDir));
	// bias = max(bias, 0.005);

    // vec3 projCoord = lightSpacePosition.xyz / lightSpacePosition.w;
    // if (projCoord.z > 1.0) {
    //     return 0.0;
    // }
    // projCoord = projCoord * 0.5 + 0.5;
    // float currentDepth = projCoord.z;


    // vec2 tileSize = vec2(
    //     shadowMapSize.x / 2,
    //     shadowMapSize.x / float(MAX_SHADOW_MAPS));
    // float result = 0.0;
    // vec2 texelSize = 1.0 / tileSize;
    // for (int x = -1; x <= 1; x += 1) {
    //     for (int y = -1; y <= 1; y += 1) {
    //         vec2 pcfCoord = projCoord.xy + vec2(x, y) * texelSize;
    //         float pcfDepth = sampleShadowMap(casterIndex, pcfCoord);
    //         result += currentDepth - bias > pcfDepth ? 1.0 : 0.0;
    //     }
    // }
    // result /= 9.0;
    // return result;
    return 0.0;
}

vec3 applyAtmosphericFog(in vec3 texelClr, float dist, vec3 viewDir, vec3 lightDir) {
    const vec3 fogClr = vec3(0.5, 0.6, 0.7);
    const float fogDistNear = 50.0;
    const float fogDistFarBlend = 30.0;
    const float fogDensity = 0.005;
    const float fogNearDensity = 5.0;

    float fogNearContribution = max((1.0 - pow((dist / fogDistNear), fogNearDensity)), 0.0);
    float fogFarContribution = (exp(-dist * fogDensity));
    float fogContribution = dist < fogDistFarBlend ? fogNearContribution : min(fogNearContribution, fogFarContribution);
    fogContribution = 1 - fogContribution;
    
    vec3 result = mix(texelClr, fogClr, fogContribution);
    return result;
}

