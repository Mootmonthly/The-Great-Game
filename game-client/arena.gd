extends Control
## Local arena prototype (roadmap Phase 2): champions from your world fight
## champions from a rival world under a shared cost cap.
##
## The match itself runs in the Rust core (`ArenaSim`, sim-core/src/arena.rs):
## deterministic, so a server can replay it from the rosters, seed and
## player commands (docs/GAME_DESIGN.md §6.3). This script only renders it
## and forwards input. Click a friendly unit to possess it: WASD moves it,
## Space attacks, Q breathes, Esc releases it.
##
## Online, `NetClient` takes ArenaSim's place: the arena server verifies
## the champions, finds an opponent and runs the match; the client steps an
## identical copy in lockstep and renders it the same way.

signal closed

const CreatureBuilder := preload("res://creature_builder.gd")
const ARENA_RADIUS := 16.0
## Sides with more units than this are drawn as simple shapes (one
## MultiMesh per side) instead of full creature models.
const SIMPLE_ABOVE := 60
const CAPS := [25, 50, 100, 250, 1000]
const MAX_UNITS_PER_SIDE := 500
const SIZE_SCALE := {"Tiny": 0.8, "Small": 1.1, "Medium": 1.5, "Large": 2.2, "Huge": 3.2, "Gargantuan": 4.5}
const RIVAL_PRESETS := ["earthlike", "frozen_moon", "sulfur_world"]
const DEFAULT_PORT := 7878
## Account secrets and pinned server certificates, per server.
const ONLINE_CFG := "user://online.cfg"
## Spoils of war not yet brought home or sold (grant id -> grant), and shop
## deposits bought but not yet placed (a list of grants).
const SPOILS_PATH := "user://spoils.json"
const PURCHASES_PATH := "user://purchases.json"


## What the scene shows for one arena unit; the simulation owns the rules.
class Unit:
	extends RefCounted
	var node: Node3D
	var label: Label3D
	var team := 0
	var name := ""
	var alive := true
	var hp := 0
	var max_hp := 0
	var radius := 0.5
	## Drawn as an instance of its side's MultiMesh rather than a model.
	var simple := false
	var mm_index := -1
	var color := Color.WHITE
	## Presentation state: the simulation's latest position and facing, the
	## smoothed ones drawn, and timers (seconds) for the attack lunge, hit
	## flash and death animation (negative while not running).
	var seen := false
	var has_breath := false
	var breath_ready := false
	var target_pos := Vector3.ZERO
	var vis_pos := Vector3.ZERO
	var target_yaw := 0.0
	var yaw := 0.0
	var lunge_t := -1.0
	var lunge_dir := Vector3.ZERO
	var flash_t := -1.0
	var death_t := -1.0
	var shown_frac := 1.0
	## Modelled units only: the part that lunges, topples and shrinks, the
	## meshes that take the flash overlay, and the decorations.
	var body: Node3D
	var meshes: Array = []
	var flash_mat: StandardMaterial3D
	var ring_mat: StandardMaterial3D
	var disc_mat: StandardMaterial3D
	var bar: MeshInstance3D
	var dirty := true
	var flash_color := Color.WHITE


var sim: RefCounted
var rival: RefCounted
var rival_ready := false
## Seasons the rival world still has to evolve; done a few per frame so the
## UI stays responsive (the simulation must run on the main thread).
var rival_ticks_left := 0
const RIVAL_TICKS := 2400

var my_roster: Array = []
var rival_roster: Array = []
var my_counts := {}
var cap := 100

var units: Array = []
var running := false
var finished := false
## Playback speed relative to the normal pace (0 pauses). Offline battles
## run at OFFLINE_PACE of arena time at x1; online the server sets the pace.
var speed := 1.0
const OFFLINE_PACE := 0.5
const SPEEDS := [0.0, 0.5, 1.0, 2.0, 4.0]
const SPEED_NAMES := ["⏸", "×½", "×1", "×2", "×4"]
var speed_buttons: Array = []
var possessed := -1
var arena_sim: RefCounted
var tick_budget := 0.0
var last_steer := Vector2.ZERO
var state: Dictionary = {}
var log_lines: Array = []
var rng := RandomNumberGenerator.new()

# Online play.
var net: RefCounted
var online := false
var my_team := 0
var my_name := ""
var pending_binds: Array = []
var bound_tokens: Array = []
var host_edit: LineEdit
var name_edit: LineEdit
var mode_select: OptionButton
var online_button: Button
var online_label: Label
var match_end: Dictionary = {}
var server_key := ""
var resuming := false
var rejoin_button: Button
## Connected only to shop and sell, not to queue for a match.
var signin_only := false
var signed_in := false
var essence := 0
var planet_slots := 1
var shop_items: Array = []
var shop_buttons: Array = []
var buy_busy := false
var spoils: Dictionary = {}
var spoils_busy := {}
var purchases: Array = []
var essence_label: Label
var shop_note: Label
var signin_button: Button
## Containers listing the undecided spoils (the setup panel's and, after a
## match, the battle screen's), and the one listing unplaced deposits.
var spoil_boxes: Array = []
var purchase_box: VBoxContainer
## Online, the possessed unit is drawn slightly ahead of the server's
## position in the direction you steer, so it reacts at once.
var predicted_offset := Vector3.ZERO
var prediction_tau := 0.15

var setup_panel: Control
var roster_label: RichTextLabel
var rival_label: RichTextLabel
var cap_select: OptionButton
var total_label: Label
var fight_button: Button
var battle_ui: Control
var status_label: Label
var log_label: RichTextLabel
var help_label: Label
var viewport_box: SubViewportContainer
var viewport: SubViewport
var world: Node3D
var camera: Camera3D
var cam_yaw := 0.6
var cam_zoom := 1.0
## The battlefield (ground, patches, shrine) is rebuilt for every match.
var field_root: Node3D
var field: Dictionary = {}
var field_radius := ARENA_RADIUS
var shrine_ring_mat: StandardMaterial3D
var shrine_pillar_mat: StandardMaterial3D
var shrine_tint := -2
var multimeshes: Array = [null, null]
var possess_marker: MeshInstance3D
var battlefield_select: OptionButton
var biomes: Array = []
var probe: RefCounted
var _simple_count := [0, 0]

# Battle presentation (health bars, hit effects, kill feed, header).
const TEAM_COLORS := [Color(0.35, 0.7, 1.0), Color(1.0, 0.4, 0.35)]
## Floating numbers, tracers and puffs alive at once; big battles hit the cap.
const MAX_NUMBERS := 40
const MAX_TRACERS := 24
const MAX_PUFFS := 30
## Hit effects derived per sync; the rest of a big battle's hits are skipped.
const MAX_HITS_PER_SYNC := 24
const KILL_FEED_LINES := 6
const KILL_FEED_SECONDS := 9.0
## Show name labels over units only in small battles.
const LABELS_BELOW := 30
const DEATH_TIME := 1.2
const LUNGE_TIME := 0.34
const FLASH_TIME := 0.28
var ring_mms: Array = [null, null]
var bar_mats: Array = [null, null]
var bar_mesh: QuadMesh
var number_pool: Array = []
var tracer_pool: Array = []
var puff_pool: Array = []
var fx_root: Node3D
var puff_mesh: SphereMesh
var tracer_mesh: BoxMesh
var kill_feed: Array = []
var kill_label: RichTextLabel
var kill_feed_timer := 0.0
var hud: Control
var header_bars: Array = []
var header_labels: Array = []
var start_units := [0, 0]
var start_cost := [0, 0]
var hits_flip := 0
var active_numbers: Array = []
var active_tracers: Array = []
var active_puffs: Array = []


func open(world_sim: RefCounted) -> void:
	sim = world_sim
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_scene()
	_build_setup()
	_load_my_roster()
	_start_rival()
	_load_spoils()
	_load_purchases()
	_refresh_spoils()
	_refresh_purchases()
	_refresh_shop()


func close() -> void:
	if net:
		net.close_connection()
	closed.emit()
	queue_free()


# --- 3D stage ---------------------------------------------------------------

func _build_scene() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.08)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	viewport_box = SubViewportContainer.new()
	viewport_box.stretch = true
	viewport_box.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	viewport_box.gui_input.connect(_on_view_input)
	add_child(viewport_box)
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	viewport_box.add_child(viewport)
	world = Node3D.new()
	viewport.add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.12, 0.13, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.4, 0.48)
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 30, 0)
	world.add_child(sun)
	_build_field({})
	camera = Camera3D.new()
	camera.fov = 50.0
	world.add_child(camera)
	_overview_camera()


const GROUND_COLORS := {
	"Open field": Color(0.55, 0.47, 0.36), "Plains": Color(0.42, 0.55, 0.28), "Forest": Color(0.3, 0.42, 0.22),
	"Archipelago": Color(0.8, 0.74, 0.5), "Ice field": Color(0.82, 0.88, 0.92), "Lava field": Color(0.22, 0.18, 0.17),
	"Rocky desert": Color(0.7, 0.55, 0.35),
}


func _toon(color: Color) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = preload("res://shaders/creature.gdshader")
	m.set_shader_parameter("base_color", color)
	return m


