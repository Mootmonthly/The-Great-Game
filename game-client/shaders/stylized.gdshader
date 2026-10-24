// Stylised hand-painted material for buildings and scenery.
// Vertex colour carries the paint colour (rgb) and a surface pattern id (alpha):
// alpha 1.0 = plain, otherwise round(alpha * 10) selects a procedural pattern.
shader_type spatial;

uniform vec4 base_color : source_color = vec4(1.0);
uniform vec3 glow_color : source_color = vec3(0.0);
uniform float glow = 0.0;
uniform float flicker = 0.0;
uniform int pattern = -1;          // >= 0 overrides the per-vertex pattern id
uniform float noise_scale = 1.7;
uniform float noise_amount = 0.14;
uniform float macro_amount = 0.0;  // large soft colour patches (ground)
uniform float grad_height = 1.8;
uniform float grad_amount = 0.26;
uniform float rim_amount = 0.30;
uniform float band_soft = 0.10;

varying vec3 lpos;
varying vec3 lnorm;
varying vec3 wpos;
varying vec4 vcol;

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

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
	lpos = VERTEX;
	lnorm = NORMAL;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vcol = vec4(pow(COLOR.rgb, vec3(2.2)), COLOR.a);
}

void fragment() {
	vec3 col = base_color.rgb * vcol.rgb;
	int pid = pattern >= 0 ? pattern : int(floor(vcol.a * 10.0 + 0.5));
	vec3 p = lpos;
	vec3 an = abs(lnorm);
	bool is_top = an.y > 0.8;
	float sh = 1.0;
	vec2 wuv = an.z > an.x ? vec2(p.x, p.y) : vec2(p.z, p.y);
	if (pid >= 7 && pid <= 9) {
		wuv = vec2(atan(p.z, p.x) * max(length(p.xz), 0.3), p.y);
	}
	int kind = pid == 7 ? 3 : (pid == 8 ? 1 : (pid == 9 ? 2 : pid));
	if (kind == 1 && !is_top) {
		// dressed stone blocks
		vec2 cell = vec2(0.46, 0.27);
		float row = floor(wuv.y / cell.y);
		vec2 q = vec2(wuv.x / cell.x + mod(row, 2.0) * 0.5 + hash21(vec2(row, 3.0)) * 4.0, wuv.y / cell.y);
		vec2 id = floor(q);
		vec2 f = fract(q);
		float e = min(min(f.x, 1.0 - f.x) * cell.x, min(f.y, 1.0 - f.y) * cell.y);
		float ln = smoothstep(0.0, 0.03, e);
		sh = mix(0.62, 1.0, ln) * (0.88 + 0.24 * hash21(id));
		sh *= 0.9 + 0.1 * smoothstep(0.0, 0.3, f.y);
	} else if (kind == 2 && !is_top) {
		// brick with pale mortar
		vec2 cell = vec2(0.24, 0.09);
		float row = floor(wuv.y / cell.y);
		vec2 q = vec2(wuv.x / cell.x + mod(row, 2.0) * 0.5, wuv.y / cell.y);
		vec2 id = floor(q);
		vec2 f = fract(q);
		float e = min(min(f.x, 1.0 - f.x) * cell.x, min(f.y, 1.0 - f.y) * cell.y);
		float ln = smoothstep(0.0, 0.012, e);
		vec3 mortar = vec3(0.78, 0.74, 0.66);
		col = mix(mortar * base_color.rgb, col * (0.82 + 0.3 * hash21(id)), ln);
	} else if (kind == 3) {
		// vertical boards, or boards across a deck
		float s = (is_top ? p.z : wuv.x) / 0.17;
		float id = floor(s);
		float f = fract(s);
		sh = mix(0.7, 1.0, smoothstep(0.0, 0.1, min(f, 1.0 - f))) * (0.9 + 0.2 * hash21(vec2(id, 5.0)));
		sh *= 0.94 + 0.12 * vnoise(vec3(id, p.y * 2.5, 1.0));
	} else if (kind == 4) {
		// layered thatch
		float l = p.y * 4.6 + vnoise(vec3(p.x * 3.0, p.y * 2.0, p.z * 3.0)) * 0.7;
		float f = fract(l);
		sh = 0.78 + 0.22 * smoothstep(0.0, 0.6, f);
		sh *= 0.86 + 0.28 * vnoise(vec3((p.x + p.z) * 15.0, p.y * 1.3, (p.x - p.z) * 4.0));
	} else if (kind == 5 || kind == 6) {
		// overlapping tiles / shingles
		float rf = p.y / 0.15;
		float u = kind == 5 ? p.x / 0.21 : atan(p.z, p.x) * 3.8197;
		float row = floor(rf);
		vec2 q = vec2(u + mod(row, 2.0) * 0.5, rf);
		vec2 id = floor(q);
		vec2 f = fract(q);
		sh = mix(0.7, 1.0, smoothstep(0.0, 0.24, f.y)) * (0.88 + 0.24 * hash21(id));
		sh *= 1.0 - 0.18 * (1.0 - smoothstep(0.0, 0.07, min(f.x, 1.0 - f.x)));
	}
	col *= sh;
	// hand-painted brush variation in world space
	float n1 = vnoise(wpos * noise_scale * vec3(1.0, 0.45, 1.0));
	float n2 = vnoise(wpos * noise_scale * 3.1 + 7.0);
	col *= 1.0 + (n1 - 0.5) * noise_amount * 2.0 + (n2 - 0.5) * noise_amount;
	col = mix(col, col * vec3(1.06, 1.0, 0.9), smoothstep(0.35, 0.75, n1) * noise_amount * 1.5);
	if (macro_amount > 0.0) {
		float m = vnoise(wpos * 0.09 + 3.0) * 0.6 + vnoise(wpos * 0.31) * 0.4;
		col = mix(col * vec3(0.94, 0.97, 0.98), col * vec3(1.07, 1.04, 0.94), m);
		col *= 1.0 + (m - 0.5) * macro_amount;
	}
	// darker toward the ground
	float g = clamp(p.y / grad_height, 0.0, 1.0);
	col *= mix(1.0 - grad_amount, 1.0, smoothstep(0.0, 1.0, g));
	ALBEDO = col;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 2.6);
	vec3 em = col * rim * rim_amount;
	if (glow > 0.0) {
		vec3 gc = dot(glow_color, vec3(1.0)) > 0.001 ? glow_color : col;
		float fl = 1.0 + flicker * (0.5 * sin(TIME * 7.0 + wpos.x * 3.0 + wpos.z * 2.0) + 0.5 * sin(TIME * 13.0 + wpos.y * 5.0));
		em += gc * glow * fl;
	}
	EMISSION = em;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}

void light() {
	float ndl = dot(NORMAL, LIGHT) * 0.5 + 0.5;
	float s = band_soft;
	float band = smoothstep(0.34 - s, 0.34 + s, ndl) * 0.38 + smoothstep(0.66 - s, 0.66 + s, ndl) * 0.62;
	vec3 warm = mix(vec3(0.82, 0.86, 1.0), vec3(1.0, 0.97, 0.9), band);
	DIFFUSE_LIGHT += (0.16 + band * 0.84) * warm * ATTENUATION * LIGHT_COLOR / PI;
}
