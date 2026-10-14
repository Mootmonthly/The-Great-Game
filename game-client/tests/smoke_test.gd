extends SceneTree
## Headless smoke test for the viewer:
##   godot --headless --path game-client -s res://tests/smoke_test.gd
## Loads the main scene, drives the UI and the simulation, and exits with a
## non-zero code on failure.

var failures := 0


func check(cond: bool, what: String) -> void:
	if cond:
		print("PASS ", what)
	else:
		failures += 1
		printerr("FAIL ", what)


func _initialize() -> void:
	check(ClassDB.class_exists("SimWorld"), "SimWorld class is registered by the extension")
	if failures > 0:
		quit(1)
		return
	var main: Control = load("res://main.tscn").instantiate()
	root.add_child(main)
	await process_frame

	var sim = main.sim
	var st: Dictionary = JSON.parse_string(sim.status_json())
	check(st["year"] == 10, "earthlike preset settles for 10 years")
	check(st["pressure"] > 0.5, "earthlike world has an atmosphere")

	main._advance(400)
	st = JSON.parse_string(sim.status_json())
	check(st["living_species"] > 0, "life emerges after 100 years")

	var bytes: PackedByteArray = sim.overlay(0)
	check(bytes.size() == sim.width() * sim.height() * 4, "overlay has one RGBA pixel per region")
	for mode in range(5 + main.substances.size()):
		main.overlay_select.select(mode)
		main._refresh_map()
	check(main.map_rect.texture != null, "map texture is shown")

	main.tool_select.select(1)
	main._apply_tool(Vector2i(5, 5))
	main.tool_select.select(3)
	main._apply_tool(Vector2i(20, 10))
	main.tool_select.select(0)
	main._apply_tool(Vector2i(30, 16))
	check(main.region_label.text.begins_with("[b]Region (30, 16)"), "inspect tool fills region panel")

	main._toggle_play()
	for i in 30:
		main._process(0.1)
	main._toggle_play()

	var hash_before: String = JSON.parse_string(sim.status_json())["hash"]
	main._save()
	main._load()
	var hash_after: String = JSON.parse_string(sim.status_json())["hash"]
	check(hash_before == hash_after, "save and load replays to the same state hash")

	# 3D globe.
	main.globe_toggle.button_pressed = true
	await process_frame
	check(main.globe_view.albedo_texture != null and main.globe_view.albedo_texture.get_width() == 1024, "3D globe builds its surface textures")
	var atmo: Dictionary = JSON.parse_string(sim.atmosphere_json())
	check(atmo["thickness"] > 0.3, "earthlike globe has a visible atmosphere")
	sim.add_moon(1.0, 1.0)
	sim.add_moon(0.5, 0.1)
	main._refresh_all()
	var planet: Dictionary = JSON.parse_string(sim.status_json())
	check(planet["moons"].size() == 1 and planet["rings"] > 0.0, "moons can be added; a moon inside the Roche limit becomes rings")
	check(main.globe_view.moon_nodes.size() == 1 and main.globe_view.rings.visible, "globe shows moons and rings")
	main.globe_toggle.button_pressed = false

	# Species tab and detail.
	main.tabs.current_tab = 0
	main._refresh_tabs()
	var top: Array = JSON.parse_string(sim.species_json(1))
	main._on_meta("s:%d" % int(top[0]["id"]))
	check(main.species_detail.text.contains("Temperament"), "species detail shows temperament")
	check(main.species_detail.text.contains("Character sheet"), "species detail shows a character sheet")
	await process_frame
	check(main.creature_preview.visible and main.creature_preview.creature != null, "species detail shows a 3D creature model")
	var sheet = JSON.parse_string(sim.sheet_json("species", int(top[0]["id"])))
	check(sheet != null and sheet["cost"] >= 1 and sheet["cost"] <= 1000, "species sheet has a cost from 1 to 1000")

	# Family tree.
	main.tabs.current_tab = 1
	main._refresh_tabs()
	check(main.tree_view.nodes.size() > 0, "family tree has species")

	# Named individuals appear once nervous systems evolve (fast on the frozen moon).
	main.preset_select.select(2)
	main._new_world()
	main._advance(2400)
	main.tabs.current_tab = 2
	main._refresh_tabs()
	var people: Array = JSON.parse_string(sim.individuals_json(5))
	check(people.size() > 0, "named individuals appear")
	if people.size() > 0:
		main._on_meta("i:%d" % int(people[0]["id"]))
		check(main.individual_detail.text.contains("Life story"), "individual detail shows life story")
		check(main.individual_detail.text.contains("Character sheet"), "individual detail shows a character sheet")
	check(main.individual_markers.size() > 0, "individual markers are drawn on the map")

	# Arena: a mirror match against this world's own roster, stepped to the end.
	main.open_arena()
	var arena = main.arena
	check(arena.my_roster.size() > 0, "arena lists champions from this world")
	arena.use_rival_roster(arena.roster_of(sim))
	arena._start_battle()
	check(arena.units.size() >= 2, "arena spawns both teams")
	var steps := 0
	while not arena.finished and steps < 4000:
		arena.step(0.25)
		steps += 1
	check(arena.finished, "arena battle reaches a result")
	check(arena.arena_sim != null and arena.state["result"] != null, "the Rust core decided the arena result")
	arena.close()
	await process_frame
	check(main.arena == null, "leaving the arena returns to the world")

	# Online arena: a real arena server; this client against a second one.
	var server_bin := ProjectSettings.globalize_path("res://../target/release/arena-server")
	if OS.get_name() == "Windows":
		server_bin += ".exe"
	if FileAccess.file_exists(server_bin):
		var data_dir := OS.get_user_data_dir() + "/smoke-server-%d" % int(Time.get_unix_time_from_system())
		var pid := OS.create_process(server_bin, ["serve", "--port", "7979", "--data", data_dir, "--speed", "0"])
		await create_timer(1.5).timeout
		# A fresh server has a fresh certificate: forget pins from earlier runs.
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://online.cfg"))
		main.open_arena()
		arena = main.arena
		arena.my_counts = arena._auto_pick(arena.my_roster)
		arena.host_edit.text = "127.0.0.1:7979"
		arena.name_edit.text = "smoke_a"
		arena.find_online_match()
		var foe = ClassDB.instantiate("NetClient")
		foe.connect_to("127.0.0.1", 7979, "smoke_b", "", "")
		var foe_species := -1
		for sp in JSON.parse_string(sim.species_json(500)):
			if int(sp["cost"]) <= arena.cap and foe_species < 0:
				foe_species = int(sp["id"])
		var started := Time.get_ticks_msec()
		while Time.get_ticks_msec() - started < 90000 and arena.match_end.is_empty():
			for m in JSON.parse_string(foe.poll()):
				if m["type"] == "welcome":
					foe.bind(sim, "species", foe_species)
				elif m["type"] == "bound":
					foe.queue("ranked", arena.cap, PackedInt64Array([int(m["champion"]["token"])]))
			await process_frame
		check(arena.online and arena.units.size() >= 2, "online: the server verifies both teams and starts a match")
		check(not arena.match_end.is_empty() and arena.finished, "online: the match reaches a result in lockstep")
		check(not arena.match_end.get("desynced", true), "online: client and server arenas stay identical")
		var saved := ConfigFile.new()
		saved.load("user://online.cfg")
		check(saved.get_value("127.0.0.1:7979", "pin", "") != "" and saved.get_value("127.0.0.1:7979", "secret_smoke_a", "") != "", "online: the connection is encrypted; certificate and account secret are saved")
		foe.close_connection()
		arena.close()
		await process_frame
		OS.kill(pid)

		# Rejoining: a real-time server; drop the connection mid-match and
		# come back. The arena is rebuilt from the server's history.
		var pid2 := OS.create_process(server_bin, ["serve", "--port", "7980", "--data", data_dir + "-paced", "--speed", "1"])
		await create_timer(1.5).timeout
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://online.cfg"))
		main.open_arena()
		arena = main.arena
		arena.my_counts = arena._auto_pick(arena.my_roster)
		arena.host_edit.text = "127.0.0.1:7980"
		arena.name_edit.text = "smoke_c"
		arena.find_online_match()
		var foe2 = ClassDB.instantiate("NetClient")
		foe2.connect_to("127.0.0.1", 7980, "smoke_d", "", "")
		started = Time.get_ticks_msec()
		while Time.get_ticks_msec() - started < 60000 and not arena.online:
			for m in JSON.parse_string(foe2.poll()):
				if m["type"] == "welcome":
					foe2.bind(sim, "species", foe_species)
				elif m["type"] == "bound":
					foe2.queue("ranked", arena.cap, PackedInt64Array([int(m["champion"]["token"])]))
			await process_frame
		await create_timer(1.0).timeout
		arena.net.close_connection()
		await create_timer(0.5).timeout
		arena.find_online_match()
		started = Time.get_ticks_msec()
		while Time.get_ticks_msec() - started < 20000 and not (arena.resuming and arena.units.size() >= 2 and arena.state.get("time", 0.0) > 1.0):
			foe2.poll()
			await process_frame
		check(arena.resuming and arena.units.size() >= 2, "online: a dropped player rejoins the running match")
		foe2.surrender()
		started = Time.get_ticks_msec()
		while Time.get_ticks_msec() - started < 20000 and arena.match_end.is_empty():
			foe2.poll()
			await process_frame
		check(not arena.match_end.is_empty() and not arena.match_end.get("desynced", true), "online: the rejoined arena stays in step and sees the result")
		foe2.close_connection()
		arena.close()
		await process_frame
		OS.kill(pid2)
	else:
		print("skipped online arena check: build arena-server first")

	# Visit a region with life and possess one of its creatures.
	var cell := Vector2i(-1, -1)
	for y in sim.height():
		for x in sim.width():
			var reg: Dictionary = JSON.parse_string(sim.region_json(x, y))
			if reg["populations"].size() > 0 and cell.x < 0:
				cell = Vector2i(x, y)
	main.visit_region(cell)
	var lv = main.local_view
	check(lv.wanderers.size() > 0, "region visit spawns creatures from its populations")
	var before: String = JSON.parse_string(sim.status_json())["hash"]
	lv.possess(lv.wanderers[0])
	for i in 10:
		lv._process(0.1)
	check(lv.possessed != null and lv.hud.text.begins_with("Possessing"), "a creature can be possessed in first person")
	check(JSON.parse_string(sim.status_json())["hash"] == before, "possession does not change the world")
	lv.close()
	await process_frame
	check(main.local_view == null, "leaving the region returns to the world")

	main.preset_select.select(4)
	main._new_world()
	main._advance(400)
	var species: Array = JSON.parse_string(sim.species_json(1))
	check(species.size() == 1 and "Silicon" in species[0]["description"], "magma world evolves silicon life")

	# Star types and Natural/Godhand modes.
	var stars: Array = JSON.parse_string(sim.stars_json())
	check(stars.size() == 8 and main.star_select.item_count == 8, "star picker lists the 8 star types")
	main.star_select.select(0)
	main.star_select.item_selected.emit(0)
	var red: Dictionary = JSON.parse_string(sim.status_json())
	check(red["star_name"] == "Red dwarf" and red["star_luminosity"] < 0.1, "a red dwarf is dim in Natural mode")
	sim.set_star_luminosity(1.0)
	check(JSON.parse_string(sim.status_json())["star_luminosity"] < 0.2, "Natural mode caps a red dwarf's brightness")
	main.mode_select.select(1)
	main.mode_select.item_selected.emit(1)
	sim.set_star_luminosity(1.0)
	main._refresh_all()
	var god: Dictionary = JSON.parse_string(sim.status_json())
	check(god["godhand"] and god["star_luminosity"] > 0.99 and god["strain"] > 1.0, "Godhand allows an impossible star, with strain")
	check(main.star_label.text.contains("Strain"), "planet panel shows strain in Godhand mode")

	# The Veil and beings from beyond.
	main.seed_box.value = 2
	main.preset_select.select(1)
	main._new_world()
	main._advance(600)
	main.planet_sliders["veil_law"]["slider"].value = 100
	sim.set_veil_law(100.0)
	main._advance(160)
	var veiled: Dictionary = JSON.parse_string(sim.status_json())
	check(veiled["veil_law"] > 99.0 and veiled["veil_min"] < 0.5, "the Veil law thins the Veil")
	check(veiled["entity_species"] > 0 and main.veil_label.text.contains("beyond"), "beings from beyond come through an open Veil")
	main.overlay_select.select(4)
	main._refresh_map()
	check(main.map_rect.texture != null, "Veil overlay renders")
	var horror_id := -1
	for sp in JSON.parse_string(sim.species_json(500)):
		if sp["otherworldly"]:
			horror_id = int(sp["id"])
			break
	var horror_sheet = JSON.parse_string(sim.sheet_json("species", horror_id))
	check(horror_sheet != null and horror_sheet["type"] == "Aberration", "beings from beyond are Aberrations")
	main.tabs.current_tab = 0
	main._on_meta("s:%d" % horror_id)
	await process_frame
	check(main.creature_preview.creature != null and main.creature_preview.creature.tentacles.size() > 0, "beings from beyond get a model with tendrils")

	print("%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