func _flat(color: Color, alpha := 1.0, glow := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(color, alpha)
	m.roughness = 1.0
	if alpha < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = color
		m.emission_energy_multiplier = glow
	return m


func _disc(parent: Node3D, pos: Vector3, radius: float, height: float, mat: Material, top_scale := 1.0) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius * top_scale
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = 32
	mesh.rings = 1
	var n := MeshInstance3D.new()
	n.mesh = mesh
	n.material_override = mat
	n.position = pos + Vector3(0, height * 0.5, 0)
	parent.add_child(n)
	return n


## Ground disc, edge pillars, terrain patches and the shrine for `f` (the
## field_json of a match; empty for the default open arena).
func _build_field(f: Dictionary) -> void:
	if field_root:
		field_root.queue_free()
	field_root = Node3D.new()
	world.add_child(field_root)
	field = f
	field_radius = float(f.get("radius", ARENA_RADIUS))
	var r := field_radius
	var floor_mesh := CylinderMesh.new()
	floor_mesh.top_radius = r + 2.0
	floor_mesh.bottom_radius = r + 2.5
	floor_mesh.height = 0.6
	floor_mesh.radial_segments = 96
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	floor_node.position.y = -0.3
	floor_node.material_override = _toon(GROUND_COLORS.get(str(f.get("biome", "Open field")), GROUND_COLORS["Open field"]))
	field_root.add_child(floor_node)
	# A ring of pillars marks the edge.
	var pillars := 16 if r < 24.0 else 32
	for i in pillars:
		var a := TAU * i / pillars
		var p := Vector3(cos(a) * (r + 1.2), 0, sin(a) * (r + 1.2))
		var pillar := _disc(field_root, p, 0.45, 3.0, _toon(Color(0.7, 0.66, 0.6)), 0.78)
		pillar.name = "Pillar%d" % i
	for patch in f.get("patches", []):
		_build_patch(patch)
	# The central shrine.
	var orad := float(f.get("objective_radius", 3.0))
	shrine_ring_mat = _flat(Color(0.8, 0.8, 0.75), 0.9)
	shrine_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = orad - 0.12
	torus.outer_radius = orad + 0.12
	torus.rings = 48
	ring.mesh = torus
	ring.material_override = shrine_ring_mat
	ring.position.y = 0.1
	field_root.add_child(ring)
	shrine_pillar_mat = _flat(Color(0.8, 0.8, 0.75), 1.0, 0.4)
	_disc(field_root, Vector3.ZERO, 0.4, 1.8, shrine_pillar_mat, 0.6)
	shrine_tint = -2
	if camera:
		_overview_camera()


func _build_patch(patch: Dictionary) -> void:
	var pos := Vector3(float(patch["x"]), 0, float(patch["z"]))
	var pr := float(patch["radius"])
	match str(patch["ground"]):
		"water":
			_disc(field_root, pos + Vector3(0, 0.03, 0), pr, 0.04, _flat(Color(0.2, 0.45, 0.9), 0.55))
		"lava":
			_disc(field_root, pos + Vector3(0, 0.04, 0), pr, 0.05, _flat(Color(1.0, 0.45, 0.05), 1.0, 2.0))
		"ice":
			_disc(field_root, pos + Vector3(0, 0.03, 0), pr, 0.04, _flat(Color(0.85, 0.94, 1.0), 0.9))
		"trees":
			_disc(field_root, pos + Vector3(0, 0.02, 0), pr, 0.03, _flat(Color(0.1, 0.28, 0.1)))
			var trng := RandomNumberGenerator.new()
			trng.seed = hash(Vector2(pos.x, pos.z)) + 7
			var trunk_mat := _toon(Color(0.4, 0.27, 0.15))
			var leaf_mat := _toon(Color(0.12, 0.38, 0.14))
			for i in clampi(int(pr * pr * 0.35), 3, 24):
				var ang := trng.randf() * TAU
				var dist := sqrt(trng.randf()) * pr * 0.9
				var tp := pos + Vector3(cos(ang) * dist, 0, sin(ang) * dist)
				var h := 1.4 + trng.randf() * 0.8
				_disc(field_root, tp, 0.12, h * 0.4, trunk_mat)
				var cone := CylinderMesh.new()
				cone.top_radius = 0.0
				cone.bottom_radius = 0.55 + trng.randf() * 0.2
				cone.height = h
				cone.radial_segments = 8
				var cn := MeshInstance3D.new()
				cn.mesh = cone
				cn.material_override = leaf_mat
				cn.position = tp + Vector3(0, h * 0.4 + h * 0.5, 0)
				field_root.add_child(cn)
		"rock":
			_disc(field_root, pos, pr, 1.6, _toon(Color(0.5, 0.5, 0.52)), 0.85)


## Tints the shrine with the colour of the side holding it.
func _tint_shrine(holder: int) -> void:
	if holder == shrine_tint or shrine_ring_mat == null:
		return
	shrine_tint = holder
	var c := Color(0.8, 0.8, 0.75)
	if holder >= 0:
		c = Color(0.35, 0.7, 1.0) if holder == my_team else Color(1.0, 0.4, 0.35)
	shrine_ring_mat.albedo_color = Color(c, 0.9)
	shrine_pillar_mat.albedo_color = c
	shrine_pillar_mat.emission = c


func _overview_camera() -> void:
	var k := field_radius / ARENA_RADIUS * cam_zoom
	camera.position = Vector3(sin(cam_yaw) * 21.0 * k, 14.0 * k, cos(cam_yaw) * 21.0 * k)
	camera.look_at(Vector3.ZERO, Vector3.UP)


# --- Team setup -------------------------------------------------------------

func _build_setup() -> void:
	setup_panel = PanelContainer.new()
	setup_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	setup_panel.custom_minimum_size = Vector2(1100, 640)
	setup_panel.position = Vector2(-550, -320)
	add_child(setup_panel)
	var v := VBoxContainer.new()
	setup_panel.add_child(v)
	var title := Label.new()
	title.text = "Arena — choose your champions"
	title.add_theme_font_size_override("font_size", 22)
	v.add_child(title)
	var row := HBoxContainer.new()
	v.add_child(row)
	row.add_child(_label("Cost cap"))
	cap_select = OptionButton.new()
	for c in CAPS:
		cap_select.add_item(str(c))
	cap_select.select(2)
	cap_select.item_selected.connect(func(i):
		cap = CAPS[i]
		_auto_pick_rival()
		_refresh_setup())
	row.add_child(cap_select)
	row.add_child(_label("Battlefield"))
	battlefield_select = OptionButton.new()
	row.add_child(battlefield_select)
	_refresh_battlefields()
	var auto := Button.new()
	auto.text = "Auto-pick my team"
	auto.pressed.connect(func():
		my_counts = _auto_pick(my_roster)
		_refresh_setup())
	row.add_child(auto)
	var clear := Button.new()
	clear.text = "Clear"
	clear.pressed.connect(func():
		my_counts.clear()
		_refresh_setup())
	row.add_child(clear)
	total_label = _label("")
	row.add_child(total_label)
	var cols := HBoxContainer.new()
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(cols)
	roster_label = RichTextLabel.new()
	roster_label.bbcode_enabled = true
	roster_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	roster_label.meta_clicked.connect(_on_roster_meta)
	cols.add_child(roster_label)
	rival_label = RichTextLabel.new()
	rival_label.bbcode_enabled = true
	rival_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rival_label.text = "[b]Rival world[/b]\nA rival world is evolving…"
	cols.add_child(rival_label)
	var buttons := HBoxContainer.new()
	v.add_child(buttons)
	fight_button = Button.new()
	fight_button.text = "Fight!"
	fight_button.disabled = true
	fight_button.pressed.connect(_start_battle)
	buttons.add_child(fight_button)
	var back := Button.new()
	back.text = "Back to world"
	back.pressed.connect(close)
	buttons.add_child(back)

	# Online: the server verifies your champions and finds an opponent.
	var online_row := HBoxContainer.new()
	v.add_child(online_row)
	online_row.add_child(_label("Online — server"))
	host_edit = LineEdit.new()
	host_edit.text = "127.0.0.1:%d" % DEFAULT_PORT
	host_edit.custom_minimum_size = Vector2(170, 0)
	online_row.add_child(host_edit)
	online_row.add_child(_label("Name"))
	name_edit = LineEdit.new()
	rng.randomize()
	name_edit.text = "player%d" % (rng.randi() % 10000)
	name_edit.custom_minimum_size = Vector2(120, 0)
	online_row.add_child(name_edit)
	mode_select = OptionButton.new()
	mode_select.add_item("Ranked (permadeath)")
	mode_select.add_item("Practice")
	online_row.add_child(mode_select)
	online_button = Button.new()
	online_button.text = "Find online match"
	online_button.pressed.connect(find_online_match)
	online_row.add_child(online_button)
	var forget := Button.new()
	forget.text = "Forget server certificate"
	forget.tooltip_text = "Use if the server was reinstalled and its certificate changed on purpose."
	forget.pressed.connect(func():
		var cfg := _online_cfg()
		cfg.set_value(_server_key(), "pin", "")
		cfg.save(ONLINE_CFG)
		online_label.text = "Forgot the saved certificate for %s." % _server_key())
	online_row.add_child(forget)
	online_label = _label("")
	v.add_child(online_label)
	_build_shop(v)


## The Essence shop, undecided spoils and unplaced purchases, in a scroll
## box under the online controls.
func _build_shop(v: Control) -> void:
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 130)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(box)
	var head := HBoxContainer.new()
	box.add_child(head)
	head.add_child(_label("Essence shop"))
	essence_label = _label("")
	head.add_child(essence_label)
	signin_button = Button.new()
	signin_button.text = "Sign in to shop"
	signin_button.tooltip_text = "Connect to the server to buy items and sell spoils, without queueing for a match."
	signin_button.pressed.connect(func(): _connect(true))
	head.add_child(signin_button)
	var items := HFlowContainer.new()
	box.add_child(items)
	shop_items = JSON.parse_string(sim.shop_catalogue_json())
	for entry in shop_items:
		var b := Button.new()
		b.text = "%s — %d Essence" % [entry["name"], int(entry["price"])]
		b.pressed.connect(_buy.bind(entry))
		items.add_child(b)
		shop_buttons.append(b)
	var spoil_box := VBoxContainer.new()
	box.add_child(spoil_box)
	spoil_boxes.append(spoil_box)
	purchase_box = VBoxContainer.new()
	box.add_child(purchase_box)


## Fills the Battlefield picker; keeps the selection across refreshes.
func _refresh_battlefields() -> void:
	if probe == null:
		probe = ClassDB.instantiate("ArenaSim")
		biomes = JSON.parse_string(probe.biomes_json())
	var keep := battlefield_select.selected
	battlefield_select.clear()
	battlefield_select.add_item("Home: %s" % _biome_name(probe.home_biome(sim, -1)))
	if rival_ready and rival:
		battlefield_select.add_item("Rival's home: %s" % _biome_name(probe.home_biome(rival, -1)))
	else:
		battlefield_select.add_item("Rival's home: (rival evolving)")
	battlefield_select.add_item("Random")
	for b in biomes:
		battlefield_select.add_item(str(b["name"]))
	battlefield_select.select(maxi(keep, 0))


func _biome_name(index: int) -> String:
	for b in biomes:
		if int(b["index"]) == index:
			return str(b["name"])
	return "Open field"


