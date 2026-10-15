extends Control
## Phase 0 world viewer.
##
## A thin UI over the Rust simulation (the `SimWorld` class from the
## godot-ext crate). The UI is built in code so the scene file stays trivial.

const SAVE_PATH := "user://world_log.json"
const BASE_OVERLAYS := ["Surface", "Temperature", "Life", "Viability", "Veil", "Mana", "Qi", "Civilizations"]
const GLOBE_HINT := "Hover over the globe to see a region; click to select it."
const TOOLS := ["Inspect", "Add substance", "Remove substance", "Heat", "Cool"]
const TreeView := preload("res://tree_view.gd")
const GlobeView := preload("res://globe_view.gd")
const CreaturePreview := preload("res://creature_preview.gd")
const Arena := preload("res://arena.gd")
const LocalView := preload("res://local_view.gd")

var sim: RefCounted
var substances: Array = []
var presets: Array = []

var running := false
var tick_budget := 0.0
var paint_cooldown := 0.0
var painting := false
var refresh_timer := 0.0
var selected_region := Vector2i(-1, -1)
var selected_species := -1
var selected_individual := -1
var individual_markers: Array = []

var map_rect: TextureRect
var map_texture: ImageTexture
var hover_label: Label
var status_label: RichTextLabel
var region_label: RichTextLabel
var species_list: RichTextLabel
var species_detail: RichTextLabel
var creature_preview: SubViewportContainer
var tree_view: Control
var individuals_list: RichTextLabel
var individual_detail: RichTextLabel
var tabs: TabContainer
var civ_list: RichTextLabel
var show_individuals: CheckBox
var globe_view: SubViewportContainer
var globe_toggle: CheckButton
var heroes_toggle: CheckButton
var globe_timer := 0.0
var moons_label: RichTextLabel
var world_select: OptionButton
var moon_list_box: VBoxContainer
var moon_rows: Array = []
var moon_slots_label: Label
var moon_info_label: RichTextLabel
var tidal_lock_label: Label
var add_moon_button: Button
var remove_moon_button: Button
var moon_mass: SpinBox
var moon_distance: SpinBox
var seed_box: SpinBox
var preset_select: OptionButton
var play_button: Button
var speed_slider: HSlider
var speed_label: Label
var overlay_select: OptionButton
var tool_select: OptionButton
var substance_select: OptionButton
var amount_box: SpinBox
var radius_box: SpinBox
var planet_sliders := {}
var mode_select: OptionButton
var star_select: OptionButton
var star_label: RichTextLabel
var veil_label: RichTextLabel
var laws_label: RichTextLabel


func _ready() -> void:
	if not ClassDB.class_exists("SimWorld"):
		_show_missing_extension()
		return
	sim = ClassDB.instantiate("SimWorld")
	substances = JSON.parse_string(sim.substances_json())
	presets = JSON.parse_string(sim.presets_json())
	_build_ui()
	_new_world()


func _show_missing_extension() -> void:
	var label := Label.new()
	label.text = "The simulation extension is not loaded.\n\nBuild it from the repository root with:\n    cargo build --release\nthen restart Godot."
	label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	add_child(label)


# --- UI construction ---------------------------------------------------------

