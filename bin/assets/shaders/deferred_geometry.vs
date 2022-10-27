#version 450 core
layout (location = 0) in vec3 attribPosition;
layout (location = 1) in vec3 attribNormal;
layout (location = 2) in vec4 attribTangent;
layout (location = 3) in vec4 attribJoints;
layout (location = 4) in vec4 attribWeights;
layout (location = 5) in vec2 attribTexCoord;
layout (location = 6) in vec4 attribColor;
layout (location = 7) in mat4 attribInstanceMat;

out VS_OUT {
	vec3 position;
	vec3 normal;
	vec2 texCoord;
    vec4 color;
	mat3 matTBN;
} frag;

layout (std140, binding = 0) uniform ContextData {
    mat4 matProjView;
    mat4 matProj;
    mat4 matView;
    vec3 viewPosition;
    float time;
    float dt;
};

#define MAX_JOINTS 32
subroutine void subModelMat(inout mat4 modelMat, inout mat3 normalMat);

// builtin uniforms
uniform mat4 matModel;
uniform mat4 matModelLocal;
uniform mat3 matNormal;
uniform mat3 matNormalLocal;
uniform mat4 matJoints[MAX_JOINTS];

uniform bool useTangentSpace;

layout (location = 0) subroutine uniform subModelMat computeModelMat;

void main()
{
	mat4 finalMatModel = mat4(1);
	mat3 finalMatNormal = mat3(1);

    computeModelMat(finalMatModel, finalMatNormal);

    mat4 finalMVP = matProjView * finalMatModel;

	frag.position = vec3(finalMatModel * vec4(attribPosition, 1.0));
	frag.normal = finalMatNormal * attribNormal;
	frag.texCoord = attribTexCoord;
    frag.color = attribColor;

	if (useTangentSpace) {
		vec3 t = normalize(finalMatNormal * vec3(attribTangent));
		vec3 n = normalize(finalMatNormal * attribNormal);
		t =  normalize(t - dot(t, n) * n);
		vec3 b = cross(n, t);

		frag.matTBN = inverse(transpose(mat3(t, b, n)));
	}

    gl_Position = finalMVP * vec4(attribPosition, 1.0);
}

////////////////////////////////////
// Model Mat subroutines
layout (index = 0) subroutine(subModelMat)
void computeInstancedStaticModelMat(inout mat4 fMatModel, inout mat3 fMatNormal) {
    fMatModel = attribInstanceMat;
    fMatNormal = mat3(transpose(inverse(attribInstanceMat * matModelLocal)));
}

layout (index = 1) subroutine(subModelMat)
void computeInstancedDynamicModelMat(inout mat4 fMatModel, inout mat3 fMatNormal) {
    mat4 matSkin = 
		attribWeights.x * matJoints[int(attribJoints.x)] +
		attribWeights.y * matJoints[int(attribJoints.y)] +
		attribWeights.z * matJoints[int(attribJoints.z)] +
		attribWeights.w * matJoints[int(attribJoints.w)];

    fMatModel = attribInstanceMat;
    fMatModel = fMatModel * matModelLocal * matSkin;
    
    fMatNormal = mat3(transpose(inverse(attribInstanceMat * matModelLocal)));
    fMatNormal = fMatNormal * mat3(matSkin);
}

layout (index = 2) subroutine(subModelMat)
void computeStaticModelMat(inout mat4 fMatModel, inout mat3 fMatNormal) {
    fMatModel = matModel;
	fMatNormal = matNormal;
}

layout (index = 3) subroutine(subModelMat)
void computeDynamicModelMat(inout mat4 fMatModel, inout mat3 fMatNormal) {
    mat4 matSkin = 
		attribWeights.x * matJoints[int(attribJoints.x)] +
		attribWeights.y * matJoints[int(attribJoints.y)] +
		attribWeights.z * matJoints[int(attribJoints.z)] +
		attribWeights.w * matJoints[int(attribJoints.w)];

    fMatModel = matModelLocal * matSkin;
	fMatNormal = matNormalLocal * mat3(matSkin);
}

////////////////////////////////////
////////////////////////////////////

////////////////////////////////////
// Offset mat subroutines