## The biome index picked in the Battlefield box.
func _chosen_biome() -> int:
	var sel := battlefield_select.selected
	if sel == 0:
		return probe.home_biome(sim, -1)
	if sel == 1:
		return probe.home_biome(rival, -1) if rival_ready and rival else 0
	if sel == 2:
		return biomes[rng.randi() % biomes.size()]["index"]
	return int(biomes[sel - 3]["index"])


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


## Candidate champions from a world: the strongest species (any number of
## copies) and the most renowned named individuals (one each).
static func roster_of(world_sim: RefCounted) -> Array:
	var out: Array = _roster_here(world_sim, -1)
	# Every moon is a world of its own: read each one in turn, then put the
	# viewer's focus back.
	var focus: int = world_sim.focused_moon()
	var moon_count: int = JSON.parse_string(world_sim.moons_json())["moons"].size()
	for k in moon_count:
		if world_sim.focus_moon(k):
			out.append_array(_roster_here(world_sim, k))
	world_sim.focus_moon(focus)
	return out


## Champions of the world the simulation is focused on. `moon` is -1 for the
## planet, else the moon's index; it tags entries and keeps their keys unique.
static func _roster_here(world_sim: RefCounted, moon: int) -> Array:
	var out: Array = []
	var prefix := "" if moon < 0 else "m%d:" % moon
	var suffix := "" if moon < 0 else " (Moon %d)" % (moon + 1)
	var species: Array = JSON.parse_string(world_sim.species_json(500))
	species.sort_custom(func(a, b): return a["cost"] > b["cost"])
	var seen := {}
	for s in species:
		if seen.size() >= 16:
			break
		if seen.has(s["description"]):
			continue
		seen[s["description"]] = true
		var detail = JSON.parse_string(world_sim.species_detail_json(int(s["id"])))
		var sheet = JSON.parse_string(world_sim.sheet_json("species", int(s["id"])))
		out.append({"key": "%ss%d" % [prefix, int(s["id"])], "name": s["name"] + suffix, "moon": moon, "hero": false, "detail": detail, "sheet": sheet, "cost": int(sheet["cost"]),
			"kind": "species", "id": int(s["id"]), "world": world_sim})
	var people: Array = JSON.parse_string(world_sim.individuals_json(300))
	people.sort_custom(func(a, b): return (a["cost"] if a["cost"] != null else 0) > (b["cost"] if b["cost"] != null else 0))
	for p in people.slice(0, 4):
		var sheet = JSON.parse_string(world_sim.sheet_json("individual", int(p["id"])))
		var detail = JSON.parse_string(world_sim.species_detail_json(int(p["species_id"])))
		if sheet == null or detail == null:
			continue
		out.append({"key": "%si%d" % [prefix, int(p["id"])], "name": p["title"] + suffix, "moon": moon, "hero": true, "detail": detail, "sheet": sheet, "cost": int(sheet["cost"]),
			"kind": "individual", "id": int(p["id"]), "world": world_sim})
	return out


func _load_my_roster() -> void:
	my_roster = roster_of(sim)
	my_counts = _auto_pick(my_roster)
	_refresh_setup()


## Greedy pick: most expensive affordable champion first, heroes once.
func _auto_pick(roster: Array) -> Dictionary:
	var counts := {}
	var left := cap
	var units_left := MAX_UNITS_PER_SIDE
	var sorted := roster.duplicate()
	sorted.sort_custom(func(a, b): return a["cost"] > b["cost"])
	var progress := true
	while progress and units_left > 0:
		progress = false
		for c in sorted:
			if c["cost"] <= left and units_left > 0 and not (c["hero"] and counts.has(c["key"])):
				counts[c["key"]] = counts.get(c["key"], 0) + 1
				left -= c["cost"]
				units_left -= 1
				progress = true
				break
	return counts


func _team_cost(roster: Array, counts: Dictionary) -> int:
	var total := 0
	for c in roster:
		total += c["cost"] * counts.get(c["key"], 0)
	return total


func _on_roster_meta(meta) -> void:
	var m := str(meta)
	var key := m.substr(1)
	var entry = null
	for c in my_roster:
		if c["key"] == key:
			entry = c
	if entry == null:
		return
	var n: int = my_counts.get(key, 0)
	if m.begins_with("+"):
		var units := 0
		for v in my_counts.values():
			units += v
		if _team_cost(my_roster, my_counts) + entry["cost"] <= cap and units < MAX_UNITS_PER_SIDE and not (entry["hero"] and n > 0):
			my_counts[key] = n + 1
	elif n > 0:
		my_counts[key] = n - 1
	_refresh_setup()


func _refresh_setup() -> void:
	var t := "[b]Your world[/b] (click + / − to change)\n"
	for c in my_roster:
		var n: int = my_counts.get(c["key"], 0)
		var sh: Dictionary = c["sheet"]
		t += "[url=-%s][ − ][/url] [url=+%s][ + ][/url] %s[color=#%s]■[/color] [b]%s[/b]%s — cost %d · %s %s · HP %d, AC %d\n" % [
			c["key"], c["key"], "[b]×%d[/b] " % n if n > 0 else "", c["detail"]["color"], c["name"],
			" ★" if c["hero"] else "", c["cost"], sh["size"], sh["type"].to_lower(), sh["hit_points"], sh["armor_class"]]
	roster_label.text = t
	total_label.text = "Your team: %d / %d" % [_team_cost(my_roster, my_counts), cap]
	if rival_ready:
		var counts := _auto_pick(rival_roster)
		var rt := "[b]Rival world[/b] (%s)\n" % rival.get_meta("preset")
		for c in rival_roster:
			var n: int = counts.get(c["key"], 0)
			if n > 0:
				rt += "[b]×%d[/b] [color=#%s]■[/color] %s — cost %d · %s\n" % [n, c["detail"]["color"], c["name"], c["cost"], c["sheet"]["size"]]
		rt += "\nRival team: %d / %d" % [_team_cost(rival_roster, counts), cap]
		rival_label.text = rt
	fight_button.disabled = not rival_ready or _team_cost(my_roster, my_counts) == 0


# --- Rival world (evolved on a background thread) ---------------------------

func _start_rival() -> void:
	rng.randomize()
	rival = ClassDB.instantiate("SimWorld")
	var preset: String = RIVAL_PRESETS[rng.randi() % RIVAL_PRESETS.size()]
	rival.set_meta("preset", preset)
	rival.new_world(rng.randi() % 100000, preset)
	rival_ticks_left = RIVAL_TICKS


func _auto_pick_rival() -> void:
	if rival_ready:
		_refresh_setup()


func _process(delta: float) -> void:
	if not rival_ready and rival_ticks_left > 0:
		var n: int = min(rival_ticks_left, 24)
		rival.tick(n)
		rival_ticks_left -= n
		rival_label.text = "[b]Rival world[/b] (%s)\nA rival world is evolving… year %d of %d" % [
			rival.get_meta("preset"), (RIVAL_TICKS - rival_ticks_left) / 4, RIVAL_TICKS / 4]
		if rival_ticks_left == 0:
			rival_roster = roster_of(rival)
			rival_ready = true
			_refresh_battlefields()
			_refresh_setup()
	if net:
		_poll_net()
	if running and not finished:
		step(delta * speed * (1.0 if online else OFFLINE_PACE))
	if running:
		_animate(delta)
	_update_camera(delta)


## Starts a battle immediately with the given rival roster (used by tests
## and when the rival world is ready).
func use_rival_roster(roster: Array, preset := "test") -> void:
	rival_ticks_left = 0
	rival = ClassDB.instantiate("SimWorld")
	rival.set_meta("preset", preset)
	rival_roster = roster
	rival_ready = true
	_refresh_battlefields()
	_refresh_setup()


# --- Battle -----------------------------------------------------------------

func _spawn(entry: Dictionary, team: int, simple := false) -> void:
	var u := Unit.new()
	u.team = team
	u.name = entry["name"]
	var size: String = entry["sheet"]["size"]
	if simple:
		# Large armies: a bare position holder; the side's MultiMesh draws it.
		u.simple = true
		u.color = Color.html("#" + str(entry["detail"]["color"]).trim_prefix("#")).lerp(_team_color(team), 0.55)
		u.node = Node3D.new()
		world.add_child(u.node)
		u.mm_index = _simple_count[team]
		_simple_count[team] += 1
		units.append(u)
		return
	var model := CreatureBuilder.build(entry["detail"])
	var box := CreatureBuilder.bounds(model)
	var extent: float = max(box.size.x, max(box.size.y, box.size.z))
	var s: float = SIZE_SCALE.get(size, 1.0) / max(extent, 0.01)
	model.scale = Vector3.ONE * s
	model.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)
	var holder := Node3D.new()
	u.body = Node3D.new()
	holder.add_child(u.body)
	u.body.add_child(model)
	for m in model.find_children("*", "MeshInstance3D", true, false):
		u.meshes.append(m)
	u.flash_mat = StandardMaterial3D.new()
	u.flash_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	u.flash_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	u.flash_mat.albedo_color = Color(1, 1, 1, 0)
	var team_col := _team_color(team)
	# Team marking on the ground: a translucent disc inside a bright ring.
	var size_r: float = SIZE_SCALE.get(size, 1.0) * 0.38
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = size_r
	torus.outer_radius = size_r + 0.1
	ring.mesh = torus
	u.ring_mat = StandardMaterial3D.new()
	u.ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	u.ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	u.ring_mat.albedo_color = team_col
	ring.material_override = u.ring_mat
	ring.position.y = 0.06
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(ring)
	var disc := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = size_r
	cyl.bottom_radius = size_r
	cyl.height = 0.02
	cyl.radial_segments = 24
	cyl.rings = 1
	disc.mesh = cyl
	u.disc_mat = StandardMaterial3D.new()
	u.disc_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	u.disc_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	u.disc_mat.albedo_color = Color(team_col, 0.2)
	disc.material_override = u.disc_mat
	disc.position.y = 0.03
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(disc)
	# Health bar and name label above the head.
	var top: float = SIZE_SCALE.get(size, 1.0) + 0.35
	u.bar = MeshInstance3D.new()
	u.bar.mesh = _bar_mesh()
	u.bar.material_override = _bar_material(team)
	u.bar.scale = Vector3.ONE * clampf(SIZE_SCALE.get(size, 1.0) * 0.55, 0.9, 2.0)
	u.bar.position.y = top
	u.bar.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(u.bar)
	world.add_child(holder)
	u.node = holder
	u.label = Label3D.new()
	u.label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	u.label.font_size = 28
	u.label.pixel_size = 0.014
	u.label.outline_size = 6
	u.label.no_depth_test = true
	u.label.modulate = Color(0.6, 0.85, 1.0) if team == my_team else Color(1.0, 0.6, 0.55)
	u.label.position = Vector3(0, top + 0.5, 0)
	holder.add_child(u.label)
	units.append(u)


