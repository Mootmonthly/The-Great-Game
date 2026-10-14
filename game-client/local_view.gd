extends Control
## Visit a region at ground level and possess one of its creatures in first
## person (roadmap Phase 2, design pillar 2).
##
## The scene is generated from the region's simulated state: terrain and
## seas from its liquids and ice, sky tint from the atmosphere, and wandering
## creatures from its populations (more biomass, more creatures), with its
## named individuals labelled. Per the camera rule (docs/GAME_DESIGN.md
## §4.8) this view is display only: nothing here changes the world.
##
## Click a creature to possess it: WASD to move, drag the mouse to look,
## Esc to release.

signal closed

const CreatureBuilder := preload("res://creature_builder.gd")
const SIZE := 60.0
const GRID := 48
const SIZE_SCALE := {"Tiny": 0.6, "Small": 0.9, "Medium": 1.3, "Large": 2.0, "Huge": 3.0, "Gargantuan": 4.2}


class Wanderer:
	extends RefCounted
	var node: Node3D
	var name := ""
	var detail: Dictionary
	var sheet: Dictionary
	var aquatic := false
	var plant := false
	var target := Vector3.ZERO
	var speed := 1.5
	var height := 1.0


var sim: RefCounted
var region := Vector2i.ZERO
var info: Dictionary
var sea_level := 0.0
var heights := PackedFloat32Array()
var wanderers: Array = []
var possessed: Wanderer
var rng := RandomNumberGenerator.new()

var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var hud: Label
var orbit_yaw := 0.4
var look_yaw := 0.0
var look_pitch := 0.0
var dragging := false


func open(world_sim: RefCounted, cell: Vector2i) -> void:
	sim = world_sim
	region = cell
	info = JSON.parse_string(sim.region_json(cell.x, cell.y))
	rng.seed = cell.x * 1000 + cell.y
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()


func close() -> void:
	closed.emit()
	queue_free()


func _build() -> void:
	var box := SubViewportContainer.new()
	box.stretch = true
	box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	box.gui_input.connect(_on_input)
	add_child(box)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	box.add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)

	var sky_tint := Color(info["sky_color"][0], info["sky_color"][1], info["sky_color"][2])
	var thickness: float = info["atmosphere"]
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.02, 0.02, 0.05).lerp(sky_tint.lightened(0.2), clampf(thickness * 1.5, 0.0, 0.9))
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.35, 0.4).lerp(sky_tint, 0.3)
	env.fog_enabled = thickness > 0.2
	env.fog_light_color = env.background_color
	env.fog_density = 0.01 * thickness
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-40, 25, 0)
	sun.light_energy = clampf(0.5 + 0.6 * sqrt(float(info["sunlight"])), 0.3, 1.6)
	world.add_child(sun)

	_build_terrain()
	_spawn_life()

	camera = Camera3D.new()
	camera.fov = 60.0
	camera.far = 400.0
	world.add_child(camera)

	var bar := VBoxContainer.new()
	bar.position = Vector2(12, 12)
	add_child(bar)
	var title := Label.new()
	title.text = "Region (%d, %d) · %.0f K · %d species here" % [region.x, region.y, info["temperature"], info["populations"].size()]
	title.add_theme_font_size_override("font_size", 20)
	bar.add_child(title)
	hud = Label.new()
	bar.add_child(hud)
	var back := Button.new()
	back.text = "Back to world"
	back.pressed.connect(close)
	bar.add_child(back)
	_update_hud()


