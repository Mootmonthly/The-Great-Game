extends Control
## Visit a region at ground level and possess one of its creatures in first
## person (roadmap Phase 2, design pillar 2).
##
## The scene is generated from the region's simulated state: terrain, seas
## and climate from its liquids, ice and temperature, sky from its
## atmosphere, plants and creatures from its populations, and its settlement
## from its tier and buildings. Everything is in metres: a medium creature
## stands about 1.7 m tall and a settlement is built to the size of the
## people who built it (docs/GAME_DESIGN.md §4.7).
##
## Life goes on while you watch: townsfolk keep a daily round (work at the
## forge or in the fields, meet in the square, go home at night), grazers
## herd and flee, hunters stalk them. Per the camera rule (§4.8) all of this
## is display only: nothing here changes the world.
##
## Drag to orbit, scroll to zoom, hover a creature to see what it is doing,
## click one to possess it: WASD to move, drag to look, Esc to release.

signal closed

const CreatureBuilder := preload("res://creature_builder.gd")
## Width of the walkable area, in metres.
const SIZE := 1400.0
## Terrain reaches this far beyond the walkable area, fading into the haze.
const MARGIN := 300.0
const EXT := SIZE / 2.0 + MARGIN
const GRID := 512
const STEP := 2.0 * EXT / GRID
## Terrain is drawn in square chunks of this many grid cells, so only what
## the camera sees (and what is near enough to cast shadows) is drawn.
const CHUNK := 32
## Grass grows in square cells around the camera, out to GRASS_RADIUS.
const GRASS_CELL := 32.0
const GRASS_RADIUS := 120.0
## Forests are drawn in tiles: full plants up close, simple shapes far off.
const FOREST_TILE := 200.0
const FOREST_NEAR := 320.0
## Body height (upright) or length (otherwise) by size class, in metres.
const SIZE_METRES := {"Tiny": 0.4, "Small": 0.9, "Medium": 1.7, "Large": 2.7, "Huge": 4.8, "Gargantuan": 8.0}
## Real seconds per day in the visit.
const DAY_LENGTH := 240.0
## Living (swaying, hoverable) plants; the rest of each species is forest.
const MAX_PLANTS := 30
## Seconds between blows in a fight (a 5e round, sped up for watching).
const BLOW_TIME := 2.0


## A settlement or farmstead in the visit: where it stands, how far it
## reaches (metres), its scene node, and the places its folk go.
class Town:
	extends RefCounted
	var info: Dictionary = {}
	var name := ""
	var farm := false
	var centre := Vector3.ZERO
	var radius := 0.0
	var node: Node3D
	var sites: Array = []
	var huts: Array = []
	var defended := false
	var alarmed := 0.0
	## The people who live here, their species and how big they build.
	var civ_id := -1
	var species := -1
	var scale := 2.0


class Wanderer:
	extends RefCounted
	var node: Node3D
	var model: Node3D
	var name := ""
	var species := ""
	var detail: Dictionary
	var sheet: Dictionary
	## "villager", "grazer", "hunter", "swimmer" or "plant".
	var role := "grazer"
	var aquatic := false
	var plant := false
	var winged := false
	var target := Vector3.ZERO
	## Walking speed in metres per second, and the current multiple of it.
	var speed := 1.5
	var mult := 1.0
	var height := 1.0
	var radius := 0.5
	var state := "idle"
	var timer := 0.0
	var scan := 0.0
	## What to do on reaching `target`.
	var then := ""
	var site: Dictionary = {}
	var home: Dictionary = {}
	var partner: Wanderer
	var prey: Wanderer
	var herd := Vector3.ZERO
	var activity := ""
	var stuck := 0.0
	var last_pos := Vector3.ZERO
	var label: Label3D
	var bubble: Label3D
	## The town or farmstead a townsperson belongs to.
	var town: Town
	var guard := false
	## Combat (display only), from the character sheet: hit points, armour
	## class, attack bonus and average damage a round; the side it fights
	## for (-1 none, 0 the townsfolk, 1 a warband, 2 a raiding hunter);
	## its current foe and time to its next blow.
	var hp := 10
	var max_hp := 10
	var ac := 10
	var to_hit := 2
	var dpr := 3.0
	var team := -1
	var foe: Wanderer
	var cd := 0.0
	var lunge := 0.0
	var flash := 0.0
	var mats: Array = []
	var warband: Dictionary = {}
	var gone := false
	## Brave townsfolk stand and fight; the rest run home.
	var brave := false
	var altitude := 0.0


var sim: RefCounted
var region := Vector2i.ZERO
var info: Dictionary
var sea_level := -100.0
var heights := PackedFloat32Array()
var wanderers: Array = []
var possessed: Wanderer
var rng := RandomNumberGenerator.new()
var detail_img: Image
var detail_tex: ImageTexture
var palette: Dictionary = {}
var terrain_mat: ShaderMaterial
var grass_mat: ShaderMaterial
var grass_mesh: Mesh
## Grass cells alive around the camera (Vector2i -> MultiMeshInstance3D or
## null when a cell has no grass), and the cells still to grow.
var grass_cells := {}
var grass_queue: Array = []
var _grass_centre := Vector2i(1 << 20, 1 << 20)
var _frame := 0

var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var env: Environment
var sun: DirectionalLight3D
var moon: DirectionalLight3D
var hud: Label
var title: Label
var tooltip: Label
var orbit_yaw := 0.6
var orbit_pitch := 0.5
var orbit_dist := 70.0
var orbit_idle := 0.0
## Where the orbiting camera looks; WASD moves it across the land.
var cam_focus := Vector3.ZERO
var home_focus := Vector3.ZERO
var look_yaw := 0.0
var look_pitch := 0.0
var dragging := false
var drag_moved := 0.0
var day := 0.3
var night := 0.0
var _hud_timer := 0.0
var _sky_timer := 0.0
var _day_sky: Color
var _day_ambient: Color

## Settlement scenery (docs/GAME_DESIGN.md §4.5): where the town stands, how
## far it reaches in metres, how big its builders are, and how many building
## pieces were placed.
var town_centre := Vector3.ZERO
var town_radius := 0.0
var town_scale := 2.0
var building_count := 0
var town: Node3D
var civ_species := -1
## Every settlement and farmstead here; the first is the first-founded town.
var towns: Array = []
var notice: Label
var _notice_time := 0.0
var _war_timer := 0.0
## Peoples at war with this region's owners: {civ_id, name, species_id, color}.
var enemies: Array = []
## Places townsfolk go: {name, kind, pos, face} in world space.
var sites: Array = []
var huts: Array = []
## Circles creatures walk around: [Vector2 centre, radius] in world space.
var obstacles: Array = []
var trodden: Image
## The trodden-ground image covers this square around the town.
var trodden_origin := Vector2.ZERO
var trodden_half := 1.0
var window_mat: StandardMaterial3D
var _meshes := {}
var _mats := {}
const TIER_RADIUS := {"Camp": 5.0, "Village": 7.0, "Town": 9.0, "City": 12.0, "Metropolis": 15.0}
const TIER_HUTS := {"Camp": 3, "Village": 6, "Town": 10, "City": 16, "Metropolis": 24}
## Rough footprint radius of each building in town units, for keeping them apart.
const FOOTPRINT := {"Longhouse": 3.0, "Workshop": 2.1, "Granary": 1.6, "Forge": 2.1, "Mine": 2.4, "Market": 3.0, "Library": 2.4,
	"Barracks": 3.0, "Shrine": 1.0, "Temple": 3.2, "Wizard's tower": 1.3, "Aqueduct": 5.0, "Factory": 3.0}
## What townsfolk do at each kind of place.
const SITE_DOING := {"Forge": "smithing at the forge", "Workshop": "crafting in the workshop", "Granary": "storing grain",
	"Mine": "digging in the mine", "Market": "trading at the market", "Library": "reading in the library",
	"Barracks": "drilling at the barracks", "Temple": "praying at the temple", "Shrine": "praying at the shrine",
	"Wizard's tower": "studying at the tower", "Factory": "working at the factory", "Longhouse": "feasting in the longhouse",
	"Harbour": "mending nets at the harbour", "Field": "tending the fields", "Well": "drawing water at the well",
	"Post": "standing guard"}
const GATHER := ["Well", "Market", "Longhouse"]


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

	_find_builders()
	_build_sky()
	_build_terrain()
	home_focus = town_centre if _has_town() else Vector3(0, maxf(_height_at(0, 0), sea_level), 0)
	cam_focus = home_focus
	_build_settlement()
	_build_ground_cover()
	_update_grass(cam_focus, true)
	_spawn_life()
	enemies = info.get("enemies", []) if not towns.is_empty() else []
	_war_timer = rng.randf_range(35.0, 70.0)

	camera = Camera3D.new()
	camera.fov = 55.0
	camera.near = 0.1
	camera.far = 4000.0
	world.add_child(camera)
	if town:
		orbit_dist = clampf(town_radius * 2.6, 40.0, 200.0)

	var bar := VBoxContainer.new()
	bar.position = Vector2(12, 12)
	add_child(bar)
	title = Label.new()
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_constant_override("outline_size", 6)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	bar.add_child(title)
	hud = Label.new()
	hud.add_theme_constant_override("outline_size", 5)
	hud.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	bar.add_child(hud)
	var back := Button.new()
	back.text = "Back to world"
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	back.pressed.connect(close)
	bar.add_child(back)
	notice = Label.new()
	notice.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	notice.grow_horizontal = Control.GROW_DIRECTION_BOTH
	notice.position.y = 90
	notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	notice.add_theme_font_size_override("font_size", 24)
	notice.add_theme_color_override("font_color", Color(1.0, 0.85, 0.55))
	notice.add_theme_constant_override("outline_size", 8)
	notice.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	notice.mouse_filter = Control.MOUSE_FILTER_IGNORE
	notice.modulate.a = 0.0
	add_child(notice)
	tooltip = Label.new()
	tooltip.visible = false
	tooltip.add_theme_constant_override("outline_size", 6)
	tooltip.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	tooltip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tooltip)
	_advance_day(0.0)
	_update_hud()


# --- Sky, light and the day ------------------------------------------------------

func _build_sky() -> void:
	var tint := Color(info["sky_color"][0], info["sky_color"][1], info["sky_color"][2])
	var thickness: float = info["atmosphere"]
	var haze := clampf(thickness * 1.5, 0.0, 0.9)
	_day_sky = Color(0.02, 0.02, 0.05).lerp(tint.lightened(0.15), haze)
	_day_ambient = Color(0.42, 0.42, 0.46).lerp(tint, 0.35)
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = _day_sky.lightened(0.05)
	sky_mat.sky_energy_multiplier = 1.3
	sky_mat.sky_horizon_color = _day_sky.lightened(0.25)
	sky_mat.ground_horizon_color = _day_sky.lightened(0.15)
	sky_mat.ground_bottom_color = _day_sky.darkened(0.5)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_32
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = _day_ambient
	env.ambient_light_energy = 0.9
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	# Haze fades the far terrain into the sky, so the region has no hard edge.
	env.fog_enabled = true
	env.fog_light_color = sky_mat.sky_horizon_color
	env.fog_density = 0.0006 + 0.0012 * haze
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 220.0
	sun.light_color = Color(1.0, 0.96, 0.88)
	world.add_child(sun)
	moon = DirectionalLight3D.new()
	moon.light_color = Color(0.55, 0.65, 1.0)
	moon.rotation_degrees = Vector3(-50, -120, 0)
	moon.light_energy = 0.0
	world.add_child(moon)


## Moves the sun across the sky; at night the townsfolk go home and their
## doorways glow.
func _advance_day(delta: float) -> void:
	day = fmod(day + delta / DAY_LENGTH, 1.0)
	var elev := sin(TAU * (day - 0.25))
	var light := smoothstep(-0.08, 0.25, elev)
	night = 1.0 - smoothstep(-0.12, 0.08, elev)
	var strength := clampf(0.55 + 0.6 * sqrt(float(info["sunlight"])), 0.4, 1.4)
	sun.rotation = Vector3(-asin(clampf(elev, -1.0, 1.0)) * 1.1 - 0.05, TAU * day * 0.5 + 0.5, 0.0)
	sun.light_energy = strength * light
	sun.visible = light > 0.01
	moon.light_energy = 0.25 * night
	var dusk := Color(1.0, 0.55, 0.35)
	var sunset := clampf(1.0 - absf(elev) * 4.0, 0.0, 1.0) * (1.0 - night)
	sun.light_color = Color(1.0, 0.96, 0.88).lerp(dusk, sunset * 0.8)
	env.ambient_light_color = _day_ambient.lerp(Color(0.12, 0.14, 0.25), night * 0.85)
	env.ambient_light_energy = lerpf(0.9, 0.55, night)
	_sky_timer -= delta
	if _sky_timer <= 0.0:
		_sky_timer = 0.5
		env.background_energy_multiplier = lerpf(1.0, 0.12, night)
		env.fog_light_color = (env.sky.sky_material as ProceduralSkyMaterial).sky_horizon_color.lerp(Color(0.04, 0.05, 0.1), night * 0.9).lerp(dusk, sunset * 0.3)
	if window_mat:
		window_mat.emission_energy_multiplier = 0.2 + 3.0 * night


func _time_name() -> String:
	if night > 0.6:
		return "Night"
	if day < 0.3:
		return "Dawn"
	if day < 0.45:
		return "Morning"
	if day < 0.62:
		return "Midday"
	return "Evening"


# --- Terrain ---------------------------------------------------------------------

