extends SceneTree
## Headless smoke test for the viewer:
##   godot --headless --path game-client -s res://tests/smoke_test.gd
## Loads the main scene, drives the UI and the simulation, and exits with a
## non-zero code on failure.

var failures := 0
## Servers started by the online checks; always killed before exiting, or
## they would keep the test's output open and hang CI.
var children: Array[int] = []


func finish() -> void:
	for pid in children:
		OS.kill(pid)
	print("%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)


func check(cond: bool, what: String) -> void:
	if cond:
		print("PASS ", what)
	else:
		failures += 1
		printerr("FAIL ", what)


func _initialize() -> void:
	# Watchdog: a stuck check fails the test instead of hanging it.
	create_timer(540.0).timeout.connect(func():
		printerr("FAIL smoke test timed out")
		failures += 1
		finish())
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
	for mode in range(8 + main.substances.size()):
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

	# Moons are worlds of their own.
	var moons: Dictionary = JSON.parse_string(sim.moons_json())
	check(moons["moons"].size() == 1 and int(moons["slots"]) == 1, "one slot holds one moon")
	sim.add_moon(1.0, 2.0)
	check(JSON.parse_string(sim.moons_json())["moons"].size() == 1, "a moon is refused when the slots are full")
	main._refresh_all()
	check(main.world_select.item_count == 2, "the world selector lists the planet and the moon")
	check(main.add_moon_button.disabled and main.add_moon_button.tooltip_text.contains("Essence"), "add moon is disabled when the slots are full")
	# The planet's hash covers its moons, so compare the planet's own region.
	var planet_region: String = sim.region_json(10, 10)
	check(sim.focus_moon(0), "a moon can be focused")
	var on_moon: Dictionary = JSON.parse_string(sim.status_json())
	check(int(on_moon["focus"]) == 0 and on_moon["host"] != null, "status shows the focused moon and its host")
	var moon_hash: String = on_moon["hash"]
	sim.add_substance(10, 10, 3, 0, 5.0)
	check(JSON.parse_string(sim.status_json())["hash"] != moon_hash, "tools change the focused moon")
	sim.focus_moon(-1)
	check(sim.region_json(10, 10) == planet_region, "tools on a moon leave the planet alone")
	check(not sim.focus_moon(5) and int(sim.focused_moon()) == -1, "focusing a missing moon fails")
	main.world_select.item_selected.emit(1)
	check(int(sim.focused_moon()) == 0 and main.planet_sliders["star_mass"]["slider"].editable == false, "the selector focuses the moon and greys out star controls")
	check(not main.planet_sliders["day_length"]["slider"].editable and main.tidal_lock_label.visible, "a tidally locked moon cannot set its day length")
	check(main.moon_info_label.visible and main.moon_info_label.text.contains("Eclipses"), "the moon info block is shown")
	main.world_select.item_selected.emit(0)
	check(int(sim.focused_moon()) == -1 and main.planet_sliders["star_mass"]["slider"].editable, "the selector returns to the planet")

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

	# Civilizations may not exist yet; the readouts must work either way.
	check(JSON.parse_string(sim.civilizations_json()) is Array, "civilizations_json is a list")
	var civ_tab := -1
	for k in main.tabs.get_tab_count():
		if main.tabs.get_tab_title(k) == "Civilizations":
			civ_tab = k
	check(civ_tab >= 0, "there is a Civilizations tab")
	if civ_tab >= 0:
		main.tabs.current_tab = civ_tab
		main._refresh_tabs()
		check(main.civ_list.text != "", "the Civilizations tab shows something")
	check(JSON.parse_string(sim.status_json()).has("civilizations"), "status reports the civilization count")
	check(JSON.parse_string(sim.region_json(3, 3)).has("settlement"), "region info has a settlement entry")

	# The metaphysical laws show up in status, the planet panel and sheets.
	main._refresh_all()
	check(main.laws_label.text == "No metaphysical laws in force.", "no laws are in force by default")
	sim.set_law_arcane(100.0)
	sim.set_law_soul(100.0)
	sim.set_law_qi(100.0)
	sim.set_law_tribulation(50.0)
	var lawful: Dictionary = JSON.parse_string(sim.status_json())
	check(lawful["law_arcane"] > 99.0 and lawful["law_soul"] > 99.0 and lawful["law_qi"] > 99.0 and absf(lawful["law_tribulation"] - 50.0) < 1.0, "metaphysical laws are reflected in the status")
	check(lawful.has("spellcasting_species") and lawful.has("reborn") and lawful.has("cultivators") and lawful.has("souls_waiting"), "status reports the law counters")
	main._refresh_all()
	check(main.laws_label.text != "No metaphysical laws in force." and main.laws_label.text.contains("Cultivators"), "the laws readout lists what the laws brought")
	var law_sheet = JSON.parse_string(sim.sheet_json("individual", int(people[0]["id"]))) if people.size() > 0 else null
	check(law_sheet != null and law_sheet.has("class"), "individual sheets carry a class entry")
	sim.set_law_arcane(0.0)
	sim.set_law_soul(0.0)
	sim.set_law_qi(0.0)
	sim.set_law_tribulation(30.0)

	# Arena: a mirror match against this world's own roster, stepped to the end.
	main.open_arena()
	var arena = main.arena
	check(arena.shop_buttons.size() == 7 and arena.shop_items.size() == 7, "the arena's shop panel lists the 7 shop items")
	check(arena.my_roster.size() > 0, "arena lists champions from this world")
	check(arena.battlefield_select != null and arena.battlefield_select.item_count == 3 + 7, "arena has a Battlefield picker (home, rival's home, random, 7 biomes)")
	var probe = ClassDB.instantiate("ArenaSim")
	var biomes: Array = JSON.parse_string(probe.biomes_json())
	check(biomes.size() == 7, "biomes_json has 7 entries")
	var home: int = probe.home_biome(sim, -1)
	check(home >= 0 and home < 7, "home_biome returns a valid index")
	var lava := -1
	for b in biomes:
		if b["name"] == "Lava field":
			lava = int(b["index"])
	var lsim = ClassDB.instantiate("ArenaSim")
	var roster: Array = arena.roster_of(sim)
	for t in 2:
		lsim.add_unit(sim, roster[0]["kind"], roster[0]["id"], t, -1)
	lsim.start(5, lava)
	var lf = JSON.parse_string(lsim.field_json())
	var has_lava := false
	for p in lf["patches"]:
		has_lava = has_lava or p["ground"] == "lava"
	check(lf["biome"] == "Lava field" and has_lava, "lava field has lava patches")
	var ls0 = JSON.parse_string(lsim.state_json())
	check(int(ls0["time_limit"]) == 600 and ls0["hold"].size() == 2, "state has time_limit 600 and a 2-element hold")
	lsim.step(300)
	var ls1 = JSON.parse_string(lsim.state_json())
	check(ls1 != null and ls1["units"].size() == 2 and (ls1["result"] == null or ls1["ended_by"] != null), "state stays valid after stepping; ended_by set when over")
	arena.use_rival_roster(arena.roster_of(sim))
	arena.battlefield_select.select(3 + lava)
	arena._start_battle()
	check(arena.field.get("biome", "") == "Lava field" and arena.field_radius > 0.0, "the arena renders the chosen battlefield")
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

	# Large army: more than 60 units per side render as MultiMeshes.
	main.open_arena()
	arena = main.arena
	arena.cap = 1000
	var cheap: Dictionary = arena.my_roster[0]
	for c in arena.my_roster:
		if c["cost"] < cheap["cost"]:
			cheap = c
	arena.my_counts = {cheap["key"]: 100}
	arena.use_rival_roster(arena.my_roster)
	arena.rival_roster = arena.my_roster
	arena._start_battle()
	check(arena.units.size() >= 120 and arena.multimeshes[0] != null, "large armies use a MultiMesh per side")
	for i in 20:
		arena.step(0.5)
	check(arena.state["time"] > 0.0 and arena.field_radius > 16.0, "large battle runs and the field grows")
	arena.close()
	await process_frame

	# Online arena: a real arena server; this client against a second one.
	var server_bin := ProjectSettings.globalize_path("res://../target/release/arena-server")
	if OS.get_name() == "Windows":
		server_bin += ".exe"
	if FileAccess.file_exists(server_bin):
		var data_dir := OS.get_user_data_dir() + "/smoke-server-%d" % int(Time.get_unix_time_from_system())
		var pid := OS.create_process(server_bin, ["serve", "--port", "7979", "--data", data_dir, "--speed", "0"])
		children.append(pid)
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
					foe.bind(sim, "species", foe_species, -1)
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
		var pid2 := OS.create_process(server_bin, ["serve", "--port", "7980", "--data", data_dir + "-paced", "--speed", "0.25"])
		children.append(pid2)
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
					foe2.bind(sim, "species", foe_species, -1)
				elif m["type"] == "bound":
					foe2.queue("ranked", arena.cap, PackedInt64Array([int(m["champion"]["token"])]))
			await process_frame
		check(arena.online, "online: a real-time match starts (%s)" % arena.online_label.text)
		# Drop the connection at once (the server runs at quarter speed, so
		# the match is still young), then rejoin. The server may need a
		# moment to notice the drop.
		if arena.net != null:
			arena.net.close_connection()
		for attempt in 3:
			await create_timer(0.5).timeout
			if arena.net != null:
				arena.net.close_connection()
				arena.net = null
			arena.find_online_match()
			started = Time.get_ticks_msec()
			while Time.get_ticks_msec() - started < 10000 and arena.net != null and not (arena.resuming and arena.units.size() >= 2):
				foe2.poll()
				await process_frame
			if arena.resuming:
				break
		check(arena.resuming and arena.units.size() >= 2, "online: a dropped player rejoins the running match (%s)" % arena.online_label.text)
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
	var pick = lv.wanderers[0]
	for cand in lv.wanderers:
		if not cand.plant:
			pick = cand
			break
	lv.possess(pick)
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

	# Humanoid and plant models.
	var CB := preload("res://creature_builder.gd")
	var human := CB.build({"parts": [{"part": "body segment", "count": 2, "size": 1.0}, {"part": "limb", "count": 4, "size": 1.0},
		{"part": "eye", "count": 2, "size": 1.0}, {"part": "brain", "count": 3, "size": 1.0}],
		"milestones": ["Multicellularity", "Nervous system", "Limbs", "Sapience"], "color": "aa8866"})
	var hbox := CB.bounds(human)
	check(human.legs.size() == 4 and hbox.size.y > hbox.size.x and absf(hbox.position.y) < 0.05, "a sapient four-limbed species is built as an upright humanoid")
	var plant_detail := {"parts": [{"part": "body segment", "count": 3, "size": 1.0}, {"part": "light-catching frond", "count": 5, "size": 1.0}],
		"milestones": ["Multicellularity"], "color": "88aa66"}
	var plant := CB.build(plant_detail)
	check(CB.is_plant(plant_detail) and plant.legs.is_empty() and plant.tentacles.size() > 0, "multicellular life without a nervous system is built as a swaying plant")
	check(not CB.is_plant({"parts": [], "milestones": []}) and not CB.is_plant({"milestones": ["Multicellularity", "Nervous system"]}), "microbes and animals are not plants")
	var kelp := CB.build({"parts": [{"part": "body segment", "count": 2, "size": 1.0}, {"part": "fin", "count": 2, "size": 1.0}, {"part": "light-catching frond", "count": 4, "size": 1.0}],
		"milestones": ["Multicellularity"], "color": "558866"})
	check(kelp.legs.is_empty() and kelp.tentacles.size() >= 2, "plants with fins become swaying kelp")
	for m in [human, plant, kelp]:
		m.free()

	# The Essence shop: elements are bought, not conjured.
	var catalogue: Array = JSON.parse_string(sim.shop_catalogue_json())
	var shop_kinds := {}
	for entry in catalogue:
		shop_kinds[entry["item"]["kind"]] = int(entry["price"])
	check(catalogue.size() == 7 and shop_kinds.get("moon_slot") == 10000 and shop_kinds.get("planet_slot") == 50000, "the shop sells 5 elements, a moon slot and a planet slot")
	var gold := -1
	var uranium := -1
	var subs: Array = JSON.parse_string(sim.substances_json())
	for k in subs.size():
		if subs[k]["name"].to_lower() == "gold":
			gold = k
		elif subs[k]["name"].to_lower() == "uranium":
			uranium = k
	check(gold >= 0 and subs[gold]["shop"] != null, "gold is marked as a shop element")
	check(not main.substance_select.is_item_disabled(main.substance_select.selected) and main.substance_select.is_item_disabled(gold), "the free tool disables shop elements")
	var gold_before := func() -> Variant:
		for s in JSON.parse_string(sim.region_json(20, 20))["substances"]:
			if s["name"].to_lower() == "gold":
				return s["amount"]
		return 0.0
	var gold_amount: Variant = gold_before.call()
	sim.add_substance(20, 20, 2, gold, 5.0)
	check(gold_before.call() == gold_amount, "the free tool cannot add gold")
	var shop_deposit := '{"id":2,"account":"me","item":{"kind":"deposit","substance":"uranium"},"signature":""}'
	check(sim.apply_purchase(shop_deposit, 20, 20), "a deposit purchase is accepted")
	var found := 0.0
	for s in JSON.parse_string(sim.region_json(20, 20))["substances"]:
		if s["name"].to_lower() == "uranium":
			found = s["amount"]
	check(uranium >= 0 and found > 0.0, "a bought deposit adds its element to the region")
	var slots_before := int(JSON.parse_string(sim.moons_json())["slots"])
	check(sim.apply_purchase('{"id":1,"account":"me","item":{"kind":"moon_slot"},"signature":""}', 0, 0), "a moon slot purchase is accepted")
	check(int(JSON.parse_string(sim.moons_json())["slots"]) == slots_before + 1, "a bought moon slot adds a moon slot")

	finish()
