// Stylised creature material: two-band toon lighting, rim light, optional glow.
shader_type spatial;

uniform vec3 base_color : source_color = vec3(0.6, 0.6, 0.6);
uniform vec3 glow_color : source_color = vec3(0.0);
uniform float glow = 0.0;

void fragment() {
	ALBEDO = base_color;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	EMISSION = glow_color * glow + base_color * rim * 0.35;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float band = smoothstep(-0.05, 0.05, ndl) * 0.6 + smoothstep(0.45, 0.55, ndl) * 0.4;
	DIFFUSE_LIGHT += (0.25 + band * 0.75) * ATTENUATION * LIGHT_COLOR / PI;
}