func _material(color: Color, glow := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/creature.gdshader")
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("glow_color", color)
	m.set_shader_parameter("glow", glow)
	return m


## Ground height at a world point, interpolated between grid points.
func _height_at(x: float, z: float) -> float:
	var fx := clampf((x + EXT) / STEP, 0.0, GRID - 0.001)
	var fz := clampf((z + EXT) / STEP, 0.0, GRID - 0.001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var i := iz * (GRID + 1) + ix
	var a := lerpf(heights[i], heights[i + 1], tx)
	var b := lerpf(heights[i + GRID + 1], heights[i + GRID + 2], tx)
	return lerpf(a, b, tz)


func _slope_at(x: float, z: float) -> float:
	var dx := _height_at(x + 1.0, z) - _height_at(x - 1.0, z)
	var dz := _height_at(x, z + 1.0) - _height_at(x, z - 1.0)
	return Vector2(dx, dz).length() * 0.5


## The detail noise, sampled the way the terrain shader samples it.
func _detail(x: float, z: float, scale: float) -> float:
	var w := detail_img.get_width()
	var px := posmod(int(x * scale * w), w)
	var pz := posmod(int(z * scale * w), w)
	return detail_img.get_pixel(px, pz).r


## Colours and cover for the region's climate: grass where life grows, sand
## and dust where it is dry, snow where it is cold, ash where it is molten.
func _make_palette() -> Dictionary:
	var temp: float = info["temperature"]
	var ice: float = info["ice_amount"]
	var liquid: float = info["liquid_amount"]
	var plant_mass := 0.0
	var plant_tint := Color(0.3, 0.5, 0.2)
	var best := 0.0
	for p in info["populations"]:
		var d: String = p["description"]
		if d.ends_with("Bloom") or d.ends_with("Plant"):
			var m: float = p["biomass"]
			plant_mass += m
			if m > best:
				best = m
				var sd = JSON.parse_string(sim.species_detail_json(int(p["id"])))
				if sd != null and sd.get("color") != null:
					plant_tint = Color.html(str(sd["color"]))
	var veg := clampf(plant_mass / 25.0, 0.0, 1.0)
	if plant_mass > 0.0:
		veg = maxf(veg, 0.3)
	var grass := Color(0.25, 0.46, 0.16).lerp(plant_tint, 0.2)
	var p := {
		"grass_a": grass.darkened(0.15), "grass_b": grass.lerp(Color(0.55, 0.62, 0.22), 0.25),
		"soil": Color(0.42, 0.33, 0.22), "sand": Color(0.80, 0.72, 0.52), "rock": Color(0.46, 0.44, 0.43),
		"snow": Color(0.93, 0.95, 1.0), "path": Color(0.52, 0.42, 0.30), "vegetation": veg,
		"snow_height": 1000.0, "ember": 0.0,
	}
	if liquid < 0.15:  # Dry: dusty soil, yellowed grass.
		p["soil"] = Color(0.62, 0.5, 0.34)
		p["grass_b"] = Color(0.66, 0.6, 0.3)
	if temp > 700.0:  # Molten: black basalt with glowing cracks.
		p["soil"] = Color(0.16, 0.12, 0.11)
		p["rock"] = Color(0.24, 0.2, 0.19)
		p["sand"] = Color(0.3, 0.22, 0.18)
		p["path"] = Color(0.25, 0.2, 0.18)
		p["vegetation"] = 0.0
		p["ember"] = 2.0
	elif temp > 380.0:  # Scorched.
		p["soil"] = Color(0.55, 0.36, 0.24)
		p["sand"] = Color(0.7, 0.5, 0.35)
		p["vegetation"] = veg * 0.5
	if ice > 0.3 or temp < 245.0:
		p["snow_height"] = -1000.0  # Snow lies everywhere flat enough to hold it.
		p["sand"] = Color(0.7, 0.72, 0.75)
	elif temp < 275.0:
		p["snow_height"] = 0.0  # Set to the upper hills once heights are known.
	return p


func _build_terrain() -> void:
	var broad := FastNoiseLite.new()
	broad.seed = rng.seed
	broad.frequency = 0.0011
	broad.fractal_octaves = 4
	var mid := FastNoiseLite.new()
	mid.seed = rng.seed + 3
	mid.frequency = 0.006
	mid.fractal_octaves = 3
	var fine := FastNoiseLite.new()
	fine.seed = rng.seed + 7
	fine.frequency = 0.04
	fine.fractal_octaves = 2
	heights.resize((GRID + 1) * (GRID + 1))
	var inner: Array[float] = []
	for z in GRID + 1:
		for x in GRID + 1:
			var wx := x * STEP - EXT
			var wz := z * STEP - EXT
			var h := broad.get_noise_2d(wx, wz) * 34.0 + mid.get_noise_2d(wx, wz) * 8.0 + fine.get_noise_2d(wx, wz) * 1.2
			heights[z * (GRID + 1) + x] = h
			if (x + z) % 3 == 0 and absf(wx) <= SIZE / 2.0 and absf(wz) <= SIZE / 2.0:
				inner.append(h)
	# Choose the sea level so the flooded share matches the region's liquid.
	var liquid: float = info["liquid_amount"]
	var wet_share := clampf(liquid / (liquid + 1.0), 0.0, 0.9)
	inner.sort()
	sea_level = inner[int(wet_share * (inner.size() - 1))] if wet_share > 0.02 else -100.0

	_plan_towns()
	palette = _make_palette()
	if float(palette["snow_height"]) == 0.0:
		var top := -100.0
		for h in heights:
			top = maxf(top, h)
		palette["snow_height"] = lerpf(maxf(sea_level, 0.0), top, 0.55)

	var dn := FastNoiseLite.new()
	dn.seed = rng.seed + 31
	dn.frequency = 0.012
	dn.fractal_octaves = 4
	detail_img = dn.get_seamless_image(256, 256)
	detail_img.convert(Image.FORMAT_RGB8)
	var d2 := detail_img.duplicate()
	d2.generate_mipmaps()
	detail_tex = ImageTexture.create_from_image(d2)

	var normals := PackedVector3Array()
	normals.resize((GRID + 1) * (GRID + 1))
	for z in GRID + 1:
		for x in GRID + 1:
			var hl := heights[z * (GRID + 1) + maxi(x - 1, 0)]
			var hr := heights[z * (GRID + 1) + mini(x + 1, GRID)]
			var hd := heights[maxi(z - 1, 0) * (GRID + 1) + x]
			var hu := heights[mini(z + 1, GRID) * (GRID + 1) + x]
			normals[z * (GRID + 1) + x] = Vector3(hl - hr, 2.0 * STEP, hd - hu).normalized()
	terrain_mat = ShaderMaterial.new()
	terrain_mat.shader = preload("res://shaders/terrain.gdshader")
	for k in ["grass_a", "grass_b", "soil", "sand", "rock", "snow"]:
		terrain_mat.set_shader_parameter(k, palette[k])
	terrain_mat.set_shader_parameter("path_color", palette["path"])
	terrain_mat.set_shader_parameter("vegetation", palette["vegetation"])
	terrain_mat.set_shader_parameter("sea_level", sea_level)
	terrain_mat.set_shader_parameter("snow_height", palette["snow_height"])
	terrain_mat.set_shader_parameter("ember_glow", palette["ember"])
	terrain_mat.set_shader_parameter("detail", detail_tex)
	var terrain := Node3D.new()
	terrain.name = "Terrain"
	world.add_child(terrain)
	# Every chunk shares one index list.
	var w := CHUNK + 1
	var indices := PackedInt32Array()
	for z in CHUNK:
		for x in CHUNK:
			var a := z * w + x
			indices.append_array([a, a + 1, a + w + 1, a, a + w + 1, a + w])
	for cz in GRID / CHUNK:
		for cx in GRID / CHUNK:
			terrain.add_child(_terrain_chunk(cx * CHUNK, cz * CHUNK, normals, indices))

	if sea_level > -50.0:
		_build_water()


func _terrain_chunk(x0: int, z0: int, normals: PackedVector3Array, indices: PackedInt32Array) -> MeshInstance3D:
	var w := CHUNK + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(w * w)
	norms.resize(w * w)
	for z in w:
		for x in w:
			var gi := (z0 + z) * (GRID + 1) + x0 + x
			verts[z * w + x] = Vector3((x0 + x) * STEP - EXT, heights[gi], (z0 + z) * STEP - EXT)
			norms[z * w + x] = normals[gi]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = terrain_mat
	return mi


func _build_water() -> void:
	var temp: float = info["temperature"]
	var water := MeshInstance3D.new()
	water.name = "Water"
	var plane := PlaneMesh.new()
	plane.size = Vector2(EXT * 2.0, EXT * 2.0)
	plane.subdivide_width = 32
	plane.subdivide_depth = 32
	water.mesh = plane
	water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var wc := Color("#" + str(info["liquid_color"])) if info["liquid_color"] != null else Color(0.2, 0.45, 0.8)
	var wm := ShaderMaterial.new()
	wm.shader = preload("res://shaders/water.gdshader")
	var molten := temp > 700.0
	wm.set_shader_parameter("shallow", (Color(1.0, 0.55, 0.15) if molten else wc.lightened(0.25)))
	wm.set_shader_parameter("deep", (Color(0.9, 0.2, 0.02) if molten else wc.darkened(0.65)))
	wm.set_shader_parameter("glow", 2.5 if molten else 0.0)
	wm.set_shader_parameter("sea_level", sea_level)
	var himg := Image.create_from_data(GRID + 1, GRID + 1, false, Image.FORMAT_RF, heights.to_byte_array())
	wm.set_shader_parameter("heightmap", ImageTexture.create_from_image(himg))
	wm.set_shader_parameter("extent", EXT)
	wm.set_shader_parameter("texel", 1.0 / (GRID + 1))
	var rimg := detail_img.duplicate()
	rimg.bump_map_to_normal_map(6.0)
	rimg.generate_mipmaps()
	wm.set_shader_parameter("ripples", ImageTexture.create_from_image(rimg))
	wm.set_shader_parameter("detail", detail_tex)
	water.material_override = wm
	water.position.y = sea_level
	world.add_child(water)


## Loose rocks everywhere (one MultiMesh) and the grass material; grass
## itself grows in cells around the camera (_update_grass). Built after the
## town so both stay off its paths and floors.
func _build_ground_cover() -> void:
	var veg: float = palette["vegetation"]
	grass_mesh = _tuft_mesh()
	grass_mat = ShaderMaterial.new()
	grass_mat.shader = preload("res://shaders/grass.gdshader")
	var ga: Color = palette["grass_a"]
	var gb: Color = palette["grass_b"]
	grass_mat.set_shader_parameter("root_color", ga.darkened(0.3))
	grass_mat.set_shader_parameter("tip_color", gb.lightened(0.1))
	var rock_xf: Array = []
	var rocks := int(SIZE * SIZE / 2500.0 * (0.5 + (1.0 - veg)))
	for attempt in rocks * 3:
		if rock_xf.size() >= rocks:
			break
		var x := rng.randf_range(-EXT * 0.95, EXT * 0.95)
		var z := rng.randf_range(-EXT * 0.95, EXT * 0.95)
		var steep := _slope_at(x, z)
		if rng.randf() > 0.3 + steep:
			continue
		if _near_town(x, z) and (_blocked(Vector2(x, z), 1.5) or _trodden_at(x, z) > 0.1):
			continue
		var s := rng.randf_range(0.25, 1.4) * (2.5 if rng.randf() < 0.08 else 1.0)
		var b := Basis.from_euler(Vector3(rng.randf() * 0.6, rng.randf() * TAU, rng.randf() * 0.6)).scaled(Vector3(s * rng.randf_range(0.9, 1.6), s * rng.randf_range(0.5, 0.9), s))
		rock_xf.append(Transform3D(b, Vector3(x, _height_at(x, z) - s * 0.2, z)))
	var rc: Color = palette["rock"]
	if not rock_xf.is_empty():
		_multimesh(_mesh("rock"), _mat(rc.lightened(0.05)), rock_xf).name = "Rocks"


## Whether a point is near enough to a town or farmstead that buildings and
## paths need checking.
func _near_town(x: float, z: float, extra := 0.0) -> bool:
	for t: Town in towns:
		if Vector2(x - t.centre.x, z - t.centre.z).length() < t.radius + 18.0 * t.scale + extra:
			return true
	return false


## Grows grass in the cells around `focus` and drops cells left behind; at
## most one new cell a frame so moving the camera never stalls.
func _update_grass(focus: Vector3, all := false) -> void:
	if grass_mat == null or float(palette["vegetation"]) <= 0.0:
		return
	var c := Vector2i(floori(focus.x / GRASS_CELL), floori(focus.z / GRASS_CELL))
	if c != _grass_centre:
		_grass_centre = c
		var reach := int(ceil(GRASS_RADIUS / GRASS_CELL))
		var want := {}
		grass_queue.clear()
		for dz in range(-reach, reach + 1):
			for dx in range(-reach, reach + 1):
				if Vector2(dx, dz).length() * GRASS_CELL > GRASS_RADIUS + GRASS_CELL * 0.5:
					continue
				var k := c + Vector2i(dx, dz)
				want[k] = true
				if not grass_cells.has(k):
					grass_queue.append(k)
		grass_queue.sort_custom(func(a: Vector2i, b: Vector2i): return (a - c).length_squared() < (b - c).length_squared())
		for k in grass_cells.keys():
			if not want.has(k):
				if grass_cells[k] != null:
					grass_cells[k].queue_free()
				grass_cells.erase(k)
	while not grass_queue.is_empty():
		var k: Vector2i = grass_queue.pop_front()
		if not grass_cells.has(k):
			grass_cells[k] = _grass_cell(k)
		if not all:
			break


func _grass_cell(k: Vector2i) -> MultiMeshInstance3D:
	var veg: float = palette["vegetation"]
	var r := RandomNumberGenerator.new()
	r.seed = hash(Vector3i(k.x, k.y, int(rng.seed)))
	var x0 := k.x * GRASS_CELL
	var z0 := k.y * GRASS_CELL
	var centre := Vector3(x0 + GRASS_CELL * 0.5, 0, z0 + GRASS_CELL * 0.5)
	if absf(centre.x) > EXT or absf(centre.z) > EXT:
		return null
	var near := _near_town(centre.x, centre.z, GRASS_CELL)
	var snow: float = palette["snow_height"]
	var xf: Array = []
	var tints: Array = []
	for attempt in int(GRASS_CELL * GRASS_CELL * 0.6 * veg):
		var x := x0 + r.randf() * GRASS_CELL
		var z := z0 + r.randf() * GRASS_CELL
		var h := _height_at(x, z)
		if sea_level > -50.0 and h < sea_level + 0.9:
			continue
		if h > snow - 1.0 or _slope_at(x, z) > 0.45:
			continue
		var cover := veg * 1.5 - 0.25 + (_detail(x, z, 0.011) - 0.5) * 0.9
		if r.randf() > cover:
			continue
		if near and (_trodden_at(x, z) > 0.25 or _blocked(Vector2(x, z), 0.4)):
			continue
		var s := r.randf_range(0.7, 1.35) * (0.8 + veg * 0.4)
		var b := Basis(Vector3.UP, r.randf() * TAU).scaled(Vector3(s, s * r.randf_range(0.8, 1.3), s))
		xf.append(Transform3D(b, Vector3(x - centre.x, h - 0.02, z - centre.z)))
		var t := r.randf_range(0.82, 1.15)
		tints.append(Color(t, t * r.randf_range(0.95, 1.05), t * 0.95))
	if xf.is_empty():
		return null
	var inst := _multimesh(grass_mesh, grass_mat, xf, tints)
	inst.position = centre
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return inst


## One grass tuft: a clump of tapering blades, UV.y running from root to tip.
func _tuft_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var r := RandomNumberGenerator.new()
	r.seed = 5
	for k in 7:
		var a := r.randf() * TAU
		var off := Vector3(cos(a), 0, sin(a)) * r.randf_range(0.0, 0.12)
		var face := r.randf() * TAU
		var side := Vector3(cos(face), 0, sin(face)) * 0.035
		var h := r.randf_range(0.28, 0.5)
		var lean := Vector3(cos(a), 0, sin(a)) * r.randf_range(0.03, 0.12)
		st.set_normal(Vector3.UP)
		st.set_uv(Vector2(0, 0))
		st.add_vertex(off - side)
		st.set_uv(Vector2(1, 0))
		st.add_vertex(off + side)
		st.set_uv(Vector2(0.5, 1))
		st.add_vertex(off + lean + Vector3(0, h, 0))
	return st.commit()


func _multimesh(mesh: Mesh, mat: Material, xf: Array, colors: Array = []) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.mesh = mesh
	mm.instance_count = xf.size()
	for i in xf.size():
		mm.set_instance_transform(i, xf[i])
		if mm.use_colors:
			mm.set_instance_color(i, colors[i])
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.material_override = mat
	world.add_child(inst)
	return inst


# --- Life ------------------------------------------------------------------------

## Which species built the settlement here, and how big its buildings are:
## a people builds doors to fit itself.
func _find_builders() -> void:
	if not _has_town():
		return
	for c in info.get("peoples", []):
		civ_species_of[int(c["civ_id"])] = int(c["species_id"])
		civ_names[int(c["civ_id"])] = str(c["name"])
		for o in c.get("at_war_with", []):
			_war_pairs[_pair(int(c["civ_id"]), int(o))] = true
	for e in info.get("enemies", []):
		_war_pairs[_pair(int(e["civ_id"]), int(e["against"]))] = true
	var main_civ := int(info["settlement"].get("civ_id", -1))
	if civ_species_of.is_empty():
		for c in JSON.parse_string(sim.civilizations_json()):
			if int(c["id"]) == main_civ and c.get("species_id") != null:
				civ_species_of[main_civ] = int(c["species_id"])
	civ_species = civ_species_of.get(main_civ, -1)
	town_scale = _scale_of(civ_species)


var civ_species_of := {}
var civ_names := {}
var _war_pairs := {}
var _scales := {}


func _pair(a: int, b: int) -> String:
	return "%d:%d" % [mini(a, b), maxi(a, b)]


func _at_war(a: int, b: int) -> bool:
	return _war_pairs.has(_pair(a, b))


## How big a species builds: doors fit the people who built them.
func _scale_of(species: int) -> float:
	if _scales.has(species):
		return _scales[species]
	var builder_m := 1.7
	if species >= 0:
		var sh = JSON.parse_string(sim.sheet_json("species", species))
		if sh != null:
			builder_m = SIZE_METRES.get(sh["size"], 1.7)
	_scales[species] = clampf(2.0 * builder_m / 1.7, 1.2, 8.0)
	return _scales[species]


func _spawn_life() -> void:
	var animals := 0
	var plants := 0
	for p in info["populations"]:
		if animals >= 14 and plants >= 7:
			break
		var id := int(p["id"])
		var detail = JSON.parse_string(sim.species_detail_json(id))
		var sheet = JSON.parse_string(sim.sheet_json("species", id))
		if detail == null or sheet == null:
			continue
		var biomass: float = p["biomass"]
		if CreatureBuilder.is_plant(detail):
			if plants >= 7:
				continue
			plants += 1
			var kelp := _is_kelp(detail)
			_plant_forest(detail, sheet, biomass, kelp)
			# A few living plants near where the visit starts sway and can be hovered.
			var stand := _spot_near(home_focus, 70.0, kelp)
			for k in 3:
				if _plant_count() < MAX_PLANTS:
					_add_wanderer(detail, sheet, p["name"], "plant", stand)
			continue
		if civ_species_of.values().has(id) and town:
			continue  # The townsfolk are spawned with their towns below.
		if animals >= 14:
			continue
		animals += 1
		var swimmer := _is_swimmer(detail)
		var total := clampi(int(biomass / 1.5), 2, 18)
		var herds := clampi(ceili(total / 5.0), 1, 4)
		for h in herds:
			# The first herd of each species stays within sight of the start.
			var herd := _spot_near(home_focus, 160.0, swimmer) if h == 0 else _random_spot(swimmer, true)
			for k in maxi(total / herds, 1):
				var w := _add_wanderer(detail, sheet, p["name"], _role(detail, p["description"]), herd)
				w.herd = herd
	if not towns.is_empty():
		var budget := 72
		for t: Town in towns:
			var detail = JSON.parse_string(sim.species_detail_json(t.species))
			var sheet = JSON.parse_string(sim.sheet_json("species", t.species))
			if detail != null and sheet != null:
				var pop: float = t.info.get("population", 4.0)
				var n := (1 + rng.randi() % 2) if t.farm else (clampi(int(pop), 4, 22) if t == towns[0] else clampi(int(pop), 2, 10))
				for k in mini(n, budget):
					_add_villager(detail, sheet, detail["name"], k, t)
				budget -= n
				if t.defended:
					# Guards keep watch at the edge of a walled or garrisoned town.
					for k in (4 if "Barracks" in t.info.get("buildings", []) else 2):
						var g := _add_villager(detail, sheet, "%s guard" % detail["name"], k, t)
						g.guard = true
						_arm(g)
	for x in info["individuals_here"]:
		var sid := int(x["species_id"])
		var detail = JSON.parse_string(sim.species_detail_json(sid))
		var sheet = JSON.parse_string(sim.sheet_json("individual", int(x["id"])))
		if detail == null or sheet == null:
			continue
		var w: Wanderer
		var home_town: Town = null
		for t: Town in towns:
			if t.species == sid and not t.farm:
				home_town = t
				break
		if home_town:
			w = _add_villager(detail, sheet, x["title"], rng.randi(), home_town)
		else:
			w = _add_wanderer(detail, sheet, x["title"], _role(detail, str(detail.get("description", ""))), _spot_near(home_focus, 120.0, false))
		_add_label(w, Color(1.0, 0.85, 0.35))


## A plant species' stands across the region, drawn as instanced copies of
## a simplified model up close and a trunk-and-crown shape far off, in tiles
## so only nearby plants are drawn in full.
func _plant_forest(detail: Dictionary, sheet: Dictionary, biomass: float, kelp: bool) -> void:
	var model := CreatureBuilder.build(detail)
	var box := CreatureBuilder.bounds(model)
	var metres: float = SIZE_METRES.get(sheet["size"], 1.7) * 1.6
	var upright := box.size.y >= maxf(box.size.x, box.size.z) * 0.9
	var ref := box.size.y if upright else maxf(box.size.x, box.size.z)
	var s: float = metres / maxf(ref, 0.01)
	model.scale = Vector3.ONE * s
	model.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)
	var meshes := _merge_model(model)
	model.free()
	var count := clampi(int(biomass * 12.0), 20, 320)
	var stands := clampi(3 + int(biomass / 2.0), 3, 16)
	var tiles := {}
	for st in stands:
		var c := _spot_near(home_focus, 200.0, kelp) if st == 0 else _random_spot(kelp, true)
		var radius := rng.randf_range(12.0, 50.0)
		for k in count / stands:
			var a := rng.randf() * TAU
			var p := c + Vector3(cos(a), 0, sin(a)) * radius * sqrt(rng.randf())
			if not _fits(p, kelp) or _in_town(p, 12.0 * town_scale):
				continue
			if not kelp and _slope_at(p.x, p.z) > 0.6:
				continue
			var sc := rng.randf_range(0.75, 1.3)
			var tk := Vector2i(floori(p.x / FOREST_TILE), floori(p.z / FOREST_TILE))
			if not tiles.has(tk):
				tiles[tk] = []
			tiles[tk].append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * sc), Vector3(p.x, _height_at(p.x, p.z) - 0.05, p.z)))
	for tk: Vector2i in tiles:
		var centre := Vector3((tk.x + 0.5) * FOREST_TILE, 0, (tk.y + 0.5) * FOREST_TILE)
		var local: Array = []
		for t: Transform3D in tiles[tk]:
			local.append(Transform3D(t.basis, t.origin - centre))
		var near := _multimesh(meshes[0], null, local)
		near.position = centre
		near.visibility_range_end = FOREST_NEAR
		near.visibility_range_end_margin = 20.0
		var far := _multimesh(meshes[1], null, local)
		far.position = centre
		far.visibility_range_begin = FOREST_NEAR
		far.visibility_range_begin_margin = 20.0
		far.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## A built model flattened into meshes for instancing: [full, distant].
