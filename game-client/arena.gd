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
const CAPS := [25, 50, 100, 250, 1000]
const MAX_UNITS_PER_SIDE := 40
const SIZE_SCALE := {"Tiny": 0.8, "Small": 1.1, "Medium": 1.5, "Large": 2.2, "Huge": 3.2, "Gargantuan": 4.5}
const RIVAL_PRESETS := ["earthlike", "frozen_moon", "sulfur_world"]
const DEFAULT_PORT := 7878
## Account secrets and pinned server certificates, per server.
const ONLINE_CFG := "user://online.cfg"


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
var speed := 1.0
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


func open(world_sim: RefCounted) -> void:
	sim = world_sim
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_scene()
	_build_setup()
	_load_my_roster()
	_start_rival()


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
	var floor_mesh := CylinderMesh.new()
	floor_mesh.top_radius = ARENA_RADIUS + 2.0
	floor_mesh.bottom_radius = ARENA_RADIUS + 2.5
	floor_mesh.height = 0.6
	floor_mesh.radial_segments = 64
	var floor_node := MeshInstance3D.new()
	floor_node.mesh = floor_mesh
	floor_node.position.y = -0.3
	var fm := ShaderMaterial.new()
	fm.shader = preload("res://shaders/creature.gdshader")
	fm.set_shader_parameter("base_color", Color(0.55, 0.47, 0.36))
	floor_node.material_override = fm
	world.add_child(floor_node)
	# A ring of pillars marks the edge.
	for i in 16:
		var a := TAU * i / 16.0
		var pillar := MeshInstance3D.new()
		var pm := CylinderMesh.new()
		pm.top_radius = 0.35
		pm.bottom_radius = 0.45
		pm.height = 3.0
		pillar.mesh = pm
		var mat := ShaderMaterial.new()
		mat.shader = preload("res://shaders/creature.gdshader")
		mat.set_shader_parameter("base_color", Color(0.7, 0.66, 0.6))
		pillar.material_override = mat
		pillar.position = Vector3(cos(a) * (ARENA_RADIUS + 1.2), 1.5, sin(a) * (ARENA_RADIUS + 1.2))
		world.add_child(pillar)
	camera = Camera3D.new()
	camera.fov = 50.0
	world.add_child(camera)
	_overview_camera()


func _overview_camera() -> void:
	camera.position = Vector3(sin(cam_yaw) * 21.0, 14.0, cos(cam_yaw) * 21.0)
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


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


