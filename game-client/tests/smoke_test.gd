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

	main.preset_select.select(4)
	main._new_world()
	main._advance(400)
	var species: Array = JSON.parse_string(sim.species_json(1))
	check(species.size() == 1 and "Silicon" in species[0]["description"], "magma world evolves silicon life")

	print("%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
