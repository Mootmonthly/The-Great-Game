// Seas and lakes of the region visit: deeper water is darker, shallows are
// clear, foam rims the shore, and the surface ripples. Lava glows instead.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque;

uniform vec3 shallow : source_color = vec3(0.25, 0.6, 0.7);
uniform vec3 deep : source_color = vec3(0.05, 0.18, 0.35);
uniform float glow = 0.0;
uniform float sea_level = 0.0;
/// Terrain heights covering [-extent, extent] on x and z.
uniform sampler2D heightmap : filter_linear;
uniform float extent = 110.0;
uniform float texel = 0.0;
uniform sampler2D ripples : hint_normal, repeat_enable, filter_linear_mipmap;
uniform sampler2D detail : repeat_enable, filter_linear_mipmap;

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = (wpos.xz / (2.0 * extent) + 0.5) * (1.0 - texel) + texel * 0.5;
	float depth = sea_level - texture(heightmap, uv).r;
	float d = clamp(depth / 4.0, 0.0, 1.0);
	float n = texture(detail, wpos.xz * 0.15 + vec2(TIME * 0.02, 0.0)).r;
	float foam = (1.0 - smoothstep(0.0, 0.25 + 0.3 * n, depth)) * (0.6 + 0.4 * sin(TIME * 1.5 + n * 9.0));
	vec3 col = mix(shallow, deep, sqrt(d));
	if (glow > 0.0) {
		ALBEDO = col * 0.3;
		EMISSION = col * glow * (0.7 + 0.6 * n);
		ROUGHNESS = 0.9;
		ALPHA = 1.0;
	} else {
		ALBEDO = mix(col, vec3(0.95), clamp(foam, 0.0, 1.0) * 0.85);
		vec3 a = texture(ripples, wpos.xz * 0.05 + vec2(TIME * 0.012, TIME * 0.007)).rgb;
		vec3 b = texture(ripples, wpos.xz * 0.09 - vec2(TIME * 0.009, -TIME * 0.011)).rgb;
		NORMAL_MAP = normalize(a + b - 1.0) * 0.5 + 0.5;
		NORMAL_MAP_DEPTH = 0.6;
		ROUGHNESS = 0.08;
		SPECULAR = 0.6;
		ALPHA = mix(0.55, 0.93, d) + foam * 0.3;
	}
}
