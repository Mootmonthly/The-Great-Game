// Stylised clouds: banded noise on a shell above the surface, toon lit, drifting
// slowly. Coverage comes from the simulated atmosphere.
shader_type spatial;
render_mode diffuse_toon, specular_disabled, depth_draw_never, cull_back;

uniform float coverage = 0.4;
uniform vec3 cloud_color : source_color = vec3(1.0);
uniform float speed = 0.01;

varying vec3 v_pos;

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

float noise(vec3 x) {
	vec3 i = floor(x);
	vec3 f = fract(x);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mix(hash(i + vec3(0, 0, 0)), hash(i + vec3(1, 0, 0)), f.x),
	               mix(hash(i + vec3(0, 1, 0)), hash(i + vec3(1, 1, 0)), f.x), f.y),
	           mix(mix(hash(i + vec3(0, 0, 1)), hash(i + vec3(1, 0, 1)), f.x),
	               mix(hash(i + vec3(0, 1, 1)), hash(i + vec3(1, 1, 1)), f.x), f.y), f.z);
}

float fbm(vec3 p) {
	float s = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		s += a * noise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return s;
}

void vertex() {
	v_pos = VERTEX;
}

void fragment() {
	float t = TIME * speed;
	vec3 p = v_pos;
	// Stretch along latitude for banded, wind-swept shapes.
	vec3 q = vec3(p.x * cos(t) - p.z * sin(t), p.y * 2.2, p.x * sin(t) + p.z * cos(t)) * 3.0;
	float n = fbm(q + fbm(q * 0.7) * 1.5);
	float edge = 1.0 - coverage;
	// Hard-edged, cartoon cloud shapes.
	float c = smoothstep(edge, edge + 0.04, n);
	ALBEDO = cloud_color;
	ALPHA = c * 0.92;
	ROUGHNESS = 1.0;
}
