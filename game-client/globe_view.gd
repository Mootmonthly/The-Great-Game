extends SubViewportContainer
## Stylised 3D globe of the current world: toon-lit surface built from the
## simulation, glowing atmosphere, drifting clouds and a starfield.
## Shows the peoples of the world (territory tint, city lights, settlement
## pins, capital labels, war arcs, heroes) and any map overlay, and can be
## clicked or hovered to pick a region.
## Drag to rotate, scroll to zoom.

## A region was clicked (not dragged).
signal region_picked(x: int, y: int)
## The region under the pointer changed; (-1, -1) when it is over space.
signal region_hovered(x: int, y: int)

const TEX_W := 1024
const TEX_H := 512
## The simulation's region grid.
const GRID_W := 64
const GRID_H := 32
## Same as the planet shader's default height_scale.
const RELIEF := 0.035
const MAX_LABELS := 12
const HERO_COUNT := 20
const WAR_SEGMENTS := 24
const BODY_REFRESH_MS := 5000

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
var info_texture: ImageTexture
var overlay_texture: ImageTexture
var albedo_image: Image
var data_image: Image

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
var moon_materials: Array = []
## Per moon: [albedo, data, info] textures.
var moon_textures: Array = []
var bodies_dirty := true
var bodies_stamp := 0
var host_planet: MeshInstance3D
var host_material: ShaderMaterial
var host_textures: Array = []
var host_active := false

var settlement_marks: MultiMeshInstance3D
var hero_marks: MultiMeshInstance3D
var capital_labels: Array[Label3D] = []
var label_dirs := PackedVector3Array()
var war_arcs: MeshInstance3D
var war_material: StandardMaterial3D
var select_ring: MeshInstance3D
var legend: Label
var show_heroes := true
var selected := Vector2i(-1, -1)
var overlay_mode := 0
var overlay_name := "Surface"
var status: Dictionary = {}
var settlement_count := 0
var press_pos := Vector2.ZERO
var mouse_inside := false
var hover_cooldown := 0.0
var hover_region := Vector2i(-2, -2)
var clock := 0.0


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

	# The host planet, seen from a moon: big and in the background.
	host_planet = MeshInstance3D.new()
	var host_sphere := SphereMesh.new()
	host_sphere.radius = 2.5
	host_sphere.height = 5.0
	host_sphere.radial_segments = 128
	host_sphere.rings = 64
	host_planet.mesh = host_sphere
	host_material = ShaderMaterial.new()
	host_material.shader = planet_material.shader
	host_material.set_shader_parameter("height_scale", 0.05)
	host_planet.material_override = host_material
	host_planet.visible = false
	viewport.add_child(host_planet)

	_build_markers()
	_update_camera()

	legend = Label.new()
	legend.position = Vector2(8, 6)
	legend.modulate = Color(1, 1, 1, 0.7)
	legend.add_theme_font_size_override("font_size", 12)
	legend.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	legend.add_theme_constant_override("outline_size", 4)
	legend.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(legend)

	mouse_exited.connect(func():
		mouse_inside = false
		_set_hover(Vector2i(-1, -1)))
	mouse_entered.connect(func(): mouse_inside = true)


## Pins, glints, labels, war arcs and the selection ring; all children of the
## pivot so they turn with the planet.
func _build_markers() -> void:
	var pin := CylinderMesh.new()
	pin.top_radius = 0.0
	pin.bottom_radius = 0.5
	pin.height = 1.0
	pin.radial_segments = 8
	pin.rings = 1
	settlement_marks = _make_multimesh(pin)
	var glint := SphereMesh.new()
	glint.radius = 0.5
	glint.height = 1.0
	glint.radial_segments = 8
	glint.rings = 4
	hero_marks = _make_multimesh(glint)

	for k in MAX_LABELS:
		var label := Label3D.new()
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.no_depth_test = true
		label.fixed_size = true
		label.pixel_size = 0.0011
		label.font_size = 24
		label.outline_size = 10
		label.outline_modulate = Color(0, 0, 0, 0.9)
		label.offset = Vector2(0, 30)
		label.render_priority = 10
		label.outline_render_priority = 9
		label.visible = false
		pivot.add_child(label)
		capital_labels.append(label)

	war_arcs = MeshInstance3D.new()
	war_arcs.mesh = ImmediateMesh.new()
	war_material = StandardMaterial3D.new()
	war_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	war_material.vertex_color_use_as_albedo = true
	war_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	war_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	war_arcs.material_override = war_material
	war_arcs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(war_arcs)

	select_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.042
	torus.outer_radius = 0.052
	torus.rings = 24
	torus.ring_segments = 6
	select_ring.mesh = torus
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(1.6, 1.6, 1.3)
	select_ring.material_override = ring_mat
	select_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	select_ring.visible = false
	pivot.add_child(select_ring)


