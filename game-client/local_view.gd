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
## Settlement scenery (docs/GAME_DESIGN.md §4.5): where the town stands, how
## far it reaches, and how many building pieces were placed.
var town_centre := Vector3.ZERO
var town_radius := 0.0
var building_count := 0
var town: Node3D
var _meshes := {}
var _mats := {}
const TIER_RADIUS := {"Camp": 5.0, "Village": 7.0, "Town": 9.0, "City": 12.0, "Metropolis": 15.0}
const TIER_HUTS := {"Camp": 3, "Village": 6, "Town": 10, "City": 16, "Metropolis": 24}
## Rough footprint radius of each building, for keeping them apart.
const FOOTPRINT := {"Longhouse": 3.0, "Workshop": 2.1, "Granary": 1.6, "Forge": 2.1, "Mine": 2.4, "Market": 3.0, "Library": 2.4,
	"Barracks": 3.0, "Shrine": 1.0, "Temple": 3.2, "Wizard's tower": 1.3, "Aqueduct": 5.0, "Factory": 3.0}


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
	_build_settlement()
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

	_level_town_site()

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


# --- Settlement scenery --------------------------------------------------------

func _has_town() -> bool:
	return info.get("settlement") != null and not (info["settlement"].get("buildings", []) as Array).is_empty()


func _tier_name() -> String:
	return str(info["settlement"].get("tier", "Village"))


## Picks the driest, most central ground for the settlement and levels it into
## a plateau, so every building stands flat on the ground, never in water.
func _level_town_site() -> void:
	if not _has_town():
		return
	town_radius = TIER_RADIUS.get(_tier_name(), 7.0)
	var land := sea_level + 0.3
	var best := Vector2.ZERO
	var best_score := -1.0
	for cz in range(-12, 13, 4):
		for cx in range(-12, 13, 4):
			var score := 0.0
			for k in 12:
				var a := TAU * k / 12.0
				var h := _height_at(cx + cos(a) * town_radius * 0.8, cz + sin(a) * town_radius * 0.8)
				score += 1.0 if h >= land else 0.0
			if _height_at(cx, cz) >= land:
				score += 3.0
			score -= Vector2(cx, cz).length() * 0.03
			if score > best_score:
				best_score = score
				best = Vector2(cx, cz)
	var plateau := _height_at(best.x, best.y)
	if sea_level > -50.0:
		plateau = maxf(plateau, sea_level + 0.5)
	var step := SIZE / GRID
	var flat := town_radius + 6.0
	var blend := town_radius + 11.0
	for z in GRID + 1:
		for x in GRID + 1:
			var d := Vector2(x * step - SIZE / 2.0 - best.x, z * step - SIZE / 2.0 - best.y).length()
			if d >= blend:
				continue
			var t := 1.0 - smoothstep(flat, blend, d)
			var i := z * (GRID + 1) + x
			heights[i] = lerpf(heights[i], plateau, t)
	town_centre = Vector3(best.x, plateau, best.y)


func _mesh(kind: String) -> Mesh:
	if _meshes.has(kind):
		return _meshes[kind]
	var m: Mesh
	match kind:
		"box":
			m = BoxMesh.new()
		"cyl":
			var c := CylinderMesh.new()
			c.top_radius = 0.5
			c.bottom_radius = 0.5
			c.height = 1.0
			c.radial_segments = 10
			c.rings = 1
			m = c
		"cone":
			var c := CylinderMesh.new()
			c.top_radius = 0.0
			c.bottom_radius = 0.5
			c.height = 1.0
			c.radial_segments = 10
			c.rings = 1
			m = c
		"dome":
			var sph := SphereMesh.new()
			sph.radius = 0.5
			sph.height = 1.0
			sph.radial_segments = 12
			sph.rings = 6
			m = sph
		"prism":
			m = PrismMesh.new()
	_meshes[kind] = m
	return m


func _mat(color: Color, glow := 0.0) -> StandardMaterial3D:
	var key := "%s/%s" % [color.to_html(), glow]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = glow
	_mats[key] = m
	return m


## One primitive of a building: `base` is the centre of its underside in the
## building's own space, `size` its extent; shared meshes are scaled to fit.
func _part(parent: Node3D, kind: String, mat: Material, base: Vector3, size: Vector3, rot := Vector3.ZERO) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh(kind)
	mi.material_override = mat
	mi.scale = size
	mi.position = base + Vector3(0, size.y * 0.5, 0)
	mi.rotation = rot
	parent.add_child(mi)
	building_count += 1


## Many copies of one primitive in a single MultiMesh (huts, posts, wall
## blocks): `xf` holds one Transform3D per copy.
func _scatter(kind: String, mat: Material, xf: Array) -> void:
	if xf.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _mesh(kind)
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.material_override = mat
	town.add_child(inst)
	building_count += xf.size()


