// Atmosphere glow: a slightly larger shell with a fresnel rim, brighter on the
// day side. Colour and thickness come from the simulated air.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back;

uniform vec3 atmo_color : source_color = vec3(0.35, 0.6, 1.0);
uniform float strength = 1.0;
uniform vec3 sun_direction = vec3(1.0, 0.3, 0.4);

void fragment() {
	float facing = clamp(dot(NORMAL, VIEW), 0.0, 1.0);
	float rim = pow(1.0 - facing, 2.2);
	vec3 world_normal = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float day = clamp(dot(world_normal, normalize(sun_direction)) * 0.8 + 0.35, 0.03, 1.0);
	ALBEDO = atmo_color * rim * strength * day * 1.6;
}
