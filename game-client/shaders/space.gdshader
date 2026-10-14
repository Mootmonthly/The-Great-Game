// Starfield and faint nebula for the globe background.
shader_type sky;

float hash(vec3 p) {
	p = fract(p * vec3(443.897, 441.423, 437.195));
	p += dot(p, p.yzx + 19.19);
	return fract((p.x + p.y) * p.z);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 cell = floor(d * 260.0);
	float h = hash(cell);
	float star = step(0.9975, h) * (0.5 + 0.5 * hash(cell + 7.0));
	float neb = pow(max(0.0, sin(d.x * 3.0 + d.y * 2.0) * cos(d.z * 2.5 - d.y)), 3.0);
	COLOR = vec3(star) + vec3(0.06, 0.03, 0.1) * neb + vec3(0.005, 0.006, 0.015);
}