func _ground(x: float, z: float) -> float:
	return _height_at(x, z)


func _dry(x: float, z: float, margin := 0.15) -> bool:
	return sea_level < -50.0 or _height_at(x, z) > sea_level + margin


func _build_settlement() -> void:
	if not _has_town():
		return
	var st: Dictionary = info["settlement"]
	var names: Array = st["buildings"]
	var civ_col := Color.html(str(st.get("color", "c8a050")))
	town = Node3D.new()
	town.name = "Town"
	world.add_child(town)
	var brng := RandomNumberGenerator.new()
	brng.seed = region.x * 7919 + region.y * 104729 + 17
	var tier := _tier_name()
	var wood := _mat(Color(0.45, 0.32, 0.2))
	var stone := _mat(Color(0.58, 0.58, 0.6))
	var dark := _mat(Color(0.3, 0.3, 0.33))
	var roof := _mat(civ_col.darkened(0.15))
	var placed: Array = []  # [Vector2 position, footprint radius]

	# Larger buildings first, so the small ones fill the gaps.
	var core: Array = []
	for n in names:
		if FOOTPRINT.has(n):
			core.append(n)
	core.sort_custom(func(a, b): return FOOTPRINT[a] > FOOTPRINT[b])
	for n in core:
		var spot = _find_spot(brng, placed, float(FOOTPRINT[n]), 1.0 if n in ["Temple", "Library", "Market"] else 0.0)
		if spot == null:
			continue
		var root := Node3D.new()
		var local: Vector2 = spot
		root.position = Vector3(town_centre.x + local.x, 0, town_centre.z + local.y)
		root.position.y = _ground(root.position.x, root.position.z) - 0.05
		root.rotation.y = atan2(-local.x, -local.y) + (brng.randf() - 0.5) * 0.3
		town.add_child(root)
		_make_building(n, root, civ_col, wood, stone, dark, roof)
		placed.append([local, float(FOOTPRINT[n])])

	# Huts, scattered over what is left.
	var huts: Array = []
	var tops: Array = []
	if "Huts" in names or tier == "Camp":
		for k in int(TIER_HUTS.get(tier, 6)):
			var spot = _find_spot(brng, placed, 1.3, 0.0)
			if spot == null:
				break
			var local: Vector2 = spot
			placed.append([local, 1.3])
			var gx := town_centre.x + local.x
			var gz := town_centre.z + local.y
			var gy := _ground(gx, gz) - 0.05
			var yaw := brng.randf() * TAU
			var sc := 0.9 + brng.randf() * 0.3
			var b := Basis(Vector3.UP, yaw)
			huts.append(Transform3D(b.scaled_local(Vector3(1.6, 1.0, 1.6) * sc), Vector3(gx, gy + 0.5 * sc, gz)))
			tops.append(Transform3D(b.scaled_local(Vector3(2.1, 0.9, 2.1) * sc), Vector3(gx, gy + 1.0 * sc + 0.45 * sc, gz)))
	_scatter("cyl", wood, huts)
	_scatter("cone", _mat(Color(0.72, 0.6, 0.3).lerp(civ_col, 0.35)), tops)

	if "Palisade" in names:
		_ring(town_radius + 3.0, 1.9, "cyl", _mat(Color(0.5, 0.36, 0.22)), Vector3(0.28, 1.8, 0.28), 0.0, 0.0)
	if "Walls" in names:
		_ring(town_radius + 5.0, 3.2, "box", stone, Vector3(0.7, 1.8, 2.4), 0.8, 0.25)
	if "Harbour" in names:
		_build_harbour(wood)


## A free spot within the town's reach, as an offset from its centre.
func _find_spot(brng: RandomNumberGenerator, placed: Array, foot: float, inner_bias: float) -> Variant:
	for attempt in 80:
		var reach := town_radius * (0.55 + 0.45 * minf(1.0, attempt / 40.0)) + attempt * 0.06
		var r := reach * sqrt(brng.randf())
		if inner_bias > 0.0:
			r *= 0.7
		r = maxf(r, 0.0)
		var a := brng.randf() * TAU
		var p := Vector2(cos(a), sin(a)) * r
		if not _dry(town_centre.x + p.x, town_centre.z + p.y, 0.3):
			continue
		var ok := true
		for o in placed:
			if p.distance_to(o[0]) < foot + float(o[1]) + 0.4:
				ok = false
				break
		if ok:
			return p
	return null


