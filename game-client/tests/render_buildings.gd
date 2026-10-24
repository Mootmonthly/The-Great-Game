extends SceneTree
## Renders every building kind of the procedural kit to PNGs (needs a display; use xvfb-run):
##   xvfb-run -a godot --rendering-driver opengl3 --path game-client -s res://tests/render_buildings.gd
## Optional user args: --eras=1,3,4 --kinds=Hut,Forge --civ=ff8030 --out=/dir/prefix --zoom --arena
const Kit := preload("res://building_kit.gd")
const OUT := "/tmp/claude-0/-home-user-The-Great-Game/3ea39d46-4263-54a5-918a-b277bcc3d09a/scratchpad/buildings_"

var eras: Array = [1, 3, 4]
var only: Array = []
var civ := Color(0.85, 0.3, 0.25)
var out_prefix := OUT
var zoom := false
var max_w := 24.0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--eras="):
			eras = []
			for e in a.substr(7).split(","):
				eras.append(int(e))
		elif a.begins_with("--kinds="):
			only = Array(a.substr(8).split(","))
		elif a.begins_with("--civ="):
			civ = Color.html(a.substr(6))
		elif a.begins_with("--out="):
			out_prefix = a.substr(6)
		elif a == "--zoom":
			zoom = true
			max_w = 9.0
	root.size = Vector2i(1920, 1080)
	_run()


func _run() -> void:
	await process_frame
	var kinds: Array = only if only.size() > 0 else Array(Kit.KINDS)
	# chunk the kinds into rows of about `max_w` town units
	var chunks: Array = []
	var cur: Array = []
	var w := 0.0
	for k in kinds:
		var kw := Kit.footprint(k) * 2.0 + 1.3
		if w + kw > max_w and cur.size() > 0:
			chunks.append(cur)
			cur = []
			w = 0.0
		cur.append(k)
		w += kw
	if cur.size() > 0:
		chunks.append(cur)
	for era in eras:
		for ci in chunks.size():
			await _render(int(era), chunks[ci], ci, chunks.size())
	quit()


func _render(era: int, kinds: Array, ci: int, nchunks: int) -> void:
	var world := Node3D.new()
	root.add_child(world)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.55, 0.72, 0.9)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.66)
	env.ambient_light_energy = 0.9
	var we := WorldEnvironment.new()
	we.environment = env
	world.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_color = Color(1.0, 0.95, 0.84)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 80.0
	world.add_child(sun)
	var win := StandardMaterial3D.new()
	win.albedo_color = Color(1.0, 0.8, 0.45)
	win.emission_enabled = true
	win.emission = Color(1.0, 0.72, 0.3)
	win.emission_energy_multiplier = 1.6
	var x := 0.0
	var maxd := 0.0
	var tris := {}
	for k in kinds:
		var fp := Kit.footprint(k)
		var w := fp * 2.0 + 1.3
		var m := Kit.mesh(k, civ, era, win)
		tris[k] = Kit.tri_count(m)
		var n := MeshInstance3D.new()
		n.mesh = m
		n.position = Vector3(x + w * 0.5, 0, 0)
		if k == "Pier":
			n.position.z = -3.0
			w = 2.6
		world.add_child(n)
		x += w
		maxd = maxf(maxd, fp * 2.0 if k != "Pier" else 3.0)
	var cxm := x * 0.5
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(300, 300)
	ground.mesh = plane
	ground.material_override = Kit.material(Color(0.42, 0.56, 0.27), "ground")
	ground.position = Vector3(cxm, 0.0, 0.0)
	world.add_child(ground)
	var cam := Camera3D.new()
	cam.fov = 40.0
	world.add_child(cam)
	var dist := maxf(x * 0.5 / 0.647, 7.0) * 0.95 + maxd * 0.5
	var elev := deg_to_rad(32.0)
	cam.position = Vector3(cxm + dist * 0.18, 0.8 + sin(elev) * dist, cos(elev) * dist)
	cam.look_at(Vector3(cxm, 0.9, 0.0), Vector3.UP)
	await process_frame
	await process_frame
	await process_frame
	var img := root.get_texture().get_image()
	var suffix := "" if nchunks == 1 else "_%d" % ci
	var name := "%sera%d%s.png" % [out_prefix, era, suffix]
	img.save_png(name)
	print("saved ", name, " : ", ", ".join(PackedStringArray(kinds)))
	var lines: Array = []
	for k in tris:
		lines.append("%s=%d" % [k, tris[k]])
	print("tris era%d: %s" % [era, ", ".join(PackedStringArray(lines))])
	world.queue_free()
	await process_frame
