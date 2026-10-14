extends Control
## Local arena prototype (roadmap Phase 2): champions from your world fight
## champions from a rival world under a shared cost cap.
##
## Combat follows the character sheets in real time: one 5e "round" is
## ROUND_SECONDS of arena time. Units walk to the nearest enemy and attack;
## breath weapons recharge on 5–6. Click a friendly unit to possess it: WASD
## moves it, Space attacks, Q breathes, Esc releases it.
##
## This is a client-side prototype. The real arena will run the same rules
## on the server (docs/GAME_DESIGN.md §6.3).

signal closed

const CreatureBuilder := preload("res://creature_builder.gd")
const ROUND_SECONDS := 1.5
const ARENA_RADIUS := 16.0
const CAPS := [25, 50, 100, 250, 1000]
const MAX_UNITS_PER_SIDE := 40
const SIZE_SCALE := {"Tiny": 0.8, "Small": 1.1, "Medium": 1.5, "Large": 2.2, "Huge": 3.2, "Gargantuan": 4.5}
const RIVAL_PRESETS := ["earthlike", "frozen_moon", "sulfur_world"]


class Unit:
	extends RefCounted
	var sheet: Dictionary
	var detail: Dictionary
	var team := 0
	var node: Node3D
	var label: Label3D
	var hp := 1
	var max_hp := 1
	var ac := 10
	var move_speed := 2.0
	var radius := 0.5
	var breath_ready := true
	var cooldown := 0.0
	var alive := true
	var facing := Vector3.FORWARD


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
var possessed: Unit
var log_lines: Array = []
var rng := RandomNumberGenerator.new()

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
		out.append({"key": "s%d" % int(s["id"]), "name": s["name"], "hero": false, "detail": detail, "sheet": sheet, "cost": int(sheet["cost"])})
	var people: Array = JSON.parse_string(world_sim.individuals_json(300))
	people.sort_custom(func(a, b): return (a["cost"] if a["cost"] != null else 0) > (b["cost"] if b["cost"] != null else 0))
	for p in people.slice(0, 4):
		var sheet = JSON.parse_string(world_sim.sheet_json("individual", int(p["id"])))
		var detail = JSON.parse_string(world_sim.species_detail_json(int(p["species_id"])))
		if sheet == null or detail == null:
			continue
		out.append({"key": "i%d" % int(p["id"]), "name": p["title"], "hero": true, "detail": detail, "sheet": sheet, "cost": int(sheet["cost"])})
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

func _spawn(entry: Dictionary, team: int, index: int, count: int) -> void:
	var u := Unit.new()
	u.sheet = entry["sheet"]
	u.detail = entry["detail"]
	u.team = team
	u.max_hp = int(u.sheet["hit_points"])
	u.hp = u.max_hp
	u.ac = int(u.sheet["armor_class"])
	var sp: Dictionary = u.sheet["speed"]
	var best_speed: int = max(max(int(sp["walk"]), int(sp["swim"])), max(int(sp["fly"]), 10))
	u.move_speed = 0.6 + best_speed / 12.0
	var model := CreatureBuilder.build(u.detail)
	var box := CreatureBuilder.bounds(model)
	var extent: float = max(box.size.x, max(box.size.y, box.size.z))
	var s: float = SIZE_SCALE.get(u.sheet["size"], 1.0) / max(extent, 0.01)
	model.scale = Vector3.ONE * s
	model.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)
	var holder := Node3D.new()
	holder.add_child(model)
	# Team ring on the ground: blue for you, red for the rival.
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	var size_r: float = SIZE_SCALE.get(u.sheet["size"], 1.0) * 0.55
	torus.inner_radius = size_r
	torus.outer_radius = size_r + 0.12
	ring.mesh = torus
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(0.35, 0.7, 1.0) if team == 0 else Color(1.0, 0.4, 0.35)
	ring.material_override = ring_mat
	ring.position.y = 0.05
	holder.add_child(ring)
	world.add_child(holder)
	u.radius = SIZE_SCALE.get(u.sheet["size"], 1.0) * 0.5
	var row := index / 8
	var col := index % 8
	var side := -1.0 if team == 0 else 1.0
	holder.position = Vector3((col - 3.5) * 2.6, 0, side * (ARENA_RADIUS * 0.55 + row * 2.6))
	holder.look_at(Vector3(holder.position.x, 0, 0), Vector3.UP, true)
	u.node = holder
	u.label = Label3D.new()
	u.label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	u.label.font_size = 28
	u.label.pixel_size = 0.02
	u.label.outline_size = 6
	u.label.modulate = Color(0.6, 0.85, 1.0) if team == 0 else Color(1.0, 0.6, 0.55)
	u.label.position = Vector3(0, SIZE_SCALE.get(u.sheet["size"], 1.0) + 0.4, 0)
	holder.add_child(u.label)
	_update_label(u)
	units.append(u)


