extends SceneTree
## Renders a gallery of evolved creatures (with their gear) to an image (needs
## a display; use xvfb-run on a server):
##   godot --path game-client -s res://tests/render_gallery.gd -- out.png [close]
## "close" renders only the geared creatures, large; "hero" renders three at once, huge.
const CreatureBuilder := preload("res://creature_builder.gd")


func _category(d: Dictionary, sheet: Dictionary) -> String:
	var kinds := {}
	for p in d["parts"]:
		kinds[p["part"]] = true
	var geared: bool = not (sheet.get("gear", []) as Array).is_empty()
	var g := "gear " if geared else ""
	if d.get("otherworldly", false):
		return "horror"
	if CreatureBuilder.is_plant(d):
		if kinds.has("fin"):
			return "kelp"
		return "tree" if kinds.has("shell") else ("bloom" if str(d["description"]).ends_with("Bloom") else "plant")
	if kinds.is_empty():
		return "cell"
	if CreatureBuilder._is_humanoid(d, kinds_to_parts(d)):
		return g + "humanoid"
	if kinds.has("wing"):
		return g + "winged"
	if kinds.has("tentacle"):
		return g + "tentacled"
	if kinds.has("limb"):
		return g + "limbed"
	if kinds.has("fin"):
		return g + "finned"
	return g + "other"


func kinds_to_parts(d: Dictionary) -> Dictionary:
	var parts := {}
	for p in d["parts"]:
		parts[p["part"]] = p
	return parts