func _team_color(team: int) -> Color:
	return TEAM_COLORS[0 if team == my_team else 1]


func _bar_mesh() -> QuadMesh:
	if bar_mesh == null:
		bar_mesh = QuadMesh.new()
		bar_mesh.size = Vector2(1.5, 0.2)
	return bar_mesh


## One health-bar material per side (the fill fraction is per instance).
func _bar_material(team: int) -> ShaderMaterial:
	if bar_mats[team] == null:
		var m := ShaderMaterial.new()
		m.shader = preload("res://shaders/arena_bar.gdshader")
		m.set_shader_parameter("team_color", _team_color(team))
		m.render_priority = 5
		bar_mats[team] = m
	return bar_mats[team]


## Removes the previous match's units and simple-shape instances.
func _clear_units() -> void:
	for u in units:
		u.node.queue_free()
	units.clear()
	for i in 2:
		if multimeshes[i]:
			multimeshes[i].queue_free()
			multimeshes[i] = null
	_simple_count = [0, 0]
	for i in 2:
		if ring_mms[i]:
			ring_mms[i].queue_free()
			ring_mms[i] = null
	bar_mats = [null, null]
	if fx_root:
		fx_root.queue_free()
		fx_root = null
	number_pool.clear()
	tracer_pool.clear()
	puff_pool.clear()
	kill_feed.clear()
	active_numbers.clear()
	active_tracers.clear()
	active_puffs.clear()
	if possess_marker:
		possess_marker.queue_free()
		possess_marker = null


## One MultiMeshInstance3D per side with `count` capsule instances.
func _make_multimesh(team: int, count: int) -> void:
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.8
	mesh.radial_segments = 8
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mesh.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	var inst := MultiMeshInstance3D.new()
	inst.multimesh = mm
	inst.custom_aabb = AABB(Vector3(-200, -5, -200), Vector3(400, 20, 400))
	world.add_child(inst)
	multimeshes[team] = inst
	# Flat team-coloured rings on the ground under every unit of the side.
	var ring := TorusMesh.new()
	ring.inner_radius = 0.62
	ring.outer_radius = 0.78
	ring.rings = 16
	ring.ring_segments = 6
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.vertex_color_use_as_albedo = true
	ring.material = rmat
	var rmm := MultiMesh.new()
	rmm.transform_format = MultiMesh.TRANSFORM_3D
	rmm.use_colors = true
	rmm.mesh = ring
	rmm.instance_count = count
	var rinst := MultiMeshInstance3D.new()
	rinst.multimesh = rmm
	rinst.custom_aabb = inst.custom_aabb
	rinst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(rinst)
	ring_mms[team] = rinst


## Sets up the field and the unit models once a match's roster is known.
func _begin_scene(f: Dictionary, counts: Array) -> void:
	_build_field(f)
	for t in 2:
		if counts[t] > SIMPLE_ABOVE:
			_make_multimesh(t, counts[t])


func _start_battle() -> void:
	setup_panel.visible = false
	_clear_units()
	finished = false
	possessed = -1
	arena_sim = ClassDB.instantiate("ArenaSim")
	var rival_counts := _auto_pick(rival_roster)
	# Units are added in the same order as their scene nodes, so index i in
	# the simulation is units[i] here.
	var added := []
	for pair in [[my_roster, my_counts, 0], [rival_roster, rival_counts, 1]]:
		for c in pair[0]:
			for k in pair[1].get(c["key"], 0):
				if arena_sim.add_unit(c["world"], c["kind"], c["id"], pair[2], c.get("moon", -1)):
					added.append([c, pair[2]])
	arena_sim.start(rng.randi(), _chosen_biome())
	var counts := [0, 0]
	for e in added:
		counts[e[1]] += 1
	_begin_scene(JSON.parse_string(arena_sim.field_json()), counts)
	for e in added:
		_spawn(e[0], e[1], counts[e[1]] > SIMPLE_ABOVE)
	_build_battle_ui()
	running = true
	_sync()
	_log("[b]The battle begins![/b]")


func _build_battle_ui() -> void:
	if is_instance_valid(hud):
		hud.queue_free()
	_build_hud()
	battle_ui = VBoxContainer.new()
	battle_ui.position = Vector2(12, 72)
	add_child(battle_ui)
	status_label = Label.new()
	status_label.add_theme_font_size_override("font_size", 18)
	battle_ui.add_child(status_label)
	var row := HBoxContainer.new()
	battle_ui.add_child(row)
	if online:
		# The server sets the pace online.
		var give_up := Button.new()
		give_up.text = "Surrender"
		give_up.pressed.connect(func():
			if net:
				net.surrender())
		row.add_child(give_up)
		rejoin_button = Button.new()
		rejoin_button.text = "Rejoin match"
		rejoin_button.visible = false
		rejoin_button.pressed.connect(func():
			rejoin_button.visible = false
			find_online_match())
		row.add_child(rejoin_button)
	else:
		# Pause and playback speed; the current one stays highlighted.
		var group := ButtonGroup.new()
		speed_buttons.clear()
		for i in SPEEDS.size():
			var b := Button.new()
			b.text = SPEED_NAMES[i]
			b.toggle_mode = true
			b.button_group = group
			b.custom_minimum_size = Vector2(44, 0)
			b.tooltip_text = "Pause" if SPEEDS[i] == 0.0 else "Playback speed %s" % SPEED_NAMES[i]
			b.button_pressed = is_equal_approx(SPEEDS[i], speed)
			b.pressed.connect(func(): speed = SPEEDS[i])
			row.add_child(b)
			speed_buttons.append(b)
	var back := Button.new()
	back.text = "Back to world"
	back.pressed.connect(close)
	row.add_child(back)
	help_label = Label.new()
	help_label.text = "Click one of your units (blue) to possess it · WASD move · Space attack · Q breath · Esc release · drag to orbit"
	battle_ui.add_child(help_label)
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.custom_minimum_size = Vector2(560, 170)
	log_label.scroll_following = true
	log_label.add_theme_font_size_override("normal_font_size", 13)
	log_label.add_theme_font_size_override("bold_font_size", 13)
	var log_bg := StyleBoxFlat.new()
	log_bg.bg_color = Color(0, 0, 0, 0.35)
	log_bg.set_content_margin_all(6)
	log_label.add_theme_stylebox_override("normal", log_bg)
	battle_ui.add_child(log_label)


## The header (each side's standing units and surviving cost, with bars) and
## the kill feed, in a full-screen overlay that lets clicks through.
func _build_hud() -> void:
	hud = Control.new()
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hud)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.position.y = 8
	hud.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 24)
	panel.add_child(row)
	header_bars.clear()
	header_labels.clear()
	for side in 2:
		var v := VBoxContainer.new()
		v.custom_minimum_size = Vector2(230, 0)
		v.add_theme_constant_override("separation", 2)
		var l := Label.new()
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if side == 0 else HORIZONTAL_ALIGNMENT_RIGHT
		l.add_theme_font_size_override("font_size", 16)
		l.add_theme_color_override("font_color", TEAM_COLORS[side].lightened(0.2))
		v.add_child(l)
		header_labels.append(l)
		var bars := []
		for kind in 2:
			var bar := ProgressBar.new()
			bar.show_percentage = false
			bar.custom_minimum_size = Vector2(0, 9 if kind == 0 else 6)
			bar.max_value = 1.0
			bar.value = 1.0
			bar.fill_mode = ProgressBar.FILL_BEGIN_TO_END if side == 0 else ProgressBar.FILL_END_TO_BEGIN
			var fill := StyleBoxFlat.new()
			fill.bg_color = TEAM_COLORS[side] if kind == 0 else TEAM_COLORS[side].darkened(0.35)
			var back := StyleBoxFlat.new()
			back.bg_color = Color(0.1, 0.1, 0.12, 0.9)
			bar.add_theme_stylebox_override("fill", fill)
			bar.add_theme_stylebox_override("background", back)
			v.add_child(bar)
			bars.append(bar)
		header_bars.append(bars)
		row.add_child(v)
	kill_label = RichTextLabel.new()
	kill_label.bbcode_enabled = true
	kill_label.fit_content = true
	kill_label.scroll_active = false
	kill_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	kill_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	kill_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	kill_label.offset_left = -400.0
	kill_label.offset_right = -12.0
	kill_label.offset_top = 64.0
	kill_label.add_theme_font_size_override("normal_font_size", 15)
	kill_label.add_theme_constant_override("outline_size", 4)
	kill_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	hud.add_child(kill_label)
	start_units = [0, 0]
	start_cost = [0, 0]
	kill_feed.clear()


func _log(text: String) -> void:
	log_lines.append(text)
	if log_lines.size() > 60:
		log_lines.pop_front()
	if log_label:
		log_label.text = "\n".join(log_lines)


func _mmss(t: float) -> String:
	var n := maxi(int(ceil(t)), 0)
	return "%d:%02d" % [n / 60, n % 60]


## Why the match ended, from `ended_by`.
func _decided_by(mine: float, theirs: float) -> String:
	match str(state.get("ended_by")):
		"wipe-out":
			return "by wiping out the enemy"
		"objective":
			return "by holding the shrine for %d s" % int(state.get("hold_time", 60))
		"time":
			return "on time: surviving cost %d vs %d" % [int(mine), int(theirs)]
		"surrender":
			return "by surrender"
	return ""


