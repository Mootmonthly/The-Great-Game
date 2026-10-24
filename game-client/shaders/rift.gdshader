// A tear in the Veil: a black void edged with swirling violet light.
shader_type spatial;
render_mode blend_add, cull_disabled, unshaded, depth_draw_never;

uniform vec3 edge : source_color = vec3(0.75, 0.35, 1.0);
uniform vec3 core : source_color = vec3(0.25, 0.05, 0.4);

float hash(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
float noise(vec2 p) {
	vec2 i = floor(p), f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), u.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), u.x), u.y);
}

void fragment() {
	vec2 c = UV - 0.5;
	c.x *= 2.2;
	float r = length(c);
	float a = atan(c.y, c.x);
	float swirl = noise(vec2(a * 3.0 + TIME * 0.8, r * 8.0 - TIME * 1.5)) + 0.5 * noise(vec2(a * 7.0 - TIME, r * 15.0));
	float shape = 0.32 + 0.08 * swirl;
	float rim = smoothstep(shape + 0.12, shape, r) * smoothstep(shape - 0.16, shape - 0.02, r);
	float inner = smoothstep(shape, shape - 0.1, r);
	vec3 col = edge * rim * (1.5 + swirl) + core * inner * 0.6;
	ALBEDO = col;
	ALPHA = clamp(rim + inner * 0.5, 0.0, 1.0);
}
