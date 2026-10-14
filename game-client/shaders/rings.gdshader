// Planetary rings: banded, semi-transparent debris disc.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform float density = 0.6;
uniform float inner = 0.62;

void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	float bands = 0.6 + 0.4 * sin(r * 90.0) * sin(r * 37.0);
	float edge = smoothstep(inner, inner + 0.03, r) * (1.0 - smoothstep(0.96, 1.0, r));
	ALBEDO = vec3(0.85, 0.8, 0.72) * (0.7 + 0.3 * bands);
	ALPHA = edge * bands * density * 0.8;
}