func _make_multimesh(mesh: Mesh) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = 0
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	inst.material_override = mat
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pivot.add_child(inst)
	return inst


# --- Regions on the sphere -----------------------------------------------------

## The point of the unit sphere (pivot space, scaled by `radius`) above the
## centre of region (x, y): the texture is equirectangular, u around +Y and v
## from the north pole down, as the SphereMesh lays it out.
func region_to_point(x: int, y: int, radius: float = 1.0) -> Vector3:
	return grid_to_point(float(x) + 0.5, float(y) + 0.5, radius)


## The point of the sphere at fractional grid coordinates (region (x, y)
## spans x..x+1, y..y+1).
func grid_to_point(gx: float, gy: float, radius: float = 1.0) -> Vector3:
	var lon := gx / GRID_W * TAU
	var colat := clampf(gy, 0.01, GRID_H - 0.01) / GRID_H * PI
	var ring := sin(colat)
	return Vector3(sin(lon) * ring, cos(colat), cos(lon) * ring) * radius


## The region under a point in pivot space (any distance from the centre).
func point_to_region(p: Vector3) -> Vector2i:
	var r := p.length()
	if r < 0.0001:
		return Vector2i(-1, -1)
	var u := fposmod(atan2(p.x, p.z) / TAU, 1.0)
	var v := acos(clampf(p.y / r, -1.0, 1.0)) / PI
	return Vector2i(clampi(int(u * GRID_W), 0, GRID_W - 1), clampi(int(v * GRID_H), 0, GRID_H - 1))


## Radius of the terrain at a region, so that markers sit on the relief.
func surface_radius(x: int, y: int) -> float:
	if data_image == null or albedo_image == null:
		return 1.0
	var px := clampi(int((x + 0.5) / GRID_W * TEX_W), 0, TEX_W - 1)
	var py := clampi(int((y + 0.5) / GRID_H * TEX_H), 0, TEX_H - 1)
	var h := data_image.get_pixel(px, py).r
	var liquid := albedo_image.get_pixel(px, py).a
	return 1.0 + h * RELIEF * (1.0 - 0.6 * liquid)


## A basis whose Y axis is `up`.
func _upright(up: Vector3) -> Basis:
	var side := up.cross(Vector3.UP if absf(up.y) < 0.99 else Vector3.RIGHT).normalized()
	return Basis(side, up, side.cross(up))


func refresh() -> void:
	if sim == null:
		return
	sim.build_globe(TEX_W, TEX_H)
	albedo_image = Image.create_from_data(TEX_W, TEX_H, false, Image.FORMAT_RGBA8, sim.globe_albedo())
	data_image = Image.create_from_data(TEX_W, TEX_H, false, Image.FORMAT_RGBA8, sim.globe_data())
	var info := Image.create_from_data(TEX_W, TEX_H, false, Image.FORMAT_RGBA8, sim.globe_info())
	var albedo := albedo_image.duplicate() as Image
	var data := data_image.duplicate() as Image
	albedo.generate_mipmaps()
	data.generate_mipmaps()
	info.generate_mipmaps()
	if albedo_texture == null:
		albedo_texture = ImageTexture.create_from_image(albedo)
		data_texture = ImageTexture.create_from_image(data)
		info_texture = ImageTexture.create_from_image(info)
		planet_material.set_shader_parameter("albedo_map", albedo_texture)
		planet_material.set_shader_parameter("data_map", data_texture)
		planet_material.set_shader_parameter("info_map", info_texture)
	else:
		albedo_texture.update(albedo)
		data_texture.update(data)
		info_texture.update(info)
	_rebuild_markers()
	_update_selection()
	_update_bodies()

	var a: Dictionary = JSON.parse_string(sim.atmosphere_json())
	var color := Color(a["color"][0], a["color"][1], a["color"][2])
	var thickness: float = a["thickness"]
	atmosphere.visible = thickness > 0.01
	# A thin Veil tints the sky violet.
	var veil_open: float = a.get("veil_open", 0.0)
	color = color.lerp(Color(0.7, 0.3, 1.0), clampf(veil_open * 0.8, 0.0, 0.6))
	if veil_open > 0.3:
		atmosphere.visible = true
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
	status = st
	_update_legend()
	# A moon in focus sees its host planet instead of moons of its own.
	var host_now = st.get("host") != null
	if host_now != host_active:
		host_active = host_now
		host_planet.visible = host_now
		bodies_dirty = true
	# Visual spin: faster for short days, never frozen.
	spin_speed = clampf(0.06 * 24.0 / float(st["day_length"]), 0.004, 0.6)
	axis.rotation.z = deg_to_rad(float(st["axial_tilt"]))
	var rings_mass: float = st["rings"]
	rings.visible = rings_mass > 0.0
	if rings.visible:
		rings.material_override.set_shader_parameter("density", clampf(0.3 + rings_mass * 0.4, 0.3, 1.0))
	var key := JSON.stringify(st["moons"])
	if key == moon_key:
		for n in moon_nodes:
			n.get_parent().visible = not host_now
		_update_bodies()
		return
	moon_key = key
	bodies_dirty = true
	for n in moon_nodes:
		n.get_parent().queue_free()
	moon_nodes.clear()
	moon_orbits.clear()
	moon_materials.clear()
	moon_textures.clear()
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
		mat.shader = planet_material.shader
		mat.set_shader_parameter("height_scale", 0.012)
		mat.set_shader_parameter("rim_strength", 0.1)
		moon.material_override = mat
		moon_materials.append(mat)
		moon_textures.append([])
		# Distances are compressed so far moons stay in view.
		moon.position = Vector3(1.6 + 1.1 * sqrt(float(m["distance"])), 0, 0)
		orbit.visible = not host_now
		orbit.add_child(moon)
		moon_nodes.append(moon)
		moon_orbits.append(0.25 / pow(float(m["distance"]), 1.5))
		i += 1
	_update_bodies()


