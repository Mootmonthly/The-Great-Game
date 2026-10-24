// Rivers in the region visit: a ribbon of water flowing along its course
// (UV.y runs downstream, UV.x across), clear at the banks, darker mid-stream,
// with foam at the edges. Frozen rivers are pale ice.
shader_type spatial;
render_mode blend_mix, cull_disabled, depth_draw_opaque;

uniform vec3 shallow : source_color = vec3(0.3, 0.6, 0.7);
uniform vec3 deep : source_color = vec3(0.08, 0.25, 0.4);
uniform sampler2D ripples : hint_normal, repeat_enable, filter_linear_mipmap;
uniform float frozen = 0.0;

void fragment() {
	float across = abs(UV.x - 0.5) * 2.0;
	float mid = 1.0 - across;
	vec2 flow = vec2(UV.x * 0.6, UV.y * 0.5 - TIME * 0.35);
	vec3 n1 = texture(ripples, flow).rgb;
	vec3 n2 = texture(ripples, flow * 1.7 + vec2(0.31, -TIME * 0.2)).rgb;
	float foam = smoothstep(0.75, 1.0, across) * (0.5 + 0.5 * n1.r);
	vec3 col = mix(shallow, deep, mid * 0.8);
	if (frozen > 0.5) {
		ALBEDO = mix(vec3(0.75, 0.85, 0.92), vec3(0.9, 0.95, 1.0), across);
		ROUGHNESS = 0.3;
		ALPHA = 0.95;
	} else {
		ALBEDO = mix(col, vec3(0.95), foam * 0.7);
		NORMAL_MAP = normalize(n1 + n2 - 1.0) * 0.5 + 0.5;
		NORMAL_MAP_DEPTH = 0.8;
		ROUGHNESS = 0.1;
		SPECULAR = 0.6;
		ALPHA = mix(0.6, 0.9, mid) + foam * 0.3;
	}
}
