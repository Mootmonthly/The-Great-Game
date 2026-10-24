// Gear material: the creature toon look plus a hard stylised highlight.
// Same uniforms as creature.gdshader (base_color, glow_color, glow) so hit
// flashes work, plus metal parameters.
shader_type spatial;

uniform vec3 base_color : source_color = vec3(0.6, 0.6, 0.65);
uniform vec3 glow_color : source_color = vec3(0.0);
uniform float glow = 0.0;
uniform vec3 sheen_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float sheen = 0.6;
uniform float shininess = 24.0;

varying float up_facing;

void vertex() {
	up_facing = normalize(MODEL_NORMAL_MATRIX * NORMAL).y;
}

void fragment() {
	vec3 top = base_color * 1.25;
	vec3 bottom = base_color * vec3(0.55, 0.55, 0.68);
	ALBEDO = mix(bottom, top, smoothstep(-0.8, 0.9, up_facing));
	float fres = 1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = smoothstep(0.5, 0.95, fres);
	EMISSION = glow_color * glow + sheen_color * rim * 0.35 * sheen;
	ROUGHNESS = 0.4;
	SPECULAR = 0.0;
}

void light() {
	float ndl = dot(NORMAL, LIGHT);
	float wrap = ndl * 0.5 + 0.5;
	float band = smoothstep(0.28, 0.4, wrap) * 0.5 + smoothstep(0.62, 0.72, wrap) * 0.25 + 0.25 * smoothstep(0.0, 0.3, wrap);
	DIFFUSE_LIGHT += (0.28 + band * 0.72) * ATTENUATION * LIGHT_COLOR / PI;
	vec3 h = normalize(LIGHT + VIEW);
	float s = pow(max(dot(NORMAL, h), 0.0), shininess);
	s = smoothstep(0.35, 0.6, s);
	SPECULAR_LIGHT += s * sheen * sheen_color * ATTENUATION * LIGHT_COLOR * max(ndl, 0.0);
}