## The full one keeps every part but with fewer segments, one surface per
## material; the distant one is a trunk and a crown in the model's colours.
func _merge_model(model: Node3D) -> Array:
	var by_mat := {}
	var whole := AABB()
	var first := true
	var crown_mat: Material
	var stem_mat: Material
	var stack: Array = [[model, model.transform]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		for ch in n.get_children():
			if ch is Node3D:
				stack.append([ch, xf * ch.transform])
		if n is MeshInstance3D and n.mesh != null:
			var mi := n as MeshInstance3D
			var mat: Material = mi.material_override
			if not by_mat.has(mat):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				by_mat[mat] = st
			by_mat[mat].append_from(_coarse(mi.mesh), 0, xf)
			var b := xf * mi.mesh.get_aabb()
			whole = b if first else whole.merge(b)
			first = false
			if mi.mesh is SphereMesh or mi.mesh is BoxMesh:
				crown_mat = mat
			else:
				stem_mat = mat
	var full := ArrayMesh.new()
	for mat in by_mat:
		by_mat[mat].commit(full)
		full.surface_set_material(full.get_surface_count() - 1, mat)
	var far := ArrayMesh.new()
	var h := whole.size.y
	var width := maxf(whole.size.x, whole.size.z)
	var parts := SurfaceTool.new()
	if stem_mat != null and h > width * 0.8:
		var trunk := CylinderMesh.new()
		trunk.top_radius = width * 0.06
		trunk.bottom_radius = width * 0.09
		trunk.height = h * 0.55
		trunk.radial_segments = 5
		trunk.rings = 0
		parts.begin(Mesh.PRIMITIVE_TRIANGLES)
		parts.append_from(trunk, 0, Transform3D(Basis(), Vector3(0, h * 0.275, 0)))
		parts.commit(far)
		far.surface_set_material(0, stem_mat)
	var crown := SphereMesh.new()
	crown.radius = 0.5
	crown.height = 1.0
	crown.radial_segments = 7
	crown.rings = 4
	var crown_h := h * (0.6 if stem_mat != null and h > width * 0.8 else 1.0)
	parts = SurfaceTool.new()
	parts.begin(Mesh.PRIMITIVE_TRIANGLES)
	parts.append_from(crown, 0, Transform3D(Basis().scaled(Vector3(width * 0.85, crown_h, width * 0.85)), Vector3(0, h - crown_h * 0.5, 0)))
	parts.commit(far)
	far.surface_set_material(far.get_surface_count() - 1, crown_mat if crown_mat != null else stem_mat)
	return [full, far]


## A cheaper copy of a creature-builder primitive, for forests.
func _coarse(mesh: Mesh) -> Mesh:
	if mesh is SphereMesh:
		var m := SphereMesh.new()
		m.radius = mesh.radius
		m.height = mesh.height
		m.radial_segments = 8
		m.rings = 4
		return m
	if mesh is CapsuleMesh:
		var m := CapsuleMesh.new()
		m.radius = mesh.radius
		m.height = mesh.height
		m.radial_segments = 6
		m.rings = 1
		return m
	if mesh is CylinderMesh:
		var m := CylinderMesh.new()
		m.top_radius = mesh.top_radius
		m.bottom_radius = mesh.bottom_radius
		m.height = mesh.height
		m.radial_segments = 6
		m.rings = 0
		return m
	return mesh


## A spot within `reach` of `p` that suits the creature, or `p` itself.
func _spot_near(p: Vector3, reach: float, aquatic: bool) -> Vector3:
	for attempt in 30:
		var a := rng.randf() * TAU
		var q := p + Vector3(cos(a), 0, sin(a)) * reach * sqrt(rng.randf())
		if _fits(q, aquatic) and not _in_town(q, 4.0):
			q.y = _height_at(q.x, q.z)
			return q
	return _random_spot(aquatic, true)


func _plant_count() -> int:
	var n := 0
	for w: Wanderer in wanderers:
		n += 1 if w.plant else 0
	return n


func _parts(detail: Dictionary) -> Dictionary:
	var kinds := {}
	for p in detail["parts"]:
		kinds[p["part"]] = true
	return kinds


func _is_kelp(detail: Dictionary) -> bool:
	return _parts(detail).has("fin") and sea_level > -50.0


func _is_swimmer(detail: Dictionary) -> bool:
	var k := _parts(detail)
	return (k.has("fin") or k.is_empty()) and not k.has("limb") and sea_level > -50.0


func _role(detail: Dictionary, description: String) -> String:
	if _is_swimmer(detail):
		return "swimmer"
	return "hunter" if description.ends_with("Hunter") else "grazer"


func _add_villager(detail: Dictionary, sheet: Dictionary, name: String, k: int, t: Town) -> Wanderer:
	var start: Vector3 = t.centre
	var home: Dictionary = {}
	if not t.huts.is_empty():
		home = t.huts[posmod(k, t.huts.size())]
		start = home["pos"]
	elif not t.sites.is_empty():
		start = t.sites[posmod(k, t.sites.size())]["pos"]
	start += Vector3(rng.randf_range(-1.5, 1.5), 0, rng.randf_range(-1.5, 1.5))
	var w := _add_wanderer(detail, sheet, name, "villager", start)
	w.home = home
	w.town = t
	w.team = t.civ_id + 10
	w.brave = rng.randf() < 0.5
	w.timer = rng.randf_range(0.0, 3.0)
	return w


## A guard's spear, held upright at its side.
func _arm(w: Wanderer) -> void:
	var h := w.height
	if h < w.radius * 1.6:
		return  # Only upright creatures carry spears.
	var shaft := MeshInstance3D.new()
	shaft.mesh = _mesh("cyl")
	shaft.material_override = _mat(Color(0.42, 0.3, 0.18))
	shaft.scale = Vector3(0.05 * h, 1.15 * h, 0.05 * h)
	shaft.position = Vector3(w.radius * 0.9, 0.58 * h, 0.1 * h)
	w.node.add_child(shaft)
	var tip := MeshInstance3D.new()
	tip.mesh = _mesh("cone")
	tip.material_override = _mat(Color(0.75, 0.76, 0.8))
	tip.scale = Vector3(0.09 * h, 0.16 * h, 0.09 * h)
	tip.position = Vector3(w.radius * 0.9, 1.23 * h, 0.1 * h)
	w.node.add_child(tip)


func _add_wanderer(detail: Dictionary, sheet: Dictionary, name: String, role: String, near: Vector3) -> Wanderer:
	var w := Wanderer.new()
	w.detail = detail
	w.sheet = sheet
	w.name = name
	w.species = str(detail.get("name", name))
	w.role = role
	w.plant = role == "plant"
	w.aquatic = role == "swimmer" or (w.plant and _is_kelp(detail))
	w.winged = _parts(detail).has("wing") and not w.plant
	var model := CreatureBuilder.build(detail)
	var box := CreatureBuilder.bounds(model)
	var metres: float = SIZE_METRES.get(sheet["size"], 1.7)
	if w.plant:
		metres *= 1.6  # Trees stand taller than beasts of their size class.
	var upright := box.size.y >= maxf(box.size.x, box.size.z) * 0.9
	var ref := box.size.y if upright else maxf(box.size.x, box.size.z)
	var s: float = metres / maxf(ref, 0.01)
	model.scale = Vector3.ONE * s
	model.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)
	model.set_meta("base_y", model.position.y)
	model.set_meta("base_z", model.position.z)
	w.height = box.size.y * s
	w.radius = maxf(box.size.x, box.size.z) * s * 0.45
	w.model = model
	var holder := Node3D.new()
	holder.add_child(model)
	world.add_child(holder)
	w.node = holder
	w.max_hp = maxi(int(sheet.get("hit_points", 10)), 1)
	w.hp = w.max_hp
	w.ac = int(sheet.get("armor_class", 10))
	for a in sheet.get("attacks", []):
		w.to_hit = maxi(w.to_hit, int(a.get("to_hit", 2)))
	w.dpr = maxf(1.0, float(sheet.get("cost_breakdown", {}).get("damage_per_round", 3.0)))
	# 5e speeds are feet per six-second round.
	var feet := maxi(int(sheet["speed"]["walk"]), int(sheet["speed"]["swim"]) if w.aquatic else 0)
	w.speed = clampf(float(maxi(feet, 10)) * 0.3048 / 6.0, 0.4, 4.0)
	var spread := 7.0 if w.plant else 5.0
	var spot := near
	if role != "villager":
		for attempt in 12:
			var cand := near + Vector3(rng.randf_range(-spread, spread), 0, rng.randf_range(-spread, spread))
			if _fits(cand, w.aquatic):
				spot = cand
				break
	holder.position = Vector3(spot.x, _ground_for(w, spot.x, spot.z), spot.z)
	holder.rotation.y = rng.randf() * TAU
	w.last_pos = holder.position
	if w.plant:
		w.speed = 0.0
		model.set("pace", 0.4)
	else:
		model.set("pace", 0.2)
		w.timer = rng.randf_range(0.0, 4.0)
	wanderers.append(w)
	return w