## Hand-made species with a full kit, so every gear slot is exercised even when
## the simulated world has not produced it.
func _synthetic() -> Array:
	var human_parts := [{"part": "body segment", "count": 2, "size": 1.0}, {"part": "limb", "count": 4, "size": 1.0},
		{"part": "eye", "count": 2, "size": 1.0}, {"part": "brain", "count": 3, "size": 1.0}]
	var sapient := ["Multicellularity", "Nervous system", "Limbs", "Sapience"]
	var warrior := {"id": 9001, "name": "Warrior", "description": "Large Sapient Hunter", "color": "b07040", "milestones": sapient,
		"parts": human_parts + [{"part": "jaw", "count": 1, "size": 1.0}, {"part": "claw", "count": 2, "size": 1.0}]}
	var wizard := {"id": 9002, "name": "Wizard", "description": "Medium Sapient Grazer", "color": "5a78c8", "milestones": sapient,
		"parts": human_parts + [{"part": "gland", "count": 1, "size": 1.0, "substance_color": "40e0ff"}]}
	var beast := {"id": 9003, "name": "Warbeast", "description": "Large Sapient Hunter", "color": "7a9a3a", "milestones": sapient,
		"parts": [{"part": "body segment", "count": 4, "size": 1.2}, {"part": "limb", "count": 6, "size": 1.0}, {"part": "eye", "count": 2, "size": 1.0},
		{"part": "brain", "count": 2, "size": 1.0}, {"part": "jaw", "count": 1, "size": 1.0}, {"part": "claw", "count": 2, "size": 1.0}, {"part": "shell", "count": 1, "size": 1.0}]}
	var drake := {"id": 9004, "name": "Drake", "description": "Large Winged Hunter", "color": "c0503a", "milestones": sapient,
		"parts": [{"part": "body segment", "count": 3, "size": 1.0}, {"part": "limb", "count": 4, "size": 1.0}, {"part": "eye", "count": 2, "size": 1.0},
		{"part": "wing", "count": 2, "size": 1.2}, {"part": "jaw", "count": 1, "size": 1.0}, {"part": "gland", "count": 1, "size": 1.0, "substance_color": "ff7020"}]}
	var kraken := {"id": 9005, "name": "Kraken", "description": "Large Tentacled Hunter", "color": "8a4aa8", "milestones": sapient,
		"parts": [{"part": "body segment", "count": 2, "size": 1.0}, {"part": "eye", "count": 2, "size": 1.0}, {"part": "brain", "count": 4, "size": 1.0},
		{"part": "tentacle", "count": 4, "size": 1.0}, {"part": "jaw", "count": 1, "size": 1.0}]}
	var horror := {"id": 9006, "name": "Horror", "description": "Large Aberration", "color": "5a3a8a", "otherworldly": true, "milestones": ["Multicellularity", "Nervous system"],
		"parts": [{"part": "body segment", "count": 3, "size": 1.2}, {"part": "eye", "count": 4, "size": 1.3}, {"part": "brain", "count": 3, "size": 1.0},
		{"part": "tendril", "count": 6, "size": 1.0}, {"part": "void", "count": 1, "size": 1.0}, {"part": "phase membrane", "count": 1, "size": 1.0}]}
	var gelk := {"id": 9007, "name": "Shellback", "description": "Large Cunning Grazer", "color": "7a7a50", "milestones": ["Multicellularity", "Nervous system", "Limbs"],
		"parts": [{"part": "body segment", "count": 3, "size": 1.0}, {"part": "limb", "count": 4, "size": 1.0}, {"part": "eye", "count": 2, "size": 1.0},
		{"part": "shell", "count": 1, "size": 1.2}, {"part": "claw", "count": 2, "size": 1.0}]}
	return [
		["fake horror", horror, {}],
		["fake shellback", gelk, {}],
		["fake warrior", warrior, {"gear": [{"name": "Enchanted tungsten war axe", "slot": "hand"}, {"name": "Tungsten shield", "slot": "hand"}, {"name": "Tungsten armour", "slot": "body"}, {"name": "Iron fang caps", "slot": "jaw"}]}],
		["fake warrior sword", warrior, {"gear": [{"name": "Iron sword", "slot": "hand"}, {"name": "Bone and wood shield", "slot": "hand"}, {"name": "Bone and wood armour", "slot": "body"}]}],
		["fake wizard", wizard, {"gear": [{"name": "Enchanted crystal spell focus", "slot": "mind"}, {"name": "Crystal breath focus", "slot": "gland"}, {"name": "Obsidian armour", "slot": "body"}]}],
		["fake wizard+sword", wizard, {"gear": [{"name": "Enchanted obsidian sword", "slot": "hand"}, {"name": "Obsidian spell focus", "slot": "mind"}]}],
		["fake warbeast", beast, {"gear": [{"name": "Chitin spear", "slot": "hand"}, {"name": "Iron shield", "slot": "hand"}, {"name": "Chitin armour", "slot": "body"}, {"name": "Enchanted tungsten fang caps", "slot": "jaw"}]}],
		["fake drake", drake, {"gear": [{"name": "Obsidian wing blades", "slot": "wing"}, {"name": "Enchanted iron armour", "slot": "body"}, {"name": "Iron breath focus", "slot": "gland"}, {"name": "Crystal spell focus", "slot": "mind"}]}],
		["fake kraken", kraken, {"gear": [{"name": "Tungsten tentacle blades", "slot": "tentacle"}, {"name": "Chitin armour", "slot": "body"}, {"name": "Iron fang caps", "slot": "jaw"}]}],
	]


