extends SceneTree
## Renders a gallery of evolved creatures to an image (needs a display; use
## xvfb-run on a server):
##   godot --path game-client -s res://tests/render_gallery.gd -- out.png
const CreatureBuilder := preload("res://creature_builder.gd")
func _initialize() -> void:
	var picks: Array = []
	for cfg in [["frozen_moon", 2400], ["earthlike", 2400], ["sulfur_world", 2400]]:
		var sim = ClassDB.instantiate("SimWorld")
		sim.new_world(1, cfg[0])
		sim.tick(cfg[1])
		print("ticked ", cfg[0], " ", Time.get_ticks_msec())
		var list: Array = JSON.parse_string(sim.species_json(120))
		var scored: Array = []
		for s in list:
			var d = JSON.parse_string(sim.species_detail_json(int(s["id"])))
			var kinds := {}
			for p in d["parts"]:
				kinds[p["part"]] = true
			scored.append([kinds.size(), d])
		scored.sort_custom(func(a, b): return a[0] > b[0])
		var seen := {}
		for e in scored:
			var key: String = e[1]["body"]
			if seen.has(key):
				continue
			seen[key] = true
			picks.append(e[1])
			if seen.size() >= 4:
				break
	print("picked ", picks.size(), " ", Time.get_ticks_msec())
	var world := Node3D.new()
	root.add_child(world)
	await process_frame
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.11, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.35, 0.42)
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	world.add_child(sun)
	var labels: Array = []
	for i in picks.size():
		var c := CreatureBuilder.build(picks[i])
		world.add_child(c)
		var box := CreatureBuilder.bounds(c)
		var ext: float = max(box.size.x, max(box.size.y, box.size.z))
		var s: float = 1.6 / max(ext, 0.01)
		c.scale = Vector3.ONE * s
		var col := i % 4
		var row := i / 4
		c.position = Vector3(col * 2.2 - 3.3 - box.get_center().x * s, -row * 2.3 - box.position.y * s, -box.get_center().z * s)
		c.rotation.y = 0.9
		c.pace = 0.0
		var l := Label3D.new()
		l.text = "%s\n%s" % [picks[i]["name"], picks[i]["description"]]
		l.font_size = 22
		l.pixel_size = 0.004
		l.width = 520
		l.autowrap_mode = TextServer.AUTOWRAP_WORD
		l.position = Vector3(col * 2.2 - 3.3, -row * 2.3 - 0.25, 0.9)
		world.add_child(l)
	var cam := Camera3D.new()
	cam.fov = 40
	cam.position = Vector3(0, -1.2, 10.5)
	world.add_child(cam)
	cam.make_current()
	cam.look_at(Vector3(0, -2.0, 0), Vector3.UP)
	for i in 10:
		await process_frame
	var args := OS.get_cmdline_user_args()
	var out: String = args[0] if args.size() > 0 else "user://creature-gallery.png"
	root.get_texture().get_image().save_png(out)
	print("wrote ", out)
	quit()
