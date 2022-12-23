#version 450 core
in VS_OUT {
    vec2 texCoord;
} frag;

out vec4 finalColor;

layout (std140, binding = 0) uniform ContextData {
    mat4 projView;
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
const int MAX_LIGHTS = 32;
const int MAX_SHADOW_MAPS = 1;
const int MAXS_SHADOW_CASCADE = 3;
layout (std140, binding = 1) uniform LightingContext {
    Light lights[MAX_LIGHTS];
    // ID of the lights used for shadow mapping in the x component
    // Number of cascade in the y component
    uvec4 shadowCasters[MAX_SHADOW_MAPS];
    // Space matrices of the lights used for shadow mapping
    mat4 matLightSpaces[MAX_SHADOW_MAPS][MAXS_SHADOW_CASCADE];
    // FIXME: Temporary uvec4 for padding related reasons
    vec4 cascadesDistances[MAX_SHADOW_MAPS];
    vec4 ambient;                            // .rgb for the color and .a for the intensity
    uint lightCount;
    uint shadowCasterCount;
};

uniform sampler2D bufferedPosition;
uniform sampler2D bufferedNormal;
uniform sampler2D bufferedAlbedo;
uniform sampler2D bufferedDepth;
uniform sampler2D shadowMaps[MAX_SHADOW_MAPS * MAXS_SHADOW_CASCADE];

vec3 computeDirectionalLighting( Light light, vec3 p, vec3 n );
vec3 computePointLighting( Light light, vec3 p, vec3 n );
float computeShadowValue(int casterIndex, vec3 position, vec3 normal);
float filterShadowMap(uint shadowMapIndex, vec3 shadowCoord, float bias);
vec3 applyAtmosphericFog(in vec3 texelClr, float dist, vec3 viewDir, vec3 lightDir);

void main() {
    vec4 p = texture(bufferedPosition, frag.texCoord).rgba;
    vec3 position = p.rgb;
    vec3 normal = texture(bufferedNormal, frag.texCoord).rgb;
    vec3 albedo = texture(bufferedAlbedo, frag.texCoord).rgb;
    float distance = length(position - viewPosition);

    if (p.a <= 0.05) {
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

float computeShadowValue(int casterIndex, vec3 position, vec3 normal) {

    const uint lightID = shadowCasters[casterIndex].x;
    const uint cascadeCount = shadowCasters[casterIndex].y;
    const Light light = lights[lightID];
    const vec3 lightDir = normalize(light.position.xyz);
    float bias = 0.0024 * (1.0 - dot(normal, lightDir));
	bias = max(bias, 0.0024);
    
    vec4 viewSpacePosition = matView * vec4(position, 1.0);
    for (int i = 0; i < cascadeCount; i += 1) {
        const uint shadowMapIndex = casterIndex * MAXS_SHADOW_CASCADE + i;
        vec4 viewCoord = matView * vec4(position, 1.0);
        vec4 shadowCoord = matLightSpaces[casterIndex][i] * vec4(position, 1.0);
        vec3 nShadowCoord = shadowCoord.xyz / shadowCoord.w;
        nShadowCoord = nShadowCoord * 0.5 + 0.5;
        if (i == cascadeCount - 1 || abs(viewCoord.z) < cascadesDistances[casterIndex][i]) {
            // const float shadowDepth = texture(shadowMaps[shadowMapIndex], nShadowCoord.xy).r;
            // return  nShadowCoord.z - bias > shadowDepth ? 1.0 : 0.0;
            return filterShadowMap(shadowMapIndex, nShadowCoord, bias);
        }
    }

    return 0.0;
}

float filterShadowMap(uint shadowMapIndex, vec3 shadowCoord, float bias) {
    const float shadowDepth = texture(shadowMaps[shadowMapIndex], shadowCoord.xy).r;
    const float depthDiff = shadowCoord.z - shadowDepth;

    const float kernelSize = max(0.0, 2.0 + (smoothstep(0.0, 0.2, depthDiff) * 5));
    const int low = -int(floor((kernelSize - 1) / 2.0));
    const int high = int(ceil((kernelSize - 1) / 2.0));
    
    const vec2 texelSize = 1.0 / textureSize(shadowMaps[shadowMapIndex], 0); 
    float result = 0.0;
    for (int x = low; x <= high; x += 1) {
        for (int y = low; y <= high; y += 1) {
           const vec2 filterCoord = shadowCoord.xy + vec2(x, y) * texelSize;
           const float filterDepth = texture(shadowMaps[shadowMapIndex], filterCoord).r;
           result += shadowCoord.z - bias > filterDepth ? 1.0 : 0.0;
        }
    }

    result /= kernelSize * kernelSize;
    return result;
    // return  shadowCoord.z - bias > shadowDepth ? 1.0 : 0.0;
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

////////////////
/*
    PBR SANDBOX
*/


