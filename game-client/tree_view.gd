extends Control
## Family tree: one horizontal line per species, from the year it appeared to
## the year it died out (or now). A vertical line joins each species to its
## parent. Click a line to select that species.

signal species_selected(id: int)

const ROW := 14
const MARGIN := 8.0

var nodes: Array = []
var year := 1
var rows := {}
var by_id := {}
var selected := -1


func set_data(data: Dictionary) -> void:
	nodes = data["nodes"]
	year = max(int(data["year"]), 1)
	by_id.clear()
	for n in nodes:
		by_id[int(n["id"])] = n
	# Depth-first order, so each lineage sits together under its parent.
	var children := {}
	var roots := []
	for n in nodes:
		var p = n["parent"]
		if p == null or not by_id.has(int(p)):
			roots.append(n)
		else:
			if not children.has(int(p)):
				children[int(p)] = []
			children[int(p)].append(n)
	var order := []
	var stack := roots.duplicate()
	stack.reverse()
	while not stack.is_empty():
		var n = stack.pop_back()
		order.append(n)
		var kids: Array = children.get(int(n["id"]), [])
		for i in range(kids.size() - 1, -1, -1):
			stack.append(kids[i])
	rows.clear()
	for i in order.size():
		rows[int(order[i]["id"])] = i
	custom_minimum_size.y = max(order.size() * ROW + 24, 120)
	queue_redraw()


func _x_for(y: float) -> float:
	return MARGIN + (y / float(year)) * (size.x - 2.0 * MARGIN - 110.0)


func _y_for(row: int) -> float:
	return 20.0 + row * ROW + ROW / 2.0


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.08, 0.1))
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(MARGIN, 14), "Year 0", HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.6, 0.6))
	draw_string(font, Vector2(_x_for(year) - 40, 14), "Year %d" % year, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.6, 0.6, 0.6))
	for n in nodes:
		var id := int(n["id"])
		if not rows.has(id):
			continue
		var y := _y_for(rows[id])
		var x0 := _x_for(float(n["born_year"]))
		var end_year = n["extinct_year"]
		var x1 := _x_for(float(year if end_year == null else end_year))
		var color := Color("#" + n["color"])
		if not n["alive"]:
			color = color.darkened(0.55)
		var p = n["parent"]
		if p != null and rows.has(int(p)):
			draw_line(Vector2(x0, _y_for(rows[int(p)])), Vector2(x0, y), color.darkened(0.3), 1.0)
		var width := 4.0 if id == selected else 2.0
		draw_line(Vector2(x0, y), Vector2(max(x1, x0 + 2.0), y), color, width)
		if n["alive"] or id == selected:
			draw_string(font, Vector2(x1 + 4, y + 4), n["name"], HORIZONTAL_ALIGNMENT_LEFT, -1, 11, color.lightened(0.2))


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var row := int(floor((event.position.y - 20.0) / ROW))
		for id in rows:
			if rows[id] == row:
				selected = id
				queue_redraw()
				species_selected.emit(id)
				return