## A ring of posts or blocks around the town; pieces over water are skipped.
## `chunk` is the arc length of each piece, `gap` the share left open.
func _ring(radius: float, chunk: float, kind: String, mat: Material, size: Vector3, gates: float, towers_on: float) -> void:
	var circ := TAU * radius
	var n := clampi(int(circ / chunk), 12, 56)
	var xf: Array = []
	var towers: Array = []
	for i in n:
		var a := TAU * i / n
		var x := town_centre.x + cos(a) * radius
		var z := town_centre.z + sin(a) * radius
		if not _dry(x, z):
			continue
		if gates > 0.0 and i % 7 == 6:
			continue  # A gap in the wall, a gate.
		var y := _ground(x, z) - 0.1
		var b := Basis(Vector3.UP, -a)
		var sz := size
		if kind == "box":
			sz.z = circ / n * (1.0 - gates * 0.3)
		if towers_on > 0.0 and i % 4 == 0:
			towers.append(Transform3D(Basis(Vector3.UP, -a).scaled_local(Vector3(1.3, 2.8, 1.3)), Vector3(x, y + 1.4, z)))
		xf.append(Transform3D(b.scaled_local(sz), Vector3(x, y + sz.y * 0.5, z)))
	_scatter(kind, mat, xf)
	if towers.size() > 0:
		_scatter("box", _mat(Color(0.5, 0.5, 0.53)), towers)


## A short pier from the nearest shore into the water, if there is any water
## within reach of the town.
func _build_harbour(wood: Material) -> void:
	if sea_level < -50.0:
		return
	var best_a := -1.0
	var best_d := 1e9
	for k in 24:
		var a := TAU * k / 24.0
		for d in range(int(town_radius), 30):
			var x := town_centre.x + cos(a) * d
			var z := town_centre.z + sin(a) * d
			if absf(x) > SIZE * 0.47 or absf(z) > SIZE * 0.47:
				break
			if _height_at(x, z) < sea_level - 0.2:
				if d < best_d:
					best_d = d
					best_a = a
				break
	if best_a < 0.0:
		return
	var dir := Vector3(cos(best_a), 0, sin(best_a))
	var shore := town_centre + dir * (best_d - 1.0)
	var root := Node3D.new()
	root.position = Vector3(shore.x, sea_level + 0.25, shore.z)
	root.rotation.y = atan2(dir.x, dir.z)
	town.add_child(root)
	_part(root, "box", wood, Vector3(0, -0.1, 3.0), Vector3(1.6, 0.15, 6.5))
	for k in 4:
		for sx in [-0.7, 0.7]:
			_part(root, "cyl", wood, Vector3(sx, -1.2, 0.6 + k * 1.7), Vector3(0.18, 1.5, 0.18))
	_part(root, "box", _mat(Color(0.6, 0.42, 0.25)), Vector3(0, 0.05, 6.4), Vector3(1.2, 0.5, 1.0))