## Copies the simulation state onto the scene and derives the hit, death and
## kill-feed effects from what changed since the last sync (the state exposes
## hit points, not who struck whom, so attackers are inferred).
func _sync() -> void:
	state = JSON.parse_string(arena_sim.state_json())
	var su: Array = state["units"]
	var events: Array = JSON.parse_string(arena_sim.events_json())
	var alive_n := [0, 0]
	## Unit index -> hit point change this sync (negative: damage).
	var deltas := {}
	var died: Array = []
	var breathers: Array = []
	for i in units.size():
		var u: Unit = units[i]
		var d: Dictionary = su[i]
		var was_alive := u.alive
		var prev_hp := u.hp
		u.alive = d["alive"]
		u.hp = int(d["hp"])
		u.max_hp = int(d["max_hp"])
		u.radius = float(d["radius"])
		var is_mine: bool = u.team == my_team
		alive_n[0 if is_mine else 1] += 1 if u.alive else 0
		var facing := Vector3(d["fx"], 0, d["fz"])
		u.target_pos = Vector3(d["x"], 0, d["z"])
		if online and i == possessed:
			u.target_pos += predicted_offset
			if last_steer.length() > 0.01:
				facing = Vector3(last_steer.x, 0, last_steer.y)
		if facing.length() > 0.01:
			u.target_yaw = atan2(facing.x, facing.z)
		var has_breath: bool = d.get("has_breath", false)
		var breath_ready: bool = d.get("breath_ready", false)
		if not u.seen:
			# First look: place the unit without animating.
			u.seen = true
			u.vis_pos = u.target_pos
			u.yaw = u.target_yaw
			u.shown_frac = float(u.hp) / maxf(u.max_hp, 1.0)
			u.node.position = u.vis_pos
			if not u.alive:
				u.death_t = DEATH_TIME
		elif was_alive:
			if u.hp != prev_hp:
				deltas[i] = u.hp - prev_hp
			if not u.alive:
				died.append(i)
			if u.has_breath and u.breath_ready and not breath_ready:
				breathers.append(i)
		u.has_breath = has_breath
		u.breath_ready = breath_ready
		u.dirty = true
		if online and i == possessed:
			u.vis_pos = u.target_pos
		if not u.simple:
			u.label.visible = u.alive and (units.size() <= LABELS_BELOW or i == possessed)
			u.label.text = "%s\n%d/%d%s" % [u.name, max(u.hp, 0), u.max_hp, "  ◆" if i == possessed else ""]
	if possessed >= 0 and not units[possessed].alive:
		possessed = -1
	_update_possess_marker()
	if not deltas.is_empty() or not breathers.is_empty():
		_hit_effects(deltas, breathers)
	if not died.is_empty():
		_death_effects(died, _falls(events))
	for line in events:
		_log(line)
	var other := 1 - my_team
	var hold: Array = state.get("hold", [0.0, 0.0])
	var hold_time := float(state.get("hold_time", 60.0))
	var cost: Array = state.get("surviving_cost", [0, 0])
	if start_units[0] + start_units[1] == 0:
		start_units = [maxi(alive_n[0], 1), maxi(alive_n[1], 1)]
		start_cost = [maxi(int(cost[my_team]), 1), maxi(int(cost[other]), 1)]
	_update_header(alive_n, [int(cost[my_team]), int(cost[other])])
	_tint_shrine(my_team if float(hold[my_team]) > 0.0 else (other if float(hold[other]) > 0.0 else -1))
	if status_label:
		var shrine := "Shrine: unheld"
		if float(hold[my_team]) > 0.0:
			shrine = "Shrine: You %d/%d s" % [int(hold[my_team]), int(hold_time)]
		elif float(hold[other]) > 0.0:
			shrine = "Shrine: Rival %d/%d s" % [int(hold[other]), int(hold_time)]
		status_label.text = "Time left %s   ·   %s" % [
			_mmss(float(state.get("time_limit", 600.0)) - float(state["time"])), shrine]
	var result = state["result"]
	if result != null and not finished:
		finished = true
		var won: bool = result == ("a" if my_team == 0 else "b")
		var text := "[b][color=#77dd77]Victory![/color][/b]" if won else ("[b]Draw.[/b]" if result == "draw" else "[b][color=#dd7777]Defeat.[/color][/b]")
		var why := _decided_by(float(cost[my_team]), float(cost[other]))
		if why != "":
			text += " Decided %s." % why
		if online:
			_log(text)
		else:
			var fallen := units.filter(func(u): return not u.alive and u.team == my_team).size()
			_log("%s %d of your champions fell. (Online, in ranked matches, they would be lost forever.)" % [text, fallen])
		if status_label:
			status_label.text = ("Victory!" if won else ("Draw." if result == "draw" else "Defeat.")) + ("\nDecided %s." % why if why != "" else "")


## Updates the header's text and bars (units standing, surviving cost).
func _update_header(alive_n: Array, cost: Array) -> void:
	if header_labels.size() < 2 or not is_instance_valid(header_labels[0]):
		return
	for side in 2:
		header_labels[side].text = "%s   %d / %d standing · cost %d" % [
			"You" if side == 0 else "Rival", alive_n[side], start_units[side], cost[side]]
		header_bars[side][0].value = float(alive_n[side]) / start_units[side]
		header_bars[side][1].value = float(cost[side]) / start_cost[side]


# --- Battle effects ---------------------------------------------------------

func _fx_root() -> Node3D:
	if fx_root == null:
		fx_root = Node3D.new()
		world.add_child(fx_root)
	return fx_root


## Where a unit's head is, for numbers and tracers.
func _head(u: Unit) -> Vector3:
	var h := maxf(u.radius, 0.3) * 3.6 if u.simple else u.bar.position.y
	return u.vis_pos + Vector3(0, h, 0)


func _chest(u: Unit) -> Vector3:
	var h := maxf(u.radius, 0.3) * 1.8 if u.simple else maxf(u.bar.position.y * 0.5, 0.5)
	return u.vis_pos + Vector3(0, h, 0)


## The nearest enemy facing `victim`, preferring attackers not yet used this
## sync (each unit strikes once a round, so hits spread over attackers).
func _find_attacker(victim: Unit, used: Dictionary) -> int:
	var best := -1
	var best_score := 1e9
	for j in units.size():
		var a: Unit = units[j]
		if a.team == victim.team or not a.alive:
			continue
		var to := victim.target_pos - a.target_pos
		var dist := to.length() - a.radius - victim.radius
		if dist > 30.0:
			continue
		var facing := Vector3(sin(a.target_yaw), 0, cos(a.target_yaw))
		var score := dist - 1.5 * facing.dot(to.normalized() if to.length() > 0.001 else Vector3.ZERO)
		if used.has(j):
			score += 4.0
		if score < best_score:
			best_score = score
			best = j
	return best


## Lunge, flash, number and tracer for this sync's hit point changes.
func _hit_effects(deltas: Dictionary, breathers: Array) -> void:
	var victims: Array = deltas.keys()
	if victims.size() > MAX_HITS_PER_SYNC:
		# Big battle: show a rotating sample of the hits.
		hits_flip += 1
		var start := hits_flip * 7 % victims.size()
		victims = victims.slice(start, start + MAX_HITS_PER_SYNC) + victims.slice(0, maxi(start + MAX_HITS_PER_SYNC - victims.size(), 0))
	var used := {}
	for b in breathers:
		var bu: Unit = units[b]
		used[b] = true
		_start_lunge(bu, Vector3(sin(bu.target_yaw), 0, cos(bu.target_yaw)))
	for v in victims:
		var vu: Unit = units[v]
		var delta: int = deltas[v]
		if delta > 0:
			_flash(vu, Color(0.4, 1.0, 0.5))
			_number(vu, "+%d" % delta, Color(0.45, 1.0, 0.5), 0.0)
			continue
		# A killing blow shows only the hit points that were left.
		var dmg := -delta + mini(vu.hp, 0)
		var att := -1
		var breath := false
		for b in breathers:
			var bu: Unit = units[b]
			var to := vu.target_pos - bu.target_pos
			if bu.team != vu.team and to.length() < 20.0 and to.normalized().dot(Vector3(sin(bu.target_yaw), 0, cos(bu.target_yaw))) > 0.4:
				att = b
				breath = true
				break
		if att < 0:
			att = _find_attacker(vu, used)
		_flash(vu, Color(1, 1, 1))
		_number(vu, "-%d" % dmg, Color(1.0, 0.3, 0.25), float(dmg) / maxf(vu.max_hp, 1.0))
		if att < 0:
			continue
		var au: Unit = units[att]
		used[att] = true
		var edge := au.target_pos.distance_to(vu.target_pos) - au.radius - vu.radius
		if breath:
			_tracer(au, vu, Color(1.0, 0.6, 0.15), 0.16)
		else:
			_start_lunge(au, vu.target_pos - au.target_pos)
			if edge > 3.0:
				_tracer(au, vu, Color(1.0, 0.95, 0.6), 0.06)


func _start_lunge(u: Unit, dir: Vector3) -> void:
	dir.y = 0.0
	if dir.length() < 0.001:
		return
	u.lunge_t = 0.0
	u.lunge_dir = dir.normalized() * minf(0.45 + u.radius * 0.5, 1.2)


func _flash(u: Unit, color: Color) -> void:
	u.flash_t = 0.0
	u.flash_color = color
	if not u.simple:
		u.flash_mat.albedo_color = Color(color, 0.0)
		for m in u.meshes:
			m.material_overlay = u.flash_mat


## A floating number that rises and fades; `scale_by` (damage / max hp)
## makes big hits bigger.
func _number(u: Unit, text: String, color: Color, scale_by: float) -> void:
	if active_numbers.size() >= MAX_NUMBERS:
		return
	var l: Label3D
	if number_pool.is_empty():
		l = Label3D.new()
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.no_depth_test = true
		l.font_size = 48
		l.outline_size = 12
		l.pixel_size = 0.007
		l.render_priority = 10
		l.outline_render_priority = 9
		_fx_root().add_child(l)
	else:
		l = number_pool.pop_back()
	l.text = text
	l.modulate = color
	l.outline_modulate = Color(0.1, 0.0, 0.0, 0.9)
	l.visible = true
	var s := 0.8 + minf(scale_by * 3.0, 1.2)
	l.scale = Vector3.ONE * s
	l.position = _head(u) + Vector3(rng.randf_range(-0.4, 0.4), 0.3, rng.randf_range(-0.2, 0.2))
	active_numbers.append({"node": l, "t": 0.0})