func _build_ui() -> void:
	var root := HBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_theme_constant_override("separation", 8)
	add_child(root)

	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(left)

	map_rect = TextureRect.new()
	map_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_rect.size_flags_stretch_ratio = 1.4
	map_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	map_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	map_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	map_rect.gui_input.connect(_on_map_input)
	map_rect.draw.connect(_draw_markers)
	left.add_child(map_rect)

	globe_view = GlobeView.new()
	globe_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	globe_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	globe_view.size_flags_stretch_ratio = 1.4
	globe_view.visible = false
	left.add_child(globe_view)
	globe_view.setup(sim)
	globe_view.region_picked.connect(_on_globe_picked)
	globe_view.region_hovered.connect(_on_globe_hovered)

	hover_label = Label.new()
	hover_label.text = "Hover over the map to see a region. Click to use the selected tool."
	left.add_child(hover_label)

	tabs = TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(tabs)

	var species_tab := HSplitContainer.new()
	species_tab.name = "Species"
	tabs.add_child(species_tab)
	species_list = _scroll_rich()
	species_list.meta_clicked.connect(_on_meta)
	species_tab.add_child(species_list)
	var species_right := VBoxContainer.new()
	species_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	species_tab.add_child(species_right)
	creature_preview = CreaturePreview.new()
	creature_preview.custom_minimum_size = Vector2(0, 220)
	creature_preview.visible = false
	species_right.add_child(creature_preview)
	species_detail = _scroll_rich()
	species_detail.meta_clicked.connect(_on_meta)
	species_detail.text = "Click a species to see its body, temperament and ancestry."
	species_right.add_child(species_detail)

	var tree_scroll := ScrollContainer.new()
	tree_scroll.name = "Family tree"
	tree_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tabs.add_child(tree_scroll)
	tree_view = TreeView.new()
	tree_view.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tree_view.species_selected.connect(_select_species)
	tree_scroll.add_child(tree_view)

	var people_tab := HSplitContainer.new()
	people_tab.name = "Individuals"
	tabs.add_child(people_tab)
	individuals_list = _scroll_rich()
	individuals_list.meta_clicked.connect(_on_meta)
	people_tab.add_child(individuals_list)
	individual_detail = _scroll_rich()
	individual_detail.meta_clicked.connect(_on_meta)
	individual_detail.text = "Named individuals appear once a species evolves a nervous system. Click one to read its story."
	people_tab.add_child(individual_detail)

	civ_list = _scroll_rich()
	civ_list.name = "Civilizations"
	civ_list.meta_clicked.connect(_on_meta)
	tabs.add_child(civ_list)
	# Connected last: adding the first tab already emits tab_changed.
	tabs.tab_changed.connect(func(_t): _refresh_tabs())

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(420, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(panel)

	var title := Label.new()
	title.text = "The Great Game — World Viewer (Phase 0.5)"
	title.add_theme_font_size_override("font_size", 18)
	panel.add_child(title)

	# World
	_section(panel, "World")
	var row := HBoxContainer.new()
	panel.add_child(row)
	row.add_child(_label("Seed"))
	seed_box = SpinBox.new()
	seed_box.min_value = 0
	seed_box.max_value = 999999
	seed_box.value = 1
	row.add_child(seed_box)
	preset_select = OptionButton.new()
	for p in presets:
		preset_select.add_item(p["key"])
	preset_select.select(1)
	preset_select.tooltip_text = "Starting setup. 'blank' is an empty petri dish."
	preset_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(preset_select)
	var new_button := Button.new()
	new_button.text = "New world"
	new_button.pressed.connect(_new_world)
	row.add_child(new_button)
	row = HBoxContainer.new()
	panel.add_child(row)
	var save_button := Button.new()
	save_button.text = "Save"
	save_button.pressed.connect(_save)
	row.add_child(save_button)
	var load_button := Button.new()
	load_button.text = "Load"
	load_button.pressed.connect(_load)
	row.add_child(load_button)

	# Time
	_section(panel, "Time")
	row = HBoxContainer.new()
	panel.add_child(row)
	play_button = Button.new()
	play_button.text = "Play"
	play_button.pressed.connect(_toggle_play)
	row.add_child(play_button)
	var step_button := Button.new()
	step_button.text = "+1 year"
	step_button.pressed.connect(func(): _advance(4))
	row.add_child(step_button)
	var step10_button := Button.new()
	step10_button.text = "+10 years"
	step10_button.pressed.connect(func(): _advance(40))
	row.add_child(step10_button)
	row = HBoxContainer.new()
	panel.add_child(row)
	row.add_child(_label("Speed"))
	speed_slider = HSlider.new()
	speed_slider.min_value = 1
	speed_slider.max_value = 100
	speed_slider.value = 10
	speed_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	speed_slider.value_changed.connect(func(_v): _update_speed_label())
	row.add_child(speed_slider)
	speed_label = _label("")
	row.add_child(speed_label)
	_update_speed_label()
	status_label = _rich(140)
	panel.add_child(status_label)

	# View
	_section(panel, "View")
	overlay_select = OptionButton.new()
	for name in BASE_OVERLAYS:
		overlay_select.add_item(name)
	for s in substances:
		overlay_select.add_item("Substance: %s (%s)" % [s["name"], s["formula"]])
	overlay_select.item_selected.connect(func(_i): _refresh_map())
	panel.add_child(overlay_select)
	globe_toggle = CheckButton.new()
	globe_toggle.text = "3D globe (drag to rotate, scroll to zoom)"
	globe_toggle.toggled.connect(_set_globe)
	panel.add_child(globe_toggle)
	heroes_toggle = CheckButton.new()
	heroes_toggle.text = "Show heroes on the globe"
	heroes_toggle.button_pressed = true
	heroes_toggle.toggled.connect(func(on: bool): globe_view.set_show_heroes(on))
	panel.add_child(heroes_toggle)
	show_individuals = CheckBox.new()
	show_individuals.text = "Show named individuals on the map"
	show_individuals.button_pressed = true
	show_individuals.toggled.connect(func(_b): map_rect.queue_redraw())
	panel.add_child(show_individuals)

	# Tools
	_section(panel, "God tools")
	tool_select = OptionButton.new()
	for t in TOOLS:
		tool_select.add_item(t)
	panel.add_child(tool_select)
	substance_select = OptionButton.new()
	var first_free := -1
	for s in substances:
		# Shop elements cannot be conjured for free: they are bought with Essence.
		if s.get("shop") != null:
			substance_select.add_item("%s (buy with Essence)" % s["name"])
			substance_select.set_item_disabled(substance_select.item_count - 1, true)
		else:
			substance_select.add_item("%s (%s)" % [s["name"], s["formula"]])
			if first_free < 0:
				first_free = substance_select.item_count - 1
	if first_free >= 0:
		substance_select.select(first_free)
	panel.add_child(substance_select)
	row = HBoxContainer.new()
	panel.add_child(row)
	row.add_child(_label("Amount"))
	amount_box = SpinBox.new()
	amount_box.min_value = 0.1
	amount_box.max_value = 100
	amount_box.step = 0.1
	amount_box.value = 2
	amount_box.tooltip_text = "Units of substance, or kelvin for Heat/Cool"
	row.add_child(amount_box)
	row.add_child(_label("Radius"))
	radius_box = SpinBox.new()
	radius_box.min_value = 0
	radius_box.max_value = 16
	radius_box.value = 3
	row.add_child(radius_box)

	# Planet
	_section(panel, "Planet")
	var world_row := HBoxContainer.new()
	panel.add_child(world_row)
	world_row.add_child(_label("Viewing"))
	world_select = OptionButton.new()
	world_select.add_item("Planet")
	world_select.tooltip_text = "Each moon is a full world of its own. Everything below, and every list and map, shows the world selected here."
	world_select.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	world_select.item_selected.connect(func(i): _set_focus(i - 1))
	world_row.add_child(world_select)
	var mode_row := HBoxContainer.new()
	panel.add_child(mode_row)
	mode_row.add_child(_label("Mode"))
	mode_select = OptionButton.new()
	mode_select.add_item("Natural")
	mode_select.add_item("Godhand")
	mode_select.tooltip_text = "Natural: physics links the settings (gravity from mass and radius, brightness from the star). Godhand: set anything, but impossible settings strain the world."
	mode_select.item_selected.connect(func(i):
		sim.set_godhand(i == 1)
		globe_timer = 0.0
		_refresh_all())
	mode_row.add_child(mode_select)
	mode_row.add_child(_label("Star"))
	star_select = OptionButton.new()
	for star in JSON.parse_string(sim.stars_json()):
		star_select.add_item(star["name"])
	star_select.item_selected.connect(func(i):
		sim.set_star_type(i)
		globe_timer = 0.0
		_refresh_all())
	mode_row.add_child(star_select)
	star_label = _rich(70)
	panel.add_child(star_label)
	_planet_slider(panel, "star_mass", "Star mass (suns)", 0.05, 100.0, 1.0, true, "set_star_mass")
	_planet_slider(panel, "star_distance", "Star distance (AU)", 0.01, 200.0, 1.0, true, "set_star_distance")
	_planet_slider(panel, "star_luminosity", "Star luminosity (suns)", 0.0001, 10000.0, 1.0, true, "set_star_luminosity")
	_planet_slider(panel, "planet_radius", "Planet radius (Earths)", 0.1, 20.0, 1.0, true, "set_planet_radius")
	_planet_slider(panel, "gravity", "Gravity (g)", 0.01, 50.0, 1.0, true, "set_gravity")
	_planet_slider(panel, "global_heat", "Global heat (K)", -200.0, 1000.0, 0.0, false, "set_global_heat")
	_planet_slider(panel, "day_length", "Day length (hours)", 2.0, 5000.0, 24.0, true, "set_day_length")
	_planet_slider(panel, "axial_tilt", "Axial tilt (degrees)", 0.0, 90.0, 0.0, false, "set_axial_tilt")
	tidal_lock_label = _label("")
	tidal_lock_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tidal_lock_label.add_theme_color_override("font_color", Color(0.7, 0.8, 0.95))
	panel.add_child(tidal_lock_label)

	_section(panel, "Laws")
	_planet_slider(panel, "veil_law", "Veil (% open)", 0.0, 100.0, 0.0, false, "set_veil_law")
	veil_label = _rich(50)
	panel.add_child(veil_label)
	_planet_slider(panel, "law_arcane", "Arcane Magic (%)", 0.0, 100.0, 0.0, false, "set_law_arcane")
	_planet_slider(panel, "law_soul", "Soul Power (%)", 0.0, 100.0, 0.0, false, "set_law_soul")
	_planet_slider(panel, "law_qi", "Daoist Cultivation (%)", 0.0, 100.0, 0.0, false, "set_law_qi")
	_planet_slider(panel, "law_tribulation", "Tribulation risk (%)", 0.0, 100.0, 30.0, false, "set_law_tribulation")
	laws_label = _rich(40)
	panel.add_child(laws_label)

	_section(panel, "Moons")
	moon_slots_label = _label("")
	panel.add_child(moon_slots_label)
	moons_label = _rich(40)
	panel.add_child(moons_label)
	moon_list_box = VBoxContainer.new()
	panel.add_child(moon_list_box)
	moon_info_label = _rich(40)
	panel.add_child(moon_info_label)
	var moon_row := HBoxContainer.new()
	panel.add_child(moon_row)
	moon_row.add_child(_label("Mass"))
	moon_mass = SpinBox.new()
	moon_mass.min_value = 0.01
	moon_mass.max_value = 50
	moon_mass.step = 0.01
	moon_mass.value = 1.0
	moon_mass.tooltip_text = "In lunar masses"
	moon_row.add_child(moon_mass)
	moon_row.add_child(_label("Distance"))
	moon_distance = SpinBox.new()
	moon_distance.min_value = 0.05
	moon_distance.max_value = 50
	moon_distance.step = 0.05
	moon_distance.value = 1.0
	moon_distance.tooltip_text = "In Earth–Moon distances. Below 0.3 the moon is torn into rings; beyond the stable limit it is drawn in (Natural) or strains the world (Godhand)."
	moon_row.add_child(moon_distance)
	var moon_buttons := HBoxContainer.new()
	panel.add_child(moon_buttons)
	add_moon_button = Button.new()
	add_moon_button.text = "Add moon"
	add_moon_button.pressed.connect(func():
		sim.add_moon(moon_mass.value, moon_distance.value)
		globe_timer = 0.0
		_refresh_all())
	moon_buttons.add_child(add_moon_button)
	remove_moon_button = Button.new()
	remove_moon_button.text = "Remove outermost"
	remove_moon_button.pressed.connect(func():
		var st: Dictionary = JSON.parse_string(sim.status_json())
		if st["moons"].size() > 0:
			sim.remove_moon(st["moons"].size() - 1)
			globe_timer = 0.0
			_refresh_all())
	moon_buttons.add_child(remove_moon_button)

	_section(panel, "Arena")
	var arena_button := Button.new()
	arena_button.text = "Enter the arena"
	arena_button.tooltip_text = "Pick champions from this world and fight a rival world's champions."
	arena_button.pressed.connect(open_arena)
	panel.add_child(arena_button)

	# Inspector
	_section(panel, "Selected region")
	region_label = _rich(200)
	region_label.text = "Use the Inspect tool and click a region."
	panel.add_child(region_label)
	visit_button = Button.new()
	visit_button.text = "Visit this region (ground level, possess a creature)"
	visit_button.disabled = true
	visit_button.pressed.connect(func(): visit_region(selected_region))
	panel.add_child(visit_button)



func _section(parent: Control, text: String) -> void:
	parent.add_child(HSeparator.new())
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", Color(0.9, 0.8, 0.5))
	parent.add_child(l)


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _scroll_rich() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.scroll_active = true
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.size_flags_vertical = Control.SIZE_EXPAND_FILL
	r.custom_minimum_size = Vector2(200, 120)
	return r


func _bar(v: float) -> String:
	var n := clampi(roundi(v * 10.0), 0, 10)
	return "▮".repeat(n) + "▯".repeat(10 - n)


func _rich(min_height: int) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.custom_minimum_size = Vector2(0, min_height)
	r.scroll_active = false
	return r


## Slider whose value is applied when the drag ends, so one drag logs one
## action. Log-scale sliders store log10 of the value.
func _planet_slider(parent: Control, key: String, text: String, lo: float, hi: float, initial: float, log_scale: bool, method: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var name_label := _label(text)
	name_label.custom_minimum_size = Vector2(170, 0)
	row.add_child(name_label)
	var slider := HSlider.new()
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.step = 0.001
	if log_scale:
		slider.min_value = log(lo) / log(10.0)
		slider.max_value = log(hi) / log(10.0)
		slider.value = log(initial) / log(10.0)
	else:
		slider.min_value = lo
		slider.max_value = hi
		slider.step = 1
		slider.value = initial
	row.add_child(slider)
	var value_label := _label("")
	value_label.custom_minimum_size = Vector2(60, 0)
	row.add_child(value_label)
	var entry := {"slider": slider, "label": value_label, "log": log_scale}
	planet_sliders[key] = entry
	var to_value := func(v: float) -> float: return pow(10.0, v) if log_scale else v
	slider.value_changed.connect(func(v): value_label.text = "%.2f" % to_value.call(v))
	slider.drag_ended.connect(func(changed):
		if changed:
			sim.call(method, to_value.call(slider.value))
			_refresh_all())
	value_label.text = "%.2f" % initial


func _sync_planet_sliders(status: Dictionary) -> void:
	for key in planet_sliders:
		var e: Dictionary = planet_sliders[key]
		var v: float = status[key]
		var slider: HSlider = e["slider"]
		slider.set_value_no_signal(log(max(v, 0.0001)) / log(10.0) if e["log"] else v)
		e["label"].text = "%.2f" % v


# --- Simulation control ------------------------------------------------------

func _new_world() -> void:
	running = false
	play_button.text = "Play"
	var preset: String = preset_select.get_item_text(preset_select.selected)
	sim.new_world(int(seed_box.value), preset)
	sim.focus_moon(-1)
	selected_region = Vector2i(-1, -1)
	selected_species = -1
	selected_individual = -1
	region_label.text = "Use the Inspect tool and click a region."
	globe_timer = 0.0
	_refresh_all()


func _toggle_play() -> void:
	running = not running
	play_button.text = "Pause" if running else "Play"


func _update_speed_label() -> void:
	speed_label.text = "%d seasons/s" % int(speed_slider.value)


func _advance(ticks: int) -> void:
	sim.tick(ticks)
	globe_timer = 0.0
	_refresh_all()


func _process(delta: float) -> void:
	if sim == null:
		return
	globe_timer -= delta
	if running:
		tick_budget += delta * speed_slider.value
		var ticks := int(tick_budget)
		if ticks > 0:
			tick_budget -= ticks
			sim.tick(min(ticks, 40))
			_refresh_map()
			refresh_timer -= delta
			if refresh_timer <= 0.0:
				refresh_timer = 0.5
				_refresh_text()
				_refresh_tabs()
	if painting:
		paint_cooldown -= delta
		if paint_cooldown <= 0.0:
			_apply_tool(_mouse_region())


func _save() -> void:
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f == null:
		push_error("Could not write %s" % SAVE_PATH)
		return
	f.store_string(sim.save_log())
	hover_label.text = "Saved to %s" % ProjectSettings.globalize_path(SAVE_PATH)


func _load() -> void:
	if not FileAccess.file_exists(SAVE_PATH):
		hover_label.text = "No save file yet."
		return
	var json := FileAccess.get_file_as_string(SAVE_PATH)
	hover_label.text = "Replaying saved world…"
	if sim.load_log(json):
		hover_label.text = "Loaded and replayed %s" % ProjectSettings.globalize_path(SAVE_PATH)
	sim.focus_moon(-1)
	_refresh_all()


# --- Map interaction ---------------------------------------------------------

func _map_geometry() -> Dictionary:
	var w: float = sim.width()
	var h: float = sim.height()
	var s: float = min(map_rect.size.x / w, map_rect.size.y / h)
	var offset := (map_rect.size - Vector2(w, h) * s) / 2.0
	return {"scale": s, "offset": offset}


func _mouse_region() -> Vector2i:
	return _region_at(map_rect.get_local_mouse_position())


func _region_at(pos: Vector2) -> Vector2i:
	var g := _map_geometry()
	var p: Vector2 = (pos - g["offset"]) / g["scale"]
	var cell := Vector2i(floori(p.x), floori(p.y))
	if cell.x < 0 or cell.y < 0 or cell.x >= sim.width() or cell.y >= sim.height():
		return Vector2i(-1, -1)
	return cell


func _on_map_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var cell := _region_at(event.position)
		if cell.x >= 0:
			var r: Dictionary = JSON.parse_string(sim.region_json(cell.x, cell.y))
			hover_label.text = "Region (%d, %d)   %.0f K (%.0f °C)   elevation %.2f   %d species" % [
				cell.x, cell.y, r["temperature"], r["temperature"] - 273.15, r["elevation"], r["populations"].size()]
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		painting = event.pressed and tool_select.selected != 0
		if event.pressed:
			_apply_tool(_region_at(event.position))


## A click on the globe selects the region like a click on the 2D map.
func _on_globe_picked(x: int, y: int) -> void:
	selected_region = Vector2i(x, y)
	hover_label.text = sim.region_summary(x, y)
	_refresh_all()


func _on_globe_hovered(x: int, y: int) -> void:
	hover_label.text = sim.region_summary(x, y) if x >= 0 else GLOBE_HINT


func _apply_tool(cell: Vector2i) -> void:
	if cell.x < 0:
		return
	paint_cooldown = 0.15
	var radius := int(radius_box.value)
	var amount := amount_box.value
	match tool_select.selected:
		0:
			selected_region = cell
		1:
			sim.add_substance(cell.x, cell.y, radius, substance_select.selected, amount)
		2:
			sim.add_substance(cell.x, cell.y, radius, substance_select.selected, -amount)
		3:
			sim.heat_region(cell.x, cell.y, radius, amount * 10.0)
		4:
			sim.heat_region(cell.x, cell.y, radius, -amount * 10.0)
	_refresh_all()


# --- Display -----------------------------------------------------------------

func _refresh_all() -> void:
	_refresh_map()
	_refresh_text()
	_refresh_tabs()


## Points the viewer and the tools at the planet (-1) or a moon (0..).
func _set_focus(k: int) -> void:
	sim.focus_moon(k)
	# Species and individual ids belong to one world.
	selected_species = -1
	selected_individual = -1
	species_detail.text = "Click a species to see its body, temperament and ancestry."
	individual_detail.text = "Named individuals appear once a species evolves a nervous system. Click one to read its story."
	creature_preview.visible = false
	region_label.text = "Use the Inspect tool and click a region."
	selected_region = Vector2i(-1, -1)
	visit_button.disabled = true
	globe_timer = 0.0
	_refresh_all()


func _set_globe(on: bool) -> void:
	globe_view.visible = on
	map_rect.visible = not on
	if on:
		globe_view.refresh()


func _refresh_map() -> void:
	if globe_view.visible and globe_timer <= 0.0:
		globe_timer = 1.0
		globe_view.refresh()
	var bytes: PackedByteArray = sim.overlay(overlay_select.selected)
	var img := Image.create_from_data(sim.width(), sim.height(), false, Image.FORMAT_RGBA8, bytes)
	if map_texture == null or map_texture.get_size() != Vector2(img.get_size()):
		map_texture = ImageTexture.create_from_image(img)
		map_rect.texture = map_texture
	else:
		map_texture.update(img)
	map_rect.queue_redraw()
	# The same view is blended over the globe.
	globe_view.set_overlay(img, overlay_select.selected, overlay_select.get_item_text(overlay_select.selected))


func _refresh_text() -> void:
	var st: Dictionary = JSON.parse_string(sim.status_json())
	_sync_planet_sliders(st)
	var atmo := []
	for a in st["atmosphere"]:
		atmo.append("%s %.2f" % [a["name"], a["column"]])
	status_label.text = "[b]Year %d[/b]  (seed %d)\nMean temperature: %.1f K (%.1f °C)\nPressure: %.2f bar   Starlight: %.2f× Earth\nAtmosphere: %s\nSpecies alive: %d   (ever: %d)   Named individuals: %d\n[color=#888888]State hash: %s[/color]" % [
		st["year"], st["seed"], st["mean_temperature"], st["mean_temperature"] - 273.15,
		st["pressure"], st["stellar_flux"], ", ".join(atmo) if atmo.size() > 0 else "none",
		st["living_species"], st["species_ever"], st["living_individuals"], st["hash"]]

	if st["civilizations"] > 0:
		status_label.text += "\nCivilizations: %d (%d at war)" % [st["civilizations"], st["wars"]]

	var moons: Dictionary = JSON.parse_string(sim.moons_json())
	var focus := int(sim.focused_moon())
	_refresh_moons(st, moons, focus)
	mode_select.select(1 if st["godhand"] else 0)
	star_select.select(int(st["star_type"]))
	var star_text := "[color=#%s]●[/color] %s · year %.2f Earth years · planet mass %.2f Earths\nSurface radiation %.2f× Earth's (harmful: %.2f)" % [
		st["star_color"], st["star_name"], st["year_length"], st["planet_mass"], st["radiation"], st["harmful_radiation"]]
	if st["last_flare_year"] >= 0:
		star_text += " · last flare in year %d" % st["last_flare_year"]
	if st["godhand"]:
		star_text += "\n[color=#e0a040]Strain %.2f[/color] (atmosphere loss, tidal heat)" % st["strain"]
	if st["reality_strain"] > 0.0:
		star_text += "\n[color=#b080ff]Reality strain %.2f[/color]" % st["reality_strain"]
	star_label.text = star_text
	var veil_text := "Veil: weakest %.2f, average %.2f (1 = sealed; below 0.5 things can come through)" % [st["veil_min"], st["veil_mean"]]
	if st["entity_species"] > 0:
		veil_text += "\n[color=#c080ff]%d kind%s of being from beyond[/color]" % [st["entity_species"], "" if st["entity_species"] == 1 else "s"]
	if st["last_breach_year"] >= 0:
		veil_text += " · last breach in year %d" % st["last_breach_year"]
	veil_label.text = veil_text
	var law_parts := []
	if st["law_arcane"] > 0.0:
		law_parts.append("Spellcasting species: %d" % st["spellcasting_species"])
	if st["law_soul"] > 0.0:
		law_parts.append("Reborn souls: %d (%d waiting)" % [st["reborn"], st["souls_waiting"]])
	if st["law_qi"] > 0.0:
		law_parts.append("Cultivators: %d" % st["cultivators"])
	laws_label.text = " · ".join(law_parts) if law_parts.size() > 0 else "No metaphysical laws in force."
	globe_view.set_planet(st)
	globe_view.set_selected(selected_region)

	if selected_region.x >= 0:
		_refresh_region()


## The world selector, the moon list and the controls that only the planet owns.
func _refresh_moons(st: Dictionary, moons: Dictionary, focus: int) -> void:
	var list: Array = moons["moons"]
	var slots := int(moons["slots"])
	var on_moon := focus >= 0
	# World selector: rebuilt only when moons come or go.
	if world_select.item_count != list.size() + 1:
		world_select.clear()
		world_select.add_item("Planet")
		for m in list:
			world_select.add_item("Moon %d" % (int(m["index"]) + 1))
	world_select.select(focus + 1)

	# Controls that belong to the planet stay in place but grey out.
	var planet_only := "Set on the planet"
	for key in ["star_mass", "star_distance", "star_luminosity"]:
		var slider: HSlider = planet_sliders[key]["slider"]
		slider.editable = not on_moon
		slider.tooltip_text = planet_only if on_moon else ""
	for c in [mode_select, star_select, moon_mass, moon_distance]:
		if c is SpinBox:
			c.editable = not on_moon
		else:
			c.disabled = on_moon
	mode_select.tooltip_text = planet_only if on_moon else "Natural: physics links the settings (gravity from mass and radius, brightness from the star). Godhand: set anything, but impossible settings strain the world."
	star_select.tooltip_text = planet_only if on_moon else ""
	moon_mass.tooltip_text = planet_only if on_moon else "In lunar masses"
	moon_distance.tooltip_text = planet_only if on_moon else "In Earth–Moon distances. Below 0.3 the moon is torn into rings; beyond the stable limit it is drawn in (Natural) or strains the world (Godhand)."
	var full := list.size() >= slots
	add_moon_button.disabled = on_moon or full
	remove_moon_button.disabled = on_moon or list.size() == 0
	if on_moon:
		add_moon_button.tooltip_text = planet_only
		remove_moon_button.tooltip_text = planet_only
	else:
		add_moon_button.tooltip_text = "More moon slots can be bought with Essence (10,000 each)" if full else ""
		remove_moon_button.tooltip_text = ""

	# Day length: a moon in Natural mode spins once per orbit.
	var day_slider: HSlider = planet_sliders["day_length"]["slider"]
	var host = st.get("host")
	var locked: bool = on_moon and host != null and host["tidally_locked"]
	day_slider.editable = not locked
	day_slider.tooltip_text = "Set by the moon's orbit in Natural mode" if locked else ""
	tidal_lock_label.visible = locked
	if locked:
		tidal_lock_label.text = "Tidally locked: a day lasts one month (%.1f days)" % (float(list[focus]["month_hours"]) / 24.0)

	moon_slots_label.text = "Moons: %d / %d" % [list.size(), slots]
	moon_list_box.visible = not on_moon
	moon_info_label.visible = on_moon
	if on_moon:
		var m: Dictionary = list[focus]
		moons_label.text = "[b]Moon %d[/b] of the planet · %.2f lunar masses" % [focus + 1, m["mass"]]
		moon_info_label.text = "Orbit: %.2f Earth–Moon distances\nMonth: %.1f days\nEclipses: %.1f%% of the time\nTidal heating: %.2f×\nGravity: %.2f g" % [
			m["distance"], float(m["month_hours"]) / 24.0, float(m["eclipse"]) * 100.0, m["tidal_strength"], m["gravity"]]
		return
	var moon_text := ("%d moon%s" % [list.size(), "" if list.size() == 1 else "s"]) if list.size() > 0 else "No moons."
	if st["rings"] > 0.0:
		moon_text += "\nRings: %.2f lunar masses of debris" % st["rings"]
	moon_text += "\nTides: %.2f× Earth's · day–night swing: ±%.0f K" % [st["tidal_strength"], st["day_night_swing"]]
	moon_text += "\nMoons beyond %.2f Earth–Moon distances %s." % [st["moon_limit"], "strain the world" if st["godhand"] else "are drawn in to it"]
	moons_label.text = moon_text
	_sync_moon_rows(list)


## One row per moon: summary, orbit box and a button that views that moon.
func _sync_moon_rows(list: Array) -> void:
	if moon_rows.size() != list.size():
		for r in moon_rows:
			r["row"].queue_free()
		moon_rows.clear()
		for m in list:
			var idx := int(m["index"])
			var row := HBoxContainer.new()
			moon_list_box.add_child(row)
			var info := _label("")
			info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			row.add_child(info)
			var orbit := SpinBox.new()
			orbit.min_value = 0.3
			orbit.max_value = 50.0
			orbit.step = 0.05
			orbit.suffix = "EM"
			orbit.tooltip_text = "Orbit distance in Earth–Moon distances. In Natural mode it stays between the Roche limit (0.3) and the stable limit."
			orbit.value_changed.connect(func(v):
				sim.set_moon_orbit(idx, v)
				globe_timer = 0.0
				_refresh_all())
			row.add_child(orbit)
			var view := Button.new()
			view.text = "View"
			view.pressed.connect(func(): _set_focus(idx))
			row.add_child(view)
			moon_rows.append({"row": row, "info": info, "orbit": orbit})
	for i in list.size():
		var m: Dictionary = list[i]
		var r: Dictionary = moon_rows[i]
		r["info"].text = "Moon %d: %d species, %.0f K" % [i + 1, m["living_species"], m["mean_temperature"]]
		r["orbit"].set_value_no_signal(m["distance"])


func _refresh_region() -> void:
	visit_button.disabled = false
	var r: Dictionary = JSON.parse_string(sim.region_json(selected_region.x, selected_region.y))
	var text := "[b]Region (%d, %d)[/b]\n%.1f K (%.1f °C), elevation %.2f, geothermal %.2f, Veil %.2f" % [
		r["x"], r["y"], r["temperature"], r["temperature"] - 273.15, r["elevation"], r["geothermal"], r["veil"]]
	if r["mana"] > 0.0:
		text += ", mana %.2f" % r["mana"]
	if r["qi"] > 0.0:
		text += ", qi %.2f" % r["qi"]
	text += "\n"
	var subs := []
	for s in r["substances"]:
		subs.append("%s %.2f (%s)" % [s["name"], s["amount"], s["phase"]])
	text += "Substances: %s\n" % (", ".join(subs) if subs.size() > 0 else "none")
	var best = r["best_profile"]
	if best == null:
		text += "Life triad: [color=#cc6666]not viable[/color]\n"
	else:
		text += "Life triad: %s backbone, %s medium, %s energy (viability %.2f)\n" % [
			best["backbone"], best["medium"], best["energy"], best["viability"]]
	var pops: Array = r["populations"]
	for i in range(min(pops.size(), 6)):
		var p: Dictionary = pops[i]
		text += "  • %s — %s (biomass %.1f)\n" % [p["name"], p["description"], p["biomass"]]
	if r["settlement"] != null:
		var st: Dictionary = r["settlement"]
		text += "Settlement: %s of %s (population %.1f thousand)\n" % [st["name"], st["civ"], st["population"]]
	region_label.text = text


# --- Species, family tree and individuals ----------------------------------

func _on_meta(meta) -> void:
	var m := str(meta)
	if m.begins_with("s:"):
		_select_species(int(m.substr(2)))
		tabs.current_tab = 0
	elif m.begins_with("i:"):
		selected_individual = int(m.substr(2))
		tabs.current_tab = 2
		_refresh_tabs()


func _select_species(id: int) -> void:
	selected_species = id
	_refresh_species_detail()


func _refresh_tabs() -> void:
	if sim == null:
		return
	match tabs.current_tab:
		0:
			_refresh_species_list()
			_refresh_species_detail()
		1:
			tree_view.selected = selected_species
			tree_view.set_data(JSON.parse_string(sim.tree_json(40)))
		2:
			_refresh_individuals()
		3:
			_refresh_civilizations()
	individual_markers = JSON.parse_string(sim.individuals_json(1000))
	map_rect.queue_redraw()


func _refresh_species_list() -> void:
	var species: Array = JSON.parse_string(sim.species_json(30))
	var lines := []
	for s in species:
		lines.append("[url=s:%d][color=#%s]■[/color] [b]%s[/b][/url] — %s · [color=#e8c860]cost %d[/color]\n    %s · %s · biomass %.0f" % [
			s["id"], s["color"], s["name"], s["description"], s["cost"], s["body"], s["temperament"], s["biomass"]])
	species_list.text = "\n".join(lines) if lines.size() > 0 else "No life yet. Life needs a backbone element, a liquid medium, and an energy source."


func _refresh_species_detail() -> void:
	if selected_species < 0:
		return
	var d = JSON.parse_string(sim.species_detail_json(selected_species))
	if d == null:
		species_detail.text = "That species is no longer on record."
		return
	creature_preview.visible = true
	creature_preview.show_species(d)
	var status := "alive, %d regions, biomass %.0f" % [d["regions"], d["biomass"]] if d["alive"] else "[color=#cc6666]extinct[/color]"
	var t: Dictionary = d["traits"]
	var tm: Dictionary = d["temperament_values"]
	var text := "[color=#%s]■[/color] [b]%s[/b] — %s\n%s · appeared in year %d\n" % [d["color"], d["name"], d["description"], status, d["born_year"]]
	text += "Life triad: %s backbone, %s medium, %s energy\n" % [d["profile"]["backbone"], d["profile"]["medium"], d["profile"]["energy"]]
	text += "Size %.2f · prefers %.0f K (±%.0f)\n\n" % [d["size"], d["temp_opt"], d["temp_tol"]]
	text += "[b]Milestones:[/b] %s\n" % (", ".join(d["milestones"]) if d["milestones"].size() > 0 else "none (single-celled)")
	text += "[b]Body:[/b] %s\n\n" % d["body"]
	text += "[b]Traits[/b]\n"
	for k in ["armor", "speed", "intelligence", "offense", "perception", "photosynthesis"]:
		text += "  %-14s %s\n" % [k.capitalize(), _bar(t[k])]
	text += "\n[b]Temperament[/b] (measured from its brain): %s\n" % d["temperament"]
	for k in ["aggression", "fear", "curiosity", "sociability"]:
		text += "  %-14s %s\n" % [k.capitalize(), _bar(tm[k])]
	text += "\n" + _sheet_text(JSON.parse_string(sim.sheet_json("species", selected_species)))
	text += "\n[b]Ancestry[/b] (%d descendant species, %d named individuals)\n" % [d["children"], d["individuals"]]
	if d["ancestors"].size() == 0:
		text += "  Arose spontaneously from non-living chemistry.\n"
	for a in d["ancestors"]:
		text += "  ↑ [url=s:%d]%s[/url] %s%s\n" % [a["id"], a["name"], a["description"], "" if a["alive"] else " (extinct)"]
	species_detail.text = text


func _refresh_civilizations() -> void:
	var civs: Array = JSON.parse_string(sim.civilizations_json())
	var blocks := []
	for c in civs:
		var fallen = c["fallen_year"] != null
		var b := "[color=#%s]●[/color] [b]%s[/b]" % [c["color"], c["name"]]
		if c["species"] != null:
			b += " (the [url=s:%d]%s[/url])" % [c["species_id"], c["species"]]
		if fallen:
			b += " — [i]fell in year %d[/i]" % c["fallen_year"]
		b += "\n    %s era" % c["era"]
		if c["arcana"] != "None":
			b += " · %s" % c["arcana"]
		b += "\n    %d settlement%s" % [c["settlements"], "" if c["settlements"] == 1 else "s"]
		if c["capital"] != null:
			b += ", capital %s" % c["capital"]
		b += " · population %.0f thousand\n    %s" % [c["population"], c["culture"]]
		if c["wars"].size() > 0:
			b += "\n    [color=#dd7777]At war with %s[/color]" % ", ".join(c["wars"])
		if c["allies"].size() > 0:
			b += "\n    [color=#77dd77]Allies: %s[/color]" % ", ".join(c["allies"])
		if c["rivals"].size() > 0:
			b += "\n    Rivals: %s" % ", ".join(c["rivals"])
		b += "\n    Battles won %d, lost %d · founded in year %d" % [c["battles_won"], c["battles_lost"], c["founded_year"]]
		if c["parent"] != null:
			b += " (broke away from %s)" % c["parent"]
		blocks.append("[color=#888888]%s[/color]" % b if fallen else b)
	civ_list.text = "\n\n".join(blocks) if blocks.size() > 0 else "No civilizations yet. They arise once a thinking species settles down."


func _refresh_individuals() -> void:
	var people: Array = JSON.parse_string(sim.individuals_json(40))
	var lines := []
	for p in people:
		lines.append("[url=i:%d][color=#%s]●[/color] [b]%s[/b][/url] (%s)%s, age %d · [color=#e8c860]cost %s[/color]\n    CHA %d · renown %.1f · %d friends, %d enemies · %s · now: %s" % [
			p["id"], p["color"] if p["color"] != null else "ffffff", p["title"], p["species"], (", " + p["class"]) if p["class"] != null else "", p["age"], str(int(p["cost"])) if p["cost"] != null else "-",
			p["charisma"], p["renown"], p["friends"], p["enemies"], p["personality"], p["last_action"] if p["last_action"] != null else "-"])
	individuals_list.text = "\n".join(lines) if lines.size() > 0 else "No named individuals yet. They appear once a species evolves a nervous system."
	if selected_individual < 0:
		return
	var d = JSON.parse_string(sim.individual_json(selected_individual))
	if d == null:
		individual_detail.text = "This individual has been forgotten."
		return
	var tm: Dictionary = d["temperament_values"]
	var text := "[b]%s[/b], a [url=s:%d]%s[/url]\n%s\n" % [d["title"], d["species_id"], d["species"], d["species_description"]]
	var extras := []
	if d["class"] != null:
		extras.append("[b]%s[/b]" % d["class"])
	if d["soul"] > 0.0:
		extras.append("soul %s" % _bar(d["soul"]))
	if d["realm"] != null:
		extras.append("cultivator: %s" % d["realm"])
	if d["past_life"] != null:
		extras.append("Reborn: once %s" % d["past_life"])
	if extras.size() > 0:
		text += " · ".join(extras) + "\n"
	if d["alive"]:
		text += "Age %d of about %d · health %s · at region (%d, %d)\n" % [d["age"], d["lifespan_years"], _bar(d["health"]), d["x"], d["y"]]
	else:
		text += "[color=#cc6666]Died at age %d: %s[/color]\n" % [d["age"], d["cause_of_death"]]
	text += "Charisma preview: [b]%d[/b] · renown %.1f\n\n" % [d["charisma"], d["renown"]]
	text += "[b]Personality[/b] (its own brain): %s\n" % d["personality"]
	for k in ["aggression", "fear", "curiosity", "sociability"]:
		text += "  %-14s %s\n" % [k.capitalize(), _bar(tm[k])]
	text += "\n[b]Relationships[/b]\n"
	if d["relations"].size() == 0:
		text += "  none yet\n"
	for r in d["relations"]:
		var a: float = r["affinity"]
		var mark := "[color=#77dd77]♥[/color]" if a >= 0.5 else ("[color=#dd7777]✖[/color]" if a <= -0.5 else "·")
		text += "  %s [url=i:%d]%s[/url] %+.2f%s%s\n" % [mark, r["id"], r["name"], a, " (kin)" if r["kin"] else "", "" if r["alive"] else " †"]
	text += "\n[b]Life story[/b]\n"
	for m in d["memories"]:
		text += "  Year %d: %s\n" % [m["year"], m["text"]]
	if d["alive"]:
		text += "\n" + _sheet_text(JSON.parse_string(sim.sheet_json("individual", selected_individual)))
	individual_detail.text = text


## A character sheet in the style of a tabletop stat block.
func _sheet_text(sh) -> String:
	if sh == null:
		return ""
	var t := "[bgcolor=#2a2418][color=#e8c860][b]Character sheet[/b]   cost %d / 1000[/color][/bgcolor]\n" % sh["cost"]
	t += "[i]%s %s, %s[/i]\n" % [sh["size"], sh["type"].to_lower(), sh["alignment"].to_lower()]
	if sh["class"] != null:
		t += "[b]%s[/b]\n" % sh["class"]
	var sp: Dictionary = sh["speed"]
	var speeds := ["%d ft." % sp["walk"]]
	for k in ["swim", "fly", "burrow"]:
		if sp[k] > 0:
			speeds.append("%s %d ft." % [k, sp[k]])
	t += "[b]Armor Class[/b] %d   [b]Hit Points[/b] %d (%dd%d)   [b]Speed[/b] %s\n" % [sh["armor_class"], sh["hit_points"], sh["hit_dice"], sh["hit_die"], ", ".join(speeds)]
	var scores := []
	for a in sh["abilities"]:
		scores.append("[b]%s[/b] %d (%+d)" % [a["name"], a["score"], a["modifier"]])
	t += "  ".join(scores) + "\n"
	for k in [["resistances", "Damage Resistances"], ["immunities", "Damage Immunities"], ["vulnerabilities", "Damage Vulnerabilities"]]:
		if sh[k[0]].size() > 0:
			t += "[b]%s[/b] %s\n" % [k[1], ", ".join(sh[k[0]])]
	t += "[b]Senses[/b] %s\n" % ", ".join(sh["senses"])
	if sh["languages"].size() > 0:
		t += "[b]Languages[/b] %s\n" % ", ".join(sh["languages"])
	t += "[b]Proficiency Bonus[/b] %+d\n" % sh["proficiency"]
	for tr in sh["traits"]:
		t += "[b][i]%s.[/i][/b] %s\n" % [tr["name"], tr["text"]]
	if sh["equipment"].size() > 0:
		t += "[b]Equipment[/b] %s\n" % "; ".join(sh["equipment"])
	t += "[b]Actions[/b]\n"
	for a in sh["actions"]:
		t += "  %s\n" % a
	var c: Dictionary = sh["cost_breakdown"]
	t += "[color=#999999]Cost: effective HP %.0f × damage per round %.1f → power %.1f (utility +%.0f%%, abilities ×%.2f)[/color]\n" % [
		c["effective_hp"], c["damage_per_round"], c["power"], c["utility"] * 100.0, c["stats"]]
	return t


func _draw_markers() -> void:
	if sim == null or not show_individuals.button_pressed:
		return
	var g := _map_geometry()
	var s: float = g["scale"]
	for p in individual_markers:
		var centre: Vector2 = g["offset"] + (Vector2(p["x"], p["y"]) + Vector2(0.5, 0.5)) * s
		var col := Color("#" + p["color"]) if p["color"] != null else Color.WHITE
		var radius: float = max(2.0, s * 0.22)
		map_rect.draw_circle(centre, radius + 1.0, Color.BLACK)
		map_rect.draw_circle(centre, radius, col.lightened(0.3))
		if int(p["id"]) == selected_individual:
			map_rect.draw_arc(centre, radius + 4.0, 0, TAU, 16, Color.WHITE, 2.0)


# --- Arena -------------------------------------------------------------------

var arena: Control
var local_view: Control
var visit_button: Button


func visit_region(cell: Vector2i) -> void:
	if cell.x < 0:
		return
	running = false
	play_button.text = "Play"
	local_view = LocalView.new()
	add_child(local_view)
	local_view.open(sim, cell)
	local_view.closed.connect(func(): local_view = null)


func open_arena() -> void:
	running = false
	play_button.text = "Play"
	arena = Arena.new()
	add_child(arena)
	arena.open(sim)
	arena.closed.connect(func(): arena = null)
