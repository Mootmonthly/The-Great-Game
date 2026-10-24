extends RefCounted
## Builds a stylised, hand-painted 3D creature from a species' body-part list,
## so every evolved body plan gets a model without hand modelling. The look is
## chunky and World of Warcraft-like: big heads, hands and feet, saturated
## colour, lighter bellies, readable silhouettes.
##
## Layout: the body runs along +Z (head in front), Y is up. Segments become a
## chain of rounded blobs; limbs, fins, wings, tentacles, eyes, jaws, shells,
## fronds and glands attach to them. Sapient four-limbed species stand upright
## as humanoids; mindless multicellular life becomes plants (trees, blooms,
## leafy stems, or kelp). Beings from beyond the Veil float, with tendrils,
## phase membranes and voids. CreatureAnim animates the result.
##
## Equipment: build(detail, sheet) reads sheet["gear"] ([{name, slot}]) and
## mounts weapons, shields, armour, fang caps, tentacle blades, wing blades,
## breath foci and spell foci on the matching body parts (see _attach_gear).

const SHADER := preload("res://shaders/creature.gdshader")
const GEAR_SHADER := preload("res://shaders/gear_metal.gdshader")
const CreatureAnim := preload("res://creature_anim.gd")
const SIDES: Array[float] = [-1.0, 1.0]

static var _sphere_cache := {}


# ---------------------------------------------------------------------------
# Materials and primitives
# ---------------------------------------------------------------------------