func _add_label(w: Wanderer, color: Color) -> void:
	var l := Label3D.new()
	l.text = w.name
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.modulate = color
	l.outline_size = 8
	l.font_size = 40
	l.pixel_size = 0.01
	l.fixed_size = false
	l.no_depth_test = true
	l.position.y = w.height + 0.6
	w.node.add_child(l)
	w.label = l


func _fits(p: Vector3, aquatic: bool) -> bool:
	if absf(p.x) > SIZE * 0.47 or absf(p.z) > SIZE * 0.47:
		return false
	var h := _height_at(p.x, p.z)
	if sea_level > -50.0 and (h < sea_level - 0.6) != aquatic:
		return false
	return aquatic or not _blocked(Vector2(p.x, p.z), 0.5)


func _random_spot(aquatic: bool, avoid_town := false) -> Vector3:
	for attempt in 60:
		var x := rng.randf_range(-SIZE * 0.44, SIZE * 0.44)
		var z := rng.randf_range(-SIZE * 0.44, SIZE * 0.44)
		var p := Vector3(x, 0, z)
		if avoid_town and town and attempt < 50 and Vector2(x - town_centre.x, z - town_centre.z).length() < town_radius + 10.0:
			continue
		if _fits(p, aquatic) or (sea_level < -50.0 and not aquatic):
			p.y = _height_at(x, z)
			return p
	return Vector3(0, maxf(_height_at(0, 0), sea_level), 0)


## Where a creature's feet (or belly, swimming) rest at a point.
func _ground_for(w: Wanderer, x: float, z: float) -> float:
	var g := _height_at(x, z)
	if w.aquatic:
		return g if w.plant else maxf(g + 0.3, sea_level - maxf(0.6, w.height))
	return maxf(g, sea_level - w.height * 0.25) if sea_level > -50.0 else g


func _blocked(p: Vector2, margin: float) -> bool:
	for o in obstacles:
		if p.distance_to(o[0]) < float(o[1]) + margin:
			return true
	return false


# --- Behaviour ---------------------------------------------------------------------

func _process(delta: float) -> void:
	_advance_day(delta)
	_frame += 1
	var eye := camera.position
	for i in wanderers.size():
		var w: Wanderer = wanderers[i]
		if w == possessed or w.plant:
			continue
		# Creatures far from the camera think a quarter as often.
		if w.node.position.distance_squared_to(eye) > 250000.0:
			if (_frame + i) % 4 == 0:
				_act(w, delta * 4.0)
		else:
			_act(w, delta)
	_update_floats(delta)
	if notice and _notice_time > 0.0:
		_notice_time -= delta
		notice.modulate.a = clampf(_notice_time / 1.5, 0.0, 1.0)
	for t: Town in towns:
		t.alarmed -= delta
	if not _war_pairs.is_empty() and not towns.is_empty():
		_war_timer -= delta
		if _war_timer <= 0.0:
			_war_timer = rng.randf_range(150.0, 240.0)
			_spawn_warband()
	if wanderers.any(func(x): return x.gone):
		for x: Wanderer in wanderers.filter(func(x): return x.gone):
			if possessed == x:
				possess(null)
			x.node.queue_free()
		wanderers = wanderers.filter(func(x): return not x.gone)
	if possessed:
		_drive(delta)
		_update_grass(possessed.node.position)
	else:
		_pan(delta)
		orbit_idle += delta
		if orbit_idle > 6.0:
			orbit_yaw += delta * 0.04
		var focus := cam_focus
		var off := Vector3(sin(orbit_yaw) * cos(orbit_pitch), sin(orbit_pitch), cos(orbit_yaw) * cos(orbit_pitch)) * orbit_dist
		camera.position = focus + off
		camera.position.y = maxf(camera.position.y, _height_at(camera.position.x, camera.position.z) + 2.0)
		camera.transform = Transform3D(Basis.looking_at(focus + Vector3(0, 1.5, 0) - camera.position, Vector3.UP), camera.position)
		_update_grass(cam_focus)
	_hud_timer -= delta
	if _hud_timer <= 0.0:
		_hud_timer = 0.5
		_update_hud()


## WASD or the arrow keys move the orbiting camera across the land (Shift
## for speed).
func _pan(delta: float) -> void:
	var input := Vector2.ZERO
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):
		input.y += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):
		input.y -= 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):
		input.x -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT):
		input.x += 1.0
	if input == Vector2.ZERO:
		return
	orbit_idle = 0.0
	var forward := Vector3(-sin(orbit_yaw), 0, -cos(orbit_yaw))
	var right := Vector3(cos(orbit_yaw), 0, -sin(orbit_yaw))
	var speed := maxf(orbit_dist, 20.0) * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	cam_focus += (forward * input.y + right * input.x).normalized() * speed * delta
	cam_focus.x = clampf(cam_focus.x, -SIZE * 0.5, SIZE * 0.5)
	cam_focus.z = clampf(cam_focus.z, -SIZE * 0.5, SIZE * 0.5)
	cam_focus.y = maxf(_height_at(cam_focus.x, cam_focus.z), sea_level)


func _act(w: Wanderer, delta: float) -> void:
	w.timer -= delta
	w.scan -= delta
	_animate_hits(w, delta)
	if w.scan <= 0.0:
		w.scan = 0.4 + rng.randf() * 0.2
		_look_around(w)
	match w.state:
		"walk":
			_walk(w, delta)
		"fight":
			_fight(w, delta)
		"hunt":
			if w.prey == null or w.prey.state == "dead" or not w.prey.node.visible or w.timer <= 0.0 or _in_town(w.prey.node.position, 2.0, false):
				w.team = -1
				_enter_state(w, "rest", rng.randf_range(4.0, 8.0), "catching its breath")
				return
			w.target = w.prey.node.position
			_walk(w, delta)
		"chat":
			if w.partner and is_instance_valid(w.partner.node):
				_face(w, w.partner.node.position - w.node.position, delta)
			if w.timer <= 0.0 or w.partner == null or w.partner.state != "chat":
				_end_chat(w)
		"work":
			if not w.site.is_empty():
				_face(w, (w.site["face"] as Vector3) - w.node.position, delta)
			w.model.position.y = _model_base(w) + absf(sin(w.timer * 5.0)) * 0.04 * w.height
			if w.timer <= 0.0:
				w.model.position.y = _model_base(w)
				_next(w)
		"inside":
			if w.timer <= 0.0 and night < 0.5:
				w.node.visible = true
				_next(w)
		"dead":
			if w.timer <= 0.0:
				_recover(w)
		_:
			if w.timer <= 0.0:
				_next(w)


func _model_base(w: Wanderer) -> float:
	return w.model.get_meta("base_y", 0.0)


## Notices threats and chances: grazers bolt from hunters (and wild ones from
## people), guards and brave townsfolk take on raiders while the rest run
## home, warbands fall on whoever they meet, hunters pick out prey (and now
## and then a lone farmer).
func _look_around(w: Wanderer) -> void:
	if w.gone or w.state in ["dead", "inside", "fight"] or (w.state == "walk" and w.mult > 2.0):
		return
	var pos := w.node.position
	if w.role == "raider":
		if w.warband.get("retreat", false):
			return
		var o := _nearest_hostile(w, 24.0)
		if o:
			_engage(w, o)
			return
		for t: Town in towns:
			if not t.farm and t.alarmed <= 0.0 and pos.distance_to(t.centre) < t.radius + 45.0:
				_alarm(t, w)
		return
	if w.role == "hunter":
		if w.state in ["hunt", "eat", "rest"]:
			return
		var best: Wanderer = null
		var best_d := 22.0
		for o: Wanderer in wanderers:
			if o.role != "grazer" or o.state in ["dead", "inside"] or o.species == w.species or o.height > w.height * 1.6:
				continue
			var d := pos.distance_to(o.node.position)
			if d < best_d and not _in_town(o.node.position, 2.0):
				best_d = d
				best = o
		if best == null and rng.randf() < 0.05:
			# A raid: a townsperson alone out in the fields or at a farmstead.
			best_d = 30.0
			for o: Wanderer in wanderers:
				if o.role != "villager" or o.guard or not o.node.visible or o.state in ["dead", "inside", "fight"] or o.height > w.height * 1.5:
					continue
				var d := pos.distance_to(o.node.position)
				if d < best_d and not _in_town(o.node.position, 0.0, false):
					best_d = d
					best = o
			if best:
				w.team = 2
				w.prey = best
				w.mult = 1.8
				_enter_state(w, "hunt", 20.0, "stalking %s" % best.name)
				_notice("A %s is stalking %s near %s!" % [w.species, best.name, best.town.name if best.town else "the town"])
				return
		if best:
			w.prey = best
			w.mult = 1.8
			w.target = best.node.position
			_enter_state(w, "hunt", 14.0, "hunting %s" % best.species)
		return
	if w.role == "villager":
		var foe := _nearest_hostile(w, 40.0 if w.guard else 10.0)
		if foe:
			if w.guard or w.brave:
				_engage(w, foe)
			elif not w.home.is_empty():
				_go(w, w.home["pos"], "home", 2.2, "fleeing from a %s" % foe.species)
			return
		if w.guard:
			return
	for o: Wanderer in wanderers:
		if o == w or o.plant or o.state in ["dead", "inside"]:
			continue
		var threat := o.role == "hunter" and o.species != w.species and o.height > w.height * 0.5
		var wary := w.role == "grazer" and o.role == "villager"
		var reach := 11.0 if threat else 4.5
		if not (threat or wary) or pos.distance_to(o.node.position) > reach:
			continue
		if w.role == "villager" and not w.home.is_empty():
			_go(w, w.home["pos"], "home", 2.0, "running home from a %s" % o.species)
		else:
			var away := (pos - o.node.position)
			away.y = 0.0
			var to := pos + away.normalized() * rng.randf_range(10.0, 16.0)
			to.x = clampf(to.x, -SIZE * 0.45, SIZE * 0.45)
			to.z = clampf(to.z, -SIZE * 0.45, SIZE * 0.45)
			_go(w, to, "", 2.3, "fleeing a %s" % o.species if threat else "shying away")
		return


# --- Fighting (display only) ---------------------------------------------------

## Teams: -1 none, 2 a raiding beast (against everyone with a side), and
## 10 + civilization id for a people's folk and warriors, who fight the
## peoples they are at war with.
func _hostile(a: Wanderer, b: Wanderer) -> bool:
	if a.team < 0 or b.team < 0 or a.team == b.team:
		return false
	if a.team == 2 or b.team == 2:
		return true
	return _at_war(a.team - 10, b.team - 10)


func _nearest_hostile(w: Wanderer, reach: float) -> Wanderer:
	var best: Wanderer = null
	var best_d := reach
	for o: Wanderer in wanderers:
		if o == w or o.gone or not o.node.visible or o.state in ["dead", "inside"] or not _hostile(w, o):
			continue
		var d := w.node.position.distance_to(o.node.position)
		if d < best_d:
			best_d = d
			best = o
	return best


func _engage(a: Wanderer, b: Wanderer) -> void:
	if a == possessed or a.state == "dead":
		return
	if a.bubble:
		a.bubble.queue_free()
		a.bubble = null
	if a.partner:
		a.partner.timer = 0.0
		a.partner = null
	a.node.visible = true
	a.foe = b
	a.cd = rng.randf_range(0.2, 0.9)
	a.mult = 1.6
	_enter_state(a, "fight", 45.0, "fighting %s" % (b.name if b.label else "a " + b.species))


## Close in on the foe and strike once a round; beasts and raiders break off
## when badly hurt.
func _fight(w: Wanderer, delta: float) -> void:
	var f := w.foe
	if f == null or f.gone or f.state == "dead" or not f.node.visible or w.timer <= 0.0:
		w.foe = null
		_after_fight(w)
		return
	if w.role != "villager" and w.hp < w.max_hp * 0.3:
		_break_off(w)
		return
	var to := f.node.position - w.node.position
	to.y = 0.0
	var reach := w.radius + f.radius + 0.7
	if to.length() > reach:
		w.target = f.node.position
		_move(w, to, delta, false)
		return
	_face(w, to, delta)
	w.model.set("pace", 0.9)
	w.cd -= delta
	if w.cd <= 0.0:
		w.cd = BLOW_TIME * rng.randf_range(0.85, 1.15)
		_strike(w, f)


