extends RefCounted
## Procedural stylised building kit (World-of-Warcraft-like: chunky shapes, deep
## sagging roofs, thick timbers, rounded stone footings, saturated hand-painted
## colour). Everything is built from code, one ArrayMesh per building with one
## surface per material: the painted body (vertex colours + pattern ids drawn by
## shaders/stylized.gdshader), the caller's window material and an emissive one.
##
## Town units: origin at the centre of the footprint, y = 0 is the ground, the
## door faces +Z.
##   BuildingKit.mesh(kind, civ, era, window_mat) -> ArrayMesh
##   BuildingKit.footprint(kind) -> float
##   BuildingKit.door(kind) -> Vector3
##   BuildingKit.material(color, kind := "plain") -> Material
##   BuildingKit.scenery(kind, seed := 0) -> ArrayMesh  (arena: trees, rocks, pillars...)

const STYLE_SHADER := preload("res://shaders/stylized.gdshader")

# Pattern ids are stored in vertex-colour alpha (alpha = id / 10, 1.0 = none).
const PAT_NONE := 1.0
const PAT_STONE := 0.1
const PAT_BRICK := 0.2
const PAT_PLANK := 0.3
const PAT_THATCH := 0.4
const PAT_TILE := 0.5
const PAT_RTILE := 0.6
const PAT_PLANK_R := 0.7
const PAT_STONE_R := 0.8
const PAT_BRICK_R := 0.9

const KINDS := ["Hut", "Longhouse", "Workshop", "Forge", "Granary", "Mine", "Market", "Library", "Barracks", "Shrine", "Temple", "Wizard's tower", "Aqueduct", "Factory", "Well", "Farmhouse", "Haystack", "WallSegment", "WallTower", "PalisadePost", "Pier", "Crop", "Fence"]

const FOOTPRINT := {
	"Hut": 0.9, "Longhouse": 3.0, "Workshop": 2.1, "Forge": 2.1, "Granary": 1.6, "Mine": 2.4, "Market": 3.0,
	"Library": 2.4, "Barracks": 3.0, "Shrine": 1.0, "Temple": 3.2, "Wizard's tower": 1.3, "Aqueduct": 5.0,
	"Factory": 3.0, "Well": 0.7, "Farmhouse": 1.4, "Haystack": 0.6, "WallSegment": 0.5, "WallTower": 1.3,
	"PalisadePost": 0.15, "Pier": 3.25, "Crop": 0.2, "Fence": 0.5,
}

# Z of the spot in front of each door where townsfolk stand.
const DOOR_Z := {
	"Hut": 1.45, "Longhouse": 2.1, "Workshop": 1.9, "Forge": 1.9, "Granary": 1.5, "Mine": 3.3, "Market": 2.3,
	"Library": 2.2, "Barracks": 2.1, "Shrine": 1.3, "Temple": 3.3, "Wizard's tower": 1.8, "Aqueduct": 1.6,
	"Factory": 2.6, "Well": 1.1, "Farmhouse": 1.7, "Haystack": 0.9, "WallSegment": 0.8, "WallTower": 1.8,
	"PalisadePost": 0.4, "Pier": 6.9, "Crop": 0.4, "Fence": 0.4,
}

static var _meshes := {}
static var _materials := {}
static var _scenery := {}


# --- Public API --------------------------------------------------------------

static func footprint(kind: String) -> float:
	return float(FOOTPRINT.get(kind, 1.0))


static func door(kind: String) -> Vector3:
	return Vector3(0, 0, float(DOOR_Z.get(kind, footprint(kind) + 0.5)))


static func mesh(kind: String, civ: Color, era: int, window_mat: Material) -> ArrayMesh:
	era = clampi(era, 0, 5)
	var key := "%s|%s|%d" % [kind, civ.to_html(false), era]
	if _meshes.has(key):
		var cached: ArrayMesh = _meshes[key]
		if window_mat != null:
			for i in cached.get_surface_count():
				if cached.surface_get_name(i) == "win":
					cached.surface_set_material(i, window_mat)
		return cached
	var b := Mb.new()
	var p := _pal(civ, era)
	match kind:
		"Hut": _hut(b, p)
		"Longhouse": _longhouse(b, p)
		"Workshop": _workshop(b, p)
		"Forge": _forge(b, p)
		"Granary": _granary(b, p)
		"Mine": _mine(b, p)
		"Market": _market(b, p)
		"Library": _library(b, p)
		"Barracks": _barracks(b, p)
		"Shrine": _shrine(b, p)
		"Temple": _temple(b, p)
		"Wizard's tower": _tower(b, p)
		"Aqueduct": _aqueduct(b, p)
		"Factory": _factory(b, p)
		"Well": _well(b, p)
		"Farmhouse": _farmhouse(b, p)
		"Haystack": _haystack(b, p)
		"WallSegment": _wall_segment(b, p)
		"WallTower": _wall_tower(b, p)
		"PalisadePost": _palisade_post(b, p)
		"Pier": _pier(b, p)
		"Crop": _crop(b, p)
		"Fence": _fence(b, p)
		_: _hut(b, p)
	var m := _finish(b, window_mat)
	_meshes[key] = m
	return m


static func tri_count(m: ArrayMesh) -> int:
	var n := 0
	for i in m.get_surface_count():
		n += (m.surface_get_arrays(i)[Mesh.ARRAY_VERTEX] as PackedVector3Array).size() / 3
	return n


## Cached stylised material. kind: plain | kit | stone | brick | wood | thatch | tile | ground | leaf | glow.
static func material(color: Color, kind := "plain") -> Material:
	var key := "%s|%s" % [color.to_html(true), kind]
	if _materials.has(key):
		return _materials[key]
	var m := ShaderMaterial.new()
	m.shader = STYLE_SHADER
	m.set_shader_parameter("base_color", color)
	match kind:
		"stone":
			m.set_shader_parameter("pattern", 1)
		"brick":
			m.set_shader_parameter("pattern", 2)
		"wood":
			m.set_shader_parameter("pattern", 3)
		"thatch":
			m.set_shader_parameter("pattern", 4)
		"tile":
			m.set_shader_parameter("pattern", 5)
		"ground":
			m.set_shader_parameter("noise_scale", 0.55)
			m.set_shader_parameter("noise_amount", 0.1)
			m.set_shader_parameter("macro_amount", 0.22)
			m.set_shader_parameter("grad_amount", 0.0)
			m.set_shader_parameter("rim_amount", 0.0)
		"leaf":
			m.set_shader_parameter("noise_scale", 1.2)
			m.set_shader_parameter("noise_amount", 0.2)
			m.set_shader_parameter("grad_height", 3.0)
			m.set_shader_parameter("grad_amount", 0.3)
			m.set_shader_parameter("rim_amount", 0.4)
		"glow":
			m.set_shader_parameter("glow", 1.8)
			m.set_shader_parameter("flicker", 0.12)
			m.set_shader_parameter("noise_amount", 0.04)
			m.set_shader_parameter("grad_amount", 0.0)
			m.set_shader_parameter("rim_amount", 0.0)
	_materials[key] = m
	return m


## Arena scenery meshes: Pine, Oak, Boulder, Pillar, Tuft, Crystal, Pebble.
static func scenery(kind: String, seed_v := 0) -> ArrayMesh:
	var key := "%s|%d" % [kind, seed_v]
	if _scenery.has(key):
		return _scenery[key]
	var b := Mb.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v * 7919 + 13
	match kind:
		"Pine": _scn_pine(b, rng)
		"Oak": _scn_oak(b, rng)
		"Boulder": _scn_boulder(b, rng, false)
		"Pillar": _scn_pillar(b)
		"Tuft": _scn_tuft(b, rng)
		"Crystal": _scn_crystal(b, rng)
		"Pebble": _scn_boulder(b, rng, true)
		"Gem": _scn_gem(b)
		"ShrineBase": _scn_shrine_base(b)
	var m := _finish(b, null)
	_scenery[key] = m
	return m


## Arena ground: a painted disc (top at y = 0) with a rounded earthen rim.
static func ground_mesh(radius: float) -> ArrayMesh:
	var b := Mb.new()
	var top := Color(1, 1, 1, PAT_NONE)
	var earth := Color(0.52, 0.42, 0.33, PAT_NONE)
	var prof: Array = [Vector2(0.0, -0.8), Vector2(radius + 2.5, -0.8), Vector2(radius + 2.45, -0.3), Vector2(radius + 2.3, -0.08), Vector2(radius + 2.0, 0.0), Vector2(radius * 0.8, 0.0), Vector2(0.0, 0.0)]
	var cols: Array = [earth, earth, _v(earth, 1.0), _mix(earth, top, 0.5), top, top, top]
	b.lathe(prof, 72, cols, 0.0, 1)
	return _finish(b, null)


## Rocks, reeds and crystals ringing a ground patch ("water", "lava", "ice", "trees", "rock").
static func patch_rim(ground: String, radius: float, seed_v: int) -> ArrayMesh:
	var b := Mb.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	match ground:
		"water":
			var n := clampi(int(radius * 3.2), 6, 30)
			for i in n:
				var a := TAU * (float(i) + rng.randf() * 0.7) / n
				var r := radius * (1.0 + rng.randf_range(0.0, 0.1))
				if rng.randf() < 0.55:
					b.push()
					b.at(Vector3(cos(a) * r, 0, sin(a) * r))
					var s := rng.randf_range(0.14, 0.3)
					b.blob(Vector3(0, s * 0.3, 0), s, s * 0.7, 6, 3, _c(_mix(Color(0.5, 0.5, 0.5), Color(0.62, 0.56, 0.5), rng.randf()), PAT_NONE), 0.15, i)
					b.pop()
				else:
					b.push()
					b.at(Vector3(cos(a) * r, 0, sin(a) * r))
					for k in 3:
						b.push()
						b.yaw(rng.randf() * TAU)
						b.pitch(rng.randf_range(-0.25, 0.25))
						var hh := rng.randf_range(0.5, 0.9)
						b.cone_up(Vector3.ZERO, 0.07, 0.0, hh, 4, _c(Color(0.45, 0.68, 0.26), PAT_NONE))
						b.pop()
					b.cone_up(Vector3(0.06, 0.55, 0), 0.05, 0.05, 0.22, 5, _c(Color(0.45, 0.3, 0.16), PAT_NONE))
					b.pop()
		"lava":
			var n2 := clampi(int(radius * 2.6), 6, 26)
			for i in n2:
				var a2 := TAU * (float(i) + rng.randf() * 0.6) / n2
				var r2 := radius * (0.98 + rng.randf_range(0.0, 0.1))
				var s2 := rng.randf_range(0.2, 0.45)
				b.push()
				b.at(Vector3(cos(a2) * r2, 0, sin(a2) * r2))
				b.blob(Vector3(0, s2 * 0.45, 0), s2, s2 * 0.85, 6, 3, _c(_mix(Color(0.32, 0.24, 0.23), Color(0.5, 0.36, 0.3), rng.randf()), PAT_NONE), 0.22, i)
				b.use("glow")
				b.blob(Vector3(0, s2 * 1.0, 0), s2 * 0.25, s2 * 0.12, 5, 2, _c(Color(1.0, 0.55, 0.12), PAT_NONE), 0.0, i)
				b.use("main")
				b.pop()
		"ice":
			var n3 := clampi(int(radius * 2.0), 5, 22)
			for i in n3:
				var a3 := TAU * (float(i) + rng.randf() * 0.8) / n3
				var r3 := radius * rng.randf_range(0.55, 1.05)
				b.push()
				b.at(Vector3(cos(a3) * r3, 0, sin(a3) * r3))
				_crystal_cluster(b, rng, rng.randf_range(0.7, 1.3), Color(0.72, 0.9, 1.0))
				b.pop()
	return _finish(b, null)


## A cluster of boulders filling a rock patch of `radius`.
static func rock_cluster(radius: float, seed_v: int) -> ArrayMesh:
	var b := Mb.new()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var big := radius * 0.62
	b.blob(Vector3(0, big * 0.45, 0), big, big * 0.85, 9, 4, _c(Color(0.56, 0.55, 0.58), PAT_NONE), 0.18, 1)
	b.blob(Vector3(0, big * 0.9, 0), big * 0.55, big * 0.4, 8, 3, _c(Color(0.62, 0.6, 0.6), PAT_NONE), 0.18, 2)
	var n := clampi(int(radius * 2.0), 3, 10)
	for i in n:
		var a := TAU * (float(i) + rng.randf() * 0.5) / n
		var s := radius * rng.randf_range(0.2, 0.34)
		var d := radius * rng.randf_range(0.6, 0.88)
		var tone := rng.randf()
		b.blob(Vector3(cos(a) * d, s * 0.45, sin(a) * d), s, s * 0.8, 7, 3, _c(_mix(Color(0.48, 0.47, 0.52), Color(0.66, 0.62, 0.58), tone), PAT_NONE), 0.2, 10 + i)
	# moss and little stones
	for i in 5:
		var a2 := rng.randf() * TAU
		var d2 := radius * rng.randf_range(0.3, 0.7)
		b.blob(Vector3(cos(a2) * d2, big * 0.2, sin(a2) * d2), radius * 0.14, radius * 0.07, 6, 2, _c(Color(0.35, 0.5, 0.22), PAT_NONE), 0.2, 30 + i)
	return _finish(b, null)