func _process(delta: float) -> void:
	if pivot == null or not is_visible_in_tree():
		return
	clock += delta
	if spin:
		pivot.rotate_y(delta * spin_speed)
		for k in moon_nodes.size():
			moon_nodes[k].get_parent().rotate_y(delta * moon_orbits[k])
	if host_active:
		host_planet.rotate_y(delta * 0.02)
	# Labels on the far side of the globe are hidden.
	var cam_dir := (pivot.global_transform.affine_inverse() * camera.global_position).normalized()
	for k in label_dirs.size():
		capital_labels[k].visible = label_dirs[k].dot(cam_dir) > 0.1
	# Wars pulse slowly; the selection ring breathes.
	var pulse := 0.65 + 0.35 * sin(clock * 2.2)
	war_material.albedo_color = Color(1.0 + pulse * 0.8, 0.85 + pulse * 0.4, 0.85 + pulse * 0.4, 0.45 + 0.5 * pulse)
	if select_ring.visible:
		select_ring.scale = Vector3.ONE * (1.0 + 0.15 * sin(clock * 4.0))
	# Hover: one ray at most every 0.1 s.
	hover_cooldown -= delta
	if mouse_inside and not dragging and hover_cooldown <= 0.0:
		hover_cooldown = 0.1
		_set_hover(pick_region_at(get_local_mouse_position()))


