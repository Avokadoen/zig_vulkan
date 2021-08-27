#version 450

vec2 quad[6] = vec2[](
    vec2( 1.0, -1.0),
    vec2( 1.0,  1.0),
    vec2(-1.0,  1.0),
    vec2(-1.0, -1.0),
    vec2( 1.0, -1.0),
    vec2(-1.0,  1.0)
);

layout(location = 0) out vec3 fragColor;

void main() {
    gl_Position = vec4(quad[gl_VertexIndex], 0.0, 1.0);
    // TODO: map texture
    fragColor = vec3(1.0, 0.0, 1.0);
}
