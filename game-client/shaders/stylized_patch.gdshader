// Ground patches for the arena: water, lava, ice and moss with a wobbly painted edge.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform int mode = 0;               // 0 water, 1 lava, 2 ice, 3 moss
uniform float radius = 3.0;
uniform float seed = 1.0;
uniform vec3 col_a : source_color = vec3(0.12, 0.35, 0.75);
uniform vec3 col_b : source_color = vec3(0.45, 0.75, 0.95);
uniform vec3 col_edge : source_color = vec3(0.9, 0.97, 1.0);
uniform float alpha = 1.0;

varying vec3 lp;

float hash31(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}

float vnoise(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = mix(mix(hash31(i), hash31(i + vec3(1, 0, 0)), f.x), mix(hash31(i + vec3(0, 1, 0)), hash31(i + vec3(1, 1, 0)), f.x), f.y);
	float b = mix(mix(hash31(i + vec3(0, 0, 1)), hash31(i + vec3(1, 0, 1)), f.x), mix(hash31(i + vec3(0, 1, 1)), hash31(i + vec3(1, 1, 1)), f.x), f.y);
	return mix(a, b, f.z);
}

void vertex() {
	lp = VERTEX;
}

void fragment() {
	vec2 q = lp.xz;
	float d = length(q);
	float a = atan(q.y, q.x);
	float wob = vnoise(vec3(cos(a) * 1.7 + seed, sin(a) * 1.7, seed * 0.37)) * 2.0 - 1.0;
	wob += 0.5 * (vnoise(vec3(cos(a) * 4.3, sin(a) * 4.3 + seed, 2.0)) * 2.0 - 1.0);
	float edge = radius * (1.0 + 0.055 * wob);
	float t = d - edge;              // negative inside
	if (t > 0.0) {
		discard;
	}
	float depth = clamp(-t / (radius * 0.35), 0.0, 1.0);
	vec3 c = col_a;
	float al = alpha;
	float n = vnoise(vec3(q * 1.3, TIME * 0.0));
	if (mode == 0) {
		float w1 = vnoise(vec3(q * 1.1 + vec2(TIME * 0.25, 0.0), TIME * 0.35));
		float w2 = vnoise(vec3(q * 2.7 - vec2(0.0, TIME * 0.3), TIME * 0.5 + 4.0));
		c = mix(col_a, col_b, smoothstep(0.35, 0.8, w1 * 0.6 + w2 * 0.4) * 0.55);
		c = mix(c, col_b, depth < 0.5 ? (1.0 - depth * 2.0) * 0.55 : 0.0);
		float ripple = smoothstep(0.78, 0.82, fract(w2 * 3.0 + TIME * 0.1));
		c = mix(c, col_edge, ripple * 0.35);
		float foam = smoothstep(0.14, 0.0, -t) * (0.6 + 0.4 * vnoise(vec3(q * 6.0, TIME * 0.8)));
		c = mix(c, col_edge, foam);
		al = mix(alpha * 0.8, alpha, foam);
	} else if (mode == 1) {
		float f1 = vnoise(vec3(q * 0.8 + vec2(0.0, TIME * 0.1), TIME * 0.15));
		float f2 = vnoise(vec3(q * 2.0 - vec2(TIME * 0.1, 0.0), TIME * 0.3 + 9.0));
		vec3 molten = mix(col_a, col_b, smoothstep(0.25, 0.85, f2 * 0.7 + f1 * 0.4));
		float plate = smoothstep(0.5, 0.58, f1 + (f2 - 0.5) * 0.25);
		c = mix(molten, vec3(0.2, 0.08, 0.06), plate * 0.88);
		float rimcrust = smoothstep(0.4, 0.0, -t);
		c = mix(c, vec3(0.12, 0.06, 0.05), rimcrust * 0.9);
		c = mix(c, col_b * 1.1, smoothstep(0.0, 0.1, -t) * (1.0 - smoothstep(0.1, 0.22, -t)) * 0.5 * (1.0 - plate));
	} else if (mode == 2) {
		float f1 = vnoise(vec3(q * 1.6, 3.0));
		float f2 = vnoise(vec3(q * 5.0, 5.0));
		c = mix(col_a, col_b, f1 * 0.7);
		float crack = 1.0 - smoothstep(0.0, 0.035, abs(f2 - 0.5) * 0.5 + abs(f1 - 0.5) * 0.15 - 0.002);
		c = mix(c, col_edge, crack * 0.55);
		float frost = smoothstep(0.3, 0.0, -t);
		c = mix(c, col_edge, frost * 0.8);
		c += vec3(smoothstep(0.93, 1.0, vnoise(vec3(q * 9.0, floor(TIME * 2.0)))) * 0.5);
	} else {
		float f1 = vnoise(vec3(q * 1.2, 1.0));
		float f2 = vnoise(vec3(q * 4.0, 2.0));
		c = mix(col_a, col_b, f1 * 0.8 + f2 * 0.25);
		c = mix(c, col_edge, smoothstep(0.2, 0.0, -t) * 0.55);
	}
	ALBEDO = c;
	EMISSION = mode == 1 ? c * 0.22 : vec3(0.0);
	ALPHA = al;
}
