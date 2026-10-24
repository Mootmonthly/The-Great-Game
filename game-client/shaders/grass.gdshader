// Grass tufts for the region visit: darker at the root, sun-bleached at the
// tip, swaying in the wind. Each instance carries its own tint.
shader_type spatial;
render_mode cull_disabled;

uniform vec3 root_color : source_color = vec3(0.18, 0.32, 0.12);
uniform vec3 tip_color : source_color = vec3(0.55, 0.65, 0.28);
uniform float wind = 1.0;

varying float tip;
varying vec3 tint;

void vertex() {
	tip = UV.y;
	tint = COLOR.rgb;
	vec3 w = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float sway = sin(TIME * 1.7 + w.x * 0.35 + w.z * 0.2) * 0.5 + sin(TIME * 2.9 + w.z * 0.5) * 0.25;
	VERTEX.x += sway * 0.12 * wind * tip * tip;
	VERTEX.z += sway * 0.06 * wind * tip * tip;
}

void fragment() {
	ALBEDO = mix(root_color, tip_color, tip) * tint;
	ROUGHNESS = 0.9;
	SPECULAR = 0.1;
	BACKLIGHT = vec3(0.25) * tip;
}