func _tracer(a: Unit, v: Unit, color: Color, width: float) -> void:
	if active_tracers.size() >= MAX_TRACERS:
		return
	var from := _chest(a)
	var to := _chest(v)
	if from.distance_to(to) < 0.1:
		return
	var n: MeshInstance3D
	if tracer_pool.is_empty():
		if tracer_mesh == null:
			tracer_mesh = BoxMesh.new()
		n = MeshInstance3D.new()
		n.mesh = tracer_mesh
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		n.material_override = m
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fx_root().add_child(n)
	else:
		n = tracer_pool.pop_back()
	n.visible = true
	n.material_override.albedo_color = color
	n.look_at_from_position((from + to) * 0.5, to, Vector3.UP)
	n.scale = Vector3(width, width, from.distance_to(to))
	active_tracers.append({"node": n, "t": 0.0, "color": color})


func _puff(pos: Vector3, size: float) -> void:
	if active_puffs.size() >= MAX_PUFFS:
		return
	var n: MeshInstance3D
	if puff_pool.is_empty():
		if puff_mesh == null:
			puff_mesh = SphereMesh.new()
			puff_mesh.radius = 0.5
			puff_mesh.height = 1.0
			puff_mesh.radial_segments = 12
			puff_mesh.rings = 6
		n = MeshInstance3D.new()
		n.mesh = puff_mesh
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		n.material_override = m
		n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_fx_root().add_child(n)
	else:
		n = puff_pool.pop_back()
	n.visible = true
	n.position = pos
	n.scale = Vector3.ONE * size * 0.5
	active_puffs.append({"node": n, "t": 0.0, "size": size})


## "Victim falls to Killer." lines of the event log, as [victim, killer].
func _falls(events: Array) -> Array:
	var out := []
	var sep := " [color=#cc6666]falls[/color] to "
	for line in events:
		var k := str(line).find(sep)
		if k >= 0:
			out.append([str(line).substr(0, k), str(line).substr(k + sep.length()).trim_suffix(".")])
	return out


## Starts the death animation, a puff and a kill-feed line for each fallen
## unit (feed lines only for the last few of a mass death).
func _death_effects(died: Array, falls: Array) -> void:
	for n in died.size():
		var u: Unit = units[died[n]]
		u.death_t = 0.0
		u.lunge_t = -1.0
		if n < MAX_PUFFS:
			_puff(u.vis_pos + Vector3(0, 0.3 + u.radius * 0.4, 0), 0.6 + u.radius * 1.2)
		if n < died.size() - KILL_FEED_LINES:
			continue
		var killer := ""
		var killer_team := 1 - u.team
		for f in falls:
			if f[0] == u.name:
				killer = f[1]
				falls.erase(f)
				break
		var line := ""
		if killer != "":
			line = "[color=#%s]%s[/color] slew [color=#%s]%s[/color]" % [
				_team_color(killer_team).lightened(0.2).to_html(false), killer,
				_team_color(u.team).lightened(0.2).to_html(false), u.name]
		else:
			line = "[color=#%s]%s[/color] fell" % [_team_color(u.team).lightened(0.2).to_html(false), u.name]
		kill_feed.append({"text": line, "age": 0.0})
	while kill_feed.size() > KILL_FEED_LINES:
		kill_feed.pop_front()
	_refresh_kill_feed()


func _refresh_kill_feed() -> void:
	if kill_label == null or not is_instance_valid(kill_label):
		return
	var lines := []
	for k in kill_feed:
		lines.append(k["text"])
	kill_label.text = "[right]%s[/right]" % "\n".join(lines)


## Per-frame presentation: smooths positions, plays lunges, flashes, deaths,
## health bars and the floating effects, in real time (so slow playback
## stays smooth).
func _animate(delta: float) -> void:
	var follow := 1.0 - exp(-delta * (30.0 if online else 14.0))
	for i in units.size():
		var u: Unit = units[i]
		if not u.seen:
			continue
		var active := u.dirty or u.lunge_t >= 0.0 or u.flash_t >= 0.0 or (u.death_t >= 0.0 and u.death_t < DEATH_TIME)
		if u.vis_pos.distance_squared_to(u.target_pos) > 0.000001:
			u.vis_pos = u.vis_pos.lerp(u.target_pos, follow)
			active = true
		if absf(angle_difference(u.yaw, u.target_yaw)) > 0.001:
			u.yaw = lerp_angle(u.yaw, u.target_yaw, follow)
			active = true
		if u.lunge_t >= 0.0:
			u.lunge_t += delta
			if u.lunge_t >= LUNGE_TIME:
				u.lunge_t = -1.0
		if u.flash_t >= 0.0:
			u.flash_t += delta
			if u.flash_t >= FLASH_TIME:
				u.flash_t = -1.0
		var dying := u.death_t >= 0.0 and u.death_t < DEATH_TIME
		if dying:
			u.death_t += delta
		if not active:
			continue
		u.dirty = false
		var lunge := Vector3.ZERO
		if u.lunge_t >= 0.0:
			lunge = u.lunge_dir * sin(PI * u.lunge_t / LUNGE_TIME)
		# Death: topple over the first third, then sink and shrink away.
		var roll := 0.0
		var shrink := 1.0
		if u.death_t >= 0.0:
			var t := clampf(u.death_t / DEATH_TIME, 0.0, 1.0)
			roll = PI * 0.5 * smoothstep(0.0, 0.35, t)
			shrink = 1.0 - smoothstep(0.45, 1.0, t)
		var flash := 0.0 if u.flash_t < 0.0 else 1.0 - u.flash_t / FLASH_TIME
		if u.simple:
			_draw_simple(u, lunge, roll, shrink, flash)
			continue
		u.node.position = u.vis_pos
		u.node.rotation = Vector3(0, u.yaw, 0)
		u.node.visible = shrink > 0.001
		u.body.position = Basis(Vector3.UP, -u.yaw) * lunge
		u.body.basis = Basis(Vector3(0, 0, 1), roll).scaled(Vector3.ONE * maxf(shrink, 0.001))
		u.ring_mat.albedo_color.a = shrink
		u.disc_mat.albedo_color.a = 0.2 * shrink
		var alive_vis := u.death_t < 0.0
		u.bar.visible = alive_vis
		if alive_vis:
			var want := clampf(float(u.hp) / maxf(u.max_hp, 1.0), 0.0, 1.0)
			u.shown_frac = move_toward(u.shown_frac, want, delta * 1.2)
			u.bar.set_instance_shader_parameter("frac", u.shown_frac)
		if flash > 0.0:
			u.flash_mat.albedo_color.a = 0.75 * flash
		elif not u.meshes.is_empty() and u.meshes[0].material_overlay != null:
			for m in u.meshes:
				m.material_overlay = null
	_animate_effects(delta)


## Draws one simple-shape unit (and its ground ring) into the side's MultiMeshes.
func _draw_simple(u: Unit, lunge: Vector3, roll: float, shrink: float, flash: float) -> void:
	var mm: MultiMesh = multimeshes[u.team].multimesh
	var rmm: MultiMesh = ring_mms[u.team].multimesh
	u.node.position = u.vis_pos
	var sc := maxf(u.radius, 0.3) * 2.0
	if shrink <= 0.001:
		mm.set_instance_transform(u.mm_index, Transform3D(Basis().scaled(Vector3.ZERO), u.vis_pos))
		rmm.set_instance_transform(u.mm_index, Transform3D(Basis().scaled(Vector3.ZERO), u.vis_pos))
		return
	var rot := Basis(Vector3.UP, u.yaw) * Basis(Vector3(0, 0, 1), roll)
	var pos := u.vis_pos + lunge
	mm.set_instance_transform(u.mm_index, Transform3D(rot.scaled(Vector3.ONE * sc * shrink), pos + rot * Vector3(0, 0.9 * sc * shrink, 0)))
	var col := u.color
	if flash > 0.0:
		col = col.lerp(u.flash_color, flash * 0.85)
	mm.set_instance_color(u.mm_index, col)
	rmm.set_instance_transform(u.mm_index, Transform3D(Basis().scaled(Vector3.ONE * sc * shrink), u.vis_pos + Vector3(0, 0.05, 0)))
	rmm.set_instance_color(u.mm_index, _team_color(u.team))


## Advances the floating numbers, tracers and puffs and recycles finished ones.
func _animate_effects(delta: float) -> void:
	for e in active_numbers:
		e["t"] += delta
		var n: Label3D = e["node"]
		var t: float = e["t"] / 1.1
		n.position.y += delta * (1.4 - t)
		n.modulate.a = 1.0 - smoothstep(0.55, 1.0, t)
		n.outline_modulate.a = n.modulate.a * 0.9
		if t >= 1.0:
			n.visible = false
			number_pool.append(n)
	active_numbers = active_numbers.filter(func(e): return e["t"] < 1.1)
	for e in active_tracers:
		e["t"] += delta
		var n: MeshInstance3D = e["node"]
		var t: float = e["t"] / 0.28
		n.material_override.albedo_color = Color(e["color"], 0.9 * (1.0 - t))
		if t >= 1.0:
			n.visible = false
			tracer_pool.append(n)
	active_tracers = active_tracers.filter(func(e): return e["t"] < 0.28)
	for e in active_puffs:
		e["t"] += delta
		var n: MeshInstance3D = e["node"]
		var t: float = e["t"] / 0.6
		n.scale = Vector3.ONE * e["size"] * lerpf(0.5, 1.5, t)
		n.material_override.albedo_color = Color(0.85, 0.8, 0.7, 0.4 * (1.0 - t))
		if t >= 1.0:
			n.visible = false
			puff_pool.append(n)
	active_puffs = active_puffs.filter(func(e): return e["t"] < 0.6)
	if not kill_feed.is_empty():
		kill_feed_timer += delta
		if kill_feed_timer > 0.5:
			for k in kill_feed:
				k["age"] += kill_feed_timer
			kill_feed_timer = 0.0
			var before := kill_feed.size()
			kill_feed = kill_feed.filter(func(k): return k["age"] < KILL_FEED_SECONDS)
			if kill_feed.size() != before:
				_refresh_kill_feed()