## One blow: d20 plus the attack bonus against armour class, damage about
## the sheet's damage per round (doubled on a 20).
func _strike(a: Wanderer, b: Wanderer) -> void:
	a.lunge = 0.3
	var roll := rng.randi_range(1, 20)
	if roll == 20 or (roll > 1 and roll + a.to_hit >= b.ac):
		var dmg := maxi(1, roundi(a.dpr * rng.randf_range(0.6, 1.4) * (2.0 if roll == 20 else 1.0)))
		b.hp -= dmg
		b.flash = 0.25
		_float_text(b, str(dmg), Color(1.0, 0.4, 0.3) if b.role == "villager" else Color(1.0, 0.85, 0.3))
		if b.hp <= 0:
			_fall(b, a)
			return
	else:
		_float_text(b, "miss", Color(0.85, 0.85, 0.85))
	# The struck fight back, and their town takes up arms.
	if b.foe == null and b != possessed and b.state != "dead":
		_engage(b, a)
	if b.role == "villager" and b.town:
		_alarm(b.town, a)


func _fall(b: Wanderer, a: Wanderer) -> void:
	b.foe = null
	b.prey = null
	b.lunge = 0.0
	b.model.position.z = b.model.get_meta("base_z", 0.0)
	b.model.rotation.z = PI / 2.0
	b.node.position.y = _height_at(b.node.position.x, b.node.position.z) + b.radius * 0.6
	if b.bubble:
		b.bubble.queue_free()
		b.bubble = null
	_enter_state(b, "dead", 45.0 if b.role == "villager" else 20.0, "fallen to %s" % (a.name if a.label else "a " + a.species))
	if b.label:
		b.label.text = "%s\n(fallen)" % b.name
	if b.role == "raider" and not b.warband.is_empty():
		b.warband["lost"] = int(b.warband["lost"]) + 1
		if not b.warband["retreat"] and int(b.warband["lost"]) * 2 >= int(b.warband["size"]):
			b.warband["retreat"] = true
			_notice("The warband of the %s breaks and flees %s!" % [b.warband["civ"], (b.warband["town"] as Town).name])
	if a.role == "hunter" and a.team == 2:
		a.team = -1
		a.foe = null
		_enter_state(a, "eat", rng.randf_range(8.0, 12.0), "feeding")


## The fallen get up again: townsfolk at home, nursed back to health;
## beasts elsewhere; raiders are gone for good.
func _recover(w: Wanderer) -> void:
	w.model.rotation = Vector3.ZERO
	if w.role == "raider":
		w.gone = true
		return
	w.hp = w.max_hp
	var p: Vector3
	if w.role == "villager":
		p = w.home.get("pos", w.town.centre if w.town else town_centre)
	else:
		p = _random_spot(w.aquatic, true)
	w.node.position = Vector3(p.x, _ground_for(w, p.x, p.z), p.z)
	if w.label:
		w.label.text = w.name
	w.activity = ""
	_next(w)


func _after_fight(w: Wanderer) -> void:
	var o := _nearest_hostile(w, 25.0)
	if o and (w.role != "villager" or w.guard or w.brave):
		_engage(w, o)
		return
	w.model.set("pace", 0.2)
	if w.team == 2:
		w.team = -1
	_next(w)


func _break_off(w: Wanderer) -> void:
	w.foe = null
	if w.role == "raider" and not w.warband.is_empty():
		_go(w, w.warband["spawn"], "leave", 1.8, "fleeing, wounded")
		return
	w.team = -1
	var away := w.node.position - w.target
	away.y = 0.0
	var to := w.node.position + (away.normalized() if away.length() > 0.1 else Vector3.FORWARD) * 40.0
	to.x = clampf(to.x, -SIZE * 0.45, SIZE * 0.45)
	to.z = clampf(to.z, -SIZE * 0.45, SIZE * 0.45)
	_go(w, to, "rest", 2.0, "fleeing, wounded")


## A town takes up arms: its guards (and any within reach) go for the
## attacker, its brave folk nearby join in, the rest run home.
func _alarm(t: Town, attacker: Wanderer) -> void:
	if t.alarmed > 0.0 or attacker.state == "dead":
		return
	t.alarmed = 30.0
	for w: Wanderer in wanderers:
		if w.role != "villager" or w.state in ["dead", "fight"] or w == possessed:
			continue
		var d := w.node.position.distance_to(attacker.node.position)
		var kin := w.town != null and w.town.civ_id == t.civ_id
		if w.guard and kin and (w.town == t or d < 300.0):
			_engage(w, attacker)
		elif w.town == t and d < 40.0 and w.state != "inside":
			if w.brave:
				_engage(w, attacker)
			elif not w.home.is_empty():
				_go(w, w.home["pos"], "home", 2.2, "running for shelter")


## Lunges and hit flashes.
func _animate_hits(w: Wanderer, delta: float) -> void:
	if w.lunge > 0.0:
		w.lunge = maxf(w.lunge - delta, 0.0)
		w.model.position.z = w.model.get_meta("base_z", 0.0) + sin((0.3 - w.lunge) / 0.3 * PI) * maxf(w.radius, 0.3) * 0.6
	if w.flash > 0.0:
		if w.mats.is_empty():
			for m in w.model.find_children("*", "MeshInstance3D", true, false):
				var sm := (m as MeshInstance3D).material_override as ShaderMaterial
				if sm:
					w.mats.append([sm, sm.get_shader_parameter("glow_color"), sm.get_shader_parameter("glow")])
		w.flash = maxf(w.flash - delta, 0.0)
		for e in w.mats:
			var sm: ShaderMaterial = e[0]
			if w.flash > 0.0:
				sm.set_shader_parameter("glow_color", Color(1.0, 0.25, 0.15))
				sm.set_shader_parameter("glow", 3.0 * w.flash / 0.25)
			else:
				sm.set_shader_parameter("glow_color", e[1])
				sm.set_shader_parameter("glow", e[2])


var _floats: Array = []


## A number (or "miss") that rises from a creature and fades.
func _float_text(w: Wanderer, text: String, color: Color) -> void:
	if _floats.size() > 30 or w.node.position.distance_squared_to(camera.position) > 90000.0:
		return
	var l := Label3D.new()
	l.text = text
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.modulate = color
	l.outline_size = 10
	l.font_size = 56
	l.pixel_size = 0.012
	l.no_depth_test = true
	l.position = w.node.position + Vector3(rng.randf_range(-0.3, 0.3), w.height + 0.4, rng.randf_range(-0.3, 0.3))
	world.add_child(l)
	_floats.append([l, 1.2])


func _update_floats(delta: float) -> void:
	for i in range(_floats.size() - 1, -1, -1):
		var e: Array = _floats[i]
		var l: Label3D = e[0]
		e[1] = float(e[1]) - delta
		l.position.y += delta * 1.2
		l.modulate.a = clampf(float(e[1]) / 0.6, 0.0, 1.0)
		if float(e[1]) <= 0.0:
			l.queue_free()
			_floats.remove_at(i)


func _notice(text: String) -> void:
	if notice == null:
		return
	notice.text = text
	notice.modulate.a = 1.0
	_notice_time = 6.0


# --- War ---------------------------------------------------------------------

## A warband of a people at war with this region's owners marches on one of
## its towns, pillages, and fights whoever stands in its way.
## A warband marches on a town of a people at war: from a people elsewhere
## (it comes in from the edge of the region) or from a rival kingdom here
## (it sets out from that kingdom's own town).
func _spawn_warband() -> void:
	var options: Array = []  # [attacker civ id, attacker name, species, target Town, from Town or null]
	for e in enemies:
		for t: Town in towns:
			if not t.farm and t.civ_id == int(e["against"]):
				options.append([int(e["civ_id"]), str(e["name"]), int(e["species_id"]), t, null])
	for a: Town in towns:
		for t: Town in towns:
			if not a.farm and not t.farm and a.civ_id != t.civ_id and _at_war(a.civ_id, t.civ_id) and a == _first_town(a.civ_id):
				options.append([a.civ_id, civ_names.get(a.civ_id, "?"), a.species, t, a])
	if options.is_empty():
		return
	var o: Array = options[rng.randi() % options.size()]
	var detail = JSON.parse_string(sim.species_detail_json(int(o[2])))
	var sheet = JSON.parse_string(sim.sheet_json("species", int(o[2])))
	if detail == null or sheet == null:
		return
	var t: Town = o[3]
	var from: Town = o[4]
	var spawn: Vector3
	if from:
		spawn = _spot_near(from.centre, from.radius + 12.0, false)
	else:
		var a := rng.randf() * TAU
		spawn = _spot_near(t.centre + Vector3(cos(a), 0, sin(a)) * (t.radius + 180.0), 50.0, false)
	var n := 4 + rng.randi() % 5
	var civ_name: String = o[1]
	var band := {"civ": civ_name, "town": t, "spawn": spawn, "size": n, "lost": 0, "pillaged": 0, "retreat": false}
	for k in n:
		var r := _add_wanderer(detail, sheet, "%s warrior of the %s" % [detail["name"], civ_name], "raider", spawn)
		r.team = int(o[0]) + 10
		r.warband = band
		r.timer = 0.3 + k * 0.3
		_arm(r)
		if k == 0:
			_add_label(r, Color(1.0, 0.5, 0.45))
			r.label.text = "Warband of the %s" % civ_name
	_notice("A warband of the %s marches on %s%s!" % [civ_name, t.name, (" from " + from.name) if from else ""])


func _first_town(civ_id: int) -> Town:
	for t: Town in towns:
		if t.civ_id == civ_id and not t.farm:
			return t
	return null


func _next_raider(w: Wanderer) -> void:
	var b := w.warband
	if b.is_empty() or b["retreat"]:
		_go(w, b.get("spawn", w.node.position), "leave", 1.3, "retreating")
		return
	var o := _nearest_hostile(w, 30.0)
	if o:
		_engage(w, o)
		return
	var t: Town = b["town"]
	if int(b["pillaged"]) >= int(b["size"]) * 2 or t.sites.is_empty():
		b["retreat"] = true
		_notice("The warband of the %s withdraws from %s with its plunder." % [b["civ"], t.name])
		_go(w, b["spawn"], "leave", 1.2, "carrying off plunder")
		return
	var s: Dictionary = t.sites[rng.randi() % t.sites.size()]
	w.site = s
	var far := w.node.position.distance_to(t.centre) > t.radius + 40.0
	_go(w, _jitter(s["pos"], 2.0), "pillage", 1.8 if far else 1.3, "marching on %s" % t.name)


func _enter_state(w: Wanderer, state: String, time: float, activity: String) -> void:
	w.state = state
	w.timer = time
	_set_activity(w, activity)
	var pace := 0.2
	match state:
		"work":
			pace = 1.4
		"chat":
			pace = 0.6
		"eat":
			pace = 1.0
		"dead":
			pace = 0.0
	if state != "walk" and state != "hunt":
		w.model.set("pace", pace)


func _set_activity(w: Wanderer, activity: String) -> void:
	if w.activity == activity:
		return
	w.activity = activity
	if w.label:
		w.label.text = "%s\n%s" % [w.name, activity] if activity != "" else w.name


func _go(w: Wanderer, to: Vector3, then: String, mult: float, activity: String) -> void:
	w.target = to
	w.then = then
	w.mult = mult
	w.stuck = 0.0
	w.last_pos = w.node.position
	w.state = "walk"
	# Long enough to get there (with detours), so walks end on arrival.
	w.timer = 20.0 + w.node.position.distance_to(to) / maxf(w.speed * mult, 0.2) * 1.6
	_set_activity(w, activity)


func _jitter(p: Vector3, r: float) -> Vector3:
	var a := rng.randf() * TAU
	return p + Vector3(cos(a), 0, sin(a)) * r * sqrt(rng.randf())


## Chooses what a creature does next.
func _next(w: Wanderer) -> void:
	w.mult = 1.0
	w.partner = null
	w.prey = null
	match w.role:
		"villager":
			_next_villager(w)
		"raider":
			_next_raider(w)
		"swimmer":
			var to := _jitter(w.herd, 14.0)
			if _fits(to, true):
				_go(w, to, "rest", 1.0, "swimming")
			else:
				_enter_state(w, "rest", 2.0, "drifting")
		"hunter":
			if rng.randf() < 0.35:
				_enter_state(w, "rest", rng.randf_range(5.0, 10.0), "resting")
			else:
				_go(w, _spot_near(w.node.position, 60.0, false), "rest", 0.8, "prowling")
		_:
			var r := rng.randf()
			if r < 0.2 and _try_chat(w, 7.0, "nuzzling"):
				return
			if r < 0.6:
				_enter_state(w, "graze", rng.randf_range(5.0, 12.0), "grazing")
			else:
				if rng.randf() < 0.15:
					w.herd = _spot_near(w.herd, 30.0, false)  # The herd drifts.
				var to := _jitter(w.herd, 14.0)
				if _fits(to, false):
					_go(w, to, "graze", 0.7 + rng.randf() * 0.4, "roaming")
				else:
					_enter_state(w, "graze", 3.0, "grazing")


func _next_villager(w: Wanderer) -> void:
	var t := w.town
	var here: Array = t.sites if t else sites
	if w.guard and t:
		# Guards walk the edge of town, day and night.
		var a := rng.randf() * TAU
		var post := t.centre + Vector3(cos(a), 0, sin(a)) * (t.radius + rng.randf_range(1.0, 4.0) * t.scale)
		if _fits(post, false):
			_go(w, post, "work", 1.0, "on patrol")
			w.site = {"name": "Post", "face": post + Vector3(cos(a), 0, sin(a)) * 10.0}
		else:
			_enter_state(w, "rest", 4.0, "keeping watch")
		return
	if night > 0.4:
		if not w.home.is_empty():
			_go(w, w.home["pos"], "home", 1.2, "heading home for the night")
		else:
			_enter_state(w, "rest", 20.0, "sleeping")
		return
	var r := rng.randf()
	if r < 0.15 and not w.home.is_empty():
		_go(w, w.home["pos"], "home", 1.0, "going home")
		return
	if r < 0.45 or (t and t.farm and r < 0.55):
		# Farmers walk into the first town to meet people.
		var meet: Array = towns[0].sites if t and t.farm and not towns.is_empty() else here
		var gather: Array = meet.filter(func(s): return s["name"] in GATHER)
		if not gather.is_empty() and (not (t and t.farm) or rng.randf() < 0.3):
			var s: Dictionary = gather[rng.randi() % gather.size()]
			w.site = s
			_go(w, _jitter(s["pos"], 3.0), "gather", 1.0, "walking to the %s" % str(s["name"]).to_lower())
			return
	var work: Array = here.filter(func(s): return not (s["name"] in GATHER) or s["name"] == "Well")
	if work.is_empty():
		_enter_state(w, "rest", 6.0, "idling")
		return
	var s: Dictionary = work[rng.randi() % work.size()]
	w.site = s
	_go(w, _jitter(s["pos"], 2.0 if s["name"] == "Field" else 0.8), "work", 1.0, "walking to the %s" % str(s["name"]).to_lower())