## Flat disc (radius r) used by the ground-patch shader.
static func disc_mesh(r: float, segs := 32) -> ArrayMesh:
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()
	verts.append(Vector3.ZERO)
	norms.append(Vector3.UP)
	for i in segs:
		var a := TAU * i / segs
		verts.append(Vector3(cos(a) * r, 0, sin(a) * r))
		norms.append(Vector3.UP)
	for i in segs:
		var j := (i + 1) % segs
		idx.append(0)
		idx.append(1 + j)
		idx.append(1 + i)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	arr[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return m


# --- Colours -------------------------------------------------------------------

static func _c(col: Color, pat := PAT_NONE) -> Color:
	return Color(col.r, col.g, col.b, pat)


static func _v(col: Color, k: float) -> Color:
	return Color(clampf(col.r * k, 0.0, 1.0), clampf(col.g * k, 0.0, 1.0), clampf(col.b * k, 0.0, 1.0), col.a)


static func _mix(a: Color, b: Color, t: float) -> Color:
	return Color(lerpf(a.r, b.r, t), lerpf(a.g, b.g, t), lerpf(a.b, b.b, t), a.a)


static func _hash(i: int, j: int, s: int) -> float:
	return fposmod(sin(float(i) * 12.9898 + float(j) * 78.233 + float(s) * 37.719) * 43758.5453, 1.0)


## Palette per people colour and era.
static func _pal(civ: Color, era: int) -> Dictionary:
	var accent := Color.from_hsv(civ.h, clampf(civ.s, 0.6, 1.0), clampf(civ.v, 0.72, 1.0))
	var muted := Color.from_hsv(civ.h, clampf(civ.s * 0.72, 0.3, 0.75), clampf(civ.v * 0.8, 0.45, 0.8))
	var p := {"era": era, "civ": civ, "accent": accent, "muted": muted,
		"gold": Color(0.95, 0.74, 0.25), "iron": Color(0.22, 0.23, 0.27), "glass": Color(1.0, 0.85, 0.5)}
	match era:
		0:
			p.wall = Color(0.66, 0.5, 0.34)
			p.wall_pat = PAT_NONE
			p.timber = Color(0.47, 0.32, 0.2)
			p.stone = Color(0.58, 0.54, 0.48)
			p.roof = _mix(Color(0.86, 0.72, 0.4), muted, 0.1)
			p.roof_pat = PAT_THATCH
			p.round_pat = PAT_THATCH
		1:
			p.wall = Color(0.6, 0.42, 0.25)
			p.wall_pat = PAT_PLANK
			p.timber = Color(0.5, 0.34, 0.2)
			p.stone = Color(0.6, 0.56, 0.5)
			p.roof = _mix(Color(0.88, 0.74, 0.38), muted, 0.15)
			p.roof_pat = PAT_THATCH
			p.round_pat = PAT_THATCH
		2:
			p.wall = Color(0.93, 0.85, 0.66)
			p.wall_pat = PAT_NONE
			p.timber = Color(0.5, 0.33, 0.2)
			p.stone = Color(0.62, 0.6, 0.56)
			p.roof = muted
			p.roof_pat = PAT_TILE
			p.round_pat = PAT_RTILE
		3:
			p.wall = Color(0.96, 0.9, 0.76)
			p.wall_pat = PAT_NONE
			p.timber = Color(0.42, 0.27, 0.17)
			p.stone = Color(0.66, 0.64, 0.6)
			p.roof = _v(muted, 1.05)
			p.roof_pat = PAT_TILE
			p.round_pat = PAT_RTILE
		4:
			p.wall = Color(0.88, 0.86, 0.81)
			p.wall_pat = PAT_STONE
			p.timber = Color(0.9, 0.7, 0.26)
			p.stone = Color(0.8, 0.78, 0.73)
			p.roof = _v(_mix(Color(0.78, 0.42, 0.28), civ, 0.4), 0.88)
			p.roof_pat = PAT_TILE
			p.round_pat = PAT_RTILE
		_:
			p.wall = Color(0.74, 0.37, 0.27)
			p.wall_pat = PAT_BRICK
			p.timber = Color(0.27, 0.28, 0.33)
			p.stone = Color(0.78, 0.76, 0.72)
			p.roof = _v(_mix(civ, Color(0.34, 0.38, 0.5), 0.55), 1.12)
			p.roof_pat = PAT_TILE
			p.round_pat = PAT_RTILE
	p.roof_dark = _v(p.roof, 0.6)
	p.ridge = _v(p.roof, 0.78) if era != 4 else p.gold
	p.stone_pat = PAT_STONE
	return p


# --- Mesh builder ------------------------------------------------------------

class Mb:
	var buf := {}
	var xf := Transform3D.IDENTITY
	var stack: Array = []
	var cur := "main"

	func _init() -> void:
		for k in ["main", "win", "glow"]:
			buf[k] = {"v": PackedVector3Array(), "n": PackedVector3Array(), "c": PackedColorArray()}

	func push() -> void:
		stack.append(xf)

	func pop() -> void:
		xf = stack.pop_back()

	func at(p: Vector3) -> void:
		xf = xf.translated_local(p)

	func yaw(a: float) -> void:
		xf = xf.rotated_local(Vector3.UP, a)

	func pitch(a: float) -> void:
		xf = xf.rotated_local(Vector3.RIGHT, a)

	func roll(a: float) -> void:
		xf = xf.rotated_local(Vector3.BACK, a)

	func use(name: String) -> void:
		cur = name

	## One triangle, given counter-clockwise as seen from outside (Godot wants clockwise).
	func tri3(a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3, ca: Color, cb: Color, cc: Color) -> void:
		if (b - a).cross(c - a).length_squared() < 1e-10:
			return
		var d: Dictionary = buf[cur]
		var bs := xf.basis
		d.v.append(xf * a)
		d.v.append(xf * c)
		d.v.append(xf * b)
		d.n.append((bs * na).normalized())
		d.n.append((bs * nc).normalized())
		d.n.append((bs * nb).normalized())
		d.c.append(ca)
		d.c.append(cc)
		d.c.append(cb)

	func tri(a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
		var n := (b - a).cross(c - a)
		if n.length_squared() < 1e-10:
			return
		n = n.normalized()
		tri3(a, b, c, n, n, n, col, col, col)

	func tri2(a: Vector3, b: Vector3, c: Vector3, col: Color) -> void:
		tri(a, b, c, col)
		tri(a, c, b, col)

	func quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
		tri(a, b, c, col)
		tri(a, c, d, col)

	func quad2(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color) -> void:
		quad(a, b, c, d, col)
		quad(a, d, c, b, col)

	## Quad oriented so that its normal faces `hint`.
	func quad_h(a: Vector3, b: Vector3, c: Vector3, d: Vector3, col: Color, hint: Vector3) -> void:
		if (b - a).cross(c - a).dot(hint) >= 0.0:
			quad(a, b, c, d, col)
		else:
			quad(a, d, c, b, col)

	func tri_h(a: Vector3, b: Vector3, c: Vector3, col: Color, hint: Vector3) -> void:
		if (b - a).cross(c - a).dot(hint) >= 0.0:
			tri(a, b, c, col)
		else:
			tri(a, c, b, col)

	## Box (optionally tapering to the top by `shrink`).
	func box(c: Vector3, s: Vector3, col: Color, shrink := 0.0, lift := 1.07) -> void:
		var h := s * 0.5
		var tx := h.x * (1.0 - shrink)
		var tz := h.z * (1.0 - shrink)
		var a := c + Vector3(-h.x, -h.y, -h.z)
		var b := c + Vector3(h.x, -h.y, -h.z)
		var cc := c + Vector3(h.x, -h.y, h.z)
		var d := c + Vector3(-h.x, -h.y, h.z)
		var e := c + Vector3(-tx, h.y, -tz)
		var f := c + Vector3(tx, h.y, -tz)
		var g := c + Vector3(tx, h.y, tz)
		var hh := c + Vector3(-tx, h.y, tz)
		quad(d, cc, g, hh, col)
		quad(b, a, e, f, col)
		quad(cc, b, f, g, col)
		quad(a, d, hh, e, col)
		var topc := Color(minf(col.r * lift, 1.0), minf(col.g * lift, 1.0), minf(col.b * lift, 1.0), col.a)
		quad(hh, g, f, e, topc)
		quad(a, b, cc, d, Color(col.r * 0.7, col.g * 0.7, col.b * 0.7, col.a))

	## Box between two points.
	func beam(a: Vector3, b: Vector3, thick: float, col: Color) -> void:
		var d := b - a
		var l := d.length()
		if l < 0.001:
			return
		push()
		var q := Quaternion(Vector3.UP, d / l)
		xf = xf * Transform3D(Basis(q), (a + b) * 0.5)
		box(Vector3.ZERO, Vector3(thick, l, thick), col, 0.0, 1.0)
		pop()

	## Surface of revolution. prof: Vector2(radius, y) from bottom to top (outside faces outward).
	func lathe(prof: Array, segs: int, col, jit := 0.0, seed_v := 1, bend: Array = []) -> void:
		var n := prof.size()
		var seg_n: Array = []
		for i in n - 1:
			var dv: Vector2 = prof[i + 1] - prof[i]
			var nn := Vector2(dv.y, -dv.x)
			seg_n.append(nn.normalized() if nn.length() > 1e-6 else Vector2.UP)
		var thr := cos(deg_to_rad(50.0))
		for i in n - 1:
			var n0: Vector2 = seg_n[i]
			var n1: Vector2 = seg_n[i]
			if i > 0 and (seg_n[i - 1] as Vector2).dot(seg_n[i]) > thr:
				n0 = ((seg_n[i - 1] as Vector2) + (seg_n[i] as Vector2)).normalized()
			if i < n - 2 and (seg_n[i + 1] as Vector2).dot(seg_n[i]) > thr:
				n1 = ((seg_n[i + 1] as Vector2) + (seg_n[i] as Vector2)).normalized()
			var c0: Color = col[i] if col is Array else col
			var c1: Color = col[i + 1] if col is Array else col
			for j in segs:
				var a0 := TAU * j / segs
				var a1 := TAU * (j + 1) / segs
				var p00 := _lp(prof, bend, i, a0, j, jit, seed_v, segs)
				var p01 := _lp(prof, bend, i, a1, j + 1, jit, seed_v, segs)
				var p10 := _lp(prof, bend, i + 1, a0, j, jit, seed_v, segs)
				var p11 := _lp(prof, bend, i + 1, a1, j + 1, jit, seed_v, segs)
				var na0 := Vector3(cos(a0) * n0.x, n0.y, sin(a0) * n0.x)
				var na1 := Vector3(cos(a1) * n0.x, n0.y, sin(a1) * n0.x)
				var nb0 := Vector3(cos(a0) * n1.x, n1.y, sin(a0) * n1.x)
				var nb1 := Vector3(cos(a1) * n1.x, n1.y, sin(a1) * n1.x)
				tri3(p01, p00, p10, na1, na0, nb0, c0, c0, c1)
				tri3(p01, p10, p11, na1, nb0, nb1, c0, c1, c1)

	func _lp(prof: Array, bend: Array, i: int, a: float, j: int, jit: float, seed_v: int, segs: int) -> Vector3:
		var pr: Vector2 = prof[i]
		var k := 1.0
		if jit > 0.0 and pr.x > 0.001:
			k += (_h(i, j % segs, seed_v) - 0.5) * 2.0 * jit
		var off := Vector2.ZERO
		if i < bend.size():
			off = bend[i]
		return Vector3(cos(a) * pr.x * k + off.x, pr.y, sin(a) * pr.x * k + off.y)

	static func _h(i: int, j: int, s: int) -> float:
		return fposmod(sin(float(i) * 12.9898 + float(j) * 78.233 + float(s) * 37.719) * 43758.5453, 1.0)

	## Frustum / cone standing on `base` (cap on top).
	func cone_up(base: Vector3, r0: float, r1: float, h: float, segs: int, col: Color, bottom := false) -> void:
		push()
		at(base)
		var prof: Array = []
		if bottom:
			prof.append(Vector2(0, 0))
		prof.append(Vector2(r0, 0))
		prof.append(Vector2(r1, h))
		if r1 > 0.001:
			prof.append(Vector2(0, h))
		lathe(prof, segs, col)
		pop()

	## Squashed low-poly sphere.
	func blob(c: Vector3, rx: float, ry: float, segs: int, rings: int, col: Color, jit := 0.0, seed_v := 1) -> void:
		push()
		at(c)
		var prof: Array = []
		var cols: Array = []
		for k in rings + 1:
			var ph := -PI * 0.5 + PI * k / rings
			prof.append(Vector2(maxf(cos(ph) * rx, 0.0), sin(ph) * ry))
			var t := float(k) / rings
			cols.append(Color(col.r * lerpf(0.78, 1.1, t), col.g * lerpf(0.78, 1.1, t), col.b * lerpf(0.8, 1.06, t), col.a))
		lathe(prof, segs, cols, jit, seed_v)
		pop()

	## Smooth-lit sloped surface fn(u, v) -> Vector3 with per-cell colours, facing `hint`.
	func grid(fn: Callable, nu: int, nv: int, col_fn: Callable, hint: Vector3) -> void:
		var pts: Array = []
		for i in nu + 1:
			var row: Array = []
			for j in nv + 1:
				row.append(fn.call(float(i) / nu, float(j) / nv))
			pts.append(row)
		var e := 0.002
		for i in nu:
			for j in nv:
				var a: Vector3 = pts[i][j]
				var b: Vector3 = pts[i + 1][j]
				var c: Vector3 = pts[i + 1][j + 1]
				var d: Vector3 = pts[i][j + 1]
				var col: Color = col_fn.call(i, j)
				var flip := ((b - a).cross(d - a)).dot(hint) < 0.0
				var q := [a, b, c, d]
				var us := [float(i) / nu, float(i + 1) / nu, float(i + 1) / nu, float(i) / nu]
				var vs := [float(j) / nv, float(j) / nv, float(j + 1) / nv, float(j + 1) / nv]
				var ns: Array = []
				for k in 4:
					var uu: float = us[k]
					var vv: float = vs[k]
					var du: Vector3 = (fn.call(minf(uu + e, 1.0), vv) as Vector3) - (fn.call(maxf(uu - e, 0.0), vv) as Vector3)
					var dv: Vector3 = (fn.call(uu, minf(vv + e, 1.0)) as Vector3) - (fn.call(uu, maxf(vv - e, 0.0)) as Vector3)
					var nn := du.cross(dv).normalized()
					ns.append(-nn if flip else nn)
				if flip:
					tri3(q[0], q[3], q[2], ns[0], ns[3], ns[2], col, col, col)
					tri3(q[0], q[2], q[1], ns[0], ns[2], ns[1], col, col, col)
				else:
					tri3(q[0], q[1], q[2], ns[0], ns[1], ns[2], col, col, col)
					tri3(q[0], q[2], q[3], ns[0], ns[2], ns[3], col, col, col)

	## Strip joining two polylines, facing `hint`.
	func strip(pa: Array, pb: Array, col: Color, hint: Vector3) -> void:
		for i in pa.size() - 1:
			quad_h(pa[i], pa[i + 1], pb[i + 1], pb[i], col, hint)

	## Banner hanging in the local XY plane (+Z faces forward), top centre at the origin.
	func banner(w: float, h: float, col: Color, trim: Color) -> void:
		var n := 4
		var top: Array = []
		var bot: Array = []
		for i in n + 1:
			var x := -w * 0.5 + w * i / n
			var wz := sin(float(i) * 1.3) * 0.03
			top.append(Vector3(x, 0, wz))
			var tail := absf(x) / (w * 0.5)
			bot.append(Vector3(x, -h + (1.0 - tail) * h * 0.2, wz))
		for i in n:
			quad2(top[i], bot[i], bot[i + 1], top[i + 1], col)
		var t := Color(trim.r, trim.g, trim.b, trim.a)
		box(Vector3(0, 0.02, 0), Vector3(w + 0.1, 0.07, 0.07), t, 0.0, 1.0)
		box(Vector3(0, -h * 0.42, 0.015), Vector3(w * 0.14, h * 0.4, 0.02), t, 0.0, 1.0)

	func to_mesh(win_mat: Material, main_mat: Material, glow_mat: Material) -> ArrayMesh:
		var m := ArrayMesh.new()
		for k in ["main", "win", "glow"]:
			var d: Dictionary = buf[k]
			if d.v.size() == 0:
				continue
			var arr := []
			arr.resize(Mesh.ARRAY_MAX)
			arr[Mesh.ARRAY_VERTEX] = d.v
			arr[Mesh.ARRAY_NORMAL] = d.n
			arr[Mesh.ARRAY_COLOR] = d.c
			m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			var si := m.get_surface_count() - 1
			m.surface_set_name(si, k)
			match k:
				"main":
					m.surface_set_material(si, main_mat)
				"win":
					m.surface_set_material(si, win_mat)
				"glow":
					m.surface_set_material(si, glow_mat)
		return m


static func _finish(b: Mb, win_mat: Material) -> ArrayMesh:
	if win_mat == null:
		win_mat = material(Color(1.0, 0.8, 0.4), "glow")
	return b.to_mesh(win_mat, material(Color.WHITE, "kit"), material(Color.WHITE, "glow"))


# --- Shared parts --------------------------------------------------------------

static func _roof_y(sp: Dictionary, x: float, z: float) -> float:
	var hw: float = sp.hw
	var hl: float = sp.hl
	var s := clampf(absf(z) / hw, 0.0, 1.0)
	var xn := clampf(x / hl, -1.0, 1.0)
	var lin := 1.0 - s
	var cur := pow(1.0 - s, 1.9)
	var y: float = float(sp.y0) + float(sp.rise) * lerpf(lin, cur, float(sp.curve))
	y -= float(sp.sag) * (1.0 - xn * xn) * (1.0 - s * 0.6)
	y += float(sp.up) * xn * xn * s * s
	return y


## Gable roof with the ridge along X, concave slopes, a saggy ridge and chunky eaves.
static func _gable(b: Mb, sp: Dictionary, col: Color, under: Color, ridge: Color, nx := 6) -> void:
	var hw: float = sp.hw
	var hl: float = sp.hl
	var th: float = sp.thick
	var fn_top := func(u: float, v: float) -> Vector3:
		var x := lerpf(-hl, hl, u)
		var z := lerpf(-hw, hw, v)
		return Vector3(x, _roof_y(sp, x, z), z)
	var fn_bot := func(u: float, v: float) -> Vector3:
		var x := lerpf(-hl, hl, u)
		var z := lerpf(-hw, hw, v)
		return Vector3(x, _roof_y(sp, x, z) - th, z)
	var nv := 8
	var colf := func(i: int, j: int) -> Color:
		var jj := j if j < nv / 2 else nv - 1 - j
		var k := 1.0 + (0.045 if jj % 2 == 0 else -0.04) + (_hash(i, j, 3) - 0.5) * 0.09 + float(jj) * 0.02
		return _v(col, k)
	b.grid(fn_top, nx, nv, colf, Vector3.UP)
	b.grid(fn_bot, nx, nv, func(_i: int, _j: int) -> Color: return under, Vector3.DOWN)
	# edges
	var tl: Array = []
	var bl: Array = []
	for z_side in [0.0, 1.0]:
		tl.clear()
		bl.clear()
		for i in nx + 1:
			tl.append(fn_top.call(float(i) / nx, z_side))
			bl.append(fn_bot.call(float(i) / nx, z_side))
		b.strip(tl, bl, under, Vector3(0, 0, -1.0 if z_side == 0.0 else 1.0))
	for u_side in [0.0, 1.0]:
		tl.clear()
		bl.clear()
		for j in nv + 1:
			tl.append(fn_top.call(u_side, float(j) / nv))
			bl.append(fn_bot.call(u_side, float(j) / nv))
		b.strip(tl, bl, _v(col, 0.8), Vector3(-1.0 if u_side == 0.0 else 1.0, 0, 0))
	# ridge cap
	var rn := maxi(2, nx / 2)
	for i in rn:
		var x0 := lerpf(-hl, hl, float(i) / rn)
		var x1 := lerpf(-hl, hl, float(i + 1) / rn)
		b.beam(Vector3(x0, _roof_y(sp, x0, 0) + 0.02, 0), Vector3(x1, _roof_y(sp, x1, 0) + 0.02, 0), float(sp.ridge_w), ridge)


## Wall fill under the gable roof at both ends (x = +-xw).
static func _gable_fill(b: Mb, sp: Dictionary, xw: float, hd: float, y_bot: float, col: Color) -> void:
	var n := 8
	for side in [-1.0, 1.0]:
		var top: Array = []
		var bot: Array = []
		for k in n + 1:
			var z := lerpf(-hd, hd, float(k) / n)
			top.append(Vector3(side * xw, _roof_y(sp, side * xw, z) - float(sp.thick) * 0.7, z))
			bot.append(Vector3(side * xw, y_bot, z))
		b.strip(top, bot, col, Vector3(side, 0, 0))


static func _spec(hd: float, hl: float, y0: float, rise: float, over := 0.38) -> Dictionary:
	return {"hw": hd + over, "hl": hl + over * 0.85, "y0": y0, "rise": rise, "curve": 0.55, "sag": 0.05 + rise * 0.04, "up": 0.05, "thick": 0.13, "ridge_w": 0.13}


## Round roof with a flared eave, optionally jittered thatch.
static func _cone_roof(b: Mb, p: Dictionary, r: float, y0: float, h: float, jit: float, segs := 12, tip := 0.0) -> void:
	var col: Color = _c(p.roof, p.round_pat)
	var prof: Array = [Vector2(r * 0.5, y0 - 0.12), Vector2(r, y0 - 0.1), Vector2(r, y0 + 0.05)]
	var cols: Array = [_v(col, 0.55), _v(col, 0.6), _v(col, 0.85)]
	var steps := 4
	for k in range(1, steps + 1):
		var s := float(k) / steps
		prof.append(Vector2(r * (1.0 - s) + tip * s, y0 + 0.05 + h * pow(s, 1.7)))
		cols.append(_v(col, lerpf(0.88, 1.12, s)))
	b.lathe(prof, segs, cols, jit, int(r * 100.0))


static func _arch_poly(b: Mb, cx: float, y0: float, w: float, h: float, z: float, col: Color, segs := 5) -> void:
	var r := w * 0.5
	var ys := y0 + h - r
	var pts: Array = [Vector3(cx - r, y0, z), Vector3(cx + r, y0, z)]
	for k in segs + 1:
		var a := PI * k / segs
		pts.append(Vector3(cx + cos(a) * r, ys + sin(a) * r, z))
	var c := Vector3(cx, y0 + h * 0.4, z)
	for i in pts.size():
		var j := (i + 1) % pts.size()
		b.tri(c, pts[i], pts[j], col)


## Door at local x with its base on the ground, wall face at z (+Z outwards).
static func _door(b: Mb, p: Dictionary, x: float, z: float, w: float, h: float, lit := true) -> void:
	var f: Color = _c(p.timber if int(p.era) != 4 else _mix(p.stone, p.timber, 0.35))
	b.push()
	b.at(Vector3(x, 0, z))
	b.box(Vector3(-w * 0.5 - 0.07, h * 0.5, 0.0), Vector3(0.14, h, 0.16), f, 0.0, 1.0)
	b.box(Vector3(w * 0.5 + 0.07, h * 0.5, 0.0), Vector3(0.14, h, 0.16), f, 0.0, 1.0)
	b.box(Vector3(0, h + 0.07, 0.0), Vector3(w + 0.4, 0.16, 0.2), f, 0.0, 1.05)
	b.box(Vector3(0, 0.05, 0.14), Vector3(w + 0.36, 0.1, 0.36), _c(p.stone, PAT_STONE), 0.0)
	if lit:
		b.use("win")
		_arch_poly(b, 0.0, 0.0, w, h, 0.06, Color.WHITE)
		b.use("main")
		for s in [-1.0, 1.0]:
			b.box(Vector3(s * w * 0.18, h * 0.5, 0.075), Vector3(0.035, h - 0.1, 0.03), _c(_v(p.timber, 0.8)), 0.0, 1.0)
		b.box(Vector3(0, h * 0.45, 0.08), Vector3(w, 0.05, 0.03), _c(_v(p.timber, 0.8)), 0.0, 1.0)
	b.pop()


static func _window(b: Mb, p: Dictionary, x: float, y: float, z: float, w: float, h: float, shutters := true) -> void:
	var f: Color = _c(_v(p.timber, 1.05) if int(p.era) != 4 else p.gold)
	b.push()
	b.at(Vector3(x, y, z))
	b.use("win")
	b.quad(Vector3(-w * 0.5, -h * 0.5, 0.05), Vector3(w * 0.5, -h * 0.5, 0.05), Vector3(w * 0.5, h * 0.5, 0.05), Vector3(-w * 0.5, h * 0.5, 0.05), Color.WHITE)
	b.use("main")
	var t := 0.06
	b.box(Vector3(0, h * 0.5 + t * 0.5, 0.04), Vector3(w + t * 2.0, t, 0.1), f, 0.0, 1.0)
	b.box(Vector3(0, -h * 0.5 - t * 0.5, 0.06), Vector3(w + t * 2.6, t * 1.2, 0.16), _c(p.stone, PAT_NONE), 0.0)
	b.box(Vector3(-w * 0.5 - t * 0.5, 0, 0.04), Vector3(t, h, 0.1), f, 0.0, 1.0)
	b.box(Vector3(w * 0.5 + t * 0.5, 0, 0.04), Vector3(t, h, 0.1), f, 0.0, 1.0)
	if int(p.era) >= 2:
		b.box(Vector3(0, 0, 0.065), Vector3(0.035, h, 0.03), f, 0.0, 1.0)
		b.box(Vector3(0, 0, 0.065), Vector3(w, 0.035, 0.03), f, 0.0, 1.0)
	if shutters and int(p.era) >= 2:
		for s in [-1.0, 1.0]:
			b.box(Vector3(s * (w * 0.5 + 0.1 + t), 0, 0.05), Vector3(0.14, h + 0.04, 0.05), _c(p.accent), 0.0, 1.0)
	b.pop()


static func _chimney(b: Mb, p: Dictionary, x: float, z: float, y0: float, h: float, w := 0.38, embers := false) -> void:
	var era: int = p.era
	var col: Color = _c(p.stone if era != 5 else p.wall, PAT_BRICK if era == 5 else PAT_STONE)
	b.push()
	b.at(Vector3(x, y0, z))
	b.box(Vector3(0, h * 0.5, 0), Vector3(w, h, w), col, 0.1)
	b.box(Vector3(0, h + 0.05, 0), Vector3(w + 0.14, 0.12, w + 0.14), _c(_v(p.stone, 0.85), PAT_NONE), 0.0)
	b.box(Vector3(0, h + 0.2, 0), Vector3(w * 0.7, 0.18, w * 0.7), _c(Color(0.1, 0.09, 0.09), PAT_NONE), 0.0, 1.0)
	if embers:
		b.use("glow")
		b.box(Vector3(0, h + 0.3, 0), Vector3(w * 0.55, 0.06, w * 0.55), _c(Color(1.0, 0.45, 0.1), PAT_NONE), 0.0, 1.0)
		b.blob(Vector3(0.03, h + 0.55, 0), 0.07, 0.07, 5, 2, _c(Color(1.0, 0.65, 0.2), PAT_NONE))
		b.blob(Vector3(-0.07, h + 0.85, 0.04), 0.045, 0.045, 5, 2, _c(Color(1.0, 0.55, 0.15), PAT_NONE))
		b.use("main")
	b.pop()


static func _frame(b: Mb, p: Dictionary, ln: float, dep: float, wh: float, door_x: float, win_xs: Array, y0 := 0.0) -> void:
	var t: Color = _c(p.timber)
	var hl := ln * 0.5
	var hd := dep * 0.5
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			b.box(Vector3(sx * hl, y0 + wh * 0.5, sz * hd), Vector3(0.17, wh, 0.17), t, 0.0, 1.0)
	for sz in [-1.0, 1.0]:
		b.box(Vector3(0, y0 + wh - 0.07, sz * (hd + 0.02)), Vector3(ln, 0.14, 0.08), t, 0.0, 1.0)
		b.box(Vector3(0, y0 + 0.1, sz * (hd + 0.02)), Vector3(ln, 0.12, 0.08), t, 0.0, 1.0)
	for sx in [-1.0, 1.0]:
		b.box(Vector3(sx * (hl + 0.02), y0 + wh - 0.07, 0), Vector3(0.08, 0.14, dep), t, 0.0, 1.0)
		b.box(Vector3(sx * (hl + 0.02), y0 + 0.1, 0), Vector3(0.08, 0.12, dep), t, 0.0, 1.0)
		b.beam(Vector3(sx * (hl + 0.02), y0 + 0.15, -hd * 0.6), Vector3(sx * (hl + 0.02), y0 + wh - 0.15, hd * 0.6), 0.09, t)
		b.beam(Vector3(sx * (hl + 0.02), y0 + 0.15, hd * 0.6), Vector3(sx * (hl + 0.02), y0 + wh - 0.15, -hd * 0.6), 0.09, t)
	var n := maxi(1, int(round(ln / 0.95)))
	for sz in [-1.0, 1.0]:
		var zf: float = sz * (hd + 0.02)
		for i in range(1, n):
			var x := -hl + ln * i / n
			if sz > 0.0 and _near(x, door_x, win_xs, 0.5):
				continue
			b.box(Vector3(x, y0 + wh * 0.5, zf), Vector3(0.11, wh - 0.2, 0.08), t, 0.0, 1.0)
		for i in n:
			var xa := -hl + ln * i / n
			var xb := -hl + ln * (i + 1) / n
			var xm := (xa + xb) * 0.5
			if sz > 0.0 and _near(xm, door_x, win_xs, 0.55):
				continue
			if i % 2 == 0:
				b.beam(Vector3(xa + 0.1, y0 + 0.16, zf), Vector3(xb - 0.1, y0 + wh - 0.16, zf), 0.08, t)
			else:
				b.beam(Vector3(xb - 0.1, y0 + 0.16, zf), Vector3(xa + 0.1, y0 + wh - 0.16, zf), 0.08, t)


static func _near(x: float, door_x: float, win_xs: Array, r: float) -> bool:
	if absf(x - door_x) < r + 0.1:
		return true
	for wx in win_xs:
		if absf(x - float(wx)) < r - 0.1:
			return true
	return false


## The walls of a rectangular building, by era. Returns nothing; roof is separate.
static func _walls(b: Mb, p: Dictionary, ln: float, dep: float, wh: float, door_x: float, win_xs: Array, y0 := 0.0, footing := true) -> void:
	var era: int = p.era
	var hl := ln * 0.5
	var hd := dep * 0.5
	var wall: Color = p.wall
	if footing:
		if era >= 2:
			b.box(Vector3(0, y0 + 0.17, 0), Vector3(ln + 0.18, 0.34, dep + 0.18), _c(p.stone, PAT_STONE), 0.04)
		else:
			b.box(Vector3(0, y0 + 0.09, 0), Vector3(ln + 0.26, 0.18, dep + 0.26), _c(_v(p.stone, 0.85), PAT_NONE), 0.18)
	match era:
		0:
			b.box(Vector3(0, y0 + wh * 0.5, 0), Vector3(ln, wh, dep), _c(wall, PAT_NONE), 0.06)
			b.box(Vector3(0, y0 + wh - 0.08, 0), Vector3(ln + 0.06, 0.14, dep + 0.06), _c(p.accent, PAT_NONE), 0.0, 1.0)
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					b.beam(Vector3(sx * (hl + 0.05), y0, sz * (hd + 0.05)), Vector3(sx * (hl + 0.02), y0 + wh + 0.2, sz * (hd + 0.02)), 0.12, _c(p.timber, PAT_NONE))
		1:
			var rows := maxi(3, int(wh / 0.23))
			var rh := wh / rows
			for i in rows:
				var k := 0.16 if i % 2 == 0 else 0.0
				var tone := 0.92 + 0.14 * _hash(i, 1, 9)
				b.box(Vector3(0, y0 + rh * (i + 0.5), 0), Vector3(ln + 0.14 - k, rh * 0.98, dep + k - 0.02), _c(_v(wall, tone), PAT_NONE), 0.0, 1.03)
			b.box(Vector3(0, y0 + wh - 0.13, 0), Vector3(ln + 0.2, 0.09, dep + 0.2), _c(_v(p.accent, 0.9), PAT_NONE), 0.0, 1.0)
		2, 3:
			b.box(Vector3(0, y0 + wh * 0.5, 0), Vector3(ln, wh, dep), _c(wall, PAT_NONE), 0.0)
			_frame(b, p, ln, dep, wh, door_x, win_xs, y0)
		4:
			b.box(Vector3(0, y0 + wh * 0.5, 0), Vector3(ln, wh, dep), _c(wall, PAT_STONE), 0.0)
			b.box(Vector3(0, y0 + wh - 0.08, 0), Vector3(ln + 0.14, 0.12, dep + 0.14), _c(p.stone, PAT_NONE), 0.0)
			b.box(Vector3(0, y0 + wh - 0.16, 0), Vector3(ln + 0.24, 0.05, dep + 0.24), _c(p.gold, PAT_NONE), 0.0, 1.0)
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					b.box(Vector3(sx * hl, y0 + wh * 0.5, sz * hd), Vector3(0.22, wh, 0.22), _c(p.stone, PAT_NONE), 0.0)
			var n4 := maxi(1, int(round(ln / 1.3)))
			for i in range(1, n4):
				var x := -hl + ln * i / n4
				if _near(x, door_x, win_xs, 0.5):
					continue
				b.box(Vector3(x, y0 + wh * 0.5, hd + 0.04), Vector3(0.16, wh, 0.1), _c(p.stone, PAT_NONE), 0.0)
		_:
			b.box(Vector3(0, y0 + wh * 0.5, 0), Vector3(ln, wh, dep), _c(wall, PAT_BRICK), 0.0)
			b.box(Vector3(0, y0 + wh * 0.5 + 0.02, 0), Vector3(ln + 0.06, 0.1, dep + 0.06), _c(p.stone, PAT_NONE), 0.0, 1.0)
			b.box(Vector3(0, y0 + wh - 0.08, 0), Vector3(ln + 0.12, 0.12, dep + 0.12), _c(p.stone, PAT_NONE), 0.0)
			var qn := maxi(2, int(wh / 0.3))
			for sx in [-1.0, 1.0]:
				for sz in [-1.0, 1.0]:
					for i in qn:
						var wq := 0.3 if i % 2 == 0 else 0.22
						b.box(Vector3(sx * hl, y0 + (i + 0.5) * wh / qn, sz * hd), Vector3(wq, wh / qn * 0.96, wq), _c(p.stone, PAT_NONE), 0.0)


## Rectangular cottage body with a gable roof; returns the roof spec.
static func _cottage(b: Mb, p: Dictionary, ln: float, dep: float, wh: float, rise: float, door_x := 0.0, win_xs: Array = [], over := 0.38) -> Dictionary:
	var hl := ln * 0.5
	var hd := dep * 0.5
	_walls(b, p, ln, dep, wh, door_x, win_xs)
	var sp := _spec(hd, hl, wh - 0.05, rise, over)
	if int(p.era) <= 1:
		sp.sag = float(sp.sag) + 0.06
		sp.thick = 0.2
		sp.ridge_w = 0.2
	_gable(b, sp, _c(p.roof, p.roof_pat), _c(p.roof_dark, PAT_NONE), _c(p.ridge, PAT_NONE), clampi(int(ln * 1.4), 4, 10))
	_gable_fill(b, sp, hl - 0.02, hd, wh - 0.02, _c(p.wall, PAT_NONE if int(p.era) != 4 else PAT_STONE))
	var zf := hd + (0.02 if int(p.era) != 0 else -0.04)
	_door(b, p, door_x, zf + 0.06, 0.62, 1.0)
	for wx in win_xs:
		_window(b, p, float(wx), wh * 0.58, zf + 0.04, 0.34, 0.38)
	return sp


static func _barrel(b: Mb, p: Dictionary, c: Vector3, s := 1.0) -> void:
	b.push()
	b.at(c)
	var w := _c(_mix(p.timber, Color(0.7, 0.5, 0.28), 0.55), PAT_NONE)
	b.lathe([Vector2(0.17 * s, 0), Vector2(0.21 * s, 0.17 * s), Vector2(0.17 * s, 0.38 * s), Vector2(0.0, 0.38 * s)], 8, w)
	b.cone_up(Vector3(0, 0.1 * s, 0), 0.2 * s, 0.2 * s, 0.04 * s, 8, _c(p.iron, PAT_NONE))
	b.cone_up(Vector3(0, 0.26 * s, 0), 0.2 * s, 0.2 * s, 0.04 * s, 8, _c(p.iron, PAT_NONE))
	b.pop()


static func _crate(b: Mb, p: Dictionary, c: Vector3, s := 0.34, yaw := 0.0) -> void:
	b.push()
	b.at(c)
	b.yaw(yaw)
	b.box(Vector3(0, s * 0.5, 0), Vector3(s, s, s), _c(_mix(p.timber, Color(0.72, 0.52, 0.3), 0.5), PAT_PLANK), 0.0)
	b.box(Vector3(0, s * 0.5, 0), Vector3(s + 0.02, 0.04, s + 0.02), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.pop()


static func _sack(b: Mb, c: Vector3, col: Color, s := 1.0) -> void:
	b.blob(c + Vector3(0, 0.12 * s, 0), 0.16 * s, 0.13 * s, 6, 3, _c(col, PAT_NONE), 0.08, int(c.x * 10))
	b.blob(c + Vector3(0, 0.26 * s, 0), 0.07 * s, 0.05 * s, 5, 2, _c(_v(col, 0.85), PAT_NONE))


static func _pole_flag(b: Mb, p: Dictionary, c: Vector3, h: float, w := 0.5, fh := 0.32) -> void:
	b.push()
	b.at(c)
	b.cone_up(Vector3.ZERO, 0.045, 0.03, h, 5, _c(p.timber, PAT_NONE))
	b.blob(Vector3(0, h + 0.03, 0), 0.06, 0.06, 5, 2, _c(p.gold, PAT_NONE))
	var n := 4
	for i in n:
		var x0 := w * i / n
		var x1 := w * (i + 1) / n
		var t0 := 1.0 - float(i) / n * 0.7
		var t1 := 1.0 - float(i + 1) / n * 0.7
		var wz0 := sin(float(i) * 1.2) * 0.05
		var wz1 := sin(float(i + 1) * 1.2) * 0.05
		b.quad2(Vector3(x0, h - 0.03, wz0), Vector3(x0, h - 0.03 - fh * t0, wz0), Vector3(x1, h - 0.03 - fh * t1, wz1), Vector3(x1, h - 0.03, wz1), _c(p.accent, PAT_NONE))
	b.pop()


# --- Kinds ---------------------------------------------------------------------

static func _hut(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var wh := 1.1
	var segs := 10
	# footing and walls
	if era >= 2:
		b.lathe([Vector2(0.93, 0.0), Vector2(0.9, 0.24), Vector2(0.82, 0.3)], segs, _c(p.stone, PAT_STONE_R))
	else:
		b.lathe([Vector2(0.95, 0.0), Vector2(0.9, 0.16), Vector2(0.8, 0.2)], segs, _c(_v(p.stone, 0.85), PAT_NONE), 0.06, 4)
	var wcol := _c(p.wall, PAT_NONE)
	match era:
		1: wcol = _c(p.wall, PAT_PLANK_R)
		4: wcol = _c(p.wall, PAT_STONE_R)
		5: wcol = _c(p.wall, PAT_BRICK_R)
	b.lathe([Vector2(0.82, 0.2), Vector2(0.78, wh * 0.5), Vector2(0.74, wh)], segs, wcol, 0.03 if era <= 1 else 0.0, 7)
	if era == 0 or era == 1:
		b.lathe([Vector2(0.745, wh - 0.18), Vector2(0.79, wh - 0.18), Vector2(0.79, wh - 0.04), Vector2(0.745, wh - 0.04)], segs, _c(p.accent, PAT_NONE))
	if era == 2 or era == 3:
		for i in 6:
			b.push()
			b.yaw(TAU * i / 6.0 + 0.25)
			b.box(Vector3(0, wh * 0.5 + 0.1, 0.78), Vector3(0.13, wh - 0.1, 0.1), _c(p.timber, PAT_NONE), 0.0, 1.0)
			b.pop()
		b.lathe([Vector2(0.745, wh - 0.1), Vector2(0.83, wh - 0.1), Vector2(0.83, wh + 0.02), Vector2(0.75, wh + 0.02)], segs, _c(p.timber, PAT_NONE))
	if era >= 4:
		b.lathe([Vector2(0.745, wh - 0.1), Vector2(0.84, wh - 0.1), Vector2(0.84, wh + 0.02), Vector2(0.75, wh + 0.02)], segs, _c(p.gold if era == 4 else p.stone, PAT_NONE))
	var tip := 0.0
	_cone_roof(b, p, 1.1, wh - 0.04, 1.2, 0.05 if era <= 1 else 0.0, segs, tip)
	b.blob(Vector3(0, wh + 1.2 + 0.04, 0), 0.1, 0.1, 5, 3, _c(p.gold if era >= 4 else p.accent, PAT_NONE))
	if era <= 1:
		b.beam(Vector3(0, wh + 1.15, 0), Vector3(0.0, wh + 1.55, 0), 0.07, _c(p.timber, PAT_NONE))
		for s in [-1.0, 1.0]:
			b.beam(Vector3(0, wh + 1.35, 0), Vector3(s * 0.2, wh + 1.55, 0), 0.05, _c(p.timber, PAT_NONE))
	_door(b, p, 0, 0.8, 0.54, 0.95)
	for s in [-1.0, 1.0]:
		b.push()
		b.yaw(s * 1.95)
		_window(b, p, 0, 0.66, 0.74, 0.28, 0.3, era >= 2)
		b.pop()
	if era >= 3:
		_chimney(b, p, -0.35, -0.45, 1.25, 0.9, 0.3)
	if era <= 1:
		_pole_flag(b, p, Vector3(0.9, 0, 0.6), 1.3, 0.38, 0.28)
	else:
		_barrel(b, p, Vector3(0.95, 0, 0.45), 0.8)


static func _longhouse(b: Mb, p: Dictionary) -> void:
	var ln := 5.2
	var dep := 2.5
	var wh := 1.45
	var doorx := 0.0
	var wins := [-1.85, -0.95, 0.95, 1.85]
	var sp := _cottage(b, p, ln, dep, wh, 1.35, doorx, wins, 0.45)
	# crossed gable beams and banners
	for sx in [-1.0, 1.0]:
		var x: float = sx * (ln * 0.5 + 0.35)
		var ry := _roof_y(sp, x, 0.0)
		b.beam(Vector3(x, ry + 0.4, -0.45), Vector3(x, ry - 0.2, 0.35), 0.13, _c(p.timber, PAT_NONE))
		b.beam(Vector3(x, ry + 0.4, 0.45), Vector3(x, ry - 0.2, -0.35), 0.13, _c(p.timber, PAT_NONE))
	b.push()
	b.at(Vector3(ln * 0.5 + 0.02, wh - 0.1, 0.0))
	b.yaw(PI * 0.5)
	b.banner(0.7, 1.0, _c(p.accent, PAT_NONE), _c(p.gold, PAT_NONE))
	b.pop()
	if int(p.era) >= 2:
		_chimney(b, p, -1.4, -0.55, wh, 1.25, 0.42)
	_barrel(b, p, Vector3(1.6, 0, 1.45))
	_barrel(b, p, Vector3(1.95, 0, 1.3), 0.85)
	_crate(b, p, Vector3(-1.9, 0, 1.55), 0.34, 0.4)


static func _farmhouse(b: Mb, p: Dictionary) -> void:
	var sp := _cottage(b, p, 2.3, 1.8, 1.25, 1.1, 0.35, [-0.7], 0.34)
	if int(p.era) >= 2:
		_chimney(b, p, 0.6, -0.4, 1.2, 1.05, 0.34)
	_barrel(b, p, Vector3(-1.05, 0, 1.15))
	_sack(b, Vector3(1.1, 0, 1.15), Color(0.82, 0.74, 0.5))
	_sack(b, Vector3(1.32, 0, 1.0), Color(0.78, 0.68, 0.45), 0.9)
	# little porch roof
	b.push()
	b.at(Vector3(0.35, 1.28, 1.0))
	b.box(Vector3(0, 0, 0), Vector3(0.95, 0.09, 0.62), _c(p.roof_dark, PAT_NONE), 0.0)
	b.box(Vector3(-0.38, -0.62, 0.22), Vector3(0.09, 1.2, 0.09), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.box(Vector3(0.38, -0.62, 0.22), Vector3(0.09, 1.2, 0.09), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.pop()


static func _workshop(b: Mb, p: Dictionary) -> void:
	var sp := _cottage(b, p, 2.6, 2.1, 1.4, 1.1, -0.25, [-0.95], 0.36)
	_chimney(b, p, -0.7, -0.55, 1.3, 1.1, 0.4, int(p.era) >= 3)
	# lean-to with a workbench
	var x0 := 1.3
	for sz in [-1.0, 1.0]:
		b.box(Vector3(x0 + 0.85, 0.65, sz * 0.7), Vector3(0.12, 1.3, 0.12), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.quad2(Vector3(x0 - 0.1, 1.35, -0.95), Vector3(x0 - 0.1, 1.35, 0.95), Vector3(x0 + 1.0, 1.0, 0.95), Vector3(x0 + 1.0, 1.0, -0.95), _c(p.roof, p.roof_pat))
	b.box(Vector3(x0 + 0.5, 0.42, 0.0), Vector3(0.55, 0.1, 1.15), _c(p.timber, PAT_PLANK), 0.0)
	for sz in [-1.0, 1.0]:
		b.box(Vector3(x0 + 0.5, 0.2, sz * 0.5), Vector3(0.45, 0.4, 0.08), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.box(Vector3(x0 + 0.5, 0.56, 0.05), Vector3(0.22, 0.14, 0.34), _c(p.iron, PAT_NONE), 0.2)
	_crate(b, p, Vector3(x0 + 0.35, 0, 0.95), 0.32, 0.2)
	# hanging sign in the civ colour, on a bracket at the left corner
	b.beam(Vector3(-1.2, 1.15, 1.05), Vector3(-1.2, 1.15, 1.7), 0.06, _c(p.timber, PAT_NONE))
	b.box(Vector3(-1.2, 0.88, 1.68), Vector3(0.05, 0.5, 0.42), _c(p.accent, PAT_NONE), 0.0)
	b.box(Vector3(-1.2, 0.9, 1.68), Vector3(0.07, 0.24, 0.22), _c(p.gold, PAT_NONE), 0.0, 1.0)
	_barrel(b, p, Vector3(-1.45, 0, 1.3))


static func _forge(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var q := p.duplicate()
	q.wall = _mix(p.stone, p.wall, 0.15 if era == 5 else 0.0)
	if era < 5:
		q.wall_pat = PAT_STONE
		q.wall = _v(p.stone, 0.92) if era >= 2 else Color(0.55, 0.5, 0.46)
		q.era = maxi(era, 4) if era >= 3 else era
	var ln := 2.7
	var dep := 2.2
	var wh := 1.35
	var door_x := 0.55
	if era >= 2:
		q.era = era
	_walls(b, q, ln, dep, wh, door_x, [], 0.0, true)
	var sp := _spec(dep * 0.5, ln * 0.5, wh - 0.05, 0.95, 0.34)
	_gable(b, sp, _c(_v(p.roof, 0.82), p.roof_pat), _c(p.roof_dark, PAT_NONE), _c(p.ridge, PAT_NONE), 6)
	_gable_fill(b, sp, ln * 0.5 - 0.02, dep * 0.5, wh - 0.02, _c(q.wall, PAT_STONE))
	_door(b, p, door_x, dep * 0.5 + 0.06, 0.6, 0.95)
	# glowing forge mouth
	var fx := -0.7
	b.push()
	b.at(Vector3(fx, 0, dep * 0.5))
	b.box(Vector3(0, 0.45, 0.06), Vector3(0.95, 0.9, 0.2), _c(_v(p.stone, 0.7), PAT_STONE), 0.15)
	b.use("glow")
	b.quad(Vector3(-0.28, 0.12, 0.17), Vector3(0.28, 0.12, 0.17), Vector3(0.22, 0.58, 0.17), Vector3(-0.22, 0.58, 0.17), _c(Color(1.0, 0.5, 0.1), PAT_NONE))
	b.quad(Vector3(-0.15, 0.14, 0.175), Vector3(0.15, 0.14, 0.175), Vector3(0.1, 0.4, 0.175), Vector3(-0.1, 0.4, 0.175), _c(Color(1.0, 0.85, 0.35), PAT_NONE))
	b.use("main")
	b.pop()
	_chimney(b, p, 0.95, -0.5, wh - 0.1, 1.9, 0.5, true)
	# anvil and tools
	b.push()
	b.at(Vector3(-0.1, 0, 1.55))
	b.cone_up(Vector3.ZERO, 0.16, 0.12, 0.3, 6, _c(p.timber, PAT_NONE))
	b.box(Vector3(0, 0.38, 0), Vector3(0.44, 0.14, 0.2), _c(p.iron, PAT_NONE), 0.15)
	b.box(Vector3(0.28, 0.4, 0), Vector3(0.18, 0.08, 0.12), _c(p.iron, PAT_NONE), 0.3)
	b.pop()
	_barrel(b, p, Vector3(1.2, 0, 1.45))
	_pole_flag(b, p, Vector3(-1.5, 0, 1.25), 1.1, 0.3, 0.22)


static func _granary(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var lift := 0.5
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			b.cone_up(Vector3(sx * 0.62, 0, sz * 0.62), 0.2, 0.15, lift, 6, _c(p.stone, PAT_NONE))
			b.cone_up(Vector3(sx * 0.62, lift, sz * 0.62), 0.24, 0.24, 0.07, 6, _c(_v(p.stone, 0.8), PAT_NONE))
	b.push()
	b.at(Vector3(0, lift, 0))
	var q := p.duplicate()
	_walls(b, q, 1.7, 1.7, 1.2, 0.0, [], 0.0, false)
	b.box(Vector3(0, 0.05, 0), Vector3(1.9, 0.1, 1.9), _c(p.timber, PAT_PLANK), 0.0)
	var sp := _spec(0.85, 0.85, 1.15, 1.35, 0.35)
	sp.sag = 0.03
	_gable(b, sp, _c(p.roof, p.roof_pat), _c(p.roof_dark, PAT_NONE), _c(p.ridge, PAT_NONE), 4)
	_gable_fill(b, sp, 0.83, 0.85, 1.18, _c(p.wall, PAT_NONE if era != 4 else PAT_STONE))
	_door(b, p, 0, 0.9, 0.6, 0.8)
	b.pop()
	# ladder and sacks
	b.beam(Vector3(0.55, 0, 1.55), Vector3(0.6, lift + 0.75, 0.98), 0.07, _c(p.timber, PAT_NONE))
	b.beam(Vector3(0.85, 0, 1.55), Vector3(0.88, lift + 0.75, 0.98), 0.07, _c(p.timber, PAT_NONE))
	for i in 4:
		b.box(Vector3(0.71, 0.18 + i * 0.2, 1.4 - i * 0.14), Vector3(0.3, 0.04, 0.05), _c(p.timber, PAT_NONE), 0.0, 1.0)
	_sack(b, Vector3(-0.7, 0, 1.15), Color(0.84, 0.76, 0.5))
	_sack(b, Vector3(-0.95, 0, 1.0), Color(0.78, 0.7, 0.44), 0.9)
	_sack(b, Vector3(-0.8, 0.22, 1.1), Color(0.8, 0.72, 0.46), 0.8)


static func _mine(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var grass := Color(0.4, 0.6, 0.25)
	var earth := Color(0.55, 0.43, 0.3)
	var prof := [Vector2(2.45, 0.0), Vector2(2.3, 0.35), Vector2(1.95, 0.85), Vector2(1.4, 1.28), Vector2(0.7, 1.52), Vector2(0.0, 1.58)]
	var cols := [_c(_v(earth, 0.8)), _c(earth), _c(_mix(earth, grass, 0.6)), _c(grass), _c(_v(grass, 1.1)), _c(_v(grass, 1.15))]
	b.lathe(prof, 14, cols, 0.07, 5)
	# boulders and shrubs on the mound
	for i in 7:
		var a := TAU * i / 7.0 + 0.4
		var r := 1.2 + _hash(i, 2, 3) * 0.9
		var s := 0.2 + _hash(i, 3, 3) * 0.2
		if cos(a) * r > -0.5 and sin(a) * r > 1.0:
			continue
		b.blob(Vector3(cos(a) * r, 0.2 + (2.4 - r) * 0.5, sin(a) * r), s * 1.4, s, 6, 3, _c(_mix(Color(0.5, 0.48, 0.5), Color(0.62, 0.58, 0.52), _hash(i, 4, 3)), PAT_NONE), 0.18, i)
	for i in 5:
		var a2 := PI + i * 0.9
		b.blob(Vector3(cos(a2) * 1.3, 1.1, sin(a2) * 1.3 - 0.2), 0.3, 0.22, 6, 3, _c(Color(0.28, 0.5, 0.2), PAT_NONE), 0.15, 20 + i)
	# timber-framed adit
	var wood := _c(p.timber if era != 4 else Color(0.55, 0.4, 0.25), PAT_PLANK)
	b.push()
	b.at(Vector3(0, 0, 2.0))
	b.box(Vector3(0, 0.65, -0.3), Vector3(1.3, 1.3, 0.8), _c(Color(0.07, 0.06, 0.06), PAT_NONE), 0.0, 1.0)
	b.use("win")
	_arch_poly(b, 0.0, 0.0, 0.95, 1.15, 0.12, Color.WHITE)
	b.use("main")
	for s in [-1.0, 1.0]:
		b.box(Vector3(s * 0.68, 0.78, 0.05), Vector3(0.26, 1.56, 0.28), wood, 0.0, 1.0)
		b.beam(Vector3(s * 0.68, 0.0, 0.0), Vector3(s * 0.95, 1.1, -0.4), 0.18, wood)
	b.box(Vector3(0, 1.64, 0.05), Vector3(1.9, 0.26, 0.34), wood, 0.0, 1.0)
	b.box(Vector3(0, 1.9, 0.0), Vector3(1.6, 0.18, 0.3), _c(_v(p.timber, 0.85), PAT_NONE), 0.0, 1.0)
	b.beam(Vector3(-0.68, 1.1, 0.14), Vector3(-0.28, 1.55, 0.14), 0.12, wood)
	b.beam(Vector3(0.68, 1.1, 0.14), Vector3(0.28, 1.55, 0.14), 0.12, wood)
	# lantern
	b.box(Vector3(0.95, 1.1, 0.12), Vector3(0.06, 0.5, 0.06), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.use("win")
	b.quad2(Vector3(0.84, 0.74, 0.14), Vector3(1.06, 0.74, 0.14), Vector3(1.06, 0.96, 0.14), Vector3(0.84, 0.96, 0.14), Color.WHITE)
	b.use("main")
	# rails and a cart
	for s in [-1.0, 1.0]:
		b.box(Vector3(s * 0.26, 0.03, 0.8), Vector3(0.06, 0.05, 1.7), _c(p.iron, PAT_NONE), 0.0, 1.0)
	for i in 6:
		b.box(Vector3(0, 0.0, 0.1 + i * 0.28), Vector3(0.7, 0.04, 0.1), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.push()
	b.at(Vector3(0.0, 0.0, 1.15))
	b.box(Vector3(0, 0.34, 0), Vector3(0.56, 0.34, 0.7), _c(_mix(Color(0.45, 0.42, 0.4), p.accent, 0.3), PAT_NONE), 0.2)
	for s in [-1.0, 1.0]:
		for z in [-0.22, 0.22]:
			b.cone_up(Vector3(s * 0.3, 0.12, z), 0.13, 0.13, 0.04, 6, _c(Color(0.25, 0.25, 0.28), PAT_NONE))
	b.blob(Vector3(0, 0.52, 0), 0.25, 0.14, 6, 3, _c(Color(0.6, 0.57, 0.6), PAT_NONE), 0.15, 3)
	b.use("glow")
	b.blob(Vector3(0.07, 0.62, 0.04), 0.08, 0.07, 5, 2, _c(Color(0.95, 0.75, 0.2), PAT_NONE))
	b.use("main")
	b.pop()
	b.pop()
	# spoil heap with ore
	b.blob(Vector3(1.9, 0.18, 2.3), 0.55, 0.32, 7, 3, _c(Color(0.5, 0.4, 0.32), PAT_NONE), 0.2, 1)
	b.use("glow")
	b.blob(Vector3(1.95, 0.4, 2.35), 0.1, 0.08, 5, 2, _c(Color(0.5, 0.9, 1.0), PAT_NONE))
	b.use("main")
	_pole_flag(b, p, Vector3(-1.5, 0, 2.0), 1.4, 0.4, 0.3)


static func _awning(b: Mb, w: float, d: float, y_hi: float, y_lo: float, c1: Color, c2: Color, stripes := 6) -> void:
	for i in stripes:
		var x0 := -w * 0.5 + w * i / stripes
		var x1 := -w * 0.5 + w * (i + 1) / stripes
		var col := c1 if i % 2 == 0 else c2
		var sag := 0.03
		b.quad2(Vector3(x0, y_hi, -d * 0.5), Vector3(x0, y_lo, d * 0.5), Vector3(x1, y_lo, d * 0.5), Vector3(x1, y_hi, -d * 0.5), col)
		b.tri2(Vector3(x0, y_lo, d * 0.5), Vector3(x0 + (x1 - x0) * 0.5, y_lo - 0.16, d * 0.5 + sag), Vector3(x1, y_lo, d * 0.5), _v(col, 0.92))


static func _stall(b: Mb, p: Dictionary, goods: Array, c1: Color, c2: Color) -> void:
	var t := _c(p.timber, PAT_PLANK)
	b.box(Vector3(0, 0.45, 0.1), Vector3(1.5, 0.1, 0.8), t, 0.0)
	b.box(Vector3(0, 0.22, 0.1), Vector3(1.4, 0.44, 0.7), _c(_v(p.timber, 0.85), PAT_PLANK), 0.0)
	for sx in [-1.0, 1.0]:
		b.box(Vector3(sx * 0.72, 0.85, -0.25), Vector3(0.09, 1.7, 0.09), _c(p.timber, PAT_NONE), 0.0, 1.0)
		b.box(Vector3(sx * 0.72, 0.65, 0.5), Vector3(0.09, 1.3, 0.09), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.push()
	b.at(Vector3(0, 0, 0.12))
	_awning(b, 1.75, 1.2, 1.7, 1.3, c1, c2)
	b.pop()
	for i in goods.size():
		var gx := -0.5 + i * 0.33
		b.blob(Vector3(gx, 0.58, 0.1), 0.13, 0.11, 6, 3, _c(goods[i], PAT_NONE), 0.05, i)
		b.blob(Vector3(gx + 0.1, 0.55, 0.3), 0.1, 0.09, 6, 3, _c(_v(goods[i], 0.9), PAT_NONE), 0.05, i + 4)
	b.use("win")
	b.quad2(Vector3(0.6, 1.08, 0.5), Vector3(0.74, 1.08, 0.5), Vector3(0.74, 1.26, 0.5), Vector3(0.6, 1.26, 0.5), Color.WHITE)
	b.use("main")


static func _market(b: Mb, p: Dictionary) -> void:
	var c2 := Color(0.97, 0.92, 0.78)
	var cols := [p.accent, _mix(p.accent, Color(1.0, 0.8, 0.2), 0.6), _mix(p.accent, Color(0.2, 0.7, 0.7), 0.55)]
	var goods := [
		[Color(0.9, 0.2, 0.15), Color(0.95, 0.75, 0.15), Color(0.5, 0.75, 0.2), Color(0.9, 0.5, 0.15)],
		[Color(0.55, 0.3, 0.7), Color(0.95, 0.85, 0.3), Color(0.3, 0.6, 0.85), Color(0.9, 0.4, 0.5)],
		[Color(0.85, 0.7, 0.4), Color(0.7, 0.5, 0.3), Color(0.9, 0.85, 0.7), Color(0.6, 0.4, 0.25)],
	]
	var spots := [Vector3(-1.9, 0, 0.6), Vector3(1.9, 0, 0.6), Vector3(0, 0, -1.55)]
	var yaws := [0.4, -0.4, 0.0]
	# cobbled ground
	b.lathe([Vector2(2.9, 0.0), Vector2(2.8, 0.07), Vector2(0.0, 0.07)], 16, _c(_mix(p.stone, Color(0.55, 0.5, 0.42), 0.4), PAT_STONE), 0.03, 9)
	for i in 3:
		b.push()
		b.at(spots[i])
		b.yaw(yaws[i])
		_stall(b, p, goods[i], cols[i], c2 if i != 1 else Color(0.95, 0.95, 0.9))
		b.pop()
	_pole_flag(b, p, Vector3(0, 0, 0.5), 2.3, 0.7, 0.45)
	b.cone_up(Vector3(0, 0, 0.5), 0.2, 0.15, 0.2, 6, _c(p.stone, PAT_STONE))
	_barrel(b, p, Vector3(-1.0, 0, 1.7))
	_crate(b, p, Vector3(1.0, 0, 1.75), 0.34, 0.5)
	_crate(b, p, Vector3(1.15, 0.34, 1.7), 0.26, 0.1)
	_sack(b, Vector3(-0.3, 0, 1.9), Color(0.85, 0.78, 0.55))


static func _library(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var ln := 3.4
	var dep := 2.4
	var wh := 2.3
	var win_xs := [-1.2, 1.2]
	_walls(b, p, ln, dep, wh, 0.0, win_xs, 0.0, true)
	b.box(Vector3(0, 1.2, 0), Vector3(ln + 0.12, 0.1, dep + 0.12), _c(p.timber if era != 5 else p.stone, PAT_NONE), 0.0, 1.0)
	var sp := _spec(dep * 0.5, ln * 0.5, wh - 0.05, 1.7, 0.4)
	sp.sag = 0.07
	_gable(b, sp, _c(p.roof, p.roof_pat), _c(p.roof_dark, PAT_NONE), _c(p.ridge, PAT_NONE), 7)
	_gable_fill(b, sp, ln * 0.5 - 0.02, dep * 0.5, wh - 0.02, _c(p.wall, PAT_NONE if era != 4 else PAT_STONE))
	var zf := dep * 0.5 + 0.06
	_door(b, p, 0, zf, 0.78, 1.2)
	for wx in win_xs:
		_window(b, p, wx, 0.85, zf - 0.02, 0.4, 0.55, false)
		_window(b, p, wx, 1.85, zf - 0.02, 0.4, 0.55, true)
	_window(b, p, 0.0, 1.85, zf - 0.02, 0.3, 0.5, false)
	# porch with pillars, civ banner
	for s in [-1.0, 1.0]:
		b.cone_up(Vector3(s * 0.75, 0, 1.5), 0.13, 0.11, 1.35, 6, _c(p.stone, PAT_NONE))
	b.box(Vector3(0, 1.45, 1.5), Vector3(1.9, 0.14, 0.4), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.quad2(Vector3(-1.0, 1.5, 0.95), Vector3(1.0, 1.5, 0.95), Vector3(1.0, 1.5, 1.7), Vector3(-1.0, 1.5, 1.7), _c(p.roof_dark, PAT_NONE))
	b.push()
	b.at(Vector3(1.4, 2.2, zf))
	b.banner(0.5, 1.2, _c(p.accent, PAT_NONE), _c(p.gold, PAT_NONE))
	b.pop()
	_crate(b, p, Vector3(-1.3, 0, 1.45), 0.3, 0.2)
	_crate(b, p, Vector3(-1.3, 0.3, 1.45), 0.24, 0.6)


static func _rack(b: Mb, p: Dictionary) -> void:
	b.box(Vector3(-0.6, 0.55, 0), Vector3(0.1, 1.1, 0.1), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.box(Vector3(0.6, 0.55, 0), Vector3(0.1, 1.1, 0.1), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.box(Vector3(0, 0.95, 0), Vector3(1.3, 0.09, 0.1), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.box(Vector3(0, 0.4, 0), Vector3(1.3, 0.09, 0.1), _c(p.timber, PAT_NONE), 0.0, 1.0)
	for i in 4:
		var x := -0.42 + i * 0.28
		b.beam(Vector3(x, 0.05, 0.08), Vector3(x + 0.04, 1.55, 0.02), 0.04, _c(Color(0.55, 0.38, 0.22), PAT_NONE))
		b.cone_up(Vector3(x + 0.04, 1.53, 0.02), 0.05, 0.0, 0.18, 4, _c(Color(0.82, 0.84, 0.9), PAT_NONE))


static func _shield(b: Mb, p: Dictionary, c: Vector3) -> void:
	b.push()
	b.at(c)
	b.pitch(PI * 0.5)
	b.cone_up(Vector3.ZERO, 0.24, 0.24, 0.05, 8, _c(p.accent, PAT_NONE), true)
	b.cone_up(Vector3(0, 0.04, 0), 0.08, 0.04, 0.06, 6, _c(p.gold, PAT_NONE))
	b.cone_up(Vector3(0, -0.01, 0), 0.26, 0.26, 0.03, 8, _c(p.iron, PAT_NONE))
	b.pop()


static func _barracks(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var ln := 5.0
	var dep := 2.4
	var wh := 1.55
	var win_xs := [-1.8, -0.9, 0.9, 1.8]
	var sp := _cottage(b, p, ln, dep, wh, 1.0, 0.0, win_xs, 0.4)
	if era >= 4:
		for sx in [-1.0, 1.0]:
			b.cone_up(Vector3(sx * (ln * 0.5 + 0.1), 0, dep * 0.5 + 0.1), 0.38, 0.34, wh + 0.9, 8, _c(p.wall, p.wall_pat if era == 5 else PAT_STONE_R))
			b.cone_up(Vector3(sx * (ln * 0.5 + 0.1), wh + 0.9, dep * 0.5 + 0.1), 0.5, 0.0, 0.7, 8, _c(p.roof, PAT_RTILE))
	# racks, shields and a banner pole out front
	for sx in [-1.0, 1.0]:
		b.push()
		b.at(Vector3(sx * 1.55, 0, 1.65))
		b.yaw(-sx * 0.15)
		_rack(b, p)
		b.pop()
	for i in 5:
		_shield(b, p, Vector3(-1.2 + i * 0.6, 0.95, dep * 0.5 + 0.12 + 0.0))
	_pole_flag(b, p, Vector3(0, 0, 1.9), 3.0, 0.9, 0.55)
	b.cone_up(Vector3(0, 0, 1.9), 0.22, 0.16, 0.25, 6, _c(p.stone, PAT_STONE))
	# training dummy
	b.push()
	b.at(Vector3(-0.75, 0, 1.75))
	b.cone_up(Vector3.ZERO, 0.06, 0.06, 1.05, 5, _c(p.timber, PAT_NONE))
	b.blob(Vector3(0, 0.82, 0), 0.2, 0.28, 6, 3, _c(Color(0.82, 0.72, 0.5), PAT_NONE), 0.04, 2)
	b.box(Vector3(0, 0.9, 0), Vector3(0.62, 0.08, 0.08), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.blob(Vector3(0, 1.18, 0), 0.12, 0.12, 6, 3, _c(Color(0.8, 0.68, 0.45), PAT_NONE))
	b.pop()


static func _shrine(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var glow := _c(_mix(p.accent, Color(0.7, 0.95, 1.0), 0.4), PAT_NONE)
	b.lathe([Vector2(1.0, 0.0), Vector2(0.96, 0.14), Vector2(0.86, 0.18), Vector2(0.84, 0.3), Vector2(0.7, 0.34)], 10, _c(p.stone, PAT_STONE_R))
	if era <= 1:
		for i in 5:
			var a := TAU * i / 5.0
			b.push()
			b.at(Vector3(cos(a) * 0.62, 0.3, sin(a) * 0.62))
			b.yaw(-a)
			b.pitch(0.08 * (1.0 if i % 2 == 0 else -1.0))
			var h := 1.15 + 0.4 * _hash(i, 1, 4)
			b.box(Vector3(0, h * 0.5, 0), Vector3(0.28, h, 0.16), _c(_mix(p.stone, Color(0.5, 0.5, 0.52), 0.4), PAT_NONE), 0.35)
			b.use("glow")
			b.box(Vector3(0, h * 0.5, 0.085), Vector3(0.05, h * 0.5, 0.012), glow, 0.0, 1.0)
			b.use("main")
			b.pop()
		b.cone_up(Vector3(0, 0.3, 0), 0.2, 0.15, 0.3, 6, _c(p.stone, PAT_STONE))
	elif era <= 3:
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				b.box(Vector3(sx * 0.55, 0.95, sz * 0.55), Vector3(0.14, 1.3, 0.14), _c(p.timber, PAT_NONE), 0.0, 1.0)
		var cap := {"hw": 0.95, "hl": 0.95, "y0": 1.5, "rise": 0.55, "curve": 0.55, "sag": 0.0, "up": 0.04, "thick": 0.1, "ridge_w": 0.11}
		_gable(b, cap, _c(p.roof, p.roof_pat), _c(p.roof_dark, PAT_NONE), _c(p.ridge, PAT_NONE), 3)
		b.cone_up(Vector3(0, 0.3, 0), 0.22, 0.16, 0.45, 6, _c(p.stone, PAT_STONE))
	else:
		for i in 6:
			var a2 := TAU * i / 6.0
			b.cone_up(Vector3(cos(a2) * 0.68, 0.34, sin(a2) * 0.68), 0.1, 0.085, 1.15, 6, _c(p.wall, PAT_NONE))
			b.cone_up(Vector3(cos(a2) * 0.68, 1.49, sin(a2) * 0.68), 0.13, 0.13, 0.08, 6, _c(p.gold, PAT_NONE))
		b.lathe([Vector2(0.9, 1.55), Vector2(0.85, 1.7), Vector2(0.7, 1.95), Vector2(0.4, 2.2), Vector2(0.1, 2.32), Vector2(0, 2.34)], 12, _c(_mix(p.roof, p.gold, 0.25), PAT_RTILE))
		b.cone_up(Vector3(0, 0.34, 0), 0.22, 0.16, 0.45, 6, _c(p.wall, PAT_NONE))
	b.use("glow")
	var cy := 0.95 if era <= 1 else (1.0 if era <= 3 else 1.1)
	b.blob(Vector3(0, cy, 0), 0.13, 0.2, 5, 3, glow)
	b.use("main")


static func _temple(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	if era <= 1:
		_temple_primal(b, p)
	elif era <= 3:
		_temple_hall(b, p)
	else:
		_temple_classical(b, p)


static func _column(b: Mb, p: Dictionary, x: float, z: float, h: float, r: float, col: Color) -> void:
	b.push()
	b.at(Vector3(x, 0, z))
	b.lathe([Vector2(r * 1.55, 0.0), Vector2(r * 1.55, 0.1), Vector2(r * 1.15, 0.16), Vector2(r * 1.0, 0.3), Vector2(r * 0.88, h - 0.28), Vector2(r * 1.0, h - 0.2), Vector2(r * 1.4, h - 0.14), Vector2(r * 1.55, h - 0.1)], 8, col)
	b.cone_up(Vector3(0, h - 0.1, 0), r * 1.7, r * 1.7, 0.1, 8, _c(_v(col, 0.95), PAT_NONE))
	b.pop()


static func _temple_primal(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	b.lathe([Vector2(2.85, 0.0), Vector2(2.7, 0.28), Vector2(2.4, 0.36)], 16, _c(p.stone, PAT_STONE_R), 0.04, 2)
	b.lathe([Vector2(2.4, 0.3), Vector2(2.3, 1.2), Vector2(2.15, 2.1)], 16, _c(p.wall, PAT_PLANK_R if era == 1 else PAT_NONE), 0.02, 5)
	b.lathe([Vector2(2.16, 1.85), Vector2(2.4, 1.85), Vector2(2.4, 2.03), Vector2(2.18, 2.03)], 16, _c(p.accent, PAT_NONE))
	_cone_roof(b, p, 2.85, 2.05, 2.3, 0.06, 16)
	b.blob(Vector3(0, 4.45, 0), 0.2, 0.2, 6, 3, _c(p.accent, PAT_NONE))
	b.beam(Vector3(0, 4.2, 0), Vector3(0, 5.0, 0), 0.1, _c(p.timber, PAT_NONE))
	b.push()
	b.at(Vector3(0, 4.9, 0))
	b.banner(0.5, 0.9, _c(p.accent, PAT_NONE), _c(p.gold, PAT_NONE))
	b.pop()
	_door(b, p, 0, 2.22, 1.0, 1.55)
	for s in [-1.0, 1.0]:
		b.push()
		b.at(Vector3(s * 1.6, 0, 2.7))
		b.cone_up(Vector3.ZERO, 0.2, 0.17, 2.2, 7, _c(p.timber, PAT_NONE))
		for k in 3:
			var cols := [p.accent, p.gold, Color(0.2, 0.6, 0.6)]
			b.box(Vector3(0, 0.5 + k * 0.6, 0.17), Vector3(0.3, 0.3, 0.1), _c(cols[k], PAT_NONE), 0.0, 1.0)
			b.box(Vector3(0, 0.62 + k * 0.6, 0.0), Vector3(0.6, 0.08, 0.1), _c(cols[k], PAT_NONE), 0.0, 1.0)
		b.cone_up(Vector3(0, 2.2, 0), 0.22, 0.0, 0.3, 6, _c(p.accent, PAT_NONE))
		b.pop()
	for i in 7:
		var a := PI * 0.1 + TAU * i / 7.0
		if sin(a) > 0.5:
			continue
		b.push()
		b.at(Vector3(cos(a) * 3.05, 0, sin(a) * 3.05))
		b.yaw(-a + PI * 0.5)
		var h := 1.1 + _hash(i, 8, 2) * 0.7
		b.box(Vector3(0, h * 0.5, 0), Vector3(0.5, h, 0.3), _c(Color(0.55, 0.53, 0.57), PAT_NONE), 0.3)
		b.pop()
	b.push()
	b.at(Vector3(0, 0, 3.15))
	b.cone_up(Vector3.ZERO, 0.28, 0.22, 0.3, 6, _c(p.stone, PAT_STONE))
	b.use("glow")
	b.blob(Vector3(0, 0.58, 0), 0.12, 0.17, 5, 3, _c(_mix(p.accent, Color.WHITE, 0.4), PAT_NONE))
	b.use("main")
	b.pop()


static func _temple_hall(b: Mb, p: Dictionary) -> void:
	var ln := 4.6
	var dep := 3.2
	var wh := 1.9
	b.box(Vector3(0, 0.15, 0), Vector3(ln + 1.0, 0.3, dep + 1.0), _c(p.stone, PAT_STONE), 0.03)
	b.box(Vector3(0, 0.42, 0), Vector3(ln + 0.6, 0.24, dep + 0.6), _c(_v(p.stone, 1.05), PAT_STONE), 0.03)
	b.push()
	b.at(Vector3(0, 0.3, 0))
	_walls(b, p, ln, dep, wh, 0.0, [], 0.0, false)
	b.pop()
	var y0 := 0.3
	var sp := _spec(dep * 0.5, ln * 0.5, y0 + wh - 0.05, 1.1, 0.7)
	sp.up = 0.14
	sp.curve = 0.75
	_gable(b, sp, _c(p.roof, p.roof_pat), _c(p.roof_dark, PAT_NONE), _c(p.ridge, PAT_NONE), 8)
	_gable_fill(b, sp, ln * 0.5 - 0.02, dep * 0.5, y0 + wh - 0.02, _c(p.wall, PAT_NONE))
	# raised clerestory with a second roof
	var cl := 2.2
	b.box(Vector3(0, y0 + wh + 0.7, 0), Vector3(cl + 0.6, 1.0, 1.7), _c(p.wall, PAT_NONE), 0.0)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			b.box(Vector3(sx * (cl * 0.5 + 0.3), y0 + wh + 0.7, sz * 0.85), Vector3(0.14, 1.0, 0.14), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.use("win")
	for k in 3:
		var x := -0.7 + k * 0.7
		b.quad(Vector3(x - 0.2, y0 + wh + 0.45, 0.87), Vector3(x + 0.2, y0 + wh + 0.45, 0.87), Vector3(x + 0.2, y0 + wh + 0.9, 0.87), Vector3(x - 0.2, y0 + wh + 0.9, 0.87), Color.WHITE)
	b.use("main")
	var sp2 := _spec(0.85, cl * 0.5 + 0.3, y0 + wh + 1.15, 1.2, 0.55)
	sp2.up = 0.12
	sp2.curve = 0.8
	_gable(b, sp2, _c(_v(p.roof, 1.1), p.roof_pat), _c(p.roof_dark, PAT_NONE), _c(p.gold, PAT_NONE), 6)
	b.blob(Vector3(0, _roof_y(sp2, 0, 0) + 0.2, 0), 0.14, 0.2, 5, 3, _c(p.gold, PAT_NONE))
	_door(b, p, 0, dep * 0.5 + 0.12, 0.95, 1.4)
	for s in [-1.0, 1.0]:
		_window(b, p, s * 1.5, 1.35, dep * 0.5 + 0.08, 0.4, 0.55)
		_window(b, p, s * 0.82, 1.35, dep * 0.5 + 0.08, 0.3, 0.5, false)
		b.cone_up(Vector3(s * 1.25, 0.3, dep * 0.5 + 0.6), 0.14, 0.12, 1.85, 6, _c(p.timber, PAT_NONE))
		b.push()
		b.at(Vector3(s * 1.0, 1.6, dep * 0.5 + 0.05))
		b.banner(0.42, 1.05, _c(p.accent, PAT_NONE), _c(p.gold, PAT_NONE))
		b.pop()
	b.box(Vector3(0, 2.2, dep * 0.5 + 0.6), Vector3(3.0, 0.14, 0.2), _c(p.timber, PAT_NONE), 0.0, 1.0)
	# steps
	for i in 3:
		b.box(Vector3(0, 0.1 + i * 0.1, dep * 0.5 + 0.8 + (2 - i) * 0.25), Vector3(1.6, 0.2 + i * 0.1 - 0.0, 0.3), _c(p.stone, PAT_STONE), 0.0)


static func _temple_classical(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var ln := 5.2
	var dep := 3.6
	var marble := _c(p.wall if era == 4 else p.stone, PAT_STONE)
	b.box(Vector3(0, 0.12, 0), Vector3(ln + 1.0, 0.24, dep + 1.0), marble, 0.0)
	b.box(Vector3(0, 0.34, 0), Vector3(ln + 0.7, 0.2, dep + 0.7), _c(_v(marble, 1.04), PAT_STONE), 0.0)
	b.box(Vector3(0, 0.54, 0), Vector3(ln + 0.4, 0.2, dep + 0.4), _c(_v(marble, 1.08), PAT_STONE), 0.0)
	var y0 := 0.64
	var ch := 2.4
	# cella
	b.box(Vector3(0, y0 + ch * 0.5, 0), Vector3(ln - 1.0, ch, dep - 1.0), _c(p.wall, PAT_STONE), 0.0)
	var col := _c(p.stone if era == 5 else p.wall, PAT_NONE)
	var nf := 6
	var ns := 4
	for i in nf:
		var x := -ln * 0.5 + 0.25 + (ln - 0.5) * i / (nf - 1)
		_column_at(b, p, x, dep * 0.5 - 0.25, y0, ch, 0.17, col)
		_column_at(b, p, x, -dep * 0.5 + 0.25, y0, ch, 0.17, col)
	for k in range(1, ns - 1):
		var z := -dep * 0.5 + 0.25 + (dep - 0.5) * k / (ns - 1)
		_column_at(b, p, -ln * 0.5 + 0.25, z, y0, ch, 0.17, col)
		_column_at(b, p, ln * 0.5 - 0.25, z, y0, ch, 0.17, col)
	# entablature and pediment
	b.box(Vector3(0, y0 + ch + 0.14, 0), Vector3(ln, 0.28, dep), _c(_v(marble, 1.03), PAT_NONE), 0.0)
	b.box(Vector3(0, y0 + ch + 0.31, 0), Vector3(ln + 0.14, 0.1, dep + 0.14), _c(p.gold, PAT_NONE), 0.0, 1.0)
	var top := y0 + ch + 0.34
	var sp := {"hw": dep * 0.5 + 0.12, "hl": ln * 0.5 + 0.1, "y0": top, "rise": 1.05, "curve": 0.0, "sag": 0.0, "up": 0.0, "thick": 0.16, "ridge_w": 0.12}
	_gable(b, sp, _c(p.roof, PAT_TILE), _c(p.roof_dark, PAT_NONE), _c(p.gold, PAT_NONE), 6)
	_gable_fill(b, sp, ln * 0.5, dep * 0.5, top, _c(_mix(p.wall, p.accent, 0.35), PAT_NONE))
	# pediment fronts on the front and back
	b.use("win")
	_arch_poly(b, 0.0, y0, 1.0, 1.7, dep * 0.5 - 0.48, Color.WHITE)
	b.use("main")
	b.box(Vector3(-0.58, y0 + 0.85, dep * 0.5 - 0.5), Vector3(0.14, 1.7, 0.1), _c(p.gold, PAT_NONE), 0.0, 1.0)
	b.box(Vector3(0.58, y0 + 0.85, dep * 0.5 - 0.5), Vector3(0.14, 1.7, 0.1), _c(p.gold, PAT_NONE), 0.0, 1.0)
	if era == 5:
		b.lathe([Vector2(1.5, top + 0.4), Vector2(1.48, top + 0.9), Vector2(1.3, top + 1.0)], 14, _c(p.wall, PAT_BRICK_R))
		b.lathe([Vector2(1.5, top + 0.95), Vector2(1.3, top + 1.5), Vector2(0.8, top + 1.95), Vector2(0.3, top + 2.2), Vector2(0.0, top + 2.25)], 14, _c(_mix(p.roof, p.gold, 0.2), PAT_RTILE))
		b.blob(Vector3(0, top + 2.35, 0), 0.1, 0.14, 5, 3, _c(p.gold, PAT_NONE))
	else:
		# acroteria, braziers
		b.blob(Vector3(0, top + 1.2, 0), 0.14, 0.2, 5, 3, _c(p.gold, PAT_NONE))
	for s in [-1.0, 1.0]:
		b.push()
		b.at(Vector3(s * 1.4, 0.74, dep * 0.5 + 0.55))
		b.cone_up(Vector3.ZERO, 0.2, 0.14, 0.7, 7, _c(marble, PAT_NONE))
		b.cone_up(Vector3(0, 0.7, 0), 0.28, 0.36, 0.2, 7, _c(p.gold, PAT_NONE))
		b.use("glow")
		b.blob(Vector3(0, 1.0, 0), 0.17, 0.22, 5, 3, _c(Color(1.0, 0.65, 0.2), PAT_NONE))
		b.use("main")
		b.pop()
		b.push()
		b.at(Vector3(s * 2.0, 1.55, dep * 0.5 + 0.45))
		b.banner(0.5, 1.3, _c(p.accent, PAT_NONE), _c(p.gold, PAT_NONE))
		b.pop()
	for i in 4:
		b.box(Vector3(0, 0.74 + i * 0.0 - 0.1, dep * 0.5 + 0.75 + (3 - i) * 0.22), Vector3(2.4 + i * 0.0, 0.14 + 0.0, 0.26), _c(_v(marble, 1.0 + i * 0.02), PAT_STONE), 0.0)


static func _column_at(b: Mb, p: Dictionary, x: float, z: float, y0: float, h: float, r: float, col: Color) -> void:
	b.push()
	b.at(Vector3(0, y0, 0))
	_column(b, p, x, z, h, r, col)
	b.pop()


static func _tower(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var stone := _c(_mix(p.wall if era >= 4 else p.stone, Color(0.65, 0.62, 0.7), 0.35), PAT_STONE_R)
	b.lathe([Vector2(1.35, 0.0), Vector2(1.25, 0.35), Vector2(1.08, 0.55)], 12, _c(p.stone, PAT_STONE_R), 0.03, 3)
	b.lathe([Vector2(1.08, 0.5), Vector2(0.92, 1.8), Vector2(0.84, 3.3)], 12, stone)
	# corbelled upper room
	b.lathe([Vector2(0.84, 3.3), Vector2(1.0, 3.4), Vector2(1.18, 3.55), Vector2(1.18, 3.7), Vector2(1.02, 3.78), Vector2(0.98, 4.5)], 12, stone)
	b.lathe([Vector2(0.98, 4.35), Vector2(1.12, 4.38), Vector2(1.12, 4.55), Vector2(0.98, 4.55)], 12, _c(p.accent, PAT_NONE))
	# bent pointy hat
	var bend: Array = []
	var prof: Array = []
	var cols: Array = []
	var hc := _c(_mix(p.roof, p.accent, 0.5), PAT_NONE)
	prof.append(Vector2(1.55, 4.5))
	bend.append(Vector2.ZERO)
	cols.append(_v(hc, 0.7))
	prof.append(Vector2(1.55, 4.58))
	bend.append(Vector2.ZERO)
	cols.append(_v(hc, 0.8))
	var steps := 6
	for k in range(1, steps + 1):
		var s := float(k) / steps
		prof.append(Vector2(1.55 * pow(1.0 - s, 1.3) + 0.0, 4.58 + 2.6 * pow(s, 1.25)))
		bend.append(Vector2(0.9 * s * s, 0.0))
		cols.append(_v(hc, lerpf(0.9, 1.2, s)))
	b.lathe(prof, 12, cols, 0.0, 1, bend)
	b.use("glow")
	b.blob(Vector3(0.95, 7.3, 0), 0.17, 0.2, 5, 3, _c(Color(0.7, 0.95, 1.0), PAT_NONE))
	var crys := _c(_mix(p.accent, Color(0.8, 0.95, 1.0), 0.5), PAT_NONE)
	for i in 3:
		var a := TAU * i / 3.0 + 0.5
		b.blob(Vector3(cos(a) * 1.55, 4.9 + i * 0.35, sin(a) * 1.55), 0.1, 0.18, 4, 2, crys)
	b.use("main")
	# lit windows spiralling up, door at the front
	for i in 4:
		var yaw := 0.9 + i * 1.5
		var y := 1.5 + i * 0.7
		b.push()
		b.yaw(yaw)
		_window(b, p, 0, y, lerpf(0.92, 0.84, (y - 0.5) / 2.8) + 0.04, 0.26, 0.45, false)
		b.pop()
	for i in 3:
		b.push()
		b.yaw(i * 2.1 + 0.3)
		_window(b, p, 0, 4.05, 0.98, 0.3, 0.5, true)
		b.pop()
	_door(b, p, 0, 1.02, 0.58, 1.0)
	# stairs
	for i in 3:
		b.box(Vector3(0, 0.05 + i * 0.08, 1.35 - i * 0.12), Vector3(0.9 - i * 0.05, 0.1 + i * 0.08, 0.3), _c(p.stone, PAT_STONE), 0.0)


static func _aqueduct(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var col := _c(p.stone if era != 4 else p.wall, PAT_STONE if era != 5 else PAT_BRICK)
	if era == 5:
		col = _c(p.wall, PAT_BRICK)
	if era <= 1:
		col = _c(_mix(p.stone, Color(0.5, 0.5, 0.45), 0.5), PAT_STONE)
	var pier_w := 0.8
	var span := 2.3
	var depth := 1.1
	var hd := depth * 0.5
	var spring := 2.0
	var ytop := 3.55
	var bays := 3
	var total := pier_w * (bays + 1) + span * bays
	var x := -total * 0.5
	for i in bays + 1:
		var pc := x + pier_w * 0.5
		b.box(Vector3(pc, spring * 0.5, 0), Vector3(pier_w, spring, depth), col, 0.08)
		b.box(Vector3(pc, 0.12, 0), Vector3(pier_w + 0.3, 0.24, depth + 0.3), _c(_v(p.stone, 0.9), PAT_STONE), 0.1)
		b.box(Vector3(pc, spring + 0.07, 0), Vector3(pier_w + 0.14, 0.14, depth + 0.14), _c(_v(p.stone, 1.05), PAT_NONE), 0.0)
		x += pier_w
		if i < bays:
			var xc := x + span * 0.5
			var a := span * 0.5
			var rise := a * 1.05
			var prev_f := Vector3.ZERO
			var prev_b := Vector3.ZERO
			var n := 8
			for k in n + 1:
				var th := PI * k / n
				var px := xc - cos(th) * a
				var py := spring + 0.14 + sin(th) * rise
				var pf := Vector3(px, py, hd)
				var pb := Vector3(px, py, -hd)
				if k > 0:
					var tf0 := Vector3(prev_f.x, ytop, hd)
					var tf1 := Vector3(px, ytop, hd)
					b.quad(prev_f, pf, tf1, tf0, col)
					b.quad(Vector3(pf.x, pf.y, -hd), Vector3(prev_f.x, prev_f.y, -hd), Vector3(prev_f.x, ytop, -hd), Vector3(px, ytop, -hd), col)
					var mid := (prev_f + pf) * 0.5
					b.quad_h(prev_f, pf, pb, prev_b, _v(col, 0.85), Vector3(xc, spring, 0) - mid)
				prev_f = pf
				prev_b = pb
			x += span
	# deck, parapets and the water channel
	b.box(Vector3(0, ytop + 0.1, 0), Vector3(total + 0.1, 0.2, depth + 0.3), _c(_v(p.stone, 1.05), PAT_NONE), 0.0)
	for sz in [-1.0, 1.0]:
		b.box(Vector3(0, ytop + 0.4, sz * (hd + 0.05)), Vector3(total + 0.1, 0.4, 0.2), col, 0.0)
	for sx in [-1.0, 1.0]:
		b.box(Vector3(sx * (total * 0.5 + 0.02), ytop + 0.4, 0), Vector3(0.22, 0.4, depth + 0.3), col, 0.0)
	b.box(Vector3(0, ytop + 0.28, 0), Vector3(total - 0.1, 0.12, depth - 0.2), _c(Color(0.28, 0.58, 0.88), PAT_NONE), 0.0, 1.0)
	b.use("glow")
	b.box(Vector3(0, ytop + 0.345, 0), Vector3(total - 0.2, 0.01, depth - 0.35), _c(Color(0.25, 0.55, 0.85), PAT_NONE), 0.0, 1.0)
	b.use("main")
	_pole_flag(b, p, Vector3(-total * 0.5 + 0.2, ytop + 0.55, hd - 0.1), 1.0, 0.4, 0.28)


static func _factory(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var ln := 4.4
	var dep := 3.2
	var wh := 2.1
	_walls(b, p, ln, dep, wh, 0.0, [-1.5, 1.5], 0.0, true)
	var hl := ln * 0.5
	var hd := dep * 0.5
	var roof_col := _c(_v(p.roof, 0.9), PAT_TILE)
	# sawtooth roof: slopes rising to the front, glazed risers facing +Z
	var teeth := 3
	var tz := dep / teeth
	for i in teeth:
		var z0 := -hd + tz * i
		var z1 := z0 + tz
		var yl := wh - 0.02
		var yh := wh + 0.7
		b.quad2(Vector3(-hl - 0.15, yh, z0), Vector3(hl + 0.15, yh, z0), Vector3(hl + 0.15, yl, z1 + 0.1), Vector3(-hl - 0.15, yl, z1 + 0.1), roof_col)
		b.use("win")
		b.quad2(Vector3(-hl + 0.2, yl + 0.1, z0 - 0.02), Vector3(hl - 0.2, yl + 0.1, z0 - 0.02), Vector3(hl - 0.2, yh - 0.08, z0 - 0.02), Vector3(-hl + 0.2, yh - 0.08, z0 - 0.02), Color.WHITE)
		b.use("main")
		b.box(Vector3(0, yh, z0), Vector3(ln + 0.3, 0.12, 0.14), _c(p.iron, PAT_NONE), 0.0, 1.0)
		for sx in [-1.0, 1.0]:
			b.tri2(Vector3(sx * (hl + 0.15), yh, z0), Vector3(sx * (hl + 0.15), yl, z0), Vector3(sx * (hl + 0.15), yl, z1 + 0.1), _c(p.roof_dark, PAT_NONE))
	_gable_fill(b, {"hw": hd, "hl": hl, "y0": wh, "rise": 0.0, "curve": 0.0, "sag": 0.0, "up": 0.0, "thick": 0.0}, hl - 0.02, hd, wh - 0.02, _c(p.wall, p.wall_pat))
	# big arched doors and a cog
	_door(b, p, 0, hd + 0.08, 1.3, 1.5)
	b.push()
	b.at(Vector3(0, 1.95, hd + 0.08))
	b.cone_up(Vector3.ZERO, 0.28, 0.28, 0.08, 8, _c(p.iron, PAT_NONE), true)
	for i in 8:
		b.push()
		b.yaw(0.0)
		var a := TAU * i / 8.0
		b.box(Vector3(cos(a) * 0.3, 0.04, sin(a) * 0.3), Vector3(0.1, 0.08, 0.1), _c(p.iron, PAT_NONE), 0.0, 1.0)
		b.pop()
	b.pop()
	for wx in [-1.5, 1.5]:
		_window(b, p, wx, 1.15, hd + 0.08, 0.5, 0.6, false)
	# chimneys with smoke embers
	_chimney(b, p, -1.5, -0.8, wh, 2.6, 0.55, true)
	_chimney(b, p, -0.8, -1.0, wh, 2.0, 0.45, true)
	# pipes and barrels
	b.beam(Vector3(hl + 0.1, 0.2, 0.5), Vector3(hl + 0.1, wh + 0.4, 0.5), 0.14, _c(p.iron, PAT_NONE))
	b.beam(Vector3(hl + 0.1, wh + 0.4, 0.5), Vector3(hl - 0.5, wh + 0.4, 0.5), 0.14, _c(p.iron, PAT_NONE))
	_barrel(b, p, Vector3(1.9, 0, 2.0))
	_barrel(b, p, Vector3(2.25, 0, 1.85), 0.9)
	_crate(b, p, Vector3(-1.9, 0, 2.0), 0.4, 0.3)
	_pole_flag(b, p, Vector3(-2.2, 0, hd + 0.1), 3.0, 0.8, 0.5)


static func _well(b: Mb, p: Dictionary) -> void:
	b.lathe([Vector2(0.72, 0.0), Vector2(0.7, 0.3), Vector2(0.62, 0.52), Vector2(0.45, 0.52)], 10, _c(p.stone, PAT_STONE_R), 0.02, 3)
	b.use("main")
	b.cone_up(Vector3(0, 0.38, 0), 0.46, 0.46, 0.04, 10, _c(Color(0.22, 0.5, 0.8), PAT_NONE))
	b.use("glow")
	b.cone_up(Vector3(0, 0.425, 0), 0.4, 0.4, 0.01, 10, _c(Color(0.2, 0.45, 0.8), PAT_NONE))
	b.use("main")
	for s in [-1.0, 1.0]:
		b.box(Vector3(s * 0.55, 0.95, 0), Vector3(0.12, 1.0, 0.14), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.box(Vector3(0, 1.05, 0), Vector3(1.3, 0.08, 0.1), _c(p.timber, PAT_NONE), 0.0, 1.0)
	var sp := {"hw": 0.62, "hl": 0.82, "y0": 1.4, "rise": 0.5, "curve": 0.55, "sag": 0.02, "up": 0.04, "thick": 0.09, "ridge_w": 0.1}
	_gable(b, sp, _c(p.roof, p.roof_pat), _c(p.roof_dark, PAT_NONE), _c(p.ridge, PAT_NONE), 3)
	b.beam(Vector3(0, 1.45, 0), Vector3(0, 1.05, 0.02), 0.025, _c(Color(0.5, 0.42, 0.3), PAT_NONE))
	b.cone_up(Vector3(0.03, 0.78, 0.0), 0.1, 0.13, 0.18, 6, _c(_mix(p.timber, Color(0.7, 0.5, 0.3), 0.5), PAT_NONE))


static func _haystack(b: Mb, p: Dictionary) -> void:
	var hay := Color(0.93, 0.8, 0.38)
	var tc := [_c(_v(hay, 0.72), PAT_THATCH), _c(_v(hay, 0.88), PAT_THATCH), _c(hay, PAT_THATCH), _c(_v(hay, 1.08), PAT_THATCH), _c(_v(hay, 1.16), PAT_THATCH), _c(_v(hay, 1.2), PAT_THATCH)]
	b.lathe([Vector2(0.7, 0.0), Vector2(0.74, 0.2), Vector2(0.6, 0.5), Vector2(0.38, 0.8), Vector2(0.17, 0.98), Vector2(0.0, 1.04)], 10, tc, 0.07, 6)
	b.beam(Vector3(0.0, 0.9, 0), Vector3(0.03, 1.4, 0), 0.04, _c(Color(0.55, 0.4, 0.25), PAT_NONE))
	b.blob(Vector3(0.7, 0.1, 0.35), 0.18, 0.1, 6, 2, _c(_v(hay, 0.95), PAT_THATCH), 0.15, 3)


static func _wall_segment(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var col := _c(p.stone if era != 5 else _mix(p.stone, p.wall, 0.4), PAT_STONE)
	if era <= 1:
		col = _c(_v(p.stone, 0.88), PAT_STONE)
	if era == 4:
		col = _c(p.wall, PAT_STONE)
	b.box(Vector3(0, 0.18, 0), Vector3(1.14, 0.36, 1.0), _c(_v(col, 0.9), PAT_STONE), 0.04)
	b.box(Vector3(0, 0.88, 0), Vector3(0.92, 1.08, 1.0), col, 0.05)
	b.box(Vector3(0, 1.46, 0), Vector3(1.08, 0.18, 1.0), _c(_v(col, 1.08), PAT_NONE), 0.0)
	for s in [-1.0, 1.0]:
		b.box(Vector3(s * 0.4, 1.68, 0), Vector3(0.24, 0.24, 0.56), _c(_v(col, 1.1), PAT_NONE), 0.0)
	if era >= 2:
		b.box(Vector3(0, 1.57, 0), Vector3(1.1, 0.05, 1.0), _c(p.accent if era != 4 else p.gold, PAT_NONE), 0.0, 1.0)


static func _wall_tower(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var col := _c(p.stone if era != 4 else p.wall, PAT_STONE_R)
	if era <= 1:
		col = _c(p.wall, PAT_PLANK_R)
	b.lathe([Vector2(1.38, 0.0), Vector2(1.3, 0.4), Vector2(1.12, 0.6)], 10, _c(p.stone, PAT_STONE_R), 0.02, 3)
	b.lathe([Vector2(1.12, 0.5), Vector2(1.0, 2.0), Vector2(0.98, 2.7)], 10, col)
	b.lathe([Vector2(0.98, 2.6), Vector2(1.18, 2.75), Vector2(1.2, 3.0), Vector2(1.0, 3.0)], 10, _c(_v(p.stone, 1.05), PAT_NONE))
	var n := 8
	for i in n:
		var a := TAU * (i + 0.5) / n
		b.push()
		b.at(Vector3(cos(a) * 1.06, 3.0, sin(a) * 1.06))
		b.yaw(-a + PI * 0.5)
		b.box(Vector3(0, 0.15, 0), Vector3(0.5, 0.3, 0.2), _c(_v(p.stone, 1.08), PAT_NONE), 0.0)
		b.pop()
	if era >= 2:
		var rc := _c(_mix(p.roof, p.accent, 0.35), PAT_RTILE)
		b.lathe([Vector2(1.18, 3.15), Vector2(1.15, 3.55), Vector2(0.7, 4.15), Vector2(0.28, 4.6), Vector2(0.0, 4.75)], 10, rc)
		b.beam(Vector3(0, 4.7, 0), Vector3(0, 5.2, 0), 0.06, _c(p.timber, PAT_NONE))
		b.push()
		b.at(Vector3(0, 5.15, 0))
		b.banner(0.0001, 0.0001, _c(p.accent, PAT_NONE), _c(p.gold, PAT_NONE))
		b.pop()
		_pole_flag(b, p, Vector3(0, 4.55, 0), 0.7, 0.45, 0.3)
	else:
		_pole_flag(b, p, Vector3(0.3, 3.0, 0.2), 1.3, 0.5, 0.35)
	b.use("win")
	b.quad(Vector3(-0.1, 1.6, 1.0), Vector3(0.1, 1.6, 1.0), Vector3(0.1, 2.05, 1.0), Vector3(-0.1, 2.05, 1.0), Color.WHITE)
	b.use("main")
	b.box(Vector3(0, 1.82, 1.0), Vector3(0.36, 0.08, 0.1), _c(p.stone, PAT_NONE), 0.0, 1.0)
	_door(b, p, 0, 1.12, 0.6, 0.9)


static func _palisade_post(b: Mb, p: Dictionary) -> void:
	var wood := _c(_mix(p.timber, Color(0.72, 0.52, 0.32), 0.6), PAT_NONE)
	b.lathe([Vector2(0.17, 0.0), Vector2(0.15, 0.3), Vector2(0.14, 1.7), Vector2(0.0, 2.15)], 7, [_v(wood, 0.7), _v(wood, 0.85), _v(wood, 1.0), _v(wood, 1.15)], 0.06, 3)
	b.lathe([Vector2(0.145, 1.2), Vector2(0.19, 1.2), Vector2(0.19, 1.3), Vector2(0.145, 1.3)], 7, _c(p.accent, PAT_NONE))


static func _pier(b: Mb, p: Dictionary) -> void:
	var wood := _mix(p.timber, Color(0.74, 0.55, 0.34), 0.65)
	var n := 13
	var pl := 6.5 / n
	for i in n:
		var tone := 0.86 + 0.24 * _hash(i, 4, 8)
		b.box(Vector3(0, -0.07, pl * (i + 0.5)), Vector3(1.6 - (0.0 if i % 2 == 0 else 0.06), 0.14, pl * 0.92), _c(_v(wood, tone), PAT_NONE), 0.0, 1.06)
	for sx in [-1.0, 1.0]:
		b.box(Vector3(sx * 0.62, -0.28, 3.25), Vector3(0.14, 0.2, 6.5), _c(_v(p.timber, 0.9), PAT_NONE), 0.0, 1.0)
	var posts := 5
	for i in posts:
		var z := 0.35 + (6.2 - 0.35) * i / (posts - 1)
		for sx in [-1.0, 1.0]:
			var h := 0.42 if i % 2 == 0 else 0.3
			b.lathe([Vector2(0.12, -1.55), Vector2(0.12, -0.1), Vector2(0.12, h), Vector2(0.09, h + 0.06), Vector2(0.0, h + 0.08)], 6, _c(_mix(p.timber, Color(0.55, 0.4, 0.26), 0.4), PAT_NONE), 0.04, i * 3 + int(sx) + 7)
			if i % 2 == 0:
				b.lathe([Vector2(0.125, h - 0.16), Vector2(0.16, h - 0.16), Vector2(0.16, h - 0.08), Vector2(0.125, h - 0.08)], 6, _c(p.accent, PAT_NONE))
			if i % 2 == 1:
				b.beam(Vector3(sx * 0.7, -1.0, z), Vector3(sx * 0.7, -0.2, z), 0.1, _c(p.timber, PAT_NONE))
	b.beam(Vector3(-0.7, -0.5, 0.35), Vector3(0.7, -0.5, 0.35), 0.1, _c(p.timber, PAT_NONE))
	b.beam(Vector3(-0.7, -0.5, 6.2), Vector3(0.7, -0.5, 6.2), 0.1, _c(p.timber, PAT_NONE))
	# lantern at the end
	b.box(Vector3(0.7, 0.95, 6.2), Vector3(0.06, 1.0, 0.06), _c(p.timber, PAT_NONE), 0.0, 1.0)
	b.box(Vector3(0.7, 1.5, 6.2), Vector3(0.26, 0.05, 0.26), _c(p.iron, PAT_NONE), 0.0, 1.0)
	b.use("win")
	b.box(Vector3(0.7, 1.35, 6.2), Vector3(0.18, 0.22, 0.18), Color.WHITE, 0.0, 1.0)
	b.use("main")
	# a coil of rope and a crate
	b.cone_up(Vector3(-0.5, 0.0, 1.2), 0.2, 0.2, 0.1, 8, _c(Color(0.75, 0.62, 0.38), PAT_NONE))
	_crate(b, p, Vector3(-0.5, 0.0, 2.6), 0.34, 0.3)


static func _crop(b: Mb, p: Dictionary) -> void:
	var era: int = p.era
	var stalk := Color(0.5, 0.68, 0.22)
	var grain := Color(0.93, 0.76, 0.28) if era < 4 else Color(0.95, 0.82, 0.3)
	b.box(Vector3(0, 0.02, 0), Vector3(0.3, 0.04, 0.3), _c(Color(0.42, 0.3, 0.2), PAT_NONE), 0.3, 1.0)
	for i in 6:
		var a := TAU * i / 6.0 + 0.4
		var r := 0.07 + 0.04 * (i % 2)
		var base := Vector3(cos(a) * r, 0.03, sin(a) * r)
		var lean := Vector3(cos(a) * 0.05, 0, sin(a) * 0.05)
		var h := 0.3 + 0.06 * (i % 3)
		var tip := base + Vector3(0, h, 0) + lean
		var side := Vector3(-sin(a), 0, cos(a)) * 0.022
		b.tri2(base - side, base + side, tip, _c(_mix(stalk, grain, float(i % 3) * 0.2), PAT_NONE))
		b.blob(tip + Vector3(0, 0.02, 0), 0.026, 0.06, 5, 3, _c(grain, PAT_NONE))


static func _fence(b: Mb, p: Dictionary) -> void:
	var wood := _c(_mix(p.timber, Color(0.74, 0.55, 0.34), 0.6), PAT_NONE)
	for sx in [-0.5, 0.5]:
		b.lathe([Vector2(0.06, 0.0), Vector2(0.055, 0.5), Vector2(0.0, 0.62)], 6, wood, 0.05, 2)
	for y in [0.2, 0.42]:
		b.box(Vector3(0, y, 0), Vector3(1.0, 0.07, 0.05), wood, 0.0, 1.0)


# --- Arena scenery ---------------------------------------------------------------

static func _scn_pine(b: Mb, rng: RandomNumberGenerator) -> void:
	var trunk := Color(0.42, 0.28, 0.16)
	b.lathe([Vector2(0.2, 0.0), Vector2(0.14, 0.4), Vector2(0.11, 1.0)], 7, [_c(_v(trunk, 0.8)), _c(trunk), _c(_v(trunk, 1.1))], 0.05, 3)
	var g := Color(0.2, 0.55, 0.26)
	var tiers := 4
	for k in tiers:
		var s := float(k) / (tiers - 1)
		var r := lerpf(0.95, 0.42, s)
		var y := 0.65 + k * 0.62
		var h := 0.95 - s * 0.2
		var gc := _mix(g, Color(0.4, 0.72, 0.28), s * 0.7)
		b.lathe([Vector2(r, y), Vector2(r * 0.86, y + 0.06), Vector2(r * 0.25, y + h * 0.9), Vector2(0.0, y + h)], 8, [_c(_v(gc, 0.72), PAT_NONE), _c(_v(gc, 0.9), PAT_NONE), _c(_v(gc, 1.1), PAT_NONE), _c(_v(gc, 1.25), PAT_NONE)], 0.1, 5 + k)


static func _scn_oak(b: Mb, rng: RandomNumberGenerator) -> void:
	var trunk := Color(0.45, 0.3, 0.17)
	b.lathe([Vector2(0.3, 0.0), Vector2(0.2, 0.5), Vector2(0.16, 1.2), Vector2(0.2, 1.5)], 7, [_c(_v(trunk, 0.75)), _c(trunk), _c(_v(trunk, 1.1)), _c(trunk)], 0.06, 2)
	b.beam(Vector3(0, 1.1, 0), Vector3(0.4, 1.7, 0.1), 0.1, _c(trunk))
	b.beam(Vector3(0, 1.2, 0), Vector3(-0.35, 1.75, -0.1), 0.1, _c(trunk))
	var g := Color(0.36, 0.68, 0.22)
	b.blob(Vector3(0, 2.0, 0), 0.95, 0.7, 9, 4, _c(_v(g, 0.95), PAT_NONE), 0.12, 1)
	b.blob(Vector3(0.6, 1.7, 0.1), 0.62, 0.5, 8, 3, _c(_v(g, 0.82), PAT_NONE), 0.12, 2)
	b.blob(Vector3(-0.55, 1.75, -0.15), 0.6, 0.48, 8, 3, _c(_mix(g, Color(0.5, 0.65, 0.15), 0.4), PAT_NONE), 0.12, 3)
	b.blob(Vector3(0.1, 2.5, -0.05), 0.55, 0.42, 8, 3, _c(_mix(g, Color(0.5, 0.72, 0.2), 0.5), PAT_NONE), 0.12, 4)


static func _scn_boulder(b: Mb, rng: RandomNumberGenerator, small: bool) -> void:
	var s := 0.12 if small else 0.55
	var tone := _mix(Color(0.5, 0.49, 0.53), Color(0.65, 0.6, 0.55), rng.randf())
	if small:
		tone = _v(tone, 1.45)
	b.blob(Vector3(0, s * 0.45, 0), s * 1.1, s * 0.85, 7, 3, _c(tone, PAT_NONE), 0.2, rng.randi() % 100)
	if not small:
		b.blob(Vector3(s * 0.6, s * 0.2, s * 0.4), s * 0.5, s * 0.38, 6, 3, _c(_v(tone, 0.9), PAT_NONE), 0.2, 3)
		b.blob(Vector3(-s * 0.2, s * 0.8, 0), s * 0.6, s * 0.35, 6, 3, _c(_mix(tone, Color(0.4, 0.55, 0.25), 0.3), PAT_NONE), 0.2, 5)


static func _scn_pillar(b: Mb) -> void:
	var st := Color(0.74, 0.7, 0.64)
	b.lathe([Vector2(0.62, 0.0), Vector2(0.6, 0.18), Vector2(0.5, 0.3)], 8, _c(_v(st, 0.85), PAT_STONE_R))
	b.lathe([Vector2(0.5, 0.28), Vector2(0.4, 1.5), Vector2(0.37, 2.7)], 8, _c(st, PAT_STONE_R))
	b.lathe([Vector2(0.37, 2.65), Vector2(0.55, 2.78), Vector2(0.6, 3.05), Vector2(0.58, 3.15), Vector2(0.0, 3.15)], 8, _c(_v(st, 1.08), PAT_NONE))
	b.use("glow")
	for i in 4:
		var a := TAU * i / 4.0 + PI * 0.25
		b.push()
		b.yaw(-a + PI * 0.5)
		b.at(Vector3(0, 1.7, 0.39))
		b.box(Vector3(0, 0, 0), Vector3(0.1, 0.55, 0.03), _c(Color(0.5, 0.85, 1.0), PAT_NONE), 0.0, 1.0)
		b.box(Vector3(0, 0.1, 0), Vector3(0.34, 0.08, 0.03), _c(Color(0.5, 0.85, 1.0), PAT_NONE), 0.0, 1.0)
		b.pop()
	b.use("main")


static func _scn_gem(b: Mb) -> void:
	var g := Color(1, 1, 1, PAT_NONE)
	b.lathe([Vector2(0.0, -0.62), Vector2(0.3, -0.12), Vector2(0.3, 0.1), Vector2(0.0, 0.62)], 6, g)


static func _scn_shrine_base(b: Mb) -> void:
	var st := Color(0.78, 0.74, 0.68)
	b.lathe([Vector2(1.15, 0.0), Vector2(1.1, 0.16), Vector2(0.95, 0.22), Vector2(0.92, 0.42), Vector2(0.75, 0.5), Vector2(0.0, 0.5)], 12, [_c(_v(st, 0.8), PAT_STONE_R), _c(_v(st, 0.9), PAT_STONE_R), _c(st, PAT_STONE_R), _c(_v(st, 1.05), PAT_STONE_R), _c(_v(st, 1.1), PAT_NONE), _c(_v(st, 1.1), PAT_NONE)])
	b.lathe([Vector2(0.4, 0.5), Vector2(0.3, 0.7), Vector2(0.27, 1.25), Vector2(0.38, 1.35), Vector2(0.38, 1.42), Vector2(0.0, 1.42)], 8, _c(_v(st, 1.05), PAT_STONE_R))
	b.use("glow")
	for i in 4:
		var a := TAU * i / 4.0 + PI * 0.25
		b.push()
		b.yaw(-a + PI * 0.5)
		b.at(Vector3(0, 0.95, 0.29))
		b.box(Vector3(0, 0, 0), Vector3(0.06, 0.34, 0.02), _c(Color(0.55, 0.9, 1.0), PAT_NONE), 0.0, 1.0)
		b.pop()
	b.use("main")


static func _scn_tuft(b: Mb, rng: RandomNumberGenerator) -> void:
	for i in 7:
		var a := TAU * i / 7.0 + rng.randf() * 0.5
		var r := 0.03 + rng.randf() * 0.06
		var base := Vector3(cos(a) * r, 0.0, sin(a) * r)
		var h := 0.22 + rng.randf() * 0.2
		var lean := Vector3(cos(a), 0, sin(a)) * (0.06 + rng.randf() * 0.08)
		var side := Vector3(-sin(a), 0, cos(a)) * 0.03
		var gc := _mix(Color(0.35, 0.55, 0.2), Color(0.6, 0.75, 0.3), rng.randf())
		b.tri2(base - side, base + side, base + Vector3(0, h, 0) + lean, _c(gc, PAT_NONE))


static func _crystal_cluster(b: Mb, rng: RandomNumberGenerator, scale: float, col: Color) -> void:
	for i in 4:
		b.push()
		b.yaw(rng.randf() * TAU)
		b.pitch(rng.randf_range(-0.35, 0.35))
		var h := (0.35 + rng.randf() * 0.5) * scale
		var r := (0.07 + rng.randf() * 0.05) * scale
		var c := _mix(col, Color.WHITE, rng.randf() * 0.5)
		b.lathe([Vector2(r, 0.0), Vector2(r * 1.1, h * 0.65), Vector2(0.0, h)], 5, [_c(_v(c, 0.8)), _c(c), _c(_v(c, 1.15))])
		b.pop()
	b.blob(Vector3(0, 0.03 * scale, 0), 0.2 * scale, 0.07 * scale, 6, 2, _c(Color(0.7, 0.85, 0.95), PAT_NONE), 0.1, 1)


static func _scn_crystal(b: Mb, rng: RandomNumberGenerator) -> void:
	_crystal_cluster(b, rng, 1.2, Color(0.55, 0.85, 1.0))