func _make_building(n: String, root: Node3D, civ: Color, wood: Material, stone: Material, dark: Material, roof: Material) -> void:
	var pale := _mat(Color(0.82, 0.8, 0.72))
	match n:
		"Longhouse":
			_part(root, "box", wood, Vector3.ZERO, Vector3(1.9, 1.3, 5.0))
			_part(root, "prism", roof, Vector3(0, 1.3, 0), Vector3(2.4, 1.0, 5.3))
		"Workshop", "Forge":
			var forge := n == "Forge"
			_part(root, "box", dark if forge else wood, Vector3.ZERO, Vector3(2.6, 1.6, 2.6))
			_part(root, "box", roof, Vector3(0, 1.6, 0), Vector3(2.9, 0.25, 2.9))
			_part(root, "cyl", stone, Vector3(0.8, 1.85, 0.8), Vector3(0.55, 1.5, 0.55))
			if forge:
				_part(root, "cyl", _mat(Color(1.0, 0.45, 0.1), 2.5), Vector3(0.8, 3.3, 0.8), Vector3(0.4, 0.15, 0.4))
				_part(root, "box", _mat(Color(1.0, 0.4, 0.1), 2.0), Vector3(0, 0.2, 1.31), Vector3(1.0, 0.7, 0.05))
		"Granary":
			_part(root, "cyl", wood, Vector3.ZERO, Vector3(2.2, 1.6, 2.2))
			_part(root, "dome", _mat(Color(0.75, 0.62, 0.3)), Vector3(0, 1.4, 0), Vector3(2.4, 1.3, 2.4))
		"Mine":
			_part(root, "dome", _mat(Color(0.36, 0.28, 0.2)), Vector3(0, -2.0, 0), Vector3(4.2, 4.0, 4.2))
			_part(root, "box", _mat(Color(0.05, 0.04, 0.04)), Vector3(0, 0, 1.55), Vector3(1.2, 1.0, 0.5))
			_part(root, "cyl", _mat(Color(0.05, 0.04, 0.04)), Vector3(0, 1.0, 1.55), Vector3(1.2, 0.5, 1.2), Vector3(PI / 2.0, 0, 0))
			_part(root, "box", wood, Vector3(-0.7, 0, 1.75), Vector3(0.18, 1.5, 0.18))
			_part(root, "box", wood, Vector3(0.7, 0, 1.75), Vector3(0.18, 1.5, 0.18))
		"Market":
			var awnings := [Color(0.85, 0.25, 0.2), Color(0.25, 0.5, 0.85), Color(0.9, 0.75, 0.2), Color(0.3, 0.7, 0.35)]
			for k in 4:
				var o := Vector3(-1.1 if k % 2 == 0 else 1.1, 0, -1.1 if k < 2 else 1.1)
				_part(root, "box", wood, o, Vector3(1.4, 0.7, 0.9))
				for sx in [-0.65, 0.65]:
					_part(root, "cyl", wood, o + Vector3(sx, 0, 0.4), Vector3(0.1, 1.7, 0.1))
				_part(root, "box", _mat(awnings[k]), o + Vector3(0, 1.7, 0.1), Vector3(1.7, 0.1, 1.5), Vector3(0.15, 0, 0))
		"Library":
			_part(root, "box", pale, Vector3.ZERO, Vector3(3.0, 0.3, 2.8))
			_part(root, "box", pale, Vector3(0, 0.3, -0.2), Vector3(2.6, 2.0, 2.0))
			for k in 4:
				_part(root, "cyl", pale, Vector3(-1.1 + k * 0.73, 0.3, 1.0), Vector3(0.28, 2.0, 0.28))
			_part(root, "prism", roof, Vector3(0, 2.3, 0), Vector3(3.2, 0.9, 2.8))
		"Barracks":
			_part(root, "box", _mat(Color(0.5, 0.42, 0.35)), Vector3.ZERO, Vector3(1.8, 1.0, 5.0))
			_part(root, "box", dark, Vector3(0, 1.0, 0), Vector3(2.0, 0.15, 5.2))
			_part(root, "cyl", wood, Vector3(0.9, 0, 2.4), Vector3(0.1, 3.2, 0.1))
			_part(root, "box", _mat(civ), Vector3(1.25, 2.5, 2.4), Vector3(0.8, 0.55, 0.05))
		"Shrine":
			_part(root, "box", stone, Vector3.ZERO, Vector3(1.1, 0.7, 1.1))
			_part(root, "box", stone, Vector3(0, 0.7, 0), Vector3(0.75, 0.2, 0.75))
			_part(root, "dome", _mat(Color(0.7, 0.85, 1.0), 1.2), Vector3(0, 0.9, 0), Vector3(0.35, 0.35, 0.35))
		"Temple":
			_part(root, "box", pale, Vector3.ZERO, Vector3(5.4, 0.4, 5.4))
			_part(root, "box", pale, Vector3(0, 0.4, 0), Vector3(4.4, 0.4, 4.4))
			_part(root, "box", pale, Vector3(0, 0.8, 0), Vector3(3.2, 1.9, 3.2))
			_part(root, "cone", roof, Vector3(0, 2.7, 0), Vector3(1.8, 2.8, 1.8))
		"Wizard's tower":
			_part(root, "cyl", _mat(Color(0.5, 0.5, 0.62)), Vector3.ZERO, Vector3(1.3, 6.5, 1.3))
			_part(root, "cone", _mat(Color(0.3, 0.2, 0.5)), Vector3(0, 6.5, 0), Vector3(1.9, 1.6, 1.9))
			_part(root, "dome", _mat(Color(0.7, 0.4, 1.0), 2.5), Vector3(0, 8.1, 0), Vector3(0.5, 0.5, 0.5))
		"Aqueduct":
			for k in 5:
				_part(root, "box", stone, Vector3(-3.6 + k * 1.8, 0, 0), Vector3(0.7, 3.0, 0.9))
			for k in 4:
				_part(root, "cyl", _mat(Color(0.5, 0.5, 0.52)), Vector3(-2.7 + k * 1.8, 2.0, 0), Vector3(1.1, 0.9, 0.9), Vector3(PI / 2.0, 0, 0))
			_part(root, "box", stone, Vector3(0, 3.0, 0), Vector3(8.0, 0.6, 1.1))
			_part(root, "box", _mat(Color(0.3, 0.55, 0.85)), Vector3(0, 3.5, 0), Vector3(7.8, 0.1, 0.7))
		"Factory":
			_part(root, "box", _mat(Color(0.4, 0.38, 0.38)), Vector3.ZERO, Vector3(4.5, 2.5, 3.5))
			_part(root, "box", dark, Vector3(0, 2.5, 0), Vector3(4.7, 0.2, 3.7))
			for k in 2:
				_part(root, "cyl", _mat(Color(0.5, 0.28, 0.22)), Vector3(-1.3 + k * 2.0, 2.7, -0.9), Vector3(0.8, 4.5, 0.8))
				_part(root, "cyl", dark, Vector3(-1.3 + k * 2.0, 7.0, -0.9), Vector3(0.95, 0.3, 0.95))