## Simple-shape units have no label or model, so the possessed one gets a ring.
func _update_possess_marker() -> void:
	var u: Unit = units[possessed] if possessed >= 0 and possessed < units.size() else null
	if u == null or not u.simple or not u.alive:
		if possess_marker:
			possess_marker.visible = false
		return
	if possess_marker == null:
		possess_marker = MeshInstance3D.new()
		var torus := TorusMesh.new()
		torus.inner_radius = 0.9
		torus.outer_radius = 1.1
		possess_marker.mesh = torus
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = Color(1.0, 0.9, 0.3)
		possess_marker.material_override = mat
		world.add_child(possess_marker)
	possess_marker.visible = true
	possess_marker.position = u.node.position + Vector3(0, 0.08, 0)


## Advances the battle by `dt` seconds of arena time.
func step(dt: float) -> void:
	if finished or arena_sim == null:
		return
	if possessed >= 0:
		_steer_possessed()
	if online:
		_predict(dt)
		_sync()
		return
	tick_budget += dt
	var ticks := int(tick_budget / 0.1)
	if ticks > 0:
		tick_budget -= ticks * 0.1
		arena_sim.step(ticks)
		_sync()


# --- Possession -------------------------------------------------------------

func _steer_possessed() -> void:
	var input := Vector2.ZERO
	if Input.is_key_pressed(KEY_W):
		input.y -= 1.0
	if Input.is_key_pressed(KEY_S):
		input.y += 1.0
	if Input.is_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input.x += 1.0
	# Movement is relative to the follow camera.
	var dir3 := Basis(Vector3.UP, cam_yaw) * Vector3(input.x, 0, input.y)
	var dir := Vector2(dir3.x, dir3.z)
	if dir.distance_to(last_steer) > 0.01:
		last_steer = dir
		arena_sim.steer(possessed, dir.x, dir.y)


func possess(index: int) -> void:
	possessed = index
	last_steer = Vector2.ZERO
	arena_sim.possess(index)
	if index >= 0:
		_log("You possess %s." % units[index].name)
	_sync()


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed) or arena_sim == null:
		return
	if event.keycode == KEY_ESCAPE:
		possess(-1)
	elif possessed >= 0:
		if event.keycode == KEY_SPACE:
			arena_sim.attack(possessed)
		elif event.keycode == KEY_Q:
			arena_sim.breathe(possessed)


var dragging := false


func _on_view_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
		if event.pressed and running:
			_pick_unit(event.position)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
		cam_zoom = clampf(cam_zoom * 0.9, 0.4, 1.8)
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		cam_zoom = clampf(cam_zoom / 0.9, 0.4, 1.8)
	elif event is InputEventMouseMotion and dragging and possessed < 0:
		cam_yaw -= event.relative.x * 0.005


func _pick_unit(pos: Vector2) -> void:
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var best := -1
	var best_d := 1.5
	for i in units.size():
		var u: Unit = units[i]
		if not u.alive or u.team != my_team:
			continue
		var c: Vector3 = u.node.position + Vector3(0, 0.8, 0)
		var t := (c - from).dot(dir)
		var d := (from + dir * t).distance_to(c)
		if d < best_d:
			best_d = d
			best = i
	if best >= 0:
		possess(best)


func _update_camera(delta: float) -> void:
	if camera == null:
		return
	if possessed >= 0 and units[possessed].alive:
		var target: Vector3 = units[possessed].node.position
		var back := Basis(Vector3.UP, cam_yaw) * Vector3(0, 0, 1)
		var want := target + (back * 9.0 + Vector3(0, 6.0, 0)) * cam_zoom
		camera.position = camera.position.lerp(want, clampf(delta * 4.0, 0.0, 1.0))
		camera.look_at(target + Vector3(0, 0.8, 0), Vector3.UP)
	else:
		_overview_camera()


# --- Online -----------------------------------------------------------------

## Connects to the arena server, binds the picked team and queues.
func find_online_match() -> void:
	if _team_cost(my_roster, my_counts) == 0:
		online_label.text = "Pick at least one champion first."
		return
	_connect(false)


## Opens the connection to the server in the host box. With `shop_only` it
## signs in without binding champions or queueing.
func _connect(shop_only: bool) -> void:
	var host := host_edit.text.strip_edges()
	var port := DEFAULT_PORT
	if host.contains(":"):
		port = int(host.get_slice(":", 1))
		host = host.get_slice(":", 0)
	my_name = name_edit.text.strip_edges()
	server_key = "%s:%d" % [host, port]
	var cfg := _online_cfg()
	var secret: String = cfg.get_value(server_key, "secret_" + my_name, "")
	var pin: String = cfg.get_value(server_key, "pin", "")
	if net:
		net.close_connection()
	signin_only = shop_only
	signed_in = false
	buy_busy = false
	spoils_busy.clear()
	net = ClassDB.instantiate("NetClient")
	net.connect_to(host, port, my_name, secret, pin)
	online_button.disabled = true
	signin_button.disabled = true
	online_label.text = "Connecting to %s:%d…" % [host, port]
	_refresh_shop()


func _poll_net() -> void:
	for msg in JSON.parse_string(net.poll()):
		match str(msg["type"]):
			"certificate":
				# Pin the server's certificate on first contact (like SSH).
				var cfg := _online_cfg()
				if cfg.get_value(server_key, "pin", "") == "":
					cfg.set_value(server_key, "pin", msg["fingerprint"])
					cfg.save(ONLINE_CFG)
			"welcome":
				resuming = msg["resuming"]
				if msg["secret"] != null:
					var cfg := _online_cfg()
					cfg.set_value(server_key, "secret_" + str(msg["account"]), msg["secret"])
					cfg.save(ONLINE_CFG)
				signed_in = true
				signin_button.disabled = false
				essence = int(msg["essence"])
				planet_slots = int(msg.get("planet_slots", planet_slots))
				_sync_grants(msg.get("spoils", []), msg.get("purchases", []))
				_refresh_shop()
				if resuming:
					online_label.text = "Rejoining your match…"
				elif signin_only:
					online_label.text = "Signed in as %s (%d Essence). The shop is open." % [msg["account"], essence]
					online_button.disabled = false
				else:
					online_label.text = "Signed in as %s (rating %.0f, %d Essence). The server is replaying your world to verify your champions…" % [msg["account"], msg["rating"]["rating"], int(msg["essence"])]
					pending_binds.clear()
					bound_tokens.clear()
					for c in my_roster:
						for k in my_counts.get(c["key"], 0):
							if net.bind(c["world"], c["kind"], c["id"], c.get("moon", -1)):
								pending_binds.append(c)
			"bound":
				pending_binds.pop_front()
				bound_tokens.append(int(msg["champion"]["token"]))
				_queue_when_bound()
			"purchased":
				_on_purchased(msg)
			"sold":
				_on_sold(msg)
			"rejected":
				if msg["request"] == "buy" or msg["request"] == "sell_loot":
					buy_busy = false
					spoils_busy.clear()
					_note("Server refused the %s: %s" % ["purchase" if msg["request"] == "buy" else "sale", msg["reason"]])
					_refresh_shop()
					_refresh_spoils()
					continue
				_log("Server: %s" % msg["reason"])
				online_label.text = "Server: %s" % msg["reason"]
				if msg["request"] == "bind":
					pending_binds.pop_front()
					_queue_when_bound()
				else:
					online_button.disabled = false
			"queued":
				online_label.text = "Waiting for an opponent (team cost %d, cap %d)…" % [msg["cost"], msg["cap"]]
			"match_start":
				_start_online_battle(msg)
			"match_end":
				_online_end(msg)
			"disconnected":
				online_label.text = "Disconnected: %s" % msg["reason"]
				online_button.disabled = false
				signin_button.disabled = false
				signed_in = false
				buy_busy = false
				spoils_busy.clear()
				_refresh_shop()
				_refresh_spoils()
				if running and not finished:
					_log("[color=#dd7777]Disconnected: %s. Rejoin within 30 seconds or it counts as surrender.[/color]" % msg["reason"])
					if rejoin_button:
						rejoin_button.visible = true
				net = null
				return


func _queue_when_bound() -> void:
	if not pending_binds.is_empty():
		return
	if bound_tokens.is_empty():
		online_label.text = "None of your champions could be verified."
		online_button.disabled = false
		return
	var mode := "practice" if mode_select.selected == 1 else "ranked"
	net.queue(mode, cap, PackedInt64Array(bound_tokens))


## Builds the scene from the server's rosters; the opponent's champions
## arrive with their sheets and appearance.
func _start_online_battle(msg: Dictionary) -> void:
	# Rejoining: rebuild the scene from scratch.
	_clear_units()
	if battle_ui:
		battle_ui.queue_free()
		battle_ui = null
	finished = false
	possessed = -1
	online = true
	my_team = int(msg["team"])
	setup_panel.visible = false
	arena_sim = net
	var counts := [0, 0]
	for team in 2:
		counts[team] = msg["rosters"][team].size()
	_begin_scene(JSON.parse_string(net.field_json()), counts)
	for team in 2:
		var sheets: Array = msg["rosters"][team]
		var looks: Array = msg["looks"][team]
		for i in sheets.size():
			var look: Dictionary = looks[i]
			var parts := []
			for p in look["parts"]:
				parts.append({"part": p["part"], "count": p["count"], "size": float(p["size_milli"]) / 1000.0})
			var detail := {"parts": parts, "color": look["color"], "otherworldly": look["otherworldly"]}
			_spawn({"name": sheets[i]["name"], "sheet": {"size": sheets[i]["size"]}, "detail": detail}, team, counts[team] > SIMPLE_ABOVE)
	_build_battle_ui()
	running = true
	_sync()
	var foe: String = msg["players"][1 - my_team]
	_log("[b]Online %s match against %s begins![/b]" % ["practice" if msg["mode"] == "practice" else "ranked", foe])