func _start_battle() -> void:
	setup_panel.visible = false
	var rival_counts := _auto_pick(rival_roster)
	for pair in [[my_roster, my_counts, 0], [rival_roster, rival_counts, 1]]:
		var index := 0
		var total := 0
		for c in pair[0]:
			total += pair[1].get(c["key"], 0)
		for c in pair[0]:
			for k in pair[1].get(c["key"], 0):
				_spawn(c, pair[2], index, total)
				index += 1
	_build_battle_ui()
	running = true
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


func _update_label(u: Unit) -> void:
	var name: String = u.sheet["name"]
	u.label.text = "%s\n%d/%d%s" % [name, max(u.hp, 0), u.max_hp, "  ◆" if u == possessed else ""]


func _alive(team: int) -> Array:
	return units.filter(func(u): return u.alive and u.team == team)


func _nearest_enemy(u: Unit) -> Unit:
	var best: Unit = null
	var best_d := INF
	for e: Unit in units:
		if e.alive and e.team != u.team:
			var d := u.node.position.distance_squared_to(e.node.position)
			if d < best_d:
				best_d = d
				best = e
	return best


func _roll(dice: int, sides: int) -> int:
	var total := 0
	for i in dice:
		total += rng.randi_range(1, max(sides, 1))
	return total


func _damage_after_defences(target: Unit, damage: int, kind: String) -> int:
	if kind in target.sheet["immunities"]:
		return 0
	if kind in target.sheet["resistances"]:
		return damage / 2
	if kind in target.sheet["vulnerabilities"]:
		return damage * 2
	return damage


func _hurt(target: Unit, amount: int, attacker: Unit, what: String) -> void:
	target.hp -= amount
	_update_label(target)
	if target.hp <= 0 and target.alive:
		target.alive = false
		target.node.visible = false
		if target == possessed:
			possessed = null
		_log("%s [color=#cc6666]falls[/color] to %s's %s." % [target.sheet["name"], attacker.sheet["name"], what])


func _attack(u: Unit, target: Unit) -> void:
	var allies := _alive(u.team).size()
	for a in u.sheet["attacks"]:
		for k in int(a["uses"]):
			if not target.alive:
				return
			var natural := rng.randi_range(1, 20)
			var bonus := int(a["to_hit"]) + (2 if u.sheet["pack_tactics"] and allies > 1 else 0)
			if natural == 1 or (natural != 20 and natural + bonus < target.ac):
				continue
			var dice := int(a["dice"]) * (2 if natural == 20 else 1)
			var dmg: int = max(_roll(dice, int(a["die"])) + int(a["bonus"]), 1)
			_hurt(target, _damage_after_defences(target, dmg, a["damage"]), u, a["name"].to_lower())


func _breathe(u: Unit) -> void:
	var b: Dictionary = u.sheet["breath"]
	u.breath_ready = false
	var damage := _roll(int(b["dice"]), 6)
	# The cone hits the closest enemies in front of the breather.
	var targets: Array = units.filter(func(e): return e.alive and e.team != u.team and u.facing.dot((e.node.position - u.node.position).normalized()) > 0.3)
	targets.sort_custom(func(a, c): return u.node.position.distance_squared_to(a.node.position) < u.node.position.distance_squared_to(c.node.position))
	var hit := 0
	for t: Unit in targets.slice(0, int(b["targets"])):
		var save_mod: int = int(t.sheet["abilities"][int(b["save_ability"])]["modifier"])
		var dealt := damage / 2 if rng.randi_range(1, 20) + save_mod >= int(b["dc"]) else damage
		_hurt(t, _damage_after_defences(t, dealt, b["damage"]), u, b["name"].to_lower())
		hit += 1
	_log("%s uses %s (%d %s)." % [u.sheet["name"], b["name"], hit, "target" if hit == 1 else "targets"])


func _reach(u: Unit, t: Unit) -> float:
	return u.radius + t.radius + 0.6