func _material(color: Color, glow := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/creature.gdshader")
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("glow_color", color)
	m.set_shader_parameter("glow", glow)
	return m


func _height_at(x: float, z: float) -> float:
	var gx := clampi(int((x / SIZE + 0.5) * GRID), 0, GRID)
	var gz := clampi(int((z / SIZE + 0.5) * GRID), 0, GRID)
	return heights[gz * (GRID + 1) + gx]


func _build_terrain() -> void:
	var noise := FastNoiseLite.new()
	noise.seed = rng.seed
	noise.frequency = 0.035
	noise.fractal_octaves = 4
	heights.resize((GRID + 1) * (GRID + 1))
	var values: Array[float] = []
	for z in GRID + 1:
		for x in GRID + 1:
			var h := noise.get_noise_2d(x * 2.0, z * 2.0) * 6.0
			heights[z * (GRID + 1) + x] = h
			values.append(h)
	# Choose the sea level so the flooded share matches the region's liquid.
	var liquid: float = info["liquid_amount"]
	var wet_share := clampf(liquid / (liquid + 1.0), 0.0, 0.95)
	values.sort()
	sea_level = values[int(wet_share * (values.size() - 1))] if wet_share > 0.02 else -100.0

	var temp: float = info["temperature"]
	var icy: bool = float(info["ice_amount"]) > 0.3
	var ground := Color(0.55, 0.47, 0.33)
	if temp > 700.0:
		ground = Color(0.2, 0.12, 0.1)
	elif icy:
		ground = Color(0.88, 0.92, 0.98)
	elif info["populations"].size() > 0:
		ground = ground.lerp(Color(0.32, 0.55, 0.28), 0.5)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var step := SIZE / GRID
	for z in GRID:
		for x in GRID:
			var corners := [Vector2i(x, z), Vector2i(x + 1, z), Vector2i(x + 1, z + 1), Vector2i(x, z), Vector2i(x + 1, z + 1), Vector2i(x, z + 1)]
			for c in corners:
				var h := heights[c.y * (GRID + 1) + c.x]
				st.set_color(ground.darkened(clampf(-h * 0.04, 0.0, 0.3)).lightened(clampf(h * 0.03, 0.0, 0.3)))
				st.add_vertex(Vector3(c.x * step - SIZE / 2.0, h, c.y * step - SIZE / 2.0))
	st.generate_normals()
	var terrain := MeshInstance3D.new()
	terrain.mesh = st.commit()
	var tm := StandardMaterial3D.new()
	tm.vertex_color_use_as_albedo = true
	tm.roughness = 1.0
	terrain.material_override = tm
	world.add_child(terrain)

	if sea_level > -50.0:
		var water := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(SIZE, SIZE)
		water.mesh = plane
		var wc := Color("#" + str(info["liquid_color"])) if info["liquid_color"] != null else Color(0.2, 0.4, 0.8)
		var glow := 1.2 if temp > 700.0 else 0.0
		var wm := _material(wc.lerp(Color(0.1, 0.2, 0.4), 0.2) if glow == 0.0 else Color(1.0, 0.45, 0.1), glow)
		water.material_override = wm
		water.position.y = sea_level
		world.add_child(water)


func _spawn_life() -> void:
	var pops: Array = info["populations"]
	for p in pops.slice(0, 8):
		var detail = JSON.parse_string(sim.species_detail_json(int(p["id"])))
		var sheet = JSON.parse_string(sim.sheet_json("species", int(p["id"])))
		if detail == null or sheet == null:
			continue
		var n := clampi(int(float(p["biomass"]) / 6.0), 1, 6)
		if CreatureBuilder.is_plant(detail):
			n = clampi(int(float(p["biomass"]) / 3.0), 2, 14)  # Plants grow in stands.
		for k in n:
			_add_wanderer(detail, sheet, p["name"], Color.WHITE, false)
	for x in info["individuals_here"]:
		var detail = JSON.parse_string(sim.species_detail_json(int(x["species_id"])))
		var sheet = JSON.parse_string(sim.sheet_json("individual", int(x["id"])))
		if detail != null and sheet != null:
			_add_wanderer(detail, sheet, x["title"], Color(1.0, 0.85, 0.35), true)


func _add_wanderer(detail: Dictionary, sheet: Dictionary, name: String, label_color: Color, named: bool) -> void:
	var w := Wanderer.new()
	w.detail = detail
	w.sheet = sheet
	w.name = name
	var limbs := false
	var fins := false
	for p in detail["parts"]:
		limbs = limbs or p["part"] == "limb"
		fins = fins or p["part"] == "fin"
	w.plant = CreatureBuilder.is_plant(detail)
	# Plants with fins are kelp and grow on the seabed; the rest on land.
	w.aquatic = (fins or (detail["parts"].is_empty() and not w.plant)) and not limbs and sea_level > -50.0
	var model := CreatureBuilder.build(detail)
	var box := CreatureBuilder.bounds(model)
	var extent: float = max(box.size.x, max(box.size.y, box.size.z))
	var s: float = SIZE_SCALE.get(sheet["size"], 1.0) / max(extent, 0.01)
	model.scale = Vector3.ONE * s
	model.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)
	w.height = box.size.y * s
	var holder := Node3D.new()
	holder.add_child(model)
	world.add_child(holder)
	w.node = holder
	w.speed = 0.8 + float(max(int(sheet["speed"]["walk"]), int(sheet["speed"]["swim"]))) / 20.0
	holder.position = _random_spot(w.aquatic)
	w.target = _random_spot(w.aquatic)
	if w.plant:
		w.speed = 0.0
		holder.position.y = _height_at(holder.position.x, holder.position.z)  # Rooted in the ground or seabed.
		holder.rotation.y = rng.randf() * TAU
	if named:
		var l := Label3D.new()
		l.text = name
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.modulate = label_color
		l.outline_size = 6
		l.font_size = 32
		l.pixel_size = 0.015
		l.position.y = w.height + 0.5
		holder.add_child(l)
	wanderers.append(w)