func _arrive(w: Wanderer) -> void:
	w.model.set("pace", 0.2)
	match w.then:
		"work":
			_enter_state(w, "work", rng.randf_range(7.0, 15.0), SITE_DOING.get(w.site.get("name", ""), "working"))
		"gather":
			if not _try_chat(w, 9.0, "chatting"):
				_enter_state(w, "wait", rng.randf_range(5.0, 9.0), "waiting for company")
		"home":
			w.node.visible = false
			_enter_state(w, "inside", rng.randf_range(6.0, 14.0), "at home")
		"graze":
			_enter_state(w, "graze", rng.randf_range(5.0, 12.0), "grazing")
		"rest":
			_enter_state(w, "rest", rng.randf_range(2.0, 6.0), "resting")
		"pillage":
			w.warband["pillaged"] = int(w.warband["pillaged"]) + 1
			_enter_state(w, "work", rng.randf_range(6.0, 10.0), "pillaging the %s" % str(w.site.get("name", "town")).to_lower())
		"leave":
			w.gone = true
		_:
			_next(w)


## Pairs up with a nearby idle creature of the same kind to talk (or nuzzle).
func _try_chat(w: Wanderer, reach: float, doing: String) -> bool:
	for o: Wanderer in wanderers:
		if o == w or o == possessed or o.species != w.species or not (o.state in ["wait", "graze", "rest"]):
			continue
		if o.node.position.distance_to(w.node.position) > reach:
			continue
		var t := rng.randf_range(5.0, 10.0)
		for x: Wanderer in [w, o]:
			_enter_state(x, "chat", t, doing)
			if w.role == "villager":
				x.bubble = _bubble(x)
		w.partner = o
		o.partner = w
		return true
	return false


func _end_chat(w: Wanderer) -> void:
	if w.bubble:
		w.bubble.queue_free()
		w.bubble = null
	w.partner = null
	_next(w)


func _bubble(w: Wanderer) -> Label3D:
	var l := Label3D.new()
	l.text = "…"
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.font_size = 64
	l.outline_size = 10
	l.pixel_size = 0.01
	l.position.y = w.height + (1.1 if w.label else 0.35)
	w.node.add_child(l)
	return l


## Whether a point is within a settlement (and, with `farms`, a farmstead).
func _in_town(p: Vector3, margin: float, farms := true) -> bool:
	for t: Town in towns:
		if (farms or not t.farm) and Vector2(p.x - t.centre.x, p.z - t.centre.z).length() < t.radius + margin:
			return true
	return false


func _walk(w: Wanderer, delta: float) -> void:
	var pos := w.node.position
	var to := w.target - pos
	to.y = 0.0
	var d := to.length()
	var reach := 0.4 + w.radius * 0.5
	if w.state == "hunt":
		reach = w.radius + w.prey.radius + 0.4
		if d < reach:
			_pounce(w)
			return
	elif d < reach or w.timer <= 0.0:
		_arrive(w)
		return
	_move(w, to, delta, true)


## One step towards `to` (an offset), steering round buildings and others;
## blocked by water (or out of it, for swimmers). `arrive` ends the walk when
## blocked or stuck.
func _move(w: Wanderer, to: Vector3, delta: float, arrive: bool) -> void:
	var pos := w.node.position
	var d := to.length()
	var dir := to / maxf(d, 0.001) + _avoid(w, to)
	dir.y = 0.0
	dir = dir.normalized()
	var next := pos + dir * w.speed * w.mult * delta
	next.x = clampf(next.x, -SIZE * 0.48, SIZE * 0.48)
	next.z = clampf(next.z, -SIZE * 0.48, SIZE * 0.48)
	var g := _height_at(next.x, next.z)
	if sea_level > -50.0 and not w.winged:
		if (w.aquatic and g > sea_level - 0.6) or (not w.aquatic and g < sea_level - w.height * 0.3):
			if arrive:
				_arrive(w)
			return
	if w.winged and w.mult >= 0.9 and d > 6.0:
		w.altitude = move_toward(w.altitude, clampf(w.height * 2.0, 2.0, 6.0), delta * 2.0)
	else:
		w.altitude = move_toward(w.altitude, 0.0, delta * 2.5)
	next.y = _ground_for(w, next.x, next.z) + w.altitude
	w.node.position = next
	_face(w, dir, delta)
	w.model.set("pace", w.speed * w.mult / maxf(w.height, 0.4) * 1.2)
	w.stuck += delta
	if w.stuck > 2.5:
		if arrive and w.node.position.distance_to(w.last_pos) < 0.5:
			_arrive(w)
		w.stuck = 0.0
		w.last_pos = w.node.position


## Steering away from buildings (sliding round them towards the goal) and
## from other creatures.
func _avoid(w: Wanderer, to: Vector3) -> Vector3:
	var p := Vector2(w.node.position.x, w.node.position.z)
	var goal := Vector2(to.x, to.z)
	var push := Vector2.ZERO
	if not w.aquatic and w.altitude < 1.0 and _near_town(p.x, p.y):
		for o in obstacles:
			var c: Vector2 = o[0]
			var r: float = o[1] + w.radius + 0.3
			var off := p - c
			var d := off.length()
			if d > r + 1.2 or d < 0.001:
				continue
			var n := off / d
			var weight := (r + 1.2 - d) / 1.2
			var tangent := Vector2(-n.y, n.x)
			if tangent.dot(goal) < 0.0:
				tangent = -tangent
			if n.dot(goal) < 0.3:
				push += tangent * weight * 1.5
			push += n * weight * (2.5 if d < r else 0.6)
	for o: Wanderer in wanderers:
		if o == w or o.plant or not o.node.visible:
			continue
		var off := p - Vector2(o.node.position.x, o.node.position.z)
		if absf(off.x) > 8.0 or absf(off.y) > 8.0:
			continue
		var d := off.length()
		var r := w.radius + o.radius + 0.2
		if d < r and d > 0.001:
			push += off / d * (r - d) / r * 1.5
	return Vector3(push.x, 0, push.y)


func _face(w: Wanderer, dir: Vector3, delta: float) -> void:
	if Vector2(dir.x, dir.z).length() < 0.01:
		return
	w.node.rotation.y = lerp_angle(w.node.rotation.y, atan2(dir.x, dir.z), clampf(delta * 6.0, 0.0, 1.0))


## The end of a chase: sometimes the hunter brings its prey down and feeds,
## otherwise the prey bolts.
func _pounce(w: Wanderer) -> void:
	var prey := w.prey
	w.prey = null
	if prey.role == "villager":
		_engage(w, prey)
		_strike(w, prey)
		return
	if rng.randf() < 0.4:
		prey.model.rotation.z = PI / 2.0
		prey.node.position.y = _height_at(prey.node.position.x, prey.node.position.z) + prey.radius * 0.6
		if prey.label:
			prey.label.text = "%s\n(fallen)" % prey.name
		_enter_state(prey, "dead", 18.0, "fallen to a %s" % w.species)
		_enter_state(w, "eat", rng.randf_range(8.0, 14.0), "feeding on %s" % prey.species)
	else:
		var away := prey.node.position - w.node.position
		away.y = 0.0
		var to := prey.node.position + away.normalized() * 14.0
		to.x = clampf(to.x, -SIZE * 0.45, SIZE * 0.45)
		to.z = clampf(to.z, -SIZE * 0.45, SIZE * 0.45)
		_go(prey, to, "", 2.6, "escaping a %s" % w.species)
		_enter_state(w, "rest", rng.randf_range(5.0, 9.0), "missed its prey")


func _drive(delta: float) -> void:
	var w := possessed
	w.cd = maxf(w.cd - delta, 0.0)
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
		var move := (facing * input).normalized()
		move += _avoid(w, move * 3.0) * 0.5
		move.y = 0.0
		var next := w.node.position + move * w.speed * 2.2 * (3.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0) * delta
		next.x = clampf(next.x, -SIZE * 0.5, SIZE * 0.5)
		next.z = clampf(next.z, -SIZE * 0.5, SIZE * 0.5)
		var ground := _height_at(next.x, next.z)
		if w.aquatic and ground > sea_level - 0.4:
			next = w.node.position
		next.y = _ground_for(w, next.x, next.z)
		w.node.position = next
	w.node.rotation = Vector3(0, look_yaw + PI, 0)
	# First person: eyes at the front top of the body.
	var eye := w.node.position + Vector3(0, w.height * 0.9 + 0.1, 0) + facing * Vector3(0, 0, -w.radius * 0.6)
	camera.position = eye
	camera.rotation = Vector3(look_pitch, look_yaw, 0)


func _update_hud() -> void:
	var head := "Region (%d, %d) · %.0f K · %d species here · %s" % [region.x, region.y, info["temperature"], info["populations"].size(), _time_name()]
	if not towns.is_empty():
		var st: Dictionary = towns[0].info
		var folk := 0
		for w: Wanderer in wanderers:
			folk += 1 if w.role == "villager" and w.state != "dead" else 0
		var villages := towns.filter(func(t): return not t.farm).size() - 1
		var farms := towns.filter(func(t): return t.farm).size()
		head += "\n%s, a %s of the %s (%s era)%s · %d farmstead%s · %d townsfolk about" % [st.get("name", "?"), str(st.get("tier", "")).to_lower(), st.get("civ", "?"), st.get("era", "?"),
			(" · %d village%s nearby" % [villages, "" if villages == 1 else "s"]) if villages > 0 else "", farms, "" if farms == 1 else "s", folk]
		if civ_names.size() > 1:
			var names: Array = []
			for id in civ_names:
				var n := towns.filter(func(t): return t.civ_id == id and not t.farm).size()
				names.append("the %s (%d settlement%s)" % [civ_names[id], n, "" if n == 1 else "s"])
			head += "\nKingdoms here: " + ", ".join(names)
		var wars: Array = []
		var ids: Array = civ_names.keys()
		for i in ids.size():
			for j in range(i + 1, ids.size()):
				if _at_war(ids[i], ids[j]):
					wars.append("the %s and the %s are at war" % [civ_names[ids[i]], civ_names[ids[j]]])
		for e in enemies:
			wars.append("the %s are at war with the %s" % [civ_names.get(int(e["against"]), "?"), e["name"]])
		if not wars.is_empty():
			var line := "; ".join(wars)
			head += "\n" + line.left(1).to_upper() + line.substr(1)
	title.text = head
	if possessed:
		var sh := possessed.sheet
		hud.text = "Possessing %s — %s %s · HP %d · AC %d · cost %d\nWASD move (Shift to run) · Space to strike · drag to look · Esc to release. Possession is display only: it does not change the world." % [
			possessed.name, sh["size"], sh["type"].to_lower(), sh["hit_points"], sh["armor_class"], sh["cost"]]
	else:
		hud.text = "WASD to travel (Shift faster) · drag to orbit · scroll to zoom · H to return%s\nHover a creature to see what it is doing · click one to possess it." % (" to town" if town else "")


func possess(w: Wanderer) -> void:
	if possessed:
		cam_focus = possessed.node.position
		possessed.node.visible = true
		possessed.model.set("pace", 0.2)
		possessed.state = "idle"
		possessed.timer = 0.5
	possessed = w
	if w:
		if w.bubble:
			w.bubble.queue_free()
			w.bubble = null
		if w.partner:
			w.partner.timer = 0.0
		w.altitude = 0.0
		w.model.rotation = Vector3.ZERO
		w.node.visible = false
		look_yaw = w.node.rotation.y - PI
		look_pitch = 0.0
		tooltip.visible = false
	_update_hud()


func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		possess(null)
	elif event is InputEventKey and event.pressed and event.keycode in [KEY_H, KEY_HOME] and possessed == null:
		cam_focus = home_focus
	elif event is InputEventKey and event.pressed and event.keycode == KEY_SPACE and possessed:
		_player_strike()


## The possessed creature strikes whatever is in front of it.
func _player_strike() -> void:
	var w := possessed
	if w.cd > 0.0:
		return
	var facing := Vector3(-sin(look_yaw), 0, -cos(look_yaw))
	var best: Wanderer = null
	var best_d := 1e9
	for o: Wanderer in wanderers:
		if o == w or o.plant or not o.node.visible or o.state in ["dead", "inside"]:
			continue
		var to := o.node.position - w.node.position
		to.y = 0.0
		var d := to.length()
		if d < w.radius + o.radius + 1.2 and to.normalized().dot(facing) > 0.3 and d < best_d:
			best_d = d
			best = o
	w.cd = BLOW_TIME * 0.6
	if best:
		_strike(w, best)


func _on_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				dragging = true
				drag_moved = 0.0
			else:
				dragging = false
				if possessed == null and drag_moved < 6.0:
					_pick(event.position)
		elif event.pressed and possessed == null and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			orbit_dist = clampf(orbit_dist * (0.9 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.1), 8.0, 420.0)
	elif event is InputEventMouseMotion:
		if dragging:
			drag_moved += event.relative.length()
			if possessed:
				look_yaw -= event.relative.x * 0.005
				look_pitch = clampf(look_pitch - event.relative.y * 0.005, -1.2, 1.2)
			else:
				orbit_idle = 0.0
				orbit_yaw -= event.relative.x * 0.006
				orbit_pitch = clampf(orbit_pitch + event.relative.y * 0.005, 0.08, 1.35)
		elif possessed == null:
			_hover(event.position)


func _under(pos: Vector2, plants: bool) -> Wanderer:
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var best: Wanderer = null
	var best_score := 1e9
	for w: Wanderer in wanderers:
		if (w.plant and not plants) or not w.node.visible:
			continue
		var c := w.node.position + Vector3(0, w.height * 0.5, 0)
		var t := (c - from).dot(dir)
		if t < 0.0:
			continue
		var d := (from + dir * t).distance_to(c)
		var reach := maxf(w.height, w.radius * 2.0) * 0.6 + 0.3
		if d < reach and t < best_score:
			best_score = t
			best = w
	return best


