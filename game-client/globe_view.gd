extends SubViewportContainer
## Stylised 3D globe of the current world: toon-lit surface built from the
## simulation, glowing atmosphere, drifting clouds and a starfield.
## Drag to rotate, scroll to zoom.

const TEX_W := 1024
const TEX_H := 512

var sim: RefCounted
var viewport: SubViewport
var pivot: Node3D
var planet: MeshInstance3D
var clouds: MeshInstance3D
var atmosphere: MeshInstance3D
var camera: Camera3D
var sun: DirectionalLight3D
var planet_material: ShaderMaterial
var cloud_material: ShaderMaterial
var atmo_material: ShaderMaterial
var albedo_texture: ImageTexture
var data_texture: ImageTexture

var yaw := 0.6
var pitch := 0.25
var distance := 3.3
var dragging := false
var spin := true
var spin_speed := 0.06
var axis: Node3D
var moon_nodes: Array = []
var moon_orbits: Array = []
var rings: MeshInstance3D
var moon_key := ""


func setup(world_sim: RefCounted) -> void:
	sim = world_sim
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	add_child(viewport)

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ShaderMaterial.new()
	sky_material.shader = load("res://shaders/space.gdshader")
	sky.sky_material = sky_material
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.06, 0.065, 0.1)
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.8
	env.glow_bloom = 0.0
	env.glow_hdr_threshold = 1.0
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	viewport.add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-15, 115, 0)
	sun.light_energy = 1.4
	viewport.add_child(sun)

	axis = Node3D.new()
	viewport.add_child(axis)
	pivot = Node3D.new()
	axis.add_child(pivot)

	planet = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 256
	sphere.rings = 128
	planet.mesh = sphere
	planet_material = ShaderMaterial.new()
	planet_material.shader = load("res://shaders/planet.gdshader")
	planet.material_override = planet_material
	pivot.add_child(planet)

	clouds = MeshInstance3D.new()
	var cloud_sphere := SphereMesh.new()
	cloud_sphere.radius = 1.04
	cloud_sphere.height = 2.08
	cloud_sphere.radial_segments = 128
	cloud_sphere.rings = 64
	clouds.mesh = cloud_sphere
	cloud_material = ShaderMaterial.new()
	cloud_material.shader = load("res://shaders/clouds.gdshader")
	clouds.material_override = cloud_material
	pivot.add_child(clouds)

	atmosphere = MeshInstance3D.new()
	var atmo_sphere := SphereMesh.new()
	atmo_sphere.radius = 1.1
	atmo_sphere.height = 2.2
	atmo_sphere.radial_segments = 128
	atmo_sphere.rings = 64
	atmosphere.mesh = atmo_sphere
	atmo_material = ShaderMaterial.new()
	atmo_material.shader = load("res://shaders/atmosphere.gdshader")
	atmosphere.material_override = atmo_material
	axis.add_child(atmosphere)

	rings = MeshInstance3D.new()
	var ring_mesh := PlaneMesh.new()
	ring_mesh.size = Vector2(4.2, 4.2)
	rings.mesh = ring_mesh
	var ring_mat := ShaderMaterial.new()
	ring_mat.shader = load("res://shaders/rings.gdshader")
	rings.material_override = ring_mat
	rings.visible = false
	axis.add_child(rings)

	camera = Camera3D.new()
	camera.fov = 40.0
	viewport.add_child(camera)
	_update_camera()