static func _material(color: Color, glow_color := Color.BLACK, glow := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("glow_color", glow_color)
	m.set_shader_parameter("glow", glow)
	return m


static func _metal(color: Color, sheen_color: Color, sheen: float, shininess := 24.0, glow_color := Color.BLACK, glow := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = GEAR_SHADER
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("glow_color", glow_color)
	m.set_shader_parameter("glow", glow)
	m.set_shader_parameter("sheen_color", sheen_color)
	m.set_shader_parameter("sheen", sheen)
	m.set_shader_parameter("shininess", shininess)
	return m


static func _mesh(parent: Node3D, mesh: Mesh, material: Material, pos: Vector3, scale := Vector3.ONE, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = material
	mi.position = pos
	mi.scale = scale
	mi.rotation = rot
	parent.add_child(mi)
	return mi


static func _sphere(r: float, radial := 16, rings := 8) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = radial
	s.rings = rings
	return s


## A unit sphere (shared per resolution) to be scaled into an ellipsoid.
static func _unit_sphere(radial := 16, rings := 8) -> SphereMesh:
	var key := radial * 100 + rings
	if not _sphere_cache.has(key):
		_sphere_cache[key] = _sphere(1.0, radial, rings)
	return _sphere_cache[key]


## An ellipsoid with the given radii on each axis.
static func _blob(parent: Node3D, material: Material, pos: Vector3, radii: Vector3, rot := Vector3.ZERO, radial := 16, rings := 8) -> MeshInstance3D:
	return _mesh(parent, _unit_sphere(radial, rings), material, pos, radii, rot)


static func _capsule(r: float, h: float, radial := 12, rings := 4) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = max(h, r * 2.0)
	c.radial_segments = radial
	c.rings = rings
	return c


static func _cone(r: float, h: float, radial := 12) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = 0.0
	c.bottom_radius = r
	c.height = h
	c.radial_segments = radial
	c.rings = 1
	return c


static func _cyl(r: float, h: float, radial := 14, top_r := -1.0) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r if top_r < 0.0 else top_r
	c.bottom_radius = r
	c.height = h
	c.radial_segments = radial
	c.rings = 1
	return c


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


## Part size (0.2..3) to a gentle visual scale.
static func _k(size: float) -> float:
	return clampf(sqrt(size), 0.5, 1.7)


static func _vivid(c: Color) -> Color:
	return Color.from_hsv(c.h, clampf(c.s * 1.0 + 0.04, 0.0, 0.92), clampf(c.v * 0.95 + 0.04, 0.4, 0.92))


## The shared paint set for a species.
static func _palette(detail: Dictionary) -> Dictionary:
	var base := _vivid(Color("#" + str(detail.get("color", "999999"))))
	var belly := Color.from_hsv(fposmod(base.h - 0.02, 1.0), clampf(base.s * 0.45, 0.0, 1.0), clampf(base.v + 0.28, 0.0, 1.0))
	var accent := Color.from_hsv(fposmod(base.h + 0.1, 1.0), clampf(base.s + 0.1, 0.0, 1.0), clampf(base.v + 0.1, 0.5, 1.0))
	var dark := Color.from_hsv(fposmod(base.h + 0.03, 1.0), clampf(base.s + 0.1, 0.0, 1.0), base.v * 0.55)
	return {
		"color": base,
		"skin": _material(base),
		"dark": _material(dark),
		"belly": _material(belly),
		"accent": _material(accent),
		"white": _material(Color(0.97, 0.97, 0.92)),
		"black": _material(Color(0.06, 0.05, 0.1)),
		"horn": _material(Color(0.93, 0.88, 0.74)),
		"eye": _material(Color(1.0, 0.98, 0.9), Color(1.0, 0.95, 0.8), 0.25),
		"hl": _material(Color(1, 1, 1), Color(1, 1, 1), 1.0),
	}


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

## Multicellular life with no nervous system, from this world: a plant.
static func is_plant(detail: Dictionary) -> bool:
	var ms: Array = detail.get("milestones", [])
	return ms.has("Multicellularity") and not ms.has("Nervous system") and not detail.get("otherworldly", false)


static func _is_humanoid(detail: Dictionary, parts: Dictionary) -> bool:
	if not (detail.get("milestones", []) as Array).has("Sapience") or not parts.has("limb") or parts.has("tentacle"):
		return false
	var segs: int = int(parts["body segment"]["count"]) if parts.has("body segment") else 1
	return int(parts["limb"]["count"]) == 4 and segs <= 2


static func build(detail: Dictionary, sheet: Dictionary = {}) -> Node3D:
	var root := Node3D.new()
	root.set_script(CreatureAnim)
	var parts := {}
	for p in detail.get("parts", []):
		parts[p["part"]] = p
	if is_plant(detail):
		return _build_plant(root, detail, parts)
	var gear := _parse_gear(sheet)
	var ctx := {"gear": gear, "humanoid": false}
	if _is_humanoid(detail, parts):
		_build_humanoid(root, detail, parts, ctx)
	else:
		_build_beast(root, detail, parts, ctx)
	if not gear.is_empty():
		_attach_gear(root, ctx)
	return root


# ---------------------------------------------------------------------------
# Eyes, brows, snouts: shared face pieces
# ---------------------------------------------------------------------------

## Eyes (up to four shown) on the front of a head centred at `c`. `zs` is the
## head's z stretch. Each has a highlight so it reads as alive.
static func _eyes(parent: Node3D, pal: Dictionary, part: Dictionary, c: Vector3, head_r: float, zs: float, dy: float) -> float:
	var n := mini(int(part["count"]), 4)
	var er := head_r * 0.26 * _k(float(part["size"]))
	for e in n:
		var row := e / 2
		var side := -1.0 if e % 2 == 0 else 1.0
		var x := side * head_r * (0.42 - 0.05 * row) if (n % 2 == 0 or e < n - 1) else 0.0
		var y := head_r * (dy - 0.28 * row)
		var depth := sqrt(maxf(0.08, 1.0 - pow(x / head_r, 2.0) - pow(y / head_r, 2.0)))
		var pos := c + Vector3(x, y, head_r * zs * depth * 0.93)
		_blob(parent, pal["eye"], pos, Vector3(er, er * 1.05, er * 0.8), Vector3.ZERO, 12, 6)
		_blob(parent, pal["black"], pos + Vector3(0, 0, er * 0.55), Vector3(er * 0.62, er * 0.7, er * 0.4), Vector3.ZERO, 10, 5)
		if e < 2:
			_mesh(parent, _unit_sphere(8, 4), pal["hl"], pos + Vector3(er * 0.22, er * 0.3, er * 0.82), Vector3.ONE * er * 0.2)
	return er


static func _brow(parent: Node3D, pal: Dictionary, c: Vector3, head_r: float, zs: float, y: float) -> void:
	var yy := y
	var depth := sqrt(maxf(0.1, 1.0 - pow(yy / head_r, 2.0)))
	_mesh(parent, _capsule(head_r * 0.07, head_r * 0.95, 8, 2), pal["dark"], c + Vector3(0, yy, head_r * zs * depth * 0.88), Vector3.ONE, Vector3(-0.15, 0, PI / 2))


static func _horns(parent: Node3D, pal: Dictionary, c: Vector3, head_r: float, k: float) -> void:
	for side: float in SIDES:
		_mesh(parent, _cone(head_r * 0.2 * k, head_r * 1.1 * k, 8), pal["horn"], c + Vector3(side * head_r * 0.55, head_r * 0.82, -head_r * 0.1), Vector3.ONE, Vector3(-0.35, 0, -side * 0.55))


static func _ears(parent: Node3D, pal: Dictionary, c: Vector3, head_r: float) -> void:
	for side: float in SIDES:
		_mesh(parent, _cone(head_r * 0.3, head_r * 0.8, 8), pal["skin"], c + Vector3(side * head_r * 0.78, head_r * 0.62, -head_r * 0.15), Vector3(1, 1, 0.45), Vector3(0, 0, -side * 0.75))


# ---------------------------------------------------------------------------
# Humanoid
# ---------------------------------------------------------------------------

## Upright two-legged, two-armed plan for sapient species. Legs then arms go
## into root.legs so the walk cycle swings each arm against its same-side leg.
static func _build_humanoid(root: Node3D, detail: Dictionary, parts: Dictionary, ctx: Dictionary) -> void:
	var pal := _palette(detail)
	var skin: Material = pal["skin"]
	var dark: Material = pal["dark"]
	var belly: Material = pal["belly"]
	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	root.body = body

	var segs: int = int(parts["body segment"]["count"]) if parts.has("body segment") else 1
	var sk: float = _k(float(parts["body segment"]["size"])) if parts.has("body segment") else 1.0
	var lk: float = _k(float(parts["limb"]["size"]))
	var leg_len := 0.46 * lk
	var arm_len := 0.4 * lk
	var tr := 0.17 * sk  # Torso radius (chest).
	var th := 0.5 * sk  # Torso height.
	var hip_y := leg_len
	var torso_y := hip_y + th * 0.5
	var shoulder_y := hip_y + th * 0.9
	var brain_k := 1.0
	if parts.has("brain"):
		brain_k += 0.12 * float(parts["brain"]["count"]) * float(parts["brain"]["size"])
	var head_r := 0.17 * sk * clampf(brain_k, 1.0, 1.7)  # Big heads.
	var head_y := hip_y + th + head_r * 0.7
	var hc := Vector3(0, head_y, 0)

	# Torso: broad chest tapering to the waist, pale belly, pelvis.
	_blob(body, skin, Vector3(0, torso_y + th * 0.12, 0), Vector3(tr * 1.15, th * 0.46, tr * 0.95))
	_blob(body, skin, Vector3(0, torso_y - th * 0.22, 0), Vector3(tr * 0.92, th * 0.34, tr * 0.85))
	_blob(body, belly, Vector3(0, torso_y - th * 0.02, tr * 0.38), Vector3(tr * 0.78, th * 0.4, tr * 0.6))
	_blob(body, dark, Vector3(0, hip_y + tr * 0.05, 0), Vector3(tr * (1.05 if segs >= 2 else 0.95), tr * 0.55, tr * 0.9))
	_blob(body, skin, hc, Vector3(head_r, head_r * 0.98, head_r * 1.02))

	var dy := 0.12
	var face_r := head_r
	if parts.has("eye"):
		_eyes(body, pal, parts["eye"], hc, head_r, 1.02, dy)
		_brow(body, pal, hc, head_r, 1.02, head_r * (dy + 0.3))
	if parts.has("jaw"):
		var jk := _k(float(parts["jaw"]["size"]))
		var jaw := Node3D.new()
		jaw.position = Vector3(0, head_y - head_r * 0.38, head_r * 0.62)
		body.add_child(jaw)
		var jl := head_r * 0.85 * jk
		var jr := head_r * 0.46 * jk
		_mesh(jaw, _cone(jr, jl, 12), dark, Vector3(0, 0, jl * 0.45), Vector3.ONE, Vector3(PI / 2, 0, 0))
		root.jaw = jaw
		ctx["jaw"] = {"node": jaw, "r": jr, "len": jl}
		# Fangs even without caps, small and bright.
		for side: float in SIDES:
			_mesh(jaw, _cone(jr * 0.14, jr * 0.45, 6), pal["white"], Vector3(side * jr * 0.4, -jr * 0.22, jl * 0.6), Vector3.ONE, Vector3(PI, 0, 0))
	else:
		_blob(body, belly, hc + Vector3(0, -head_r * 0.3, head_r * 0.82), Vector3(head_r * 0.42, head_r * 0.3, head_r * 0.3), Vector3.ZERO, 10, 5)
	if parts.has("claw") or parts.has("shell"):
		_horns(body, pal, hc, head_r, 0.8)
	else:
		_ears(body, pal, hc, head_r)

	var throat := Vector3(0, head_y - head_r * 0.98, head_r * 0.5)
	if parts.has("gland"):
		var gc := Color("#" + str(parts["gland"].get("substance_color", "ff8030")))
		_blob(body, _material(gc, gc, 1.2), throat, Vector3.ONE * head_r * 0.3 * _k(float(parts["gland"]["size"])), Vector3.ZERO, 10, 5)
		ctx["gland_color"] = gc
	ctx["throat"] = throat

	if parts.has("shell"):
		var sh := _k(float(parts["shell"]["size"]))
		_blob(body, dark, Vector3(0, torso_y + th * 0.12, tr * 0.5), Vector3(tr * 1.2 * sh, th * 0.4, tr * 0.85 * sh))

	if parts.has("light-catching frond"):
		var n := mini(int(parts["light-catching frond"]["count"]), 8)
		var leaf := _material(Color(pal["color"]).lerp(Color(0.3, 0.8, 0.3), 0.6))
		var fk := _k(float(parts["light-catching frond"]["size"]))
		for f in n:
			var ang := (float(f) / maxi(n, 1)) * TAU
			var dir := Vector3(sin(ang), 0, cos(ang))
			_blob(body, leaf, Vector3(0, shoulder_y + tr * 0.25, 0) + dir * (tr + 0.05 * fk), Vector3(0.06 * fk, 0.02, 0.15 * fk), Vector3(0.7, ang, 0), 8, 4)

	if parts.has("wing"):
		_wings(root, body, pal, parts["wing"], tr, tr * 0.4, shoulder_y, -tr * 0.8, th * 0.25, ctx)

	# Tail for beastfolk.
	if parts.has("jaw") or parts.has("claw"):
		var tail := Node3D.new()
		tail.position = Vector3(0, hip_y + tr * 0.1, -tr * 0.8)
		body.add_child(tail)
		_mesh(tail, _cone(tr * 0.5, leg_len * 1.1, 10), skin, Vector3(0, -leg_len * 0.05, -leg_len * 0.4), Vector3.ONE, Vector3(-1.75, 0, 0))
		root.tail = tail

	# Legs: chunky, with big boots.
	for side: float in SIDES:
		var hip := Node3D.new()
		hip.position = Vector3(side * tr * 0.55, hip_y, 0)
		body.add_child(hip)
		_mesh(hip, _capsule(0.085 * sk, leg_len * 0.95, 10, 3), skin, Vector3(0, -leg_len * 0.45, 0))
		var fr := 0.115 * sk
		_blob(hip, dark, Vector3(0, -leg_len + fr * 0.62, fr * 0.65), Vector3(fr * 1.0, fr * 0.62, fr * 1.55), Vector3.ZERO, 12, 6)
		root.legs.append(hip)
		root.rest_x.append(0.0)
		root.swing.append(1.0)
	# Arms: shoulders, thick arms, huge hands.
	var claws := parts.has("claw")
	ctx["humanoid"] = true
	ctx["body"] = body
	ctx["head"] = hc
	ctx["head_r"] = head_r
	ctx["shoulders"] = {}
	ctx["hand_r"] = 0.095 * sk
	ctx["arm_len"] = arm_len
	ctx["torso"] = {"tr": tr, "th": th, "torso_y": torso_y, "shoulder_y": shoulder_y, "hip_y": hip_y}
	for side: float in SIDES:
		var shoulder := Node3D.new()
		shoulder.position = Vector3(side * (tr * 1.05 + 0.04 * sk), shoulder_y, 0)
		body.add_child(shoulder)
		shoulder.rotation.z = side * 0.12
		_blob(shoulder, skin, Vector3.ZERO, Vector3.ONE * 0.085 * sk, Vector3.ZERO, 10, 5)
		_mesh(shoulder, _capsule(0.062 * sk, arm_len, 10, 3), skin, Vector3(0, -arm_len * 0.5, 0))
		var hand := _blob(shoulder, dark, Vector3(0, -arm_len - 0.01 * sk, 0), Vector3.ONE * 0.095 * sk, Vector3.ZERO, 12, 6)
		if claws:
			_mesh(shoulder, _cone(0.03 * sk, 0.14 * sk, 6), pal["white"], Vector3(0, -arm_len - 0.1 * sk, 0.05 * sk), Vector3.ONE, Vector3(PI, 0, 0))
		root.legs.append(shoulder)
		root.rest_x.append(0.0)
		root.swing.append(1.0)
		ctx["shoulders"][side] = {"node": shoulder, "hand": hand.position}


# ---------------------------------------------------------------------------
# Wings (shared)
# ---------------------------------------------------------------------------

static func _wings(root: Node3D, body: Node3D, pal: Dictionary, part: Dictionary, r: float, x0: float, y0: float, z0: float, dz: float, ctx: Dictionary) -> void:
	var n := mini(int(part["count"]), 4)
	var wk := _k(float(part["size"]))
	var color: Color = pal["color"]
	var membrane := _material(color.lightened(0.18).lerp(Color(0.95, 0.9, 1.0), 0.2))
	var edge := _material(color.lerp(pal["accent"].get_shader_parameter("base_color"), 0.5).lightened(0.05))
	var bone: Material = pal["dark"]
	var span := (r * 3.0 + 0.2) * wk
	ctx["wings"] = []
	for w in n:
		var side := -1.0 if w % 2 == 0 else 1.0
		var pivot := Node3D.new()
		pivot.position = Vector3(side * x0, y0, z0 - (w / 2) * dz * 3.0)
		body.add_child(pivot)
		var shrink := 1.0 - 0.25 * (w / 2)
		var sp := span * shrink
		# Scalloped membrane: three overlapping panels, then arm bone and a tip claw.
		_blob(pivot, membrane, Vector3(side * sp * 0.25, 0, -sp * 0.1), Vector3(sp * 0.3, 0.012, sp * 0.32), Vector3(0, side * 0.1, 0), 12, 4)
		_blob(pivot, edge, Vector3(side * sp * 0.55, 0, -sp * 0.2), Vector3(sp * 0.3, 0.012, sp * 0.3), Vector3(0, side * 0.2, 0), 12, 4)
		_blob(pivot, membrane, Vector3(side * sp * 0.83, 0, -sp * 0.28), Vector3(sp * 0.22, 0.012, sp * 0.22), Vector3(0, side * 0.3, 0), 12, 4)
		_mesh(pivot, _capsule(r * 0.07, sp * 1.05, 8, 2), bone, Vector3(side * sp * 0.5, 0.012, sp * 0.08), Vector3.ONE, Vector3(0, 0, PI / 2))
		_mesh(pivot, _cone(r * 0.1, r * 0.4, 6), pal["horn"], Vector3(side * sp * 1.04, 0.012, sp * 0.08), Vector3.ONE, Vector3(0, 0, -side * PI / 2))
		pivot.rotation.z = side * 0.55
		root.wings.append(pivot)
		root.wing_sides.append(side)
		ctx["wings"].append({"node": pivot, "side": side, "span": sp, "r": r})


# ---------------------------------------------------------------------------
# Everything that is not a humanoid or a plant
# ---------------------------------------------------------------------------

static func _build_beast(root: Node3D, detail: Dictionary, parts: Dictionary, ctx: Dictionary) -> void:
	var pal := _palette(detail)
	var color: Color = pal["color"]
	var skin: Material = pal["skin"]
	var dark: Material = pal["dark"]
	var belly: Material = pal["belly"]
	var white: Material = pal["white"]

	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	root.body = body
	ctx["body"] = body

	# Single cells: a glossy blob with a nucleus, organelles and a whip tail.
	if parts.is_empty():
		var cell := _material(color.lightened(0.15))
		_blob(body, cell, Vector3(0, 0.32, 0), Vector3(0.34, 0.28, 0.36))
		_blob(body, belly, Vector3(0, 0.22, 0.04), Vector3(0.28, 0.2, 0.3))
		_blob(body, _material(color.darkened(0.35)), Vector3(0.07, 0.48, 0.14), Vector3.ONE * 0.13, Vector3.ZERO, 12, 6)
		_blob(body, pal["hl"], Vector3(0.1, 0.55, 0.2), Vector3.ONE * 0.035, Vector3.ZERO, 6, 3)
		for i in 4:
			var a := float(i) * 1.7 + 0.5
			_blob(body, pal["accent"], Vector3(cos(a) * 0.27, 0.34 + sin(a * 2.0) * 0.08, sin(a) * 0.28), Vector3.ONE * 0.06, Vector3.ZERO, 8, 4)
		for i in 6:
			var a2 := float(i) / 6.0 * TAU
			_mesh(body, _cone(0.015, 0.1, 5), dark, Vector3(cos(a2) * 0.35, 0.3, sin(a2) * 0.38), Vector3.ONE, Vector3(sin(a2) * -1.5, 0, cos(a2) * 1.5))
		var tail := Node3D.new()
		tail.position = Vector3(0, 0.3, -0.34)
		body.add_child(tail)
		_mesh(tail, _capsule(0.025, 0.45, 8, 2), dark, Vector3(0, 0, -0.22), Vector3.ONE, Vector3(PI / 2, 0, 0))
		root.tentacles.append([tail])
		root.blob = true
		return

	var segs: int = mini(int(parts["body segment"]["count"]), 7) if parts.has("body segment") else 1
	var seg_k: float = _k(float(parts["body segment"]["size"])) if parts.has("body segment") else 1.0
	var r := 0.23 * seg_k
	var spacing := r * 1.4
	var has_limbs := parts.has("limb")
	var limb_n := mini(int(parts["limb"]["count"]), 8) if has_limbs else 0
	var leg_len := 0.34 * (_k(float(parts["limb"]["size"])) if has_limbs else 1.0)
	var fr := r * 0.3
	var base_y := r * 0.2 + leg_len * 0.9 + fr * 0.6 if has_limbs else (0.55 if parts.has("fin") or parts.has("wing") else r)
	var otherworldly: bool = detail.get("otherworldly", false)
	if otherworldly:
		base_y = r * 2.5 + 0.35  # Drifts above the ground, unbound by gravity.
	body.position.y = base_y
	if otherworldly:
		pal["eye"] = _material(Color(0.95, 0.8, 1.0), Color(0.8, 0.4, 1.0), 1.4)

	var seg_z: Array[float] = []
	for i in segs:
		seg_z.append((segs - 1) * spacing * 0.5 - i * spacing)
	var brain_k := 1.0
	if parts.has("brain"):
		brain_k += 0.12 * float(parts["brain"]["count"]) * float(parts["brain"]["size"])
	var head_r := r * clampf(brain_k, 1.0, 1.8) * 1.12
	var armored := parts.has("shell") or parts.has("claw")
	for i in segs:
		var rr := head_r if i == 0 else r * (1.0 - 0.05 * i)
		_blob(body, skin, Vector3(0, 0, seg_z[i]), Vector3(rr * 0.98, rr * 0.9, rr * 1.12))
		if i < 3:
			_blob(body, belly, Vector3(0, -rr * 0.3, seg_z[i] + (rr * 0.12 if i == 0 else 0.0)), Vector3(rr * 0.8, rr * 0.55, rr * 0.95), Vector3.ZERO, 12, 6)
		if armored and i > 0 and i < 5 and not ctx["gear"].has("body"):
			_mesh(body, _cone(rr * 0.16, rr * 0.55, 6), pal["horn"], Vector3(0, rr * 0.88, seg_z[i]), Vector3.ONE, Vector3(-0.2, 0, 0))
	var head_z: float = seg_z[0]
	var back_z: float = seg_z[segs - 1]
	var hc := Vector3(0, 0, head_z)
	ctx["head"] = hc
	ctx["head_r"] = head_r
	var segdata: Array = []
	for i in mini(segs, 4):
		segdata.append({"z": seg_z[i], "r": head_r if i == 0 else r * (1.0 - 0.05 * i)})
	ctx["segs"] = segdata

	if parts.has("eye"):
		_eyes(body, pal, parts["eye"], hc, head_r, 1.12, 0.36)
		_brow(body, pal, hc, head_r, 1.12, head_r * 0.68)
	if armored and not parts.has("wing"):
		_horns(body, pal, hc, head_r, 0.8)
	elif has_limbs:
		_ears(body, pal, hc, head_r)
	var throat := Vector3(0, -head_r * 0.55, head_z + head_r * 0.45)
	ctx["throat"] = throat

	if parts.has("jaw"):
		var jk := _k(float(parts["jaw"]["size"]))
		var jaw := Node3D.new()
		jaw.position = Vector3(0, -head_r * 0.25, head_z + head_r * 0.72)
		body.add_child(jaw)
		var jl := head_r * 0.95 * jk
		var jr := head_r * 0.5 * jk
		_mesh(jaw, _cone(jr, jl, 12), dark, Vector3(0, 0, jl * 0.42), Vector3.ONE, Vector3(PI / 2, 0, 0))
		for side: float in SIDES:
			_mesh(jaw, _cone(jr * 0.13, jr * 0.4, 6), white, Vector3(side * jr * 0.42, -jr * 0.2, jl * 0.55), Vector3.ONE, Vector3(PI, 0, 0))
		root.jaw = jaw
		ctx["jaw"] = {"node": jaw, "r": jr, "len": jl}
	elif has_limbs:
		_blob(body, belly, Vector3(0, -head_r * 0.28, head_z + head_r * 0.9), Vector3(head_r * 0.5, head_r * 0.34, head_r * 0.4), Vector3.ZERO, 12, 6)
		for side: float in SIDES:
			_blob(body, pal["black"], Vector3(side * head_r * 0.14, -head_r * 0.14, head_z + head_r * 1.28), Vector3.ONE * head_r * 0.06, Vector3.ZERO, 6, 3)

	if parts.has("gland"):
		var gc := Color("#" + str(parts["gland"].get("substance_color", "ff8030")))
		_blob(body, _material(gc, gc, 1.2), throat, Vector3.ONE * head_r * 0.36 * _k(float(parts["gland"]["size"])), Vector3.ZERO, 10, 5)
		ctx["gland_color"] = gc

	# Shell: a domed carapace with rim and ridge.
	if parts.has("shell"):
		var sk := _k(float(parts["shell"]["size"]))
		var mid := (head_z + back_z) * 0.5
		var length := absf(head_z - back_z) + r * 2.0
		_blob(body, dark, Vector3(0, r * 0.3, mid), Vector3(r * 1.25 * sk, r * 1.0 * sk, length * 0.6), Vector3.ZERO, 16, 8)
		_blob(body, pal["accent"], Vector3(0, r * 0.95 * sk, mid), Vector3(r * 0.35, r * 0.25, length * 0.45), Vector3.ZERO, 10, 5)

	if parts.has("light-catching frond"):
		var n := mini(int(parts["light-catching frond"]["count"]), 8)
		var leaf := _material(color.lerp(Color(0.3, 0.8, 0.3), 0.6))
		var fk := _k(float(parts["light-catching frond"]["size"]))
		for f in n:
			var ang := (float(f) / maxi(n, 1)) * TAU
			_blob(body, leaf, Vector3(cos(ang) * r * 0.4, r * 0.95, back_z * 0.5 + sin(ang) * r * 0.4),
				Vector3(r * 0.5 * fk, r * 0.08, r * 1.0 * fk), Vector3(0.6, ang, 0), 10, 4)

	# Limbs in pairs along the body: stout legs with big paws.
	var front_legs: Dictionary = {}
	if has_limbs:
		var n := limb_n
		var pairs := int(ceil(n / 2.0))
		var claws := parts.has("claw")
		for k in pairs:
			var t := 0.0 if pairs == 1 else float(k) / (pairs - 1)
			var z := lerpf(head_z - spacing * 0.35, back_z + spacing * 0.2, t) if segs > 1 else lerpf(r * 0.5, -r * 0.5, t)
			for side: float in SIDES:
				if k * 2 + (0 if side < 0 else 1) >= n:
					continue
				var hip := Node3D.new()
				hip.position = Vector3(side * r * 0.8, -r * 0.2, z)
				body.add_child(hip)
				_mesh(hip, _capsule(r * 0.22, leg_len, 10, 3), skin, Vector3(side * leg_len * 0.18, -leg_len * 0.45, 0), Vector3.ONE, Vector3(0, 0, side * 0.35))
				var foot_pos := Vector3(side * leg_len * 0.35, -leg_len * 0.9, r * 0.12)
				_blob(hip, dark, foot_pos, Vector3(fr * 1.0, fr * 0.6, fr * 1.4), Vector3.ZERO, 12, 6)
				if claws and k == 0:
					for c in 2:
						_mesh(hip, _cone(r * 0.05, r * 0.3, 6), white, foot_pos + Vector3((c - 0.5) * r * 0.2, -fr * 0.1, r * 0.35), Vector3.ONE, Vector3(PI / 2, 0, 0))
				root.legs.append(hip)
				root.rest_x.append(0.0)
				root.swing.append(1.0)
				if k == 0:
					front_legs[side] = {"node": hip, "foot": foot_pos}
	ctx["front_legs"] = front_legs
	ctx["hand_r"] = fr * 1.2

	# Fins: dorsal sail, forked tail and side paddles.
	var fin_tail := false
	if parts.has("fin"):
		var n := mini(int(parts["fin"]["count"]), 5)
		var fk := _k(float(parts["fin"]["size"]))
		var fin_mat := _material(color.lerp(pal["accent"].get_shader_parameter("base_color"), 0.6))
		_blob(body, fin_mat, Vector3(0, r * 0.95, (head_z + back_z) * 0.5 - r * 0.1), Vector3(0.015, r * 0.7 * fk, r * 0.8 * fk), Vector3(-0.35, 0, 0), 10, 5)
		var tail := Node3D.new()
		tail.position = Vector3(0, 0, back_z - r * 0.8)
		body.add_child(tail)
		for s: float in SIDES:
			_blob(tail, fin_mat, Vector3(0, s * r * 0.45 * fk, -r * 0.55), Vector3(0.015, r * 0.65 * fk, r * 0.5 * fk), Vector3(s * 0.55, 0, 0), 10, 5)
		root.tail = tail
		fin_tail = true
		for f in max(n - 1, 0):
			var side := -1.0 if f % 2 == 0 else 1.0
			_blob(body, fin_mat, Vector3(side * r * 1.1, -r * 0.3, head_z - spacing * (0.2 + 0.5 * (f / 2))), Vector3(r * 0.6 * fk, 0.015, r * 0.35 * fk), Vector3(0, side * -0.3, side * -0.4), 10, 5)

	if parts.has("wing"):
		var wz := lerpf(head_z, back_z, 0.35) if segs > 1 else 0.0
		_wings(root, body, pal, parts["wing"], r, r * 0.6, r * 0.65, wz, spacing * 0.8, ctx)

	# Tail for land animals: tapering cone with a tip.
	if not fin_tail and (has_limbs or parts.has("wing")) and not otherworldly:
		var tail := Node3D.new()
		tail.position = Vector3(0, -r * 0.1, back_z - r * 0.8)
		body.add_child(tail)
		var tl := r * 2.4
		_mesh(tail, _cone(r * 0.38, tl, 10), skin, Vector3(0, 0, -tl * 0.4), Vector3.ONE, Vector3(-PI / 2 - 0.15, 0, 0))
		_mesh(tail, _unit_sphere(8, 4), pal["accent"], Vector3(0, -tl * 0.1, -tl * 0.88), Vector3.ONE * r * 0.2)
		root.tail = tail

	# Tentacles: tapering chains from under the head, with round tips.
	if parts.has("tentacle"):
		var n := mini(int(parts["tentacle"]["count"]), 6)
		var tk := _k(float(parts["tentacle"]["size"]))
		ctx["tentacle_tips"] = []
		for i in n:
			var ang := (float(i) / n) * TAU
			var chain: Array = []
			var parent: Node3D = body
			var start := Vector3(cos(ang) * head_r * 0.55, -head_r * 0.55, head_z + head_r * 0.1 + sin(ang) * head_r * 0.35)
			for j in 3:
				var seg := Node3D.new()
				seg.position = start if j == 0 else Vector3(0, -r * 0.5 * tk, 0)
				parent.add_child(seg)
				var rad := r * 0.17 * (1.0 - j * 0.22) * tk
				_mesh(seg, _capsule(rad, r * 0.58 * tk, 8, 3), skin if j < 2 else pal["accent"], Vector3(0, -r * 0.25 * tk, 0))
				chain.append(seg)
				parent = seg
			root.tentacles.append(chain)
			ctx["tentacle_tips"].append({"node": parent, "r": r * 0.12 * tk, "len": r * 0.5 * tk})

	# Beings from beyond: glowing, eerie.
	if parts.has("tendril"):
		var n := mini(int(parts["tendril"]["count"]), 5)
		var tk := _k(float(parts["tendril"]["size"]))
		var tendril_mat := _material(color.darkened(0.55), Color(0.65, 0.25, 1.0), 0.6)
		var tip_mat := _material(Color(0.9, 0.6, 1.0), Color(0.85, 0.45, 1.0), 2.0)
		for i in n:
			var ang := (float(i) / n) * TAU
			var along: float = lerpf(head_z, back_z, float(i % 3) / 2.0)
			var chain: Array = []
			var parent: Node3D = body
			for j in 4:
				var seg := Node3D.new()
				seg.position = Vector3(cos(ang) * r * 0.8, sin(ang) * r * 0.4 - r * 0.3, along) if j == 0 else Vector3(0, -r * 0.55 * tk, 0)
				if j == 0:
					seg.rotation = Vector3(0, 0, ang * 0.3)
				parent.add_child(seg)
				_mesh(seg, _capsule(r * 0.07 * (1.0 - j * 0.14) * tk, r * 0.6 * tk, 6, 2), tendril_mat if j < 3 else tip_mat, Vector3(0, -r * 0.27 * tk, 0))
				chain.append(seg)
				parent = seg
			root.tentacles.append(chain)

	if parts.has("void"):
		var vk := _k(float(parts["void"]["size"]))
		var mid_z: float = (head_z + back_z) * 0.5
		var hole := StandardMaterial3D.new()
		hole.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		hole.albedo_color = Color(0, 0, 0)
		_mesh(body, _sphere(r * 0.7 * vk), hole, Vector3(0, r * 0.2, mid_z))
		var ring := TorusMesh.new()
		ring.inner_radius = r * 0.72 * vk
		ring.outer_radius = r * 0.9 * vk
		ring.rings = 20
		ring.ring_segments = 8
		_mesh(body, ring, _material(Color(0.45, 0.1, 0.7), Color(0.85, 0.45, 1.0), 2.5), Vector3(0, r * 0.2, mid_z), Vector3.ONE, Vector3(PI / 2, 0, 0))
		if otherworldly:
			_mesh(body, ring, _material(Color(0.3, 0.1, 0.6), Color(0.6, 0.3, 1.0), 1.8), Vector3(0, r * 0.2, mid_z), Vector3.ONE * 1.35, Vector3(PI / 2 + 0.6, 0.4, 0))

	if parts.has("phase membrane"):
		var mk := _k(float(parts["phase membrane"]["size"]))
		var shimmer := StandardMaterial3D.new()
		shimmer.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		shimmer.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		shimmer.albedo_color = Color(0.75, 0.5, 1.0, 0.16)
		shimmer.cull_mode = BaseMaterial3D.CULL_DISABLED
		var length: float = absf(head_z - back_z) + head_r * 2.0
		_mesh(body, _sphere(1.0), shimmer, Vector3(0, 0, (head_z + back_z) * 0.5), Vector3(head_r * 1.6 * mk, head_r * 1.5 * mk, length * 0.65 * mk))
	if otherworldly and parts.has("eye"):
		# A faint halo of light behind the eyes.
		_mesh(body, _unit_sphere(8, 4), _material(Color(0.8, 0.5, 1.0), Color(0.8, 0.5, 1.0), 3.0), Vector3(0, head_r * 1.35, head_z), Vector3.ONE * head_r * 0.16)


# ---------------------------------------------------------------------------
# Plants
# ---------------------------------------------------------------------------

## Trees, blooms, leafy stems and kelp for mindless multicellular life. Stem
## segments are chained into root.tentacles for a gentle sway.
static func _build_plant(root: Node3D, detail: Dictionary, parts: Dictionary) -> Node3D:
	var color := _vivid(Color("#" + str(detail.get("color", "999999"))))
	var green := Color(0.3, 0.78, 0.3)
	var leaf_c := color.lerp(green, 0.65)
	var leaf_mat := _material(leaf_c)
	var leaf_light := _material(leaf_c.lightened(0.22))
	var leaf_dark := _material(leaf_c.darkened(0.22))
	var stem_color := color.lerp(green, 0.4).darkened(0.15)
	var woody := parts.has("shell")
	if woody:
		stem_color = color.lerp(Color(0.45, 0.3, 0.16), 0.65).darkened(0.05)
	var stem_mat := _material(stem_color)
	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	root.body = body
	var segs: int = clampi(int(parts["body segment"]["count"]) if parts.has("body segment") else 1, 1, 8)
	var sk: float = _k(float(parts["body segment"]["size"])) if parts.has("body segment") else 1.0
	var n_fronds: int = mini(int(parts["light-catching frond"]["count"]), 10) if parts.has("light-catching frond") else 0
	var fk: float = _k(float(parts["light-catching frond"]["size"])) if parts.has("light-catching frond") else 1.0
	var bloom: bool = str(detail.get("description", "")).ends_with("Bloom")
	root.sway = 0.2

	# Kelp: ribbons of blades rising from a holdfast, with air bladders.
	if parts.has("fin"):
		root.sway = 0.6
		var strands := clampi(maxi(n_fronds, int(parts["fin"]["count"])), 2, 6)
		var blade_mat := _material(color.lerp(Color(0.25, 0.6, 0.3), 0.5))
		_blob(body, stem_mat, Vector3(0, 0.03, 0), Vector3(0.17 * sk, 0.06, 0.17 * sk), Vector3.ZERO, 10, 5)
		for i in strands:
			var ang := float(i) / strands * TAU + 0.5
			var spread := 0.06 + 0.03 * (i % 3)
			var blades := 3 + mini(segs, 1)
			var blade_h := 0.26 * sk * (0.8 + 0.1 * (i % 4))
			var chain: Array = []
			var parent: Node3D = body
			for j in blades:
				var seg := Node3D.new()
				seg.position = Vector3(cos(ang) * spread, 0.02, sin(ang) * spread) if j == 0 else Vector3(0, blade_h, 0)
				seg.rotation.y = ang
				parent.add_child(seg)
				var w := 0.16 * fk * (1.0 - j * 0.12)
				_blob(seg, blade_mat if j % 2 == 0 else leaf_light, Vector3(0, blade_h * 0.5, 0), Vector3(w * 0.5, blade_h * 0.62, 0.012), Vector3.ZERO, 8, 4)
				if j == blades - 1 and i % 2 == 0:
					_blob(seg, leaf_light, Vector3(0, blade_h * 1.0, 0), Vector3.ONE * 0.04 * fk, Vector3.ZERO, 8, 4)
				chain.append(seg)
				parent = seg
			root.tentacles.append(chain)
		return root

	# Stem: a chain of tapering capsules, with a root flare for trees.
	var seg_h := 0.3 * sk
	var base_r := 0.075 * sk * (2.3 if woody else 1.0)
	var chain: Array = []
	var nodes: Array[Node3D] = []
	var parent: Node3D = body
	for j in segs:
		var seg := Node3D.new()
		seg.position = Vector3.ZERO if j == 0 else Vector3(0, seg_h, 0)
		parent.add_child(seg)
		var rr := base_r * (1.0 - (0.4 if woody else 0.55) * float(j) / segs)
		_mesh(seg, _capsule(rr, seg_h * (1.5 if woody else 1.15), 10, 3), stem_mat, Vector3(0, seg_h * 0.5, 0))
		chain.append(seg)
		nodes.append(seg)
		parent = seg
	if woody:
		_mesh(body, _cone(base_r * 2.0, seg_h * 0.9, 10), stem_mat, Vector3(0, seg_h * 0.3, 0))
		for i in 3:
			var a := float(i) * TAU / 3.0 + 0.4
			_mesh(body, _cone(base_r * 0.45, seg_h * 0.6, 6), stem_mat, Vector3(cos(a) * base_r * 1.9, seg_h * 0.02, sin(a) * base_r * 1.9), Vector3.ONE, Vector3(sin(a) * 1.35, 0, -cos(a) * 1.35))
	root.tentacles.append(chain)

	var top := nodes[segs - 1]
	var tip_y := seg_h * 1.05
	if woody:
		# Layered canopy: chunky blobs, lighter toward the sun.
		var cr := 0.2 * sk * (0.9 + 0.2 * fk) * (1.0 + 0.04 * n_fronds)
		_blob(top, leaf_dark, Vector3(0, tip_y, 0), Vector3(cr * 1.25, cr * 0.8, cr * 1.25), Vector3.ZERO, 12, 6)
		_blob(top, leaf_mat, Vector3(cr * 0.5, tip_y + cr * 0.55, cr * 0.2), Vector3(cr * 0.95, cr * 0.8, cr * 0.95), Vector3.ZERO, 12, 6)
		_blob(top, leaf_mat, Vector3(-cr * 0.55, tip_y + cr * 0.4, -cr * 0.25), Vector3(cr * 0.85, cr * 0.7, cr * 0.85), Vector3.ZERO, 12, 6)
		_blob(top, leaf_light, Vector3(0, tip_y + cr * 1.05, 0), Vector3(cr * 0.8, cr * 0.65, cr * 0.8), Vector3.ZERO, 12, 6)
		return root

	if n_fronds == 0 or bloom:
		if bloom:
			var petal := Color.from_hsv(fposmod(color.h + 0.08, 1.0), 0.65, 1.0)
			var petal_mat := _material(petal.lightened(0.1))
			var petal_back := _material(petal)
			var pr := 0.13 * sk
			var petals := 6
			for i in petals:
				var a := float(i) / petals * TAU
				_blob(top, petal_mat if i % 2 == 0 else petal_back, Vector3(sin(a) * pr * 0.9, tip_y + pr * 0.2, cos(a) * pr * 0.9),
					Vector3(pr * 0.45, pr * 0.1, pr * 0.8), Vector3(-0.5, a, 0), 8, 4)
			_blob(top, _material(Color(1.0, 0.85, 0.25), Color(1.0, 0.8, 0.2), 0.3), Vector3(0, tip_y + pr * 0.35, 0), Vector3.ONE * pr * 0.42, Vector3.ZERO, 10, 5)
			_blob(top, leaf_mat, Vector3(0, tip_y - pr * 0.25, 0), Vector3(pr * 0.5, pr * 0.3, pr * 0.5), Vector3.ZERO, 8, 4)
		else:
			_blob(top, leaf_light, Vector3(0, tip_y, 0), Vector3.ONE * base_r * 1.3, Vector3.ZERO, 12, 6)
			_blob(top, leaf_mat, Vector3(0, tip_y - base_r, 0), Vector3(base_r * 1.5, base_r * 0.6, base_r * 1.5), Vector3.ZERO, 12, 6)
	if n_fronds == 0 and not bloom:
		for i in 3:
			var a3 := float(i) / 3.0 * TAU + 0.3
			_blob(body, leaf_mat if i % 2 == 0 else leaf_light, Vector3(sin(a3) * 0.1 * sk, seg_h * 0.35, cos(a3) * 0.1 * sk), Vector3(0.05 * sk, 0.015, 0.14 * sk), Vector3(-0.7, a3, 0), 8, 4)
	for f in n_fronds:
		var tier := f / 4
		var holder := nodes[maxi(segs - 1 - tier, 0)]
		var ang := (float(f) / 4.0 + float(f % 4) * 0.23) * TAU
		var tilt := 0.75 - 0.3 * (f % 3)
		var length := 0.34 * fk
		var dir := Vector3(sin(ang) * cos(tilt), sin(tilt), cos(ang) * cos(tilt))
		var base := Vector3(0, seg_h * (0.95 if holder == top else 0.7), 0)
		_blob(holder, leaf_mat if f % 2 == 0 else leaf_light, base + dir * length * 0.5, Vector3(0.36 * length, 0.03, length * 0.55), Vector3(-tilt, ang, 0), 10, 4)
	return root


# ---------------------------------------------------------------------------
# Equipment
# ---------------------------------------------------------------------------

## Reads sheet["gear"] into {slot: [item]}, item = {name, kind, mat, enchanted}.
static func _parse_gear(sheet: Dictionary) -> Dictionary:
	var out := {}
	var list = sheet.get("gear", null)
	if not (list is Array):
		return out
	for g in list:
		if not (g is Dictionary):
			continue
		var name := str(g.get("name", "")).to_lower()
		var slot := str(g.get("slot", ""))
		var kind := slot
		if slot == "hand":
			if name.contains("shield"):
				kind = "shield"
			elif name.contains("axe"):
				kind = "axe"
			elif name.contains("spear"):
				kind = "spear"
			else:
				kind = "sword"
		var mat := "iron"
		for key in ["bone and wood", "tungsten", "crystal", "obsidian", "chitin", "iron", "bone", "wood"]:
			if name.contains(key):
				mat = "bone and wood" if key in ["bone", "wood"] else key
				break
		if not out.has(slot):
			out[slot] = []
		out[slot].append({"name": name, "kind": kind, "mat": mat, "enchanted": name.contains("enchanted")})
	return out


## Materials for one item: main (blade/plate), trim (guards, studs), handle,
## glow (runes, orbs) and the magic colour.
static func _gear_mats(item: Dictionary) -> Dictionary:
	var enchanted: bool = item["enchanted"]
	var magic := Color(0.45, 0.8, 1.0)
	var main: ShaderMaterial
	var trim: ShaderMaterial
	var handle := _material(Color(0.5, 0.31, 0.15))
	var brass := _metal(Color(0.95, 0.72, 0.22), Color(1.0, 0.9, 0.6), 0.9, 30.0)
	var ench_glow := Color(0.5, 0.8, 1.0) if enchanted else Color.BLACK
	var eg := 0.45 if enchanted else 0.0
	match item["mat"]:
		"tungsten":
			main = _metal(Color(0.26, 0.31, 0.46), Color(0.75, 0.88, 1.0), 1.0, 40.0, ench_glow, eg)
			trim = brass
			magic = Color(0.5, 0.75, 1.0)
		"crystal":
			main = _metal(Color(0.35, 0.88, 0.98), Color(0.9, 1.0, 1.0), 1.0, 30.0, Color(0.3, 0.9, 1.0), 0.7 + eg)
			trim = _metal(Color(0.85, 0.95, 1.0), Color(1, 1, 1), 0.8, 30.0)
			magic = Color(0.4, 0.95, 1.0)
		"obsidian":
			main = _metal(Color(0.1, 0.07, 0.15), Color(0.75, 0.45, 1.0), 1.0, 50.0, Color(0.5, 0.2, 0.9) if enchanted else Color(0.25, 0.08, 0.4), 0.35 if enchanted else 0.2)
			trim = _metal(Color(0.5, 0.2, 0.7), Color(0.9, 0.6, 1.0), 0.9, 30.0, Color(0.5, 0.2, 0.8), 0.3)
			magic = Color(0.75, 0.4, 1.0)
		"bone and wood":
			main = _metal(Color(0.95, 0.9, 0.76), Color(1, 0.98, 0.9), 0.35, 12.0, ench_glow, eg)
			trim = _material(Color(0.5, 0.32, 0.16))
			magic = Color(0.55, 1.0, 0.6)
		"chitin":
			main = _metal(Color(0.72, 0.42, 0.1), Color(1.0, 0.85, 0.5), 0.6, 20.0, ench_glow, eg)
			trim = _metal(Color(0.35, 0.2, 0.08), Color(0.9, 0.7, 0.4), 0.5, 20.0)
			magic = Color(1.0, 0.7, 0.3)
		_:
			main = _metal(Color(0.62, 0.65, 0.7), Color(1, 1, 1), 0.8, 28.0, ench_glow, eg)
			trim = brass
	if enchanted:
		main.set_shader_parameter("glow_color", magic)
		if item["mat"] == "crystal":
			main.set_shader_parameter("glow", 1.1)
	if item["mat"] == "bone and wood":
		handle = trim
	return {"main": main, "trim": trim, "handle": handle, "rune": _material(magic, magic, 2.2), "magic": magic, "enchanted": enchanted}


## A weapon with the grip at the origin and the business end along +Y.
static func _weapon(kind: String, m: Dictionary, g: float) -> Node3D:
	var w := Node3D.new()
	w.name = "Gear_" + kind
	var main: Material = m["main"]
	var trim: Material = m["trim"]
	var handle: Material = m["handle"]
	match kind:
		"axe":
			_mesh(w, _capsule(g * 0.32, g * 11.0, 8, 2), handle, Vector3(0, g * 3.5, 0))
			_blob(w, main, Vector3(0, g * 8.0, g * 1.9), Vector3(g * 0.4, g * 2.3, g * 2.4), Vector3(-0.15, 0, 0), 12, 6)
			_mesh(w, _box(Vector3(g * 1.0, g * 1.9, g * 1.4)), trim, Vector3(0, g * 8.0, -g * 0.5))
			_mesh(w, _cone(g * 0.55, g * 2.2, 8), trim, Vector3(0, g * 10.0, 0))
			if m["enchanted"]:
				_mesh(w, _box(Vector3(g * 0.5, g * 0.3, g * 2.4)), m["rune"], Vector3(0, g * 8.0, g * 2.0))
		"spear":
			_mesh(w, _capsule(g * 0.3, g * 16.0, 8, 2), handle, Vector3(0, g * 5.0, 0))
			_mesh(w, _cone(g * 1.2, g * 4.2, 4), main, Vector3(0, g * 15.0, 0), Vector3(1, 1, 0.4), Vector3(0, PI / 4, 0))
			_mesh(w, _cyl(g * 0.55, g * 0.7, 10), trim, Vector3(0, g * 12.9, 0))
			_mesh(w, _cone(g * 0.45, g * 1.2, 6), trim, Vector3(0, -g * 3.2, 0), Vector3.ONE, Vector3(PI, 0, 0))
			if m["enchanted"]:
				_mesh(w, _box(Vector3(g * 0.25, g * 3.0, g * 0.5)), m["rune"], Vector3(0, g * 14.2, 0))
		_:
			_mesh(w, _capsule(g * 0.34, g * 2.6, 8, 2), handle, Vector3(0, g * 0.1, 0))
			_blob(w, trim, Vector3(0, -g * 1.45, 0), Vector3.ONE * g * 0.55, Vector3.ZERO, 8, 4)
			_mesh(w, _box(Vector3(g * 3.6, g * 0.55, g * 0.9)), trim, Vector3(0, g * 1.5, 0))
			_mesh(w, _box(Vector3(g * 1.25, g * 7.6, g * 0.34)), main, Vector3(0, g * 5.35, 0))
			_mesh(w, _cone(g * 0.88, g * 2.4, 4), main, Vector3(0, g * 10.35, 0), Vector3(1, 1, 0.28), Vector3(0, PI / 4, 0))
			if m["enchanted"]:
				_mesh(w, _box(Vector3(g * 0.32, g * 7.0, g * 0.4)), m["rune"], Vector3(0, g * 5.3, 0))
	return w


static func _shield(m: Dictionary, g: float, side: float) -> Node3D:
	var s := Node3D.new()
	s.name = "Gear_shield"
	var main: Material = m["main"]
	var trim: Material = m["trim"]
	_mesh(s, _cyl(g * 4.0, g * 0.5, 16), trim, Vector3(-side * g * 0.15, 0, 0), Vector3.ONE, Vector3(0, 0, PI / 2))
	_mesh(s, _cyl(g * 3.5, g * 0.8, 16), main, Vector3(side * g * 0.15, 0, 0), Vector3.ONE, Vector3(0, 0, PI / 2))
	_mesh(s, _box(Vector3(g * 0.9, g * 6.2, g * 0.35)), m["rune"] if m["enchanted"] else trim, Vector3(side * g * 0.62, 0, 0), Vector3(1, 1, 1))
	_blob(s, trim, Vector3(side * g * 0.55, 0, 0), Vector3(g * 0.9, g * 1.3, g * 1.3), Vector3.ZERO, 10, 5)
	return s


static func _staff(m: Dictionary, g: float) -> Node3D:
	var s := Node3D.new()
	s.name = "Gear_staff"
	_mesh(s, _capsule(g * 0.34, g * 18.0, 8, 2), m["handle"], Vector3(0, g * 5.0, 0))
	for i in 3:
		var a := float(i) / 3.0 * TAU
		_mesh(s, _cone(g * 0.28, g * 3.0, 6), m["trim"], Vector3(sin(a) * g * 1.1, g * 14.6, cos(a) * g * 1.1), Vector3.ONE, Vector3(cos(a) * 0.35, 0, -sin(a) * 0.35))
	var orb := _focus_orb(m, g * 1.5)
	orb.position = Vector3(0, g * 14.8, 0)
	s.add_child(orb)
	return s


## A glowing orb with three orbiting shards, spun by CreatureAnim.floaters.
static func _focus_orb(m: Dictionary, r: float) -> Node3D:
	var f := Node3D.new()
	f.name = "SpellFocus"
	var glow_c: Color = m["magic"]
	var orb := _metal(Color(glow_c).lerp(Color.WHITE, 0.35), Color(1, 1, 1), 1.0, 30.0, glow_c, 1.5)
	_blob(f, orb, Vector3.ZERO, Vector3.ONE * r, Vector3.ZERO, 12, 6)
	for i in 3:
		var a := float(i) / 3.0 * TAU
		_mesh(f, _sphere(1.0, 4, 2), m["rune"], Vector3(cos(a) * r * 1.9, sin(a * 2.0) * r * 0.4, sin(a) * r * 1.9), Vector3(r * 0.28, r * 0.5, r * 0.28))
	return f


static func _attach_gear(root: Node3D, ctx: Dictionary) -> void:
	var gear: Dictionary = ctx["gear"]
	var body: Node3D = ctx["body"]
	var humanoid: bool = ctx["humanoid"]
	var g: float = ctx.get("hand_r", 0.07) * 0.8
	var head: Vector3 = ctx["head"]
	var head_r: float = ctx["head_r"]

	# Hands: a weapon in the right hand (side -1), a shield in the left (+1).
	var weapon = null
	var shield = null
	var other_weapons := []
	for it in gear.get("hand", []):
		if it["kind"] == "shield":
			if shield == null:
				shield = it
		elif weapon == null:
			weapon = it
	var mounts: Dictionary = {}
	if humanoid:
		for side: float in SIDES:
			var sh: Dictionary = ctx["shoulders"][side]
			mounts[side] = {"node": sh["node"], "pos": sh["hand"]}
	else:
		for side: float in SIDES:
			if ctx["front_legs"].has(side):
				var fl: Dictionary = ctx["front_legs"][side]
				mounts[side] = {"node": fl["node"], "pos": fl["foot"] + Vector3(0, g * 1.5, g * 0.8)}
	var spell_staff := false
	if gear.has("mind") and humanoid and weapon == null:
		spell_staff = true
	if mounts.has(-1.0):
		var mt: Dictionary = mounts[-1.0]
		var node: Node3D = null
		var pos: Vector3 = mt["pos"]
		if weapon != null:
			node = _weapon(weapon["kind"], _gear_mats(weapon), g)
			node.scale = Vector3.ONE * (1.0 if humanoid else 0.8)
		elif spell_staff:
			node = _staff(_gear_mats(gear["mind"][0]), g)
			ctx["staff_orb"] = true
		if node != null:
			node.position = pos
			node.rotation.x = (0.55 if node.name == "Gear_staff" else 0.95) if humanoid else 0.9
			(mt["node"] as Node3D).add_child(node)
			var idx: int = root.legs.find(mt["node"])
			if idx >= 0 and humanoid:
				root.rest_x[idx] = -0.55
				root.swing[idx] = 0.35
	if mounts.has(1.0) and shield != null:
		var mt2: Dictionary = mounts[1.0]
		var sm := _gear_mats(shield)
		var sn := _shield(sm, g, 1.0)
		var off := Vector3(g * 1.5, g * 0.3, g * 2.0) if humanoid else Vector3(g * 2.2, g * 1.5, g * 2.0)
		sn.position = (mt2["pos"] as Vector3) + off
		sn.rotation.y = -0.5
		(mt2["node"] as Node3D).add_child(sn)
		var idx2: int = root.legs.find(mt2["node"])
		if idx2 >= 0 and humanoid:
			root.rest_x[idx2] = -0.25
			root.swing[idx2] = 0.35

	# Armour.
	if gear.has("body"):
		var am := _gear_mats(gear["body"][0])
		if humanoid:
			_humanoid_armour(body, ctx, am)
		else:
			_beast_armour(body, ctx, am)

	# Fang caps on the jaw.
	if gear.has("jaw") and ctx.has("jaw"):
		var jm := _gear_mats(gear["jaw"][0])
		var jd: Dictionary = ctx["jaw"]
		var jr: float = jd["r"]
		var jl: float = jd["len"]
		for side: float in SIDES:
			_mesh(jd["node"], _cone(jr * 0.3, jr * 1.1, 6), jm["main"], Vector3(side * jr * 0.46, -jr * 0.5, jl * 0.5), Vector3.ONE, Vector3(PI, 0, 0))
		_mesh(jd["node"], _cone(jr * 0.2, jr * 0.8, 6), jm["main"], Vector3(0, jr * 0.65, jl * 0.8), Vector3.ONE, Vector3(0, 0, 0))

	# Tentacle blades.
	if gear.has("tentacle") and ctx.has("tentacle_tips"):
		var tm := _gear_mats(gear["tentacle"][0])
		var count := 0
		for tip in ctx["tentacle_tips"]:
			if count >= 4:
				break
			count += 1
			var tr: float = tip["r"]
			var tl: float = tip["len"]
			_mesh(tip["node"], _cyl(tr * 2.0, tr * 1.8, 8), tm["trim"], Vector3(0, -tl * 0.95, 0))
			_mesh(tip["node"], _cone(tr * 3.6, tl * 4.6, 4), tm["main"], Vector3(0, -tl * 3.3, 0), Vector3(1, 1, 0.3), Vector3(PI, PI / 4, 0))

	# Wing blades along the leading edge, with a spike at the tip.
	if gear.has("wing") and ctx.has("wings"):
		var wm := _gear_mats(gear["wing"][0])
		for wd in ctx["wings"]:
			var side: float = wd["side"]
			var sp: float = wd["span"]
			var wr: float = wd["r"]
			var pivot: Node3D = wd["node"]
			_mesh(pivot, _box(Vector3(sp * 0.85, 0.015, wr * 0.28)), wm["main"], Vector3(side * sp * 0.5, 0.02, sp * 0.08 + wr * 0.1))
			_mesh(pivot, _cone(wr * 0.3, sp * 0.3, 4), wm["main"], Vector3(side * sp * 1.1, 0.02, sp * 0.08), Vector3(1, 0.3, 1), Vector3(0, PI / 4, -side * PI / 2))

	# Breath focus: a cradled glowing orb at the throat.
	if gear.has("gland"):
		var bm := _gear_mats(gear["gland"][0])
		var th: Vector3 = ctx["throat"]
		var bc: Color = ctx.get("gland_color", bm["magic"])
		var orb := _material(bc.lightened(0.2), bc, 2.2)
		var br := head_r * 0.42
		var tpos := th + Vector3(0, -br * 0.3, br * 0.5)
		_blob(body, orb, tpos, Vector3.ONE * br, Vector3.ZERO, 12, 6)
		var ring := TorusMesh.new()
		ring.inner_radius = br * 1.05
		ring.outer_radius = br * 1.45
		ring.rings = 14
		ring.ring_segments = 6
		_mesh(body, ring, bm["trim"], tpos, Vector3.ONE, Vector3(PI / 2, 0, 0))
		_mesh(body, _cone(br * 0.3, br * 1.2, 6), bm["main"], tpos + Vector3(0, br * 1.4, 0))

	# Spell focus: a floating orb with shards beside the head (unless it is the staff).
	if gear.has("mind") and not ctx.get("staff_orb", false):
		var fm := _gear_mats(gear["mind"][0])
		var orb2 := _focus_orb(fm, head_r * 0.42)
		orb2.position = head + Vector3(head_r * 1.9, head_r * 1.5, 0.0 if humanoid else head_r * 0.1)
		body.add_child(orb2)
		root.floaters.append(orb2)
		root.floater_y.append(orb2.position.y)


static func _humanoid_armour(body: Node3D, ctx: Dictionary, m: Dictionary) -> void:
	var t: Dictionary = ctx["torso"]
	var tr: float = t["tr"]
	var th: float = t["th"]
	var torso_y: float = t["torso_y"]
	var main: Material = m["main"]
	var trim: Material = m["trim"]
	var head: Vector3 = ctx["head"]
	var head_r: float = ctx["head_r"]
	# Breastplate, belt with buckle.
	_blob(body, main, Vector3(0, torso_y + th * 0.13, tr * 0.12), Vector3(tr * 1.25, th * 0.4, tr * 1.1), Vector3.ZERO, 14, 7)
	_mesh(body, _cyl(tr * 1.0, th * 0.13, 14), trim, Vector3(0, torso_y - th * 0.3, 0), Vector3(1.0, 1.0, 0.95))
	_mesh(body, _box(Vector3(tr * 0.55, th * 0.17, tr * 0.2)), main, Vector3(0, torso_y - th * 0.3, tr * 0.95))
	if m["enchanted"]:
		_mesh(body, _box(Vector3(tr * 0.3, th * 0.3, tr * 0.12)), m["rune"], Vector3(0, torso_y + th * 0.13, tr * 1.2))
	# Big pauldrons on the shoulders (they swing with the arms).
	for side: float in SIDES:
		var sh: Node3D = ctx["shoulders"][side]["node"]
		var u: float = ctx["hand_r"] / 0.095
		_blob(sh, main, Vector3(side * 0.03 * u, 0.025 * u, 0), Vector3(0.16 * u, 0.1 * u, 0.14 * u), Vector3(0, 0, -side * 0.25), 12, 6)
		_mesh(sh, _cone(0.04 * u, 0.15 * u, 6), trim, Vector3(side * 0.09 * u, 0.12 * u, 0), Vector3.ONE, Vector3(0, 0, -side * 0.7))
	# Helmet: a dome with a crest, brow-line above the eyes.
	var hr := head_r * 1.08
	_mesh(body, _hemisphere(hr), main, head + Vector3(0, head_r * 0.38, -head_r * 0.05), Vector3.ONE, Vector3(-0.12, 0, 0))
	_mesh(body, _cone(head_r * 0.14, head_r * 0.5, 6), trim, head + Vector3(0, head_r * 1.42, -head_r * 0.1))


static func _hemisphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r
	s.is_hemisphere = true
	s.radial_segments = 14
	s.rings = 5
	return s


static func _beast_armour(body: Node3D, ctx: Dictionary, m: Dictionary) -> void:
	var main: Material = m["main"]
	var trim: Material = m["trim"]
	var segs: Array = ctx["segs"]
	for i in segs.size():
		var sd: Dictionary = segs[i]
		var z: float = sd["z"]
		var rr: float = sd["r"]
		if i == 0:
			continue
		_blob(body, main, Vector3(0, rr * 0.38, z), Vector3(rr * 1.05, rr * 0.62, rr * 0.95), Vector3.ZERO, 12, 6)
		_mesh(body, _cone(rr * 0.17, rr * 0.6, 6), trim, Vector3(0, rr * 1.0, z), Vector3.ONE, Vector3(-0.15, 0, 0))
		if i == 1 and m["enchanted"]:
			_mesh(body, _box(Vector3(rr * 0.3, rr * 0.1, rr * 1.3)), m["rune"], Vector3(0, rr * 0.99, z))
	var head: Vector3 = ctx["head"]
	var hr: float = ctx["head_r"]
	if segs.size() == 1:
		_blob(body, main, head + Vector3(0, hr * 0.5, -hr * 0.5), Vector3(hr * 1.05, hr * 0.6, hr * 0.9), Vector3.ZERO, 12, 6)
	_mesh(body, _hemisphere(hr * 1.07), main, head + Vector3(0, hr * 0.12, -hr * 0.28), Vector3.ONE, Vector3(-0.55, 0, 0))
	_mesh(body, _cone(hr * 0.15, hr * 0.55, 6), trim, head + Vector3(0, hr * 1.1, -hr * 0.4), Vector3.ONE, Vector3(-0.4, 0, 0))


# ---------------------------------------------------------------------------
# Bounds
# ---------------------------------------------------------------------------

## Bounding box of every mesh under `node`, in `node`'s parent space. Uses
## local transforms only, so it works before the node enters the scene tree.
static func bounds(node: Node3D) -> AABB:
	var box := AABB()
	var first := true
	var stack: Array = [[node, node.transform]]
	while not stack.is_empty():
		var item: Array = stack.pop_back()
		var n: Node = item[0]
		var xf: Transform3D = item[1]
		if n is MeshInstance3D:
			var b: AABB = xf * n.get_aabb()
			box = b if first else box.merge(b)
			first = false
		for c in n.get_children():
			if c is Node3D:
				stack.append([c, xf * c.transform])
	return box