func _initialize() -> void:
	var by_cat := {}
	var args0 := OS.get_cmdline_user_args()
	var worlds := [["earthlike", 4800], ["frozen_moon", 2400], ["sulfur_world", 2400], ["earthlike", 2400]]
	if args0.size() > 1 and args0[1] in ["close", "hero"]:
		worlds = []
	for cfg in worlds:
		var sim = ClassDB.instantiate("SimWorld")
		sim.new_world(1, cfg[0])
		sim.tick(cfg[1])
		print("ticked ", cfg[0], " ", Time.get_ticks_msec())
		var list: Array = JSON.parse_string(sim.species_json(200))
		for s in list:
			var d = JSON.parse_string(sim.species_detail_json(int(s["id"])))
			var sheet = JSON.parse_string(sim.sheet_json("species", int(s["id"])))
			if sheet == null:
				sheet = {}
			var cat := _category(d, sheet)
			if not by_cat.has(cat):
				by_cat[cat] = []
			if by_cat[cat].size() < 2:
				by_cat[cat].append([d, sheet])
	var close: bool = OS.get_cmdline_user_args().size() > 1 and OS.get_cmdline_user_args()[1] == "close"
	var picks: Array = []
	var order := ["gear humanoid", "gear limbed", "gear winged", "gear tentacled", "gear finned", "gear other", "horror", "tree", "bloom", "plant", "kelp", "cell", "humanoid", "limbed", "winged", "finned", "tentacled", "other"]
	for cat in order:
		if by_cat.has(cat):
			for e in by_cat[cat]:
				if close and not cat.begins_with("gear"):
					continue
				picks.append([cat, e[0], e[1]])
	var synth := _synthetic()
	var hero: bool = OS.get_cmdline_user_args().size() > 1 and OS.get_cmdline_user_args()[1] == "hero"
	if hero:
		picks = synth.filter(func(e): return e[0] in ["fake warrior", "fake wizard", "fake drake"])
	elif close:
		picks = synth
	else:
		picks.append_array(synth)
	print("categories: ", by_cat.keys())
	for p in picks:
		print(p[0], " | ", p[1]["name"], " | ", p[1]["description"], " | ", JSON.stringify(p[2].get("gear", [])))
	var world := Node3D.new()
	root.add_child(world)
	await process_frame
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.16, 0.2, 0.28)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.47, 0.55)
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	sun.light_color = Color(1.0, 0.96, 0.88)
	world.add_child(sun)
	var cols := 3 if hero else (4 if close else 6)
	var cell := 4.4 if hero else (3.2 if close else 2.2)
	var size := 3.8 if hero else (2.8 if close else 1.6)
	var rows := int(ceil(float(picks.size()) / cols))
	var total_meshes := 0
	for i in picks.size():
		var c := CreatureBuilder.build(picks[i][1], picks[i][2])
		world.add_child(c)
		var n := 0
		var stack: Array = [c]
		while not stack.is_empty():
			var nd: Node = stack.pop_back()
			if nd is MeshInstance3D:
				n += 1
			stack.append_array(nd.get_children())
		total_meshes += n
		print("meshes ", n, " ", picks[i][1]["name"])
		var box := CreatureBuilder.bounds(c)
		var ext: float = max(box.size.x, max(box.size.y, box.size.z))
		var s: float = size / max(ext, 0.01)
		c.scale = Vector3.ONE * s
		var col := i % cols
		var row := i / cols
		var cx := (col - (cols - 1) * 0.5) * cell
		c.position = Vector3(cx - box.get_center().x * s, -row * (cell * 1.05) - box.position.y * s, -box.get_center().z * s)
		c.rotation.y = 0.6
		c.pace = 0.0
		var l := Label3D.new()
		l.text = "%s\n%s" % [picks[i][1]["name"], picks[i][0]]
		l.font_size = 22
		l.pixel_size = 0.004
		l.width = 520
		l.autowrap_mode = TextServer.AUTOWRAP_WORD
		l.position = Vector3(cx, -row * (cell * 1.05) - 0.25, 0.9)
		world.add_child(l)
	var cam := Camera3D.new()
	cam.fov = 40
	var height := size * 1.2 + (rows - 1) * cell * 1.05 + 0.6
	var midy := (size * 1.1 - (rows - 1) * cell * 1.05) * 0.5
	var t20 := tan(deg_to_rad(20.0))
	var dist: float = max(height * 0.5 / t20, cols * cell * 0.5 / (t20 * 16.0 / 9.0)) + 0.9
	cam.position = Vector3(0, midy + 0.3, dist)
	world.add_child(cam)
	cam.make_current()
	cam.look_at(Vector3(0, midy, 0), Vector3.UP)
	for i in 10:
		await process_frame
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://creature-gallery.png"
	root.get_texture().get_image().save_png(out)
	print("wrote ", out, " total meshes ", total_meshes)
	quit()