## Advances the battle by `dt` seconds of arena time.
func step(dt: float) -> void:
	if finished:
		return
	for u: Unit in units:
		if not u.alive:
			continue
		u.cooldown -= dt
		var target := _nearest_enemy(u)
		if target == null:
			break
		var to_target := target.node.position - u.node.position
		to_target.y = 0.0
		var dist := to_target.length()
		if u == possessed:
			_possessed_move(u, dt)
		elif dist > _reach(u, target):
			var dir := to_target / maxf(dist, 0.001)
			# Keep apart from allies so crowds spread out.
			for o: Unit in units:
				if o != u and o.alive and o.team == u.team:
					var away := u.node.position - o.node.position
					var d := away.length()
					if d < u.radius + o.radius and d > 0.001:
						dir += away / d * 0.6
			dir.y = 0.0
			u.facing = dir.normalized()
			u.node.position += u.facing * u.move_speed * dt
			var flat := Vector2(u.node.position.x, u.node.position.z)
			if flat.length() > ARENA_RADIUS:
				flat = flat.normalized() * ARENA_RADIUS
				u.node.position = Vector3(flat.x, 0, flat.y)
		elif dist > 0.001:
			u.facing = to_target / dist
		if u.facing.length() > 0.01:
			u.node.look_at(u.node.position + u.facing, Vector3.UP, true)
		if u == possessed:
			continue
		# One action per round.
		if u.cooldown <= 0.0:
			u.cooldown = ROUND_SECONDS
			if not u.breath_ready and rng.randi_range(1, 6) >= 5:
				u.breath_ready = true
			var regen := int(u.sheet["regeneration"])
			if regen > 0:
				u.hp = min(u.hp + regen, u.max_hp)
				_update_label(u)
			if u.breath_ready and u.sheet["breath"] != null and dist < 6.0:
				_breathe(u)
			elif dist <= _reach(u, target):
				_attack(u, target)
	var a := _alive(0).size()
	var b := _alive(1).size()
	if status_label:
		status_label.text = "Your team: %d standing   ·   Rival: %d standing" % [a, b]
	if a == 0 or b == 0:
		finished = true
		var fallen := units.filter(func(u): return not u.alive and u.team == 0).size()
		var result := "[b][color=#77dd77]Victory![/color][/b]" if b == 0 else "[b][color=#dd7777]Defeat.[/color][/b]"
		_log("%s %d of your champions fell. (In the full game they would be lost forever and looted by the winner.)" % [result, fallen])
		if status_label:
			status_label.text = "Victory!" if b == 0 else "Defeat."


# --- Possession -------------------------------------------------------------

func _possessed_move(u: Unit, dt: float) -> void:
	var input := Vector3.ZERO
	if Input.is_key_pressed(KEY_W):
		input.z -= 1.0
	if Input.is_key_pressed(KEY_S):
		input.z += 1.0
	if Input.is_key_pressed(KEY_A):
		input.x -= 1.0
	if Input.is_key_pressed(KEY_D):
		input.x += 1.0
	if input == Vector3.ZERO:
		return
	# Movement is relative to the follow camera.
	var basis := Basis(Vector3.UP, cam_yaw)
	var dir := (basis * input).normalized()
	u.facing = dir
	u.node.position += dir * u.move_speed * 1.2 * dt


func possess(u: Unit) -> void:
	var previous := possessed
	possessed = u
	if previous:
		_update_label(previous)
	if u:
		_update_label(u)
		_log("You possess %s." % u.sheet["name"])


func _unhandled_key_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	if event.keycode == KEY_ESCAPE:
		possess(null)
	elif possessed and possessed.alive:
		var u := possessed
		if event.keycode == KEY_SPACE and u.cooldown <= 0.0:
			var t := _nearest_enemy(u)
			if t and u.node.position.distance_to(t.node.position) <= _reach(u, t) + 0.5:
				u.cooldown = ROUND_SECONDS
				_attack(u, t)
		elif event.keycode == KEY_Q and u.breath_ready and u.sheet["breath"] != null and u.cooldown <= 0.0:
			u.cooldown = ROUND_SECONDS
			_breathe(u)


var dragging := false


func _on_view_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		dragging = event.pressed
		if event.pressed and running:
			_pick_unit(event.position)
	elif event is InputEventMouseMotion and dragging and possessed == null:
		cam_yaw -= event.relative.x * 0.005


func _pick_unit(pos: Vector2) -> void:
	var from := camera.project_ray_origin(pos)
	var dir := camera.project_ray_normal(pos)
	var best: Unit = null
	var best_d := 1.5
	for u: Unit in units:
		if not u.alive or u.team != 0:
			continue
		var c: Vector3 = u.node.position + Vector3(0, u.radius, 0)
		var t := (c - from).dot(dir)
		var d := (from + dir * t).distance_to(c)
		if d < best_d:
			best_d = d
			best = u
	if best:
		possess(best)


func _update_camera(delta: float) -> void:
	if camera == null:
		return
	if possessed and possessed.alive:
		var target := possessed.node.position
		var back := Basis(Vector3.UP, cam_yaw) * Vector3(0, 0, 1)
		var want := target + back * 9.0 + Vector3(0, 6.0, 0)
		camera.position = camera.position.lerp(want, clampf(delta * 4.0, 0.0, 1.0))
		camera.look_at(target + Vector3(0, 0.8, 0), Vector3.UP)
	else:
		_overview_camera()
