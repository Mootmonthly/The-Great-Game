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
	for mode in range(4 + main.substances.size()):
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

	main.preset_select.select(4)
	main._new_world()
	main._advance(400)
	var species: Array = JSON.parse_string(sim.species_json(1))
	check(species.size() == 1 and "Silicon" in species[0]["description"], "magma world evolves silicon life")

	print("%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