func _hover(pos: Vector2) -> void:
	var w := _under(pos, true)
	if w == null:
		tooltip.visible = false
		return
	var kind := "plant" if w.plant else ("%s %s" % [w.sheet["size"], w.role]).to_lower()
	tooltip.text = "%s (%s)%s" % [w.name, kind, ("\n" + w.activity) if w.activity != "" and not w.plant else ""]
	tooltip.position = pos + Vector2(16, 12)
	tooltip.visible = true


func _pick(pos: Vector2) -> void:
	var best := _under(pos, false)
	if best:
		possess(best)


# --- Settlement scenery --------------------------------------------------------

func _has_town() -> bool:
	return info.get("settlement") != null and not (info["settlement"].get("buildings", []) as Array).is_empty()


func _tier_name() -> String:
	return str(info["settlement"].get("tier", "Village"))


## Where every settlement and farmstead stands. The first-founded town takes
## the driest ground near the middle; its daughter villages stand a few
## hundred metres off; farmsteads (more for a bigger people) are scattered
## between. Each site is levelled so buildings stand flat and dry.
func _plan_towns() -> void:
	if not _has_town():
		return
	var list: Array = info.get("settlements", [])
	if list.is_empty():
		list = [info["settlement"]]
	var total_pop := 0.0
	for k in list.size():
		var st: Dictionary = list[k]
		total_pop += float(st.get("population", 1.0))
		var t := Town.new()
		t.info = st
		t.name = str(st.get("name", "?"))
		t.civ_id = int(st.get("civ_id", -1))
		t.species = civ_species_of.get(t.civ_id, civ_species)
		t.scale = _scale_of(t.species)
		t.radius = float(TIER_RADIUS.get(str(st.get("tier", "Village")), 7.0)) * t.scale
		var b: Array = st.get("buildings", [])
		t.defended = "Walls" in b or "Palisade" in b or "Barracks" in b
		var spot = _site_score_best(t.radius, Vector3.ZERO, 0.0, 240.0, 13) if k == 0 else _site_near(t.radius, towns[0].centre, 170.0, 480.0)
		if spot == null:
			continue
		var c: Vector2 = spot
		t.centre = Vector3(c.x, _level(c, t.radius + 7.0 * t.scale, 24.0), c.y)
		towns.append(t)
	if towns.is_empty():
		return
	town_centre = towns[0].centre
	town_radius = towns[0].radius
	# Farmsteads: one for every few thousand people, up to ten.
	var want := clampi(int(total_pop / 2.5), 2, 10)
	var placed := 0
	for attempt in want * 6:
		if placed >= want:
			break
		var near: Town = towns[rng.randi() % towns.size()]
		var spot = _site_near(5.0 * near.scale, near.centre, near.radius + 40.0, near.radius + 260.0)
		if spot == null:
			continue
		var c: Vector2 = spot
		var f := Town.new()
		f.farm = true
		f.name = "a farmstead of %s" % near.name
		f.info = near.info
		f.civ_id = near.civ_id
		f.species = near.species
		f.scale = near.scale
		f.radius = 5.0 * near.scale
		f.centre = Vector3(c.x, _level(c, f.radius + 2.0, 10.0), c.y)
		towns.append(f)
		placed += 1


## The best-scoring dry spot for a site of `radius` on a grid of candidates
## within `reach` of `around`.
func _site_score_best(radius: float, around: Vector3, _dmin: float, reach: float, n: int) -> Variant:
	var best: Variant = null
	var best_score := -1e9
	var half := n / 2
	for cz in range(-half, half + 1):
		for cx in range(-half, half + 1):
			var c := Vector2(around.x, around.z) + Vector2(cx, cz) * reach / half
			var score := _site_score(c, radius) - c.distance_to(Vector2(around.x, around.z)) * 0.04
			if score > best_score:
				best_score = score
				best = c
	return best


## A good spot for a site of `radius` between `dmin` and `dmax` from
## `around`, clear of every other site; null if there is none.
func _site_near(radius: float, around: Vector3, dmin: float, dmax: float) -> Variant:
	var best: Variant = null
	var best_score := 30.0
	for attempt in 50:
		var a := rng.randf() * TAU
		var d := rng.randf_range(dmin, dmax)
		var c := Vector2(around.x, around.z) + Vector2(cos(a), sin(a)) * d
		if absf(c.x) > SIZE * 0.42 or absf(c.y) > SIZE * 0.42:
			continue
		var clear := true
		for t: Town in towns:
			if c.distance_to(Vector2(t.centre.x, t.centre.z)) < t.radius + radius + 14.0 * t.scale + (0.0 if t.farm else 25.0):
				clear = false
				break
		if not clear:
			continue
		var score := _site_score(c, radius) - _slope_at(c.x, c.y) * 40.0
		if score > best_score:
			best_score = score
			best = c
	return best


## How dry a round site is: dry samples on two rings and at the centre.
func _site_score(c: Vector2, radius: float) -> float:
	var land := sea_level + 0.4
	var score := 0.0
	for k in 16:
		var a := TAU * k / 16.0
		for f in [0.5, 1.0]:
			score += 1.0 if _height_at(c.x + cos(a) * radius * f, c.y + sin(a) * radius * f) >= land else 0.0
	if _height_at(c.x, c.y) >= land:
		score += 4.0
	return score


## Levels the ground into a plateau `flat` metres across around `c`,
## blending back to the land over `blend` metres; returns its height.
func _level(c: Vector2, flat: float, blend_width: float) -> float:
	var plateau := _height_at(c.x, c.y)
	if sea_level > -50.0:
		plateau = maxf(plateau, sea_level + 0.6)
	var blend := flat + blend_width
	var gx := int((c.x + EXT) / STEP)
	var gz := int((c.y + EXT) / STEP)
	var cells := int(blend / STEP) + 2
	for z in range(maxi(gz - cells, 0), mini(gz + cells, GRID) + 1):
		for x in range(maxi(gx - cells, 0), mini(gx + cells, GRID) + 1):
			var d := Vector2(x * STEP - EXT - c.x, z * STEP - EXT - c.y).length()
			if d >= blend:
				continue
			var t := 1.0 - smoothstep(flat, blend, d)
			var i := z * (GRID + 1) + x
			heights[i] = lerpf(heights[i], plateau, t)
	return plateau


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
			c.radial_segments = 12
			c.rings = 1
			m = c
		"cone":
			var c := CylinderMesh.new()
			c.top_radius = 0.0
			c.bottom_radius = 0.5
			c.height = 1.0
			c.radial_segments = 12
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
		"rock":
			var sph := SphereMesh.new()
			sph.radius = 0.5
			sph.height = 1.0
			sph.radial_segments = 7
			sph.rings = 4
			m = sph
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
## blocks): `xf` holds one Transform3D per copy, in town space. Props that
## are not buildings (crops) are left out of the building count.
func _scatter(kind: String, mat: Material, xf: Array, count := true) -> void:
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
	if count:
		building_count += xf.size()


## Town space (offsets from the centre in building units) to world space.
func _world(p: Vector2) -> Vector3:
	var wx := town_centre.x + p.x * town_scale
	var wz := town_centre.z + p.y * town_scale
	return Vector3(wx, _height_at(wx, wz), wz)


## Ground height under a town-space point, in town space.
func _ground(p: Vector2) -> float:
	return _world(p).y / town_scale


func _dry_world(x: float, z: float, margin := 0.15) -> bool:
	return sea_level < -50.0 or _height_at(x, z) > sea_level + margin


func _dry(p: Vector2, margin := 0.15) -> bool:
	var w := _world(p)
	return _dry_world(w.x, w.z, margin)


func _add_site(name: String, local: Vector2, face: Vector2) -> void:
	sites.append({"name": name, "pos": _world(local), "face": _world(face)})


## Builds every settlement and farmstead, the paths in and around them and
## the roads that join them to the first town.
func _build_settlement() -> void:
	if towns.is_empty():
		return
	window_mat = StandardMaterial3D.new()
	window_mat.albedo_color = Color(0.12, 0.08, 0.05)
	window_mat.emission_enabled = true
	window_mat.emission = Color(1.0, 0.68, 0.32)
	trodden_origin = Vector2.ZERO
	trodden_half = SIZE * 0.5
	trodden = Image.create(2048, 2048, false, Image.FORMAT_L8)
	for k in towns.size():
		var t: Town = towns[k]
		town_centre = t.centre
		town_radius = t.radius
		town_scale = t.scale
		sites = []
		huts = []
		if t.farm:
			_build_farm(t, k)
		else:
			_build_town(t, k)
		t.node = town
		t.sites = sites
		t.huts = huts
		_paint_paths()
		if k > 0:
			_paint_line(t.centre, towns[0].centre, 1.3, 0.55)  # The road to town.
	for t: Town in towns:
		if t.farm:
			continue
		var banner := Label3D.new()
		banner.text = "%s\n%s" % [t.name, civ_names.get(t.civ_id, str(t.info.get("civ", "")))]
		banner.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		banner.modulate = Color.html(str(t.info.get("color", "ffffff"))).lightened(0.35)
		banner.outline_size = 10
		banner.font_size = 36
		banner.fixed_size = true
		banner.pixel_size = 0.0011
		banner.no_depth_test = true
		banner.visibility_range_begin = t.radius + 30.0
		banner.position = t.centre + Vector3(0, 14.0 * t.scale, 0)
		world.add_child(banner)
	terrain_mat.set_shader_parameter("trodden", ImageTexture.create_from_image(trodden))
	terrain_mat.set_shader_parameter("trodden_origin", trodden_origin)
	terrain_mat.set_shader_parameter("trodden_half", trodden_half)
	town = towns[0].node
	town_centre = towns[0].centre
	town_radius = towns[0].radius
	town_scale = towns[0].scale
	sites = towns[0].sites
	huts = towns[0].huts


## A farmstead: a house with a lit door, a fenced field of crops and a
## haystack, where a farming family works by day.
func _build_farm(t: Town, k: int) -> void:
	var brng := RandomNumberGenerator.new()
	brng.seed = region.x * 7919 + region.y * 104729 + 31 * k
	var civ_col := Color.html(str(t.info.get("color", "c8a050")))
	town = Node3D.new()
	town.name = "Farm"
	town.position = Vector3(t.centre.x, 0, t.centre.z)
	town.scale = Vector3.ONE * town_scale
	world.add_child(town)
	var wood := _mat(Color(0.45, 0.32, 0.2))
	var yaw := brng.randf() * TAU
	var fwd := Vector2(sin(yaw), cos(yaw))
	var side := Vector2(fwd.y, -fwd.x)
	var house := Node3D.new()
	house.position = Vector3(0, _ground(Vector2.ZERO) - 0.05, 0)
	house.rotation.y = yaw
	town.add_child(house)
	_part(house, "box", wood, Vector3.ZERO, Vector3(2.2, 1.2, 1.7))
	_part(house, "prism", _mat(Color(0.72, 0.6, 0.3).lerp(civ_col, 0.3)), Vector3(0, 1.2, 0), Vector3(2.6, 0.9, 1.9))
	_part(house, "box", window_mat, Vector3(0, 0, 0.86), Vector3(0.45, 0.75, 0.05))
	var hay := Node3D.new()
	var hp := -side * 1.9
	hay.position = Vector3(hp.x, _ground(hp) - 0.05, hp.y)
	town.add_child(hay)
	_part(hay, "dome", _mat(Color(0.82, 0.7, 0.35)), Vector3.ZERO, Vector3(1.1, 1.2, 1.1))
	var wc := _world(Vector2.ZERO)
	obstacles.append([Vector2(wc.x, wc.z), 1.3 * town_scale])
	huts.append({"name": "Hut", "pos": _world(fwd * 1.4), "face": wc})
	# The field in front of the house, fenced.
	var field := fwd * 4.2
	var crops: Array = []
	var posts: Array = []
	var ripe := Color(0.78, 0.66, 0.25) if brng.randf() < 0.5 else Color(0.36, 0.55, 0.2)
	for row in 5:
		for c in 8:
			var p := field + side * (c - 3.5) * 0.45 + fwd * (row - 2) * 0.5
			var h := 0.32 + brng.randf() * 0.15
			crops.append(Transform3D(Basis(Vector3.UP, yaw).scaled_local(Vector3(0.2, h, 0.2)), Vector3(p.x, _ground(p) + h * 0.5, p.y)))
	for e in 24:
		var u := float(e) / 24.0 * 4.0
		var q := Vector2.ZERO
		if u < 1.0:
			q = side * lerpf(-2.1, 2.1, u) + fwd * -1.4
		elif u < 2.0:
			q = side * 2.1 + fwd * lerpf(-1.4, 1.4, u - 1.0)
		elif u < 3.0:
			q = side * lerpf(2.1, -2.1, u - 2.0) + fwd * 1.4
		else:
			q = side * -2.1 + fwd * lerpf(1.4, -1.4, u - 3.0)
		if u >= 0.4 and u < 0.6:
			continue  # The gate faces the house.
		var p := field + q
		posts.append(Transform3D(Basis().scaled(Vector3(0.08, 0.6, 0.08)), Vector3(p.x, _ground(p) + 0.3, p.y)))
	_scatter("cone", _mat(ripe), crops, false)
	_scatter("box", wood, posts)
	_add_site("Field", field - fwd * 0.6, field)
	_add_site("Field", field + side * 1.2, field)
	var fw := _world(field)
	_paint_rect(fw, side, fwd, 2.2 * town_scale, 1.5 * town_scale, 0.8)


