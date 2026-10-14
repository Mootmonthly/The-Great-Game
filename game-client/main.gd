extends Control
## Phase 0 world viewer.
##
## A thin UI over the Rust simulation (the `SimWorld` class from the
## godot-ext crate). The UI is built in code so the scene file stays trivial.

const SAVE_PATH := "user://world_log.json"
const BASE_OVERLAYS := ["Surface", "Temperature", "Life", "Viability"]
const TOOLS := ["Inspect", "Add substance", "Remove substance", "Heat", "Cool"]

var sim: RefCounted
var substances: Array = []
var presets: Array = []

var running := false
var tick_budget := 0.0
var paint_cooldown := 0.0
var painting := false
var refresh_timer := 0.0
var selected_region := Vector2i(-1, -1)

var map_rect: TextureRect
var map_texture: ImageTexture
var hover_label: Label
var status_label: RichTextLabel
var region_label: RichTextLabel
var species_label: RichTextLabel
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
	map_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	map_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	map_rect.mouse_filter = Control.MOUSE_FILTER_STOP
	map_rect.gui_input.connect(_on_map_input)
	left.add_child(map_rect)

	hover_label = Label.new()
	hover_label.text = "Hover over the map to see a region. Click to use the selected tool."
	left.add_child(hover_label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(420, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(panel)

	var title := Label.new()
	title.text = "The Great Game — World Viewer (Phase 0)"
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

	# Tools
	_section(panel, "God tools")
	tool_select = OptionButton.new()
	for t in TOOLS:
		tool_select.add_item(t)
	panel.add_child(tool_select)
	substance_select = OptionButton.new()
	for s in substances:
		substance_select.add_item("%s (%s)" % [s["name"], s["formula"]])
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
	_planet_slider(panel, "star_distance", "Star distance (AU)", 0.03, 10.0, 1.0, true, "set_star_distance")
	_planet_slider(panel, "star_luminosity", "Star luminosity (suns)", 0.05, 20.0, 1.0, true, "set_star_luminosity")
	_planet_slider(panel, "gravity", "Gravity (g)", 0.05, 5.0, 1.0, true, "set_gravity")
	_planet_slider(panel, "global_heat", "Global heat (K)", -200.0, 1000.0, 0.0, false, "set_global_heat")

	# Inspector
	_section(panel, "Selected region")
	region_label = _rich(200)
	region_label.text = "Use the Inspect tool and click a region."
	panel.add_child(region_label)

	_section(panel, "Top species")
	species_label = _rich(320)
	panel.add_child(species_label)


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
	selected_region = Vector2i(-1, -1)
	region_label.text = "Use the Inspect tool and click a region."
	_refresh_all()


func _toggle_play() -> void:
	running = not running
	play_button.text = "Pause" if running else "Play"


func _update_speed_label() -> void:
	speed_label.text = "%d seasons/s" % int(speed_slider.value)


func _advance(ticks: int) -> void:
	sim.tick(ticks)
	_refresh_all()


func _process(delta: float) -> void:
	if sim == null:
		return
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


func _refresh_map() -> void:
	var bytes: PackedByteArray = sim.overlay(overlay_select.selected)
	var img := Image.create_from_data(sim.width(), sim.height(), false, Image.FORMAT_RGBA8, bytes)
	if map_texture == null or map_texture.get_size() != Vector2(img.get_size()):
		map_texture = ImageTexture.create_from_image(img)
		map_rect.texture = map_texture
	else:
		map_texture.update(img)


func _refresh_text() -> void:
	var st: Dictionary = JSON.parse_string(sim.status_json())
	_sync_planet_sliders(st)
	var atmo := []
	for a in st["atmosphere"]:
		atmo.append("%s %.2f" % [a["name"], a["column"]])
	status_label.text = "[b]Year %d[/b]  (seed %d)\nMean temperature: %.1f K (%.1f °C)\nPressure: %.2f bar   Starlight: %.2f× Earth\nAtmosphere: %s\nSpecies alive: %d   (ever: %d)\n[color=#888888]State hash: %s[/color]" % [
		st["year"], st["seed"], st["mean_temperature"], st["mean_temperature"] - 273.15,
		st["pressure"], st["stellar_flux"], ", ".join(atmo) if atmo.size() > 0 else "none",
		st["living_species"], st["species_ever"], st["hash"]]

	var species: Array = JSON.parse_string(sim.species_json(12))
	var lines := []
	for s in species:
		lines.append("[color=#%s]■[/color] [b]%s[/b] — %s\n    biomass %.0f, %d regions, size %.2f, likes %.0f K" % [
			s["color"], s["name"], s["description"], s["biomass"], s["regions"], s["size"], s["temp_opt"]])
	species_label.text = "\n".join(lines) if lines.size() > 0 else "No life yet. Life needs a backbone element, a liquid medium, and an energy source."

	if selected_region.x >= 0:
		_refresh_region()


func _refresh_region() -> void:
	var r: Dictionary = JSON.parse_string(sim.region_json(selected_region.x, selected_region.y))
	var text := "[b]Region (%d, %d)[/b]\n%.1f K (%.1f °C), elevation %.2f, geothermal %.2f\n" % [
		r["x"], r["y"], r["temperature"], r["temperature"] - 273.15, r["elevation"], r["geothermal"]]
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
	region_label.text = text
