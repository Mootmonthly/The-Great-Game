// Ground of the region visit: grass, earth, sand, rock and snow blended by
// slope, height above the sea and the region's climate, with trodden paths
// around a settlement and glowing cracks on molten worlds.
shader_type spatial;
render_mode cull_back;

uniform vec3 grass_a : source_color = vec3(0.30, 0.48, 0.20);
uniform vec3 grass_b : source_color = vec3(0.45, 0.55, 0.22);
uniform vec3 soil : source_color = vec3(0.42, 0.33, 0.22);
uniform vec3 sand : source_color = vec3(0.78, 0.70, 0.50);
uniform vec3 rock : source_color = vec3(0.45, 0.43, 0.42);
uniform vec3 snow : source_color = vec3(0.92, 0.95, 1.0);
uniform vec3 path_color : source_color = vec3(0.50, 0.40, 0.28);
uniform vec3 ember : source_color = vec3(1.0, 0.35, 0.05);
/// Share of the ground covered by vegetation, 0..1.
uniform float vegetation = 0.7;
uniform float sea_level = -100.0;
/// World height above which snow lies (very high on warm worlds).
uniform float snow_height = 1000.0;
uniform float ember_glow = 0.0;
uniform sampler2D detail : repeat_enable, filter_linear_mipmap;
/// Trodden ground around a settlement, covering [-extent, extent] on x and z.
uniform sampler2D trodden : filter_linear;
uniform float extent = 110.0;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	float n1 = texture(detail, wpos.xz * 0.011).r;
	float n2 = texture(detail, wpos.xz * 0.07).r;
	float n3 = texture(detail, wpos.xz * 0.45).r;
	float slope = 1.0 - clamp(wnorm.y, 0.0, 1.0);
	float h = wpos.y - sea_level;

	vec3 green = mix(grass_a, grass_b, smoothstep(0.35, 0.65, n1)) * (0.82 + 0.36 * n3);
	float cover = clamp(vegetation * 1.5 - 0.25 + (n1 - 0.5) * 0.9 + (n3 - 0.5) * 0.25, 0.0, 1.0);
	vec3 col = mix(soil * (0.85 + 0.3 * n3), green, cover);

	float beach = 1.0 - smoothstep(0.25, 1.1 + n2 * 0.8, h);
	col = mix(col, sand * (0.9 + 0.2 * n3), beach);

	float cliff = smoothstep(0.30, 0.48, slope + (n2 - 0.5) * 0.18);
	col = mix(col, rock * (0.75 + 0.5 * n3 * n2 + 0.2 * n1), cliff);

	vec2 tuv = wpos.xz / (2.0 * extent) + 0.5;
	float path = texture(trodden, tuv).r * (0.75 + 0.5 * n3);
	col = mix(col, path_color * (0.85 + 0.3 * n2), clamp(path, 0.0, 1.0));

	float frost = smoothstep(snow_height - 1.5, snow_height + 1.5, wpos.y + (n2 - 0.5) * 5.0) * (1.0 - smoothstep(0.5, 0.75, slope));
	col = mix(col, snow * (0.94 + 0.06 * n3), frost);

	col *= mix(1.0, 0.65, smoothstep(0.0, -2.0, h));  // Darker under water.
	ALBEDO = col;
	ROUGHNESS = mix(0.95, 0.5, frost);
	SPECULAR = 0.15;
	float crack = smoothstep(0.60, 0.64, n2) * (1.0 - smoothstep(0.66, 0.72, n2));
	EMISSION = ember * ember_glow * crack * (0.6 + 0.4 * n3);
}