func _random_spot(aquatic: bool) -> Vector3:
	for attempt in 30:
		var x := rng.randf_range(-SIZE * 0.42, SIZE * 0.42)
		var z := rng.randf_range(-SIZE * 0.42, SIZE * 0.42)
		var h := _height_at(x, z)
		var wet := h < sea_level
		if wet == aquatic or sea_level < -50.0:
			return Vector3(x, (sea_level - 0.4 if aquatic else h), z)
	return Vector3(0, maxf(_height_at(0, 0), sea_level), 0)


func _process(delta: float) -> void:
	for w: Wanderer in wanderers:
		if w == possessed or w.plant:
			continue
		var to := w.target - w.node.position
		to.y = 0.0
		if to.length() < 0.5:
			w.target = _random_spot(w.aquatic)
			continue
		var dir := to.normalized()
		w.node.position += dir * w.speed * delta
		var ground := _height_at(w.node.position.x, w.node.position.z)
		w.node.position.y = sea_level - 0.4 if w.aquatic else maxf(ground, sea_level - 0.3)
		w.node.look_at(w.node.position + dir, Vector3.UP, true)
	if possessed:
		_drive(delta)
	else:
		orbit_yaw += delta * 0.05
		camera.position = Vector3(sin(orbit_yaw) * 38.0, 22.0, cos(orbit_yaw) * 38.0)
		camera.look_at(Vector3.ZERO, Vector3.UP)


func _drive(delta: float) -> void:
	var w := possessed
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input.z += 1.0
	if Input.is_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input.x += 1.0
	var facing := Basis(Vector3.UP, look_yaw)
	if input != Vector3.ZERO:
		var move := (facing * input).normalized() * w.speed * 1.6 * delta
		var next := w.node.position + move
		next.x = clampf(next.x, -SIZE * 0.48, SIZE * 0.48)
		next.z = clampf(next.z, -SIZE * 0.48, SIZE * 0.48)
		var ground := _height_at(next.x, next.z)
		if w.aquatic and ground > sea_level:
			next = w.node.position
		next.y = sea_level - 0.4 if w.aquatic else maxf(ground, sea_level - 0.3)
		w.node.position = next
	w.node.rotation = Vector3(0, look_yaw + PI, 0)
	# First person: eyes at the front top of the body.
	var eye := w.node.position + Vector3(0, w.height * 0.85 + 0.2, 0) + facing * Vector3(0, 0, -0.4)
	camera.position = eye
	camera.rotation = Vector3(look_pitch, look_yaw, 0)


func _update_hud() -> void:
	if possessed:
		var sh := possessed.sheet
		hud.text = "Possessing %s — %s %s · HP %d · AC %d · cost %d\nWASD move · drag to look · Esc to release. Possession is display only: it does not change the world." % [
			possessed.name, sh["size"], sh["type"].to_lower(), sh["hit_points"], sh["armor_class"], sh["cost"]]
	else:
		hud.text = "Click a creature to possess it and see the world through its eyes."


func possess(w: Wanderer) -> void:
	if possessed:
		possessed.node.visible = true
	possessed = w
	if w:
		w.node.visible = false
		look_yaw = w.node.rotation.y - PI
		look_pitch = 0.0
	_update_hud()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		possess(null)


func _on_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
		if event.pressed and possessed == null:
			_pick(event.position)
	elif event is InputEventMouseMotion and dragging and possessed:
		look_yaw -= event.relative.x * 0.005
		look_pitch = clampf(look_pitch - event.relative.y * 0.005, -1.2, 1.2)


func _pick(pos: Vector2) -> void:
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var best: Wanderer = null
	var best_d := 3.0
	for w: Wanderer in wanderers:
		if w.plant:
			continue  # Plants cannot be possessed.
		var c := w.node.position + Vector3(0, w.height * 0.5, 0)
		var t := (c - from).dot(dir)
		var d := (from + dir * t).distance_to(c)
		if d < best_d:
			best_d = d
			best = w
	if best:
		possess(best)
