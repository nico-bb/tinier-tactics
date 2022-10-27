#version 450 core
layout (location = 0) in vec2 attribPosition;
layout (location = 5) in vec2 attribTexCoord;

out VS_OUT {
	vec2 texCoord;
} frag;

void main() {
	frag.texCoord = attribTexCoord;

	gl_Position = vec4(attribPosition, 0.0, 1.0);
}