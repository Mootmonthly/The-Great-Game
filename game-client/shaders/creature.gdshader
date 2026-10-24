// Stylised creature material: hand-painted look. Soft wrap lighting in three
// toon bands, a top-light / bottom-dark tint from the surface normal, a warm
// rim light and optional glow. Uniforms are shared with the gear shader.
shader_type spatial;

uniform vec3 base_color : source_color = vec3(0.6, 0.6, 0.6);
uniform vec3 glow_color : source_color = vec3(0.0);
uniform float glow = 0.0;

varying float up_facing;

void vertex() {
	up_facing = normalize(MODEL_NORMAL_MATRIX * NORMAL).y;
}

void fragment() {
	// Painted gradient: sky-lit tops, earthy undersides.
	vec3 top = base_color * 1.12 + vec3(0.03, 0.03, 0.01);
	vec3 bottom = base_color * vec3(0.62, 0.58, 0.70);
	vec3 col = mix(bottom, top, smoothstep(-0.8, 0.9, up_facing));
	ALBEDO = col;
	float fres = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = smoothstep(0.55, 0.95, fres);
	EMISSION = glow_color * glow + mix(base_color, vec3(1.0, 0.95, 0.85), 0.5) * rim * 0.28;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float wrap = ndl * 0.5 + 0.5;
	float band = smoothstep(0.30, 0.42, wrap) * 0.45 + smoothstep(0.62, 0.74, wrap) * 0.30 + 0.25 * smoothstep(0.0, 0.3, wrap);
	// Cool shadows, warm lights.
	vec3 tint = mix(vec3(0.82, 0.86, 1.0), vec3(1.05, 1.0, 0.95), band);
	DIFFUSE_LIGHT += (0.30 + band * 0.70) * tint * ATTENUATION * LIGHT_COLOR / PI;
}
