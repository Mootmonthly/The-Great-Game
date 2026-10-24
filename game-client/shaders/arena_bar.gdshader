shader_type spatial;
render_mode unshaded, depth_test_disabled, cull_disabled, blend_mix;
// A camera-facing health bar on a unit-sized quad. `frac` is set per
// instance, so one material per team serves every unit.

uniform vec4 team_color : source_color = vec4(0.35, 0.7, 1.0, 1.0);
instance uniform float frac = 1.0;

varying vec2 bar_uv;

void vertex() {
	bar_uv = UV;
	// Billboard: keep the model position, take the camera's orientation.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec2 uv = bar_uv;
	float edge = 0.12;
	bool border = uv.x < 0.015 || uv.x > 0.985 || uv.y < edge || uv.y > 1.0 - edge;
	vec3 col;
	float a = 0.92;
	if (border) {
		col = vec3(0.02, 0.02, 0.03);
	} else if (uv.x < frac) {
		// Team colour while healthy, shifting to amber then red when low.
		vec3 low = mix(vec3(1.0, 0.15, 0.1), vec3(1.0, 0.8, 0.15), smoothstep(0.15, 0.4, frac));
		col = mix(low, team_color.rgb, smoothstep(0.35, 0.65, frac));
		// A light stripe across the top for readability.
		col += 0.18 * step(0.55, uv.y);
	} else {
		col = vec3(0.12, 0.12, 0.14);
		a = 0.85;
	}
	ALBEDO = col;
	ALPHA = a;
}