func refresh() -> void:
	if sim == null:
		return
	sim.build_globe(TEX_W, TEX_H)
	var albedo := Image.create_from_data(TEX_W, TEX_H, false, Image.FORMAT_RGBA8, sim.globe_albedo())
	var data := Image.create_from_data(TEX_W, TEX_H, false, Image.FORMAT_RGBA8, sim.globe_data())
	albedo.generate_mipmaps()
	data.generate_mipmaps()
	if albedo_texture == null:
		albedo_texture = ImageTexture.create_from_image(albedo)
		data_texture = ImageTexture.create_from_image(data)
		planet_material.set_shader_parameter("albedo_map", albedo_texture)
		planet_material.set_shader_parameter("data_map", data_texture)
	else:
		albedo_texture.update(albedo)
		data_texture.update(data)

	var a: Dictionary = JSON.parse_string(sim.atmosphere_json())
	var color := Color(a["color"][0], a["color"][1], a["color"][2])
	var thickness: float = a["thickness"]
	atmosphere.visible = thickness > 0.01
	atmo_material.set_shader_parameter("atmo_color", color)
	atmo_material.set_shader_parameter("strength", 0.35 + thickness * 1.2)
	atmo_material.set_shader_parameter("sun_direction", sun.global_transform.basis.z)
	planet_material.set_shader_parameter("rim_color", color if thickness > 0.01 else Color(0.3, 0.3, 0.3))
	planet_material.set_shader_parameter("rim_strength", 0.1 + thickness * 0.4)
	var coverage: float = a["clouds"]
	clouds.visible = coverage > 0.01
	cloud_material.set_shader_parameter("coverage", coverage)
	cloud_material.set_shader_parameter("cloud_color", Color(a["cloud_color"][0], a["cloud_color"][1], a["cloud_color"][2]))
	var sunlight: float = a["sunlight"]
	sun.light_energy = clampf(0.6 + 0.6 * sqrt(sunlight), 0.35, 1.6)
	if a.has("star_color"):
		sun.light_color = Color.html(a["star_color"])


## Updates rotation speed, tilt, moons and rings from the world status.
func set_planet(st: Dictionary) -> void:
	if axis == null:
		return
	# Visual spin: faster for short days, never frozen.
	spin_speed = clampf(0.06 * 24.0 / float(st["day_length"]), 0.004, 0.6)
	axis.rotation.z = deg_to_rad(float(st["axial_tilt"]))
	var rings_mass: float = st["rings"]
	rings.visible = rings_mass > 0.0
	if rings.visible:
		rings.material_override.set_shader_parameter("density", clampf(0.3 + rings_mass * 0.4, 0.3, 1.0))
	var key := JSON.stringify(st["moons"])
	if key == moon_key:
		return
	moon_key = key
	for n in moon_nodes:
		n.get_parent().queue_free()
	moon_nodes.clear()
	moon_orbits.clear()
	var i := 0
	for m in st["moons"]:
		var orbit := Node3D.new()
		orbit.rotation.y = i * 2.1
		orbit.rotation.x = 0.08 * (i % 3)
		axis.add_child(orbit)
		var moon := MeshInstance3D.new()
		var sphere := SphereMesh.new()
		var radius := clampf(0.12 * pow(float(m["mass"]), 1.0 / 3.0), 0.04, 0.45)
		sphere.radius = radius
		sphere.height = radius * 2.0
		moon.mesh = sphere
		var mat := ShaderMaterial.new()
		mat.shader = load("res://shaders/creature.gdshader")
		mat.set_shader_parameter("base_color", Color(0.72, 0.7, 0.68).darkened(0.1 * (i % 3)))
		moon.material_override = mat
		# Distances are compressed so far moons stay in view.
		moon.position = Vector3(1.6 + 1.1 * sqrt(float(m["distance"])), 0, 0)
		orbit.add_child(moon)
		moon_nodes.append(moon)
		moon_orbits.append(0.25 / pow(float(m["distance"]), 1.5))
		i += 1


func _process(delta: float) -> void:
	if pivot != null and spin and is_visible_in_tree():
		pivot.rotate_y(delta * spin_speed)
		for k in moon_nodes.size():
			moon_nodes[k].get_parent().rotate_y(delta * moon_orbits[k])


func _update_camera() -> void:
	pitch = clampf(pitch, -1.3, 1.3)
	distance = clampf(distance, 1.6, 12.0)
	var dir := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	camera.position = dir * distance
	camera.look_at(Vector3.ZERO, Vector3.UP)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			distance *= 0.92
			_update_camera()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			distance *= 1.08
			_update_camera()
	elif event is InputEventMouseMotion and dragging:
		yaw -= event.relative.x * 0.006
		pitch += event.relative.y * 0.006
		_update_camera()
