// Stylised planet surface: toon lighting, height-based normals, shiny seas,
// glowing lava. Maps come from the simulation (sim-core/src/globe.rs).
shader_type spatial;


uniform sampler2D albedo_map : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D data_map : filter_linear_mipmap, repeat_enable;
uniform float height_scale = 0.035;
uniform float bump_strength = 6.0;
uniform vec3 rim_color : source_color = vec3(0.5, 0.7, 1.0);
uniform float rim_strength = 0.25;

varying float v_height;
varying float v_liquid;

void vertex() {
	float h = textureLod(data_map, UV, 0.0).r;
	float liquid = textureLod(albedo_map, UV, 0.0).a;
	// Seas stay flat at their surface; land rises with elevation.
	v_height = h;
	VERTEX += NORMAL * h * height_scale * (1.0 - 0.6 * liquid);
}

void fragment() {
	vec4 a = texture(albedo_map, UV);
	vec4 d = texture(data_map, UV);
	vec2 px = vec2(1.0) / vec2(textureSize(data_map, 0));
	float hl = texture(data_map, UV - vec2(px.x, 0.0)).r;
	float hr = texture(data_map, UV + vec2(px.x, 0.0)).r;
	float hd = texture(data_map, UV - vec2(0.0, px.y)).r;
	float hu = texture(data_map, UV + vec2(0.0, px.y)).r;
	float land = 1.0 - a.a;
	vec3 n = normalize(vec3((hl - hr) * bump_strength * land, (hd - hu) * bump_strength * land, 1.0));
	NORMAL_MAP = n * 0.5 + 0.5;

	ALBEDO = a.rgb;
	v_liquid = a.a;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
	float rim = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	// Lava glows through cracks in its crust.
	EMISSION = vec3(1.0, 0.42, 0.08) * d.b * 2.2 + rim_color * rim * rim_strength;
}

// Two-band toon lighting with a soft terminator, plus a sharp glint on seas.
void light() {
	float ndl = dot(NORMAL, LIGHT);
	float band = smoothstep(-0.02, 0.06, ndl) * 0.65 + smoothstep(0.35, 0.45, ndl) * 0.35;
	DIFFUSE_LIGHT += band * ATTENUATION * LIGHT_COLOR / PI;
	vec3 h = normalize(LIGHT + VIEW);
	float glint = smoothstep(0.994, 0.999, dot(NORMAL, h)) * v_liquid;
	SPECULAR_LIGHT += glint * ATTENUATION * LIGHT_COLOR * 0.15;
}