func _online_end(msg: Dictionary) -> void:
	match_end = msg
	_sync()
	if msg["surrendered"] != null:
		_log("%s surrendered." % ("You" if int(msg["surrendered"]) == my_team else "Your opponent"))
	for f in msg["fallen"]:
		if f["kind"] == "individual":
			_log("[color=#cc6666]%s fell forever[/color] (%s)." % [f["name"], f["account"]])
			# Log the death at home, so the world replays without them.
			if f["account"] == my_name and int(f["world_seed"]) == sim.seed():
				sim.champion_fell(int(f["id"]), int(f["moon"]) if f.get("moon") != null else -1)
		else:
			_log("%s lost a %s." % [f["account"], f["name"]])
	if msg["rating"] != null:
		_log("Your rating is now %.0f ± %.0f." % [msg["rating"]["rating"], msg["rating"]["deviation"]])
	if int(msg["essence_gained"]) > 0:
		_log("[color=#e0c060]You earn %d Essence[/color] (now %d)." % [int(msg["essence_gained"]), int(msg["essence"])])
	essence = int(msg["essence"])
	planet_slots = int(msg.get("planet_slots", planet_slots))
	# The bodies of the fallen are the winner's: bring them home or sell them.
	for g in msg["loot"]:
		spoils[int(g["id"])] = g
		_log("Spoils: the remains of %s (worth %d Essence)." % [g["from"], int(g.get("value", 0))])
	if not msg["loot"].is_empty():
		_save_spoils()
		_add_battle_spoils()
		_refresh_spoils()
	if msg.get("desynced", false):
		_log("[color=#dd7777]Warning: this client fell out of step with the server.[/color]")
	# Stay connected: selling spoils and shopping need the session.
	signed_in = true
	_refresh_shop()


# --- Spoils and the shop ----------------------------------------------------

## Logs a line and shows it in the online panel.
func _note(text: String) -> void:
	_log(text)
	if online_label:
		online_label.text = text


func _load_json_file(path: String, fallback: Variant) -> Variant:
	if not FileAccess.file_exists(path):
		return fallback
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if typeof(parsed) == typeof(fallback) else fallback


func _store_json_file(path: String, data: Variant) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("Could not write %s" % path)
		return
	f.store_string(JSON.stringify(data))


func _load_spoils() -> void:
	spoils.clear()
	var saved: Dictionary = _load_json_file(SPOILS_PATH, {})
	for key in saved:
		spoils[int(key)] = saved[key]


func _save_spoils() -> void:
	var out := {}
	for id in spoils:
		if not spoils[id].get("stub", false):
			out[str(id)] = spoils[id]
	_store_json_file(SPOILS_PATH, out)


func _load_purchases() -> void:
	purchases = _load_json_file(PURCHASES_PATH, [])


func _save_purchases() -> void:
	_store_json_file(PURCHASES_PATH, purchases)


## Reconciles spoils and purchases with the server's lists at sign-in. The
## server keeps every grant not yet used in a world, so nothing bought or
## won is lost if a reply never arrived; grants the world already holds are
## skipped.
func _sync_grants(server_spoils: Array, server_purchases: Array) -> void:
	var used: Dictionary = JSON.parse_string(sim.used_grants_json())
	var used_loot := {}
	for id in used["loot"]:
		used_loot[int(id)] = true
	var used_buys := {}
	for id in used["purchases"]:
		used_buys[int(id)] = true
	spoils.clear()
	for g in server_spoils:
		if not used_loot.has(int(g["id"])):
			spoils[int(g["id"])] = g
	_save_spoils()
	_refresh_spoils()
	purchases.clear()
	var applied := false
	for g in server_purchases:
		if used_buys.has(int(g["id"])):
			continue
		if str(g["item"].get("kind", "")) == "moon_slot":
			applied = sim.apply_purchase(JSON.stringify(g), 0, 0) or applied
		else:
			purchases.append(g)
	if applied:
		_save_world()
		_log("A moon slot bought earlier was added to your planet.")
	_save_purchases()
	_refresh_purchases()


## Gives the battle screen its own list of spoils to decide on.
func _add_battle_spoils() -> void:
	if battle_ui == null:
		return
	var box := VBoxContainer.new()
	battle_ui.add_child(box)
	spoil_boxes.append(box)


func _refresh_spoils() -> void:
	spoil_boxes = spoil_boxes.filter(func(b): return is_instance_valid(b))
	for box in spoil_boxes:
		for c in box.get_children():
			box.remove_child(c)
			c.queue_free()
		for id in spoils:
			var g: Dictionary = spoils[id]
			var row := HBoxContainer.new()
			box.add_child(row)
			row.add_child(_label("Spoils: remains of %s" % g["from"]))
			var busy: bool = spoils_busy.has(id)
			var home := Button.new()
			home.text = "Bring home"
			home.disabled = busy or g.get("stub", false)
			if g.get("stub", false):
				home.tooltip_text = "This spoil's remains are not saved on this computer; it can only be sold."
			home.pressed.connect(_bring_home.bind(id))
			row.add_child(home)
			var sell := Button.new()
			sell.text = "Sell for %d Essence" % int(g.get("value", 0))
			sell.disabled = busy or not signed_in or net == null
			sell.tooltip_text = "" if signed_in else "Sign in to sell."
			sell.pressed.connect(_sell_spoil.bind(id))
			row.add_child(sell)


func _bring_home(id: int) -> void:
	if not spoils.has(id) or spoils_busy.has(id):
		return
	var g: Dictionary = spoils[id]
	var kind: String = sim.apply_loot(JSON.stringify(g))
	if kind == "":
		_note("The remains of %s could not be brought home." % g["from"])
		return
	_note("You carry home the remains of %s: %s now lives in your world." % [g["from"], kind])
	spoils.erase(id)
	_save_spoils()
	_save_world()
	_refresh_spoils()


func _sell_spoil(id: int) -> void:
	if not spoils.has(id) or spoils_busy.has(id) or net == null:
		return
	if net.sell_loot(id):
		spoils_busy[id] = true
		_refresh_spoils()
	else:
		_note("Could not reach the server to sell.")


func _on_sold(msg: Dictionary) -> void:
	var id := int(msg["grant"])
	var from: String = spoils[id]["from"] if spoils.has(id) else "a spoil"
	spoils.erase(id)
	spoils_busy.erase(id)
	essence = int(msg["essence"])
	_save_spoils()
	_note("Sold %s for %d Essence (now %d)." % [from, int(msg["essence_gained"]), essence])
	_refresh_spoils()
	_refresh_shop()


func _refresh_shop() -> void:
	if essence_label == null:
		return
	essence_label.text = "  %d Essence · %d home world%s  " % [essence, planet_slots, "" if planet_slots == 1 else "s"]
	for i in shop_buttons.size():
		var price := int(shop_items[i]["price"])
		shop_buttons[i].disabled = buy_busy or not signed_in or net == null or essence < price
		shop_buttons[i].tooltip_text = "" if signed_in else "Sign in to shop."


func _buy(entry: Dictionary) -> void:
	if net == null or buy_busy:
		return
	if net.buy(JSON.stringify(entry["item"])):
		buy_busy = true
		_refresh_shop()
	else:
		_note("Could not reach the server to buy.")


func _item_name(item: Dictionary) -> String:
	for entry in shop_items:
		if entry["item"] == item:
			return entry["name"]
	return str(item.get("kind", "item"))


func _on_purchased(msg: Dictionary) -> void:
	buy_busy = false
	essence = int(msg["essence"])
	planet_slots = int(msg.get("planet_slots", planet_slots))
	var item: Dictionary = msg["item"]
	_note("Bought %s (now %d Essence)." % [_item_name(item), essence])
	var grant = msg.get("grant")
	match str(item.get("kind", "")):
		"moon_slot":
			if grant != null and sim.apply_purchase(JSON.stringify(grant), 0, 0):
				_save_world()
				_log("Your planet has room for another moon.")
		"planet_slot":
			_note("You can now bring champions from %d worlds." % planet_slots)
		"deposit":
			if grant != null:
				purchases.append(grant)
				_save_purchases()
				_refresh_purchases()
				_log("Place the %s deposit with the Place button." % item.get("substance", ""))
	_refresh_shop()


func _refresh_purchases() -> void:
	if purchase_box == null:
		return
	for c in purchase_box.get_children():
		purchase_box.remove_child(c)
		c.queue_free()
	for i in purchases.size():
		var row := HBoxContainer.new()
		purchase_box.add_child(row)
		row.add_child(_label("Unplaced: %s" % _item_name(purchases[i]["item"])))
		var place := Button.new()
		place.text = "Place"
		place.tooltip_text = "Place it at the region selected on the map, or the centre of the map if none is."
		place.pressed.connect(_place_purchase.bind(i))
		row.add_child(place)


## Places a bought deposit at the region selected in the main viewer, or the
## centre of the map if nothing is selected.
func _place_purchase(i: int) -> void:
	if i >= purchases.size():
		return
	var cell := Vector2i(sim.width() / 2, sim.height() / 2)
	var chosen := false
	var main := get_parent()
	if main != null and "selected_region" in main and main.selected_region.x >= 0:
		cell = main.selected_region
		chosen = true
	var grant: Dictionary = purchases[i]
	if not sim.apply_purchase(JSON.stringify(grant), cell.x, cell.y):
		_note("That deposit could not be placed.")
		return
	purchases.remove_at(i)
	_save_purchases()
	_save_world()
	_refresh_purchases()
	_note("Placed the %s deposit at region (%d, %d)%s." % [
		grant["item"].get("substance", ""), cell.x, cell.y, "" if chosen else " (the centre; select a region on the map first to choose)"])


## Saves the world the way the Save button does, and refreshes the map.
func _save_world() -> void:
	var main := get_parent()
	if main != null and main.has_method("_save"):
		main._save()
	if main != null and main.has_method("_refresh_all"):
		main._refresh_all()


func _online_cfg() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(ONLINE_CFG)
	return cfg


func _server_key() -> String:
	var host := host_edit.text.strip_edges()
	return host if host.contains(":") else "%s:%d" % [host, DEFAULT_PORT]


## Moves the possessed unit's drawn position ahead in the steering
## direction; the lead fades as the server's position catches up. Display
## only: the arena itself always follows the server.
func _predict(dt: float) -> void:
	if possessed < 0 or state.is_empty():
		predicted_offset = Vector3.ZERO
		return
	var speed: float = state["units"][possessed].get("speed", 1.0)
	var dir := Vector3(last_steer.x, 0, last_steer.y)
	predicted_offset += dir * speed * 1.2 * dt
	predicted_offset *= exp(-dt / prediction_tau)