func _build_town(t: Town, k: int) -> void:
	var st: Dictionary = t.info
	var names: Array = st["buildings"]
	var civ_col := Color.html(str(st.get("color", "c8a050")))
	town = Node3D.new()
	town.name = "Town" if k == 0 else "Village"
	town.position = Vector3(town_centre.x, 0, town_centre.z)
	town.scale = Vector3.ONE * town_scale
	world.add_child(town)
	var brng := RandomNumberGenerator.new()
	brng.seed = region.x * 7919 + region.y * 104729 + 17 + 101 * k
	var tier := str(st.get("tier", "Village"))
	var r_units := town_radius / town_scale
	var wood := _mat(Color(0.45, 0.32, 0.2))
	var stone := _mat(Color(0.58, 0.58, 0.6))
	var dark := _mat(Color(0.3, 0.3, 0.33))
	var roof := _mat(civ_col.darkened(0.15))
	var placed: Array = [[Vector2.ZERO, 1.6]]  # [town-space position, footprint radius]; the well.

	# The well in the square, where townsfolk meet.
	var well := Node3D.new()
	well.position = Vector3(0, _ground(Vector2.ZERO) - 0.05, 0)
	town.add_child(well)
	_part(well, "cyl", stone, Vector3.ZERO, Vector3(1.1, 0.45, 1.1))
	_part(well, "cyl", _mat(Color(0.15, 0.25, 0.35)), Vector3(0, 0.4, 0), Vector3(0.8, 0.06, 0.8))
	for sx in [-0.45, 0.45]:
		_part(well, "box", wood, Vector3(sx, 0.4, 0), Vector3(0.08, 0.9, 0.08))
	_part(well, "prism", roof, Vector3(0, 1.25, 0), Vector3(1.2, 0.4, 0.9))
	obstacles.append([Vector2(town_centre.x, town_centre.z), 0.6 * town_scale])
	_add_site("Well", Vector2(0, 1.1), Vector2.ZERO)

	# Larger buildings first, so the small ones fill the gaps.
	var core: Array = []
	for n in names:
		if FOOTPRINT.has(n):
			core.append(n)
	core.sort_custom(func(a, b): return FOOTPRINT[a] > FOOTPRINT[b])
	for n in core:
		var foot: float = FOOTPRINT[n]
		var spot = _find_spot(brng, placed, foot, r_units, 1.0 if n in ["Temple", "Library", "Market"] else 0.0)
		if spot == null:
			continue
		var local: Vector2 = spot
		var root := Node3D.new()
		root.position = Vector3(local.x, _ground(local) - 0.05, local.y)
		root.rotation.y = atan2(-local.x, -local.y) + (brng.randf() - 0.5) * 0.3
		town.add_child(root)
		_make_building(n, root, civ_col, wood, stone, dark, roof)
		placed.append([local, foot])
		var wc := _world(local)
		obstacles.append([Vector2(wc.x, wc.z), foot * town_scale * (0.6 if n == "Market" else 0.85)])
		if SITE_DOING.has(n):
			# The door faces the square (+Z of the building points at the centre).
			var inward := -local.normalized() if local.length() > 0.01 else Vector2(0, 1)
			_add_site(n, local + inward * (foot * 0.9 + 0.5), local)

	# Huts, scattered over what is left, each with a door to the square.
	var hut_xf: Array = []
	var tops: Array = []
	var doors: Array = []
	if "Huts" in names or tier == "Camp":
		for h in int(TIER_HUTS.get(tier, 6)):
			var spot = _find_spot(brng, placed, 1.3, r_units, 0.0)
			if spot == null:
				break
			var local: Vector2 = spot
			placed.append([local, 1.3])
			var gy := _ground(local) - 0.05
			var inward := -local.normalized()
			var yaw := atan2(inward.x, inward.y)
			var sc := 0.9 + brng.randf() * 0.3
			var b := Basis(Vector3.UP, yaw)
			hut_xf.append(Transform3D(b.scaled_local(Vector3(1.6, 1.1, 1.6) * sc), Vector3(local.x, gy + 0.55 * sc, local.y)))
			tops.append(Transform3D(b.scaled_local(Vector3(2.1, 0.9, 2.1) * sc), Vector3(local.x, gy + 1.1 * sc + 0.45 * sc, local.y)))
			var door := local + inward * 0.8 * sc
			doors.append(Transform3D(b.scaled_local(Vector3(0.42, 0.72, 0.1) * sc), Vector3(door.x, gy + 0.36 * sc, door.y)))
			var wc := _world(local)
			obstacles.append([Vector2(wc.x, wc.z), 0.8 * sc * town_scale])
			huts.append({"name": "Hut", "pos": _world(local + inward * (0.8 * sc + 0.45)), "face": wc})
	_scatter("cyl", wood, hut_xf)
	_scatter("cone", _mat(Color(0.72, 0.6, 0.3).lerp(civ_col, 0.35)), tops)
	_scatter("box", window_mat, doors)

	if "Palisade" in names:
		_ring(r_units + 3.0, 1.9, "cyl", _mat(Color(0.5, 0.36, 0.22)), Vector3(0.28, 1.8, 0.28), 0.0, 0.0)
	if "Walls" in names:
		_ring(r_units + 5.0, 3.2, "box", stone, Vector3(0.7, 1.8, 2.4), 0.8, 0.25)
	if "Harbour" in names:
		_build_harbour(wood)
	if "Granary" in names or tier != "Camp":
		_build_fields(brng, r_units + (6.5 if "Walls" in names else 4.5))


## A free spot within the town's reach, as an offset from its centre.
func _find_spot(brng: RandomNumberGenerator, placed: Array, foot: float, r_units: float, inner_bias: float) -> Variant:
	for attempt in 80:
		var reach := r_units * (0.55 + 0.45 * minf(1.0, attempt / 40.0)) + attempt * 0.06
		var r := reach * sqrt(brng.randf())
		if inner_bias > 0.0:
			r *= 0.7
		var a := brng.randf() * TAU
		var p := Vector2(cos(a), sin(a)) * r
		if not _dry(p, 0.3):
			continue
		var ok := true
		for o in placed:
			if p.distance_to(o[0]) < foot + float(o[1]) + 0.6:
				ok = false
				break
		if ok:
			return p
	return null


## A ring of posts or blocks around the town; pieces over water are skipped.
## `chunk` is the arc length of each piece, `gates` the share left open.
func _ring(radius: float, chunk: float, kind: String, mat: Material, size: Vector3, gates: float, towers_on: float) -> void:
	var circ := TAU * radius
	var n := clampi(int(circ / chunk), 12, 56)
	var xf: Array = []
	var towers: Array = []
	for i in n:
		var a := TAU * i / n
		var p := Vector2(cos(a), sin(a)) * radius
		if not _dry(p):
			continue
		if i % 7 == 6:
			continue  # A gap in the wall or fence: a gate.
		var y := _ground(p) - 0.1
		var b := Basis(Vector3.UP, -a)
		var sz := size
		if kind == "box":
			sz.z = circ / n * (1.0 - gates * 0.3)
		if towers_on > 0.0 and i % 4 == 0:
			towers.append(Transform3D(Basis(Vector3.UP, -a).scaled_local(Vector3(1.3, 2.8, 1.3)), Vector3(p.x, y + 1.4, p.y)))
		xf.append(Transform3D(b.scaled_local(sz), Vector3(p.x, y + sz.y * 0.5, p.y)))
		var w := _world(p)
		obstacles.append([Vector2(w.x, w.z), maxf(sz.x, sz.z) * 0.55 * town_scale])
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
		for d in range(int(town_radius), int(town_radius) + 40):
			var x := town_centre.x + cos(a) * d
			var z := town_centre.z + sin(a) * d
			if absf(x) > SIZE * 0.47 or absf(z) > SIZE * 0.47:
				break
			if _height_at(x, z) < sea_level - 0.3:
				if d < best_d:
					best_d = d
					best_a = a
				break
	if best_a < 0.0:
		return
	var dir := Vector2(cos(best_a), sin(best_a))
	var shore := dir * (best_d - 1.0) / town_scale
	var root := Node3D.new()
	root.position = Vector3(shore.x, (sea_level + 0.3) / town_scale, shore.y)
	root.rotation.y = atan2(dir.x, dir.y)
	town.add_child(root)
	_part(root, "box", wood, Vector3(0, -0.1, 3.0), Vector3(1.6, 0.15, 6.5))
	for k in 4:
		for sx in [-0.7, 0.7]:
			_part(root, "cyl", wood, Vector3(sx, -1.5, 0.6 + k * 1.7), Vector3(0.18, 1.5, 0.18))
	_part(root, "box", _mat(Color(0.6, 0.42, 0.25)), Vector3(0, 0.05, 6.4), Vector3(1.2, 0.5, 1.0))
	_add_site("Harbour", shore - dir * 0.8, shore + dir * 3.0)


## Fields just outside the town: rows of crops on flat dry land, where
## townsfolk work by day.
func _build_fields(brng: RandomNumberGenerator, ring: float) -> void:
	var crops: Array = []
	var ripe := Color(0.78, 0.66, 0.25) if brng.randf() < 0.5 else Color(0.36, 0.55, 0.2)
	var plots := 0
	for attempt in 24:
		if plots >= 3:
			break
		var a := brng.randf() * TAU
		var c := Vector2(cos(a), sin(a)) * (ring + 3.0)
		var cw := _world(c)
		if absf(cw.x) > SIZE * 0.44 or absf(cw.z) > SIZE * 0.44 or not _dry(c, 0.5) or _slope_at(cw.x, cw.z) > 0.15:
			continue
		var clash := false
		for s in sites:
			if s["name"] == "Field" and (s["pos"] as Vector3).distance_to(cw) < 8.0 * town_scale:
				clash = true
		if clash or _blocked(Vector2(cw.x, cw.z), 2.0 * town_scale):
			continue
		plots += 1
		var along := Vector2(-sin(a), cos(a))
		var out := Vector2(cos(a), sin(a))
		for row in 5:
			for k in 10:
				var p := c + along * (k - 4.5) * 0.45 + out * (row - 2) * 0.55
				var gy := _ground(p)
				var h := 0.35 + brng.randf() * 0.15
				crops.append(Transform3D(Basis(Vector3.UP, a).scaled_local(Vector3(0.22, h, 0.22)), Vector3(p.x, gy + h * 0.5, p.y)))
		_add_site("Field", c - out * 1.6, c)
		_paint_rect(cw, along, out, 2.6 * town_scale, 1.6 * town_scale, 0.85)
	_scatter("cone", _mat(ripe), crops, false)


func _trodden_at(x: float, z: float) -> float:
	if trodden == null:
		return 0.0
	var w := trodden.get_width()
	var px := int(((x - trodden_origin.x) / (2.0 * trodden_half) + 0.5) * w)
	var pz := int(((z - trodden_origin.y) / (2.0 * trodden_half) + 0.5) * w)
	if px < 0 or pz < 0 or px >= w or pz >= w:
		return 0.0
	return trodden.get_pixel(px, pz).r


func _paint(x: float, z: float, radius: float, strength: float) -> void:
	var w := trodden.get_width()
	var cx := ((x - trodden_origin.x) / (2.0 * trodden_half) + 0.5) * w
	var cz := ((z - trodden_origin.y) / (2.0 * trodden_half) + 0.5) * w
	var r := radius / (2.0 * trodden_half) * w
	for pz in range(int(cz - r - 1), int(cz + r + 2)):
		for px in range(int(cx - r - 1), int(cx + r + 2)):
			if px < 0 or pz < 0 or px >= w or pz >= w:
				continue
			var d := Vector2(px + 0.5 - cx, pz + 0.5 - cz).length()
			var v := strength * (1.0 - smoothstep(r * 0.5, r + 0.5, d))
			if v > trodden.get_pixel(px, pz).r:
				trodden.set_pixel(px, pz, Color(v, v, v))


func _paint_line(a: Vector3, b: Vector3, width: float, strength: float) -> void:
	var n := int(a.distance_to(b) / 0.6) + 1
	for i in n + 1:
		var p := a.lerp(b, float(i) / n)
		_paint(p.x, p.z, width, strength)


func _paint_rect(c: Vector3, along: Vector2, out: Vector2, half_a: float, half_o: float, strength: float) -> void:
	var s := 0.0
	while s <= 1.0:
		var o := -half_o + 2.0 * half_o * s
		var p := c + Vector3(out.x, 0, out.y) * o
		_paint_line(p - Vector3(along.x, 0, along.y) * half_a, p + Vector3(along.x, 0, along.y) * half_a, 0.8, strength)
		s += 0.1


## Beaten earth: the square, and paths from it to every door and field.
func _paint_paths() -> void:
	_paint(town_centre.x, town_centre.z, (1.6 if town.name == "Farm" else 3.2) * town_scale, 0.9)
	for s in sites + huts:
		_paint_line(town_centre, s["pos"], 0.9, 0.75)


func _make_building(n: String, root: Node3D, civ: Color, wood: Material, stone: Material, dark: Material, roof: Material) -> void:
	var pale := _mat(Color(0.82, 0.8, 0.72))
	match n:
		"Longhouse":
			_part(root, "box", wood, Vector3.ZERO, Vector3(1.9, 1.3, 5.0))
			_part(root, "prism", roof, Vector3(0, 1.3, 0), Vector3(2.4, 1.0, 5.3))
			_part(root, "box", window_mat, Vector3(0, 0, 2.51), Vector3(0.6, 0.85, 0.05))
		"Workshop", "Forge":
			var forge := n == "Forge"
			_part(root, "box", dark if forge else wood, Vector3.ZERO, Vector3(2.6, 1.6, 2.6))
			_part(root, "box", roof, Vector3(0, 1.6, 0), Vector3(2.9, 0.25, 2.9))
			_part(root, "cyl", stone, Vector3(0.8, 1.85, 0.8), Vector3(0.55, 1.5, 0.55))
			if forge:
				_part(root, "cyl", _mat(Color(1.0, 0.45, 0.1), 2.5), Vector3(0.8, 3.3, 0.8), Vector3(0.4, 0.15, 0.4))
				_part(root, "box", _mat(Color(1.0, 0.4, 0.1), 2.0), Vector3(0, 0.2, 1.31), Vector3(1.0, 0.7, 0.05))
				_part(root, "box", dark, Vector3(0.4, 0, 1.9), Vector3(0.5, 0.45, 0.35))  # Anvil.
			else:
				_part(root, "box", window_mat, Vector3(0, 0, 1.31), Vector3(0.6, 0.9, 0.05))
				_part(root, "box", wood, Vector3(-0.8, 0, 1.7), Vector3(0.5, 0.45, 0.5))  # Crates.
				_part(root, "box", wood, Vector3(-0.2, 0, 1.8), Vector3(0.4, 0.35, 0.4))
		"Granary":
			_part(root, "cyl", wood, Vector3.ZERO, Vector3(2.2, 1.6, 2.2))
			_part(root, "dome", _mat(Color(0.75, 0.62, 0.3)), Vector3(0, 1.4, 0), Vector3(2.4, 1.3, 2.4))
			_part(root, "box", window_mat, Vector3(0, 0, 1.08), Vector3(0.55, 0.8, 0.05))
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
			_part(root, "box", window_mat, Vector3(0, 0.3, 0.81), Vector3(0.7, 1.2, 0.05))
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
			_part(root, "box", window_mat, Vector3(0, 0.8, 1.61), Vector3(0.8, 1.3, 0.05))
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
			_part(root, "box", window_mat, Vector3(0, 0, 1.76), Vector3(1.2, 1.4, 0.05))
			for k in 2:
				_part(root, "cyl", _mat(Color(0.5, 0.28, 0.22)), Vector3(-1.3 + k * 2.0, 2.7, -0.9), Vector3(0.8, 4.5, 0.8))
				_part(root, "cyl", dark, Vector3(-1.3 + k * 2.0, 7.0, -0.9), Vector3(0.95, 0.3, 0.95))