func _update_camera() -> void:
	pitch = clampf(pitch, -1.3, 1.3)
	distance = clampf(distance, 1.6, 12.0)
	var dir := Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw))
	camera.position = dir * distance
	camera.look_at(Vector3.ZERO, Vector3.UP)
	if host_planet != null:
		host_planet.position = camera.position + camera.basis * Vector3(-3.0, 0.7, -11.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			dragging = event.pressed
			if event.pressed:
				press_pos = event.position
			elif event.position.distance_to(press_pos) < 4.0:
				var cell := pick_region_at(event.position)
				if cell.x >= 0:
					region_picked.emit(cell.x, cell.y)
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


## The region under a pixel of the globe (container coordinates), or
## (-1, -1) if the ray misses the planet.
func pick_region_at(screen_pos: Vector2) -> Vector2i:
	var to_local := pivot.global_transform.affine_inverse()
	var origin: Vector3 = to_local * camera.project_ray_origin(screen_pos)
	var dir: Vector3 = (to_local.basis * camera.project_ray_normal(screen_pos)).normalized()
	# Sphere of radius 1 plus a touch for the relief.
	var b := origin.dot(dir)
	var disc := b * b - (origin.length_squared() - 1.02 * 1.02)
	if disc < 0.0:
		return Vector2i(-1, -1)
	var t := -b - sqrt(disc)
	if t < 0.0:
		return Vector2i(-1, -1)
	return point_to_region(origin + dir * t)


func _set_hover(cell: Vector2i) -> void:
	if cell == hover_region:
		return
	hover_region = cell
	if cell.x < 0:
		tooltip_text = ""
	else:
		tooltip_text = sim.region_summary(cell.x, cell.y)
	region_hovered.emit(cell.x, cell.y)


# --- Peoples, wars and bodies ----------------------------------------------------

## Rebuilds pins, glints, capital labels and war arcs from the simulation.
func _rebuild_markers() -> void:
	var parsed = JSON.parse_string(sim.globe_markers_json(HERO_COUNT if show_heroes else 0))
	if not parsed is Dictionary:
		return
	var marks: Array = parsed["marks"]
	var places: Array = []
	var heroes: Array = []
	var capitals: Array = []
	for m in marks:
		match m["kind"]:
			"hero":
				heroes.append(m)
			"capital":
				places.append(m)
				capitals.append(m)
			_:
				places.append(m)
	settlement_count = places.size()
	var mm := settlement_marks.multimesh
	mm.instance_count = places.size()
	for k in places.size():
		var m: Dictionary = places[k]
		var x := int(m["x"])
		var y := int(m["y"])
		var capital: bool = m["kind"] == "capital"
		# Villages are small studs, towns and cities taller pins.
		var pop := float(m["size"])
		var height := clampf(0.008 + 0.012 * sqrt(pop), 0.01, 0.07) * (1.6 if capital else 1.0)
		# Break up the region grid: each settlement sits at its own spot
		# inside its region (fixed by name, so it never wanders).
		var h := hash(m["name"])
		var jx := 0.5 if capital else 0.2 + 0.6 * float(h & 0xFF) / 255.0
		var jy := 0.5 if capital else 0.2 + 0.6 * float((h >> 8) & 0xFF) / 255.0
		var up := grid_to_point(x + jx, y + jy)
		var base := _upright(up).scaled_local(Vector3(height * 0.55, height, height * 0.55))
		var r := surface_radius(x, y) - 0.002
		mm.set_instance_transform(k, Transform3D(base, up * (r + height * 0.5)))
		var color := Color.html(m["color"])
		# Kept below 1.0 so the glow pass does not bloom them into blobs.
		mm.set_instance_color(k, color.lightened(0.35) if capital else color.darkened(0.1))
	var hm := hero_marks.multimesh
	hm.instance_count = heroes.size()
	for k in heroes.size():
		var x := int(heroes[k]["x"])
		var y := int(heroes[k]["y"])
		var up := region_to_point(x, y)
		var glint := 0.012 + 0.002 * minf(float(heroes[k]["size"]), 5.0)
		hm.set_instance_transform(k, Transform3D(Basis.IDENTITY.scaled(Vector3.ONE * glint), up * (surface_radius(x, y) + 0.03)))
		hm.set_instance_color(k, Color(0.98, 0.85, 0.35))

	# Labels for the capitals of the largest peoples.
	capitals.sort_custom(func(a, b): return float(a["size"]) > float(b["size"]))
	# Skip a capital too close to a bigger one already labelled, so labels
	# never pile on top of each other.
	var shown: Array = []
	for m in capitals:
		if shown.size() >= MAX_LABELS:
			break
		var dir := region_to_point(int(m["x"]), int(m["y"]))
		if shown.all(func(o): return dir.dot(region_to_point(int(o["x"]), int(o["y"]))) < 0.985):
			shown.append(m)
	capitals = shown
	label_dirs.resize(mini(capitals.size(), MAX_LABELS))
	for k in MAX_LABELS:
		var label := capital_labels[k]
		if k >= label_dirs.size():
			label.visible = false
			continue
		var m: Dictionary = capitals[k]
		var up := region_to_point(int(m["x"]), int(m["y"]))
		label_dirs[k] = up
		label.position = up * (surface_radius(int(m["x"]), int(m["y"])) + 0.02)
		label.text = String(m["name"]).replace(" (", "\n(")
		label.modulate = Color.html(m["color"]).lightened(0.3)

	# War arcs between the two capitals, lifted above the surface.
	var arcs := war_arcs.mesh as ImmediateMesh
	arcs.clear_surfaces()
	for w in parsed["wars"]:
		var a := region_to_point(int(w["x1"]), int(w["y1"]))
		var b := region_to_point(int(w["x2"]), int(w["y2"]))
		var ca := Color.html(w["color_a"]).lerp(Color(1.0, 0.25, 0.15), 0.4)
		var cb := Color.html(w["color_b"]).lerp(Color(1.0, 0.25, 0.15), 0.4)
		# A thin four-sided tube along the great circle, bulging outwards.
		var points: Array[Vector3] = []
		for k in WAR_SEGMENTS + 1:
			var t := float(k) / WAR_SEGMENTS
			points.append(a.slerp(b, t) * (1.03 + 0.12 * sin(t * PI)))
		arcs.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
		var prev: Array[Vector3] = []
		var prev_color := ca
		for k in points.size():
			var t := float(k) / WAR_SEGMENTS
			var tangent := (points[mini(k + 1, points.size() - 1)] - points[maxi(k - 1, 0)]).normalized()
			var out := points[k].normalized()
			var side := tangent.cross(out) * 0.006
			var lift := out * 0.006
			var ring: Array[Vector3] = [points[k] + lift, points[k] + side, points[k] - lift, points[k] - side]
			var color := ca.lerp(cb, t)
			if k > 0:
				for j in 4:
					var j2 := (j + 1) % 4
					for v in [[prev[j], prev_color], [prev[j2], prev_color], [ring[j], color], [prev[j2], prev_color], [ring[j2], color], [ring[j], color]]:
						arcs.surface_set_color(v[1])
						arcs.surface_add_vertex(v[0])
			prev = ring
			prev_color = color
		arcs.surface_end()
	_update_legend()


## Rings the selected region.
func set_selected(cell: Vector2i) -> void:
	selected = cell
	_update_selection()


func _update_selection() -> void:
	select_ring.visible = selected.x >= 0
	if selected.x < 0:
		return
	var up := region_to_point(selected.x, selected.y)
	select_ring.transform = Transform3D(_upright(up), up * (surface_radius(selected.x, selected.y) + 0.006))


func set_show_heroes(on: bool) -> void:
	show_heroes = on
	if sim != null and albedo_image != null:
		_rebuild_markers()


## Blends a map view (64x32 RGBA8, as the 2D map shows it) over the surface.
func set_overlay(img: Image, mode: int, mode_name: String) -> void:
	overlay_mode = mode
	overlay_name = mode_name
	if overlay_texture == null or overlay_texture.get_size() != Vector2(img.get_size()):
		overlay_texture = ImageTexture.create_from_image(img)
		planet_material.set_shader_parameter("overlay_map", overlay_texture)
	else:
		overlay_texture.update(img)
	planet_material.set_shader_parameter("overlay_mix", 0.0 if mode == 0 else 0.75)
	_update_legend()


func _update_legend() -> void:
	if legend == null or status.is_empty():
		return
	legend.text = "Seed %d  ·  year %d\n%d peoples  ·  %d settlements  ·  %d at war\nView: %s" % [
		status["seed"], status["year"], status.get("civilizations", 0), settlement_count,
		status.get("wars", 0), overlay_name]


## Gives the moons and the host planet the maps of their own worlds. Slow to
## change, so only every few seconds (or when the bodies change).
func _update_bodies() -> void:
	if sim == null or not is_visible_in_tree():
		return
	var now := Time.get_ticks_msec()
	if not bodies_dirty and now - bodies_stamp < BODY_REFRESH_MS:
		return
	bodies_dirty = false
	bodies_stamp = now
	if host_active:
		if _body_textures(-1, 512, 256, host_textures):
			host_material.set_shader_parameter("albedo_map", host_textures[0])
			host_material.set_shader_parameter("data_map", host_textures[1])
			host_material.set_shader_parameter("info_map", host_textures[2])
		return
	for k in moon_nodes.size():
		if _body_textures(k, 256, 128, moon_textures[k]):
			moon_materials[k].set_shader_parameter("albedo_map", moon_textures[k][0])
			moon_materials[k].set_shader_parameter("data_map", moon_textures[k][1])
			moon_materials[k].set_shader_parameter("info_map", moon_textures[k][2])


## Builds the maps of body `index` (-1: the planet) into `store`, creating
## the textures the first time and updating them afterwards.
func _body_textures(index: int, w: int, h: int, store: Array) -> bool:
	if not sim.build_body_globe(index, w, h):
		return false
	var maps: Array[PackedByteArray] = [sim.aux_albedo(), sim.aux_data(), sim.aux_info()]
	for k in 3:
		var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, maps[k])
		img.generate_mipmaps()
		if store.size() < 3:
			store.append(ImageTexture.create_from_image(img))
		else:
			store[k].update(img)
	return true