## Candidate champions from a world: the strongest species (any number of
## copies) and the most renowned named individuals (one each).
static func roster_of(world_sim: RefCounted) -> Array:
	var out: Array = []
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
		out.append({"key": "s%d" % int(s["id"]), "name": s["name"], "hero": false, "detail": detail, "sheet": sheet, "cost": int(sheet["cost"]),
			"kind": "species", "id": int(s["id"]), "world": world_sim})
	var people: Array = JSON.parse_string(world_sim.individuals_json(300))
	people.sort_custom(func(a, b): return (a["cost"] if a["cost"] != null else 0) > (b["cost"] if b["cost"] != null else 0))
	for p in people.slice(0, 4):
		var sheet = JSON.parse_string(world_sim.sheet_json("individual", int(p["id"])))
		var detail = JSON.parse_string(world_sim.species_detail_json(int(p["species_id"])))
		if sheet == null or detail == null:
			continue
		out.append({"key": "i%d" % int(p["id"]), "name": p["title"], "hero": true, "detail": detail, "sheet": sheet, "cost": int(sheet["cost"]),
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
			_refresh_setup()
	if net:
		_poll_net()
	if running and not finished:
		step(delta * speed)
	_update_camera(delta)


## Starts a battle immediately with the given rival roster (used by tests
## and when the rival world is ready).
func use_rival_roster(roster: Array, preset := "test") -> void:
	rival_ticks_left = 0
	rival = ClassDB.instantiate("SimWorld")
	rival.set_meta("preset", preset)
	rival_roster = roster
	rival_ready = true
	_refresh_setup()


# --- Battle -----------------------------------------------------------------

func _spawn(entry: Dictionary, team: int) -> void:
	var u := Unit.new()
	u.team = team
	u.name = entry["name"]
	var size: String = entry["sheet"]["size"]
	var model := CreatureBuilder.build(entry["detail"])
	var box := CreatureBuilder.bounds(model)
	var extent: float = max(box.size.x, max(box.size.y, box.size.z))
	var s: float = SIZE_SCALE.get(size, 1.0) / max(extent, 0.01)
	model.scale = Vector3.ONE * s
	model.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)
	var holder := Node3D.new()
	holder.add_child(model)
	# Team ring on the ground: blue for you, red for the rival.
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	var size_r: float = SIZE_SCALE.get(size, 1.0) * 0.55
	torus.inner_radius = size_r
	torus.outer_radius = size_r + 0.12
	ring.mesh = torus
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(0.35, 0.7, 1.0) if team == my_team else Color(1.0, 0.4, 0.35)
	ring.material_override = ring_mat
	ring.position.y = 0.05
	holder.add_child(ring)
	world.add_child(holder)
	u.node = holder
	u.label = Label3D.new()
	u.label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	u.label.font_size = 28
	u.label.pixel_size = 0.02
	u.label.outline_size = 6
	u.label.modulate = Color(0.6, 0.85, 1.0) if team == my_team else Color(1.0, 0.6, 0.55)
	u.label.position = Vector3(0, SIZE_SCALE.get(size, 1.0) + 0.4, 0)
	holder.add_child(u.label)
	units.append(u)


func _start_battle() -> void:
	setup_panel.visible = false
	arena_sim = ClassDB.instantiate("ArenaSim")
	var rival_counts := _auto_pick(rival_roster)
	# Units are added in the same order as their scene nodes, so index i in
	# the simulation is units[i] here.
	for pair in [[my_roster, my_counts, 0], [rival_roster, rival_counts, 1]]:
		for c in pair[0]:
			for k in pair[1].get(c["key"], 0):
				if arena_sim.add_unit(c["world"], c["kind"], c["id"], pair[2]):
					_spawn(c, pair[2])
	arena_sim.start(rng.randi())
	_build_battle_ui()
	running = true
	_sync()
	_log("[b]The battle begins![/b]")


func _build_battle_ui() -> void:
	battle_ui = VBoxContainer.new()
	battle_ui.position = Vector2(12, 12)
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
		give_up.pressed.connect(func(): net.surrender())
		row.add_child(give_up)
	else:
		for sp in [1.0, 2.0, 4.0]:
			var b := Button.new()
			b.text = "×%d" % int(sp)
			b.pressed.connect(func(): speed = sp)
			row.add_child(b)
	var back := Button.new()
	back.text = "Back to world"
	back.pressed.connect(close)
	row.add_child(back)
	help_label = Label.new()
	help_label.text = "Click one of your units (blue) to possess it · WASD move · Space attack · Q breath · Esc release · drag to orbit"
	battle_ui.add_child(help_label)
	log_label = RichTextLabel.new()
	log_label.bbcode_enabled = true
	log_label.custom_minimum_size = Vector2(620, 220)
	log_label.scroll_following = true
	battle_ui.add_child(log_label)


func _log(text: String) -> void:
	log_lines.append(text)
	if log_lines.size() > 60:
		log_lines.pop_front()
	if log_label:
		log_label.text = "\n".join(log_lines)


## Copies the simulation state onto the scene.
func _sync() -> void:
	state = JSON.parse_string(arena_sim.state_json())
	var su: Array = state["units"]
	for i in units.size():
		var u: Unit = units[i]
		var d: Dictionary = su[i]
		u.alive = d["alive"]
		u.hp = int(d["hp"])
		u.max_hp = int(d["max_hp"])
		u.node.visible = u.alive
		u.node.position = Vector3(d["x"], 0, d["z"])
		var facing := Vector3(d["fx"], 0, d["fz"])
		if facing.length() > 0.01:
			u.node.look_at(u.node.position + facing, Vector3.UP, true)
		u.label.text = "%s\n%d/%d%s" % [u.name, max(u.hp, 0), u.max_hp, "  ◆" if i == possessed else ""]
	if possessed >= 0 and not units[possessed].alive:
		possessed = -1
	for line in JSON.parse_string(arena_sim.events_json()):
		_log(line)
	var a := units.filter(func(u): return u.alive and u.team == my_team).size()
	var b := units.filter(func(u): return u.alive and u.team != my_team).size()
	if status_label:
		status_label.text = "Your team: %d standing   ·   Rival: %d standing" % [a, b]
	var result = state["result"]
	if result != null and not finished:
		finished = true
		var won: bool = result == ("a" if my_team == 0 else "b")
		var text := "[b][color=#77dd77]Victory![/color][/b]" if won else ("[b]Draw.[/b]" if result == "draw" else "[b][color=#dd7777]Defeat.[/color][/b]")
		if online:
			_log(text)
		else:
			var fallen := units.filter(func(u): return not u.alive and u.team == my_team).size()
			_log("%s %d of your champions fell. (Online, in ranked matches, they would be lost forever.)" % [text, fallen])
		if status_label:
			status_label.text = "Victory!" if won else ("Draw." if result == "draw" else "Defeat.")


## Advances the battle by `dt` seconds of arena time.
func step(dt: float) -> void:
	if finished or arena_sim == null:
		return
	if possessed >= 0:
		_steer_possessed()
	if online:
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
		var want := target + back * 9.0 + Vector3(0, 6.0, 0)
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
	net = ClassDB.instantiate("NetClient")
	net.connect_to(host, port, my_name, secret, pin)
	online_button.disabled = true
	online_label.text = "Connecting to %s:%d…" % [host, port]


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
				if msg["secret"] != null:
					var cfg := _online_cfg()
					cfg.set_value(server_key, "secret_" + str(msg["account"]), msg["secret"])
					cfg.save(ONLINE_CFG)
				online_label.text = "Signed in as %s (rating %.0f). The server is replaying your world to verify your champions…" % [msg["account"], msg["rating"]["rating"]]
				pending_binds.clear()
				bound_tokens.clear()
				for c in my_roster:
					for k in my_counts.get(c["key"], 0):
						if net.bind(c["world"], c["kind"], c["id"]):
							pending_binds.append(c)
			"bound":
				pending_binds.pop_front()
				bound_tokens.append(int(msg["champion"]["token"]))
				_queue_when_bound()
			"rejected":
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
				if running and not finished:
					_log("[color=#dd7777]Disconnected: %s[/color]" % msg["reason"])
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
	online = true
	my_team = int(msg["team"])
	setup_panel.visible = false
	arena_sim = net
	for team in 2:
		var sheets: Array = msg["rosters"][team]
		var looks: Array = msg["looks"][team]
		for i in sheets.size():
			var look: Dictionary = looks[i]
			var parts := []
			for p in look["parts"]:
				parts.append({"part": p["part"], "count": p["count"], "size": float(p["size_milli"]) / 1000.0})
			var detail := {"parts": parts, "color": look["color"], "otherworldly": look["otherworldly"]}
			_spawn({"name": sheets[i]["name"], "sheet": {"size": sheets[i]["size"]}, "detail": detail}, team)
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
				sim.champion_fell(int(f["id"]))
		else:
			_log("%s lost a %s." % [f["account"], f["name"]])
	if msg["rating"] != null:
		_log("Your rating is now %.0f ± %.0f." % [msg["rating"]["rating"], msg["rating"]["deviation"]])
	if msg.get("desynced", false):
		_log("[color=#dd7777]Warning: this client fell out of step with the server.[/color]")
	net.close_connection()
	net = null


func _online_cfg() -> ConfigFile:
	var cfg := ConfigFile.new()
	cfg.load(ONLINE_CFG)
	return cfg


func _server_key() -> String:
	var host := host_edit.text.strip_edges()
	return host if host.contains(":") else "%s:%d" % [host, DEFAULT_PORT]

