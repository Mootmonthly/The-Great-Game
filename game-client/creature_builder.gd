extends RefCounted
## Builds a stylised 3D creature from a species' body-part list, so every
## evolved body plan gets a model without hand modelling.
##
## Layout: the body runs along +Z (head in front), Y is up. Segments become a
## chain of rounded blobs; limbs, fins, wings, tentacles, eyes, jaws, shells,
## fronds and glands attach to them. Beings from beyond the Veil float, with
## tendrils, phase membranes and voids. CreatureAnim animates the result.

const SHADER := preload("res://shaders/creature.gdshader")
const CreatureAnim := preload("res://creature_anim.gd")


static func _material(color: Color, glow_color := Color.BLACK, glow := 0.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = SHADER
	m.set_shader_parameter("base_color", color)
	m.set_shader_parameter("glow_color", glow_color)
	m.set_shader_parameter("glow", glow)
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


static func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 24
	s.rings = 12
	return s


static func _capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = max(h, r * 2.0)
	c.radial_segments = 12
	c.rings = 4
	return c


static func _cone(r: float, h: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = 0.0
	c.bottom_radius = r
	c.height = h
	c.radial_segments = 12
	return c


static func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


## Part size (0.2..3) to a gentle visual scale.
static func _k(size: float) -> float:
	return clampf(sqrt(size), 0.5, 1.7)


static func build(detail: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.set_script(CreatureAnim)
	var parts := {}
	for p in detail.get("parts", []):
		parts[p["part"]] = p
	var color := Color("#" + str(detail.get("color", "999999")))
	var skin := _material(color)
	var dark := _material(color.darkened(0.4))
	var light := _material(color.lightened(0.35))
	var white := _material(Color(0.95, 0.95, 0.9))
	var black := _material(Color(0.05, 0.05, 0.08))

	var body := Node3D.new()
	body.name = "Body"
	root.add_child(body)
	root.body = body

	# Single cells: a translucent-looking blob with a whip-like tail.
	if parts.is_empty():
		_mesh(body, _sphere(0.3), light, Vector3(0, 0.3, 0), Vector3(1.0, 0.85, 1.1))
		_mesh(body, _sphere(0.12), dark, Vector3(0.05, 0.33, 0.05))
		var tail := Node3D.new()
		tail.position = Vector3(0, 0.3, -0.3)
		body.add_child(tail)
		_mesh(tail, _capsule(0.02, 0.4), dark, Vector3(0, 0, -0.2), Vector3.ONE, Vector3(PI / 2, 0, 0))
		root.tentacles.append([tail])
		root.blob = true
		return root

	var segs: int = int(parts["body segment"]["count"]) if parts.has("body segment") else 1
	var seg_k: float = _k(float(parts["body segment"]["size"])) if parts.has("body segment") else 1.0
	var r := 0.22 * seg_k
	var spacing := r * 1.45
	var has_limbs := parts.has("limb")
	var leg_len := 0.32 * (_k(float(parts["limb"]["size"])) if has_limbs else 1.0)
	var base_y := leg_len * 0.9 + r * 0.6 if has_limbs else (0.55 if parts.has("fin") or parts.has("wing") else r)
	var otherworldly: bool = detail.get("otherworldly", false)
	if otherworldly:
		base_y = r * 2.5 + 0.35  # Drifts above the ground, unbound by gravity.
	body.position.y = base_y

	var seg_z: Array[float] = []
	for i in segs:
		seg_z.append((segs - 1) * spacing * 0.5 - i * spacing)
	var brain_k := 1.0
	if parts.has("brain"):
		brain_k += 0.12 * float(parts["brain"]["count"]) * float(parts["brain"]["size"])
	var head_r := r * clampf(brain_k, 1.0, 1.8)
	for i in segs:
		var rr := head_r if i == 0 else r * (1.0 - 0.06 * i)
		_mesh(body, _sphere(rr), skin, Vector3(0, 0, seg_z[i]), Vector3(0.95, 0.85, 1.1))
		_mesh(body, _sphere(rr * 0.8), light, Vector3(0, -rr * 0.25, seg_z[i]), Vector3(0.9, 0.6, 1.0))
	var head_z: float = seg_z[0]
	var back_z: float = seg_z[segs - 1]

	# Eyes on the front of the head, in pairs.
	if parts.has("eye"):
		var n := int(parts["eye"]["count"])
		var er := head_r * 0.22 * _k(float(parts["eye"]["size"]))
		for e in n:
			var row := e / 2
			var side := -1.0 if e % 2 == 0 else 1.0
			var x := side * head_r * (0.38 + 0.12 * row) if (n % 2 == 0 or e < n - 1) else 0.0
			var pos := Vector3(x, head_r * (0.42 - 0.18 * row), head_z + head_r * 0.78)
			_mesh(body, _sphere(er), white, pos)
			_mesh(body, _sphere(er * 0.55), black, pos + Vector3(0, 0, er * 0.6))

	# Jaw: a cone snout under the eyes.
	if parts.has("jaw"):
		var jk := _k(float(parts["jaw"]["size"]))
		var jaw := Node3D.new()
		jaw.position = Vector3(0, -head_r * 0.25, head_z + head_r * 0.7)
		body.add_child(jaw)
		_mesh(jaw, _cone(head_r * 0.45 * jk, head_r * 0.9 * jk), dark, Vector3(0, 0, head_r * 0.4 * jk), Vector3.ONE, Vector3(PI / 2, 0, 0))
		root.jaw = jaw

	# Gland: a glowing throat sac in its substance's colour.
	if parts.has("gland"):
		var gc := Color("#" + str(parts["gland"].get("substance_color", "ff8030")))
		_mesh(body, _sphere(head_r * 0.35 * _k(float(parts["gland"]["size"]))), _material(gc, gc, 1.2), Vector3(0, -head_r * 0.55, head_z + head_r * 0.3))

	# Shell: a dome over the back.
	if parts.has("shell"):
		var sk := _k(float(parts["shell"]["size"]))
		var mid := (head_z + back_z) * 0.5
		var length := absf(head_z - back_z) + r * 2.0
		_mesh(body, _sphere(0.5), dark, Vector3(0, r * 0.35, mid), Vector3(r * 2.3 * sk, r * 1.4 * sk, length * 1.05))

	# Fronds: leafy plates on the back.
	if parts.has("light-catching frond"):
		var n := int(parts["light-catching frond"]["count"])
		var leaf := _material(color.lerp(Color(0.3, 0.75, 0.3), 0.6))
		var fk := _k(float(parts["light-catching frond"]["size"]))
		for f in n:
			var ang := (float(f) / maxi(n, 1)) * TAU
			_mesh(body, _sphere(0.5), leaf, Vector3(cos(ang) * r * 0.4, r * 0.9, back_z * 0.5 + sin(ang) * r * 0.4),
				Vector3(r * 0.8 * fk, r * 0.12, r * 1.8 * fk), Vector3(0.6, ang, 0))

	# Limbs in pairs along the body.
	if has_limbs:
		var n := int(parts["limb"]["count"])
		var pairs := int(ceil(n / 2.0))
		var claws := parts.has("claw")
		for k in pairs:
			var t := 0.0 if pairs == 1 else float(k) / (pairs - 1)
			var z := lerpf(head_z - spacing * 0.35, back_z + spacing * 0.2, t) if segs > 1 else lerpf(r * 0.5, -r * 0.5, t)
			for side in [-1.0, 1.0]:
				if k * 2 + (0 if side < 0 else 1) >= n:
					continue
				var hip := Node3D.new()
				hip.position = Vector3(side * r * 0.8, -r * 0.2, z)
				body.add_child(hip)
				_mesh(hip, _capsule(r * 0.18, leg_len), skin, Vector3(side * leg_len * 0.18, -leg_len * 0.45, 0), Vector3.ONE, Vector3(0, 0, side * 0.35))
				var foot_pos := Vector3(side * leg_len * 0.35, -leg_len * 0.9, r * 0.1)
				_mesh(hip, _sphere(r * 0.2), dark, foot_pos, Vector3(1.0, 0.6, 1.3))
				if claws and k == 0:
					for c in 3:
						_mesh(hip, _cone(r * 0.05, r * 0.3), white, foot_pos + Vector3((c - 1) * r * 0.08, 0, r * 0.25), Vector3.ONE, Vector3(PI / 2, 0, 0))
				root.legs.append(hip)

	# Fins: dorsal, side and tail fins.
	if parts.has("fin"):
		var n := int(parts["fin"]["count"])
		var fk := _k(float(parts["fin"]["size"]))
		var fin_mat := _material(color.darkened(0.2))
		_mesh(body, _box(Vector3(0.02, r * 0.9 * fk, r * 1.2 * fk)), fin_mat, Vector3(0, r * 0.95, (head_z + back_z) * 0.5), Vector3.ONE, Vector3(-0.3, 0, 0))
		var tail := Node3D.new()
		tail.position = Vector3(0, 0, back_z - r * 0.8)
		body.add_child(tail)
		_mesh(tail, _box(Vector3(0.02, r * 1.4 * fk, r * 0.9 * fk)), fin_mat, Vector3(0, 0, -r * 0.4))
		root.tail = tail
		for f in max(n - 1, 0):
			var side := -1.0 if f % 2 == 0 else 1.0
			_mesh(body, _box(Vector3(r * 0.9 * fk, 0.02, r * 0.5 * fk)), fin_mat, Vector3(side * r * 1.2, -r * 0.2, head_z - spacing * (0.3 + 0.5 * (f / 2))), Vector3.ONE, Vector3(0, 0, side * -0.4))

	# Wings: broad flat sails on the shoulders that flap.
	if parts.has("wing"):
		var n := int(parts["wing"]["count"])
		var wk := _k(float(parts["wing"]["size"]))
		var membrane := _material(color.lightened(0.15).lerp(Color(0.9, 0.9, 1.0), 0.15))
		var span := (r * 3.5 + 0.3) * wk
		var wz := lerpf(head_z, back_z, 0.35) if segs > 1 else 0.0
		for w in n:
			var side := -1.0 if w % 2 == 0 else 1.0
			var pivot := Node3D.new()
			pivot.position = Vector3(side * r * 0.6, r * 0.6, wz - (w / 2) * spacing * 0.8)
			body.add_child(pivot)
			_mesh(pivot, _box(Vector3(span, 0.02, span * 0.55)), membrane, Vector3(side * span * 0.5, 0, -span * 0.12), Vector3.ONE, Vector3(0, side * 0.25, 0))
			_mesh(pivot, _capsule(r * 0.06, span), dark, Vector3(side * span * 0.5, 0.01, span * 0.12), Vector3.ONE, Vector3(0, 0, PI / 2))
			pivot.rotation.z = side * 0.55
			root.wings.append(pivot)
			root.wing_sides.append(side)

	# Tentacles: chains of shrinking capsules from under the head.
	if parts.has("tentacle"):
		var n := int(parts["tentacle"]["count"])
		var tk := _k(float(parts["tentacle"]["size"]))
		for i in n:
			var ang := (float(i) / n) * TAU
			var chain: Array = []
			var parent: Node3D = body
			var start := Vector3(cos(ang) * head_r * 0.5, -head_r * 0.6, head_z + head_r * 0.2 + sin(ang) * head_r * 0.3)
			for j in 4:
				var seg := Node3D.new()
				seg.position = start if j == 0 else Vector3(0, -r * 0.35 * tk, 0)
				parent.add_child(seg)
				_mesh(seg, _capsule(r * 0.1 * (1.0 - j * 0.18) * tk, r * 0.4 * tk), skin, Vector3(0, -r * 0.18 * tk, 0))
				chain.append(seg)
				parent = seg
			root.tentacles.append(chain)

	# Tendrils: long, thin, dark chains trailing from all around the body.
	if parts.has("tendril"):
		var n := int(parts["tendril"]["count"])
		var tk := _k(float(parts["tendril"]["size"]))
		var tendril_mat := _material(color.darkened(0.6), Color(0.6, 0.2, 0.9), 0.4)
		for i in n:
			var ang := (float(i) / n) * TAU
			var along: float = lerpf(head_z, back_z, float(i % 3) / 2.0)
			var chain: Array = []
			var parent: Node3D = body
			for j in 7:
				var seg := Node3D.new()
				seg.position = Vector3(cos(ang) * r * 0.8, sin(ang) * r * 0.4 - r * 0.3, along) if j == 0 else Vector3(0, -r * 0.42 * tk, 0)
				if j == 0:
					seg.rotation = Vector3(0, 0, ang * 0.3)
				parent.add_child(seg)
				_mesh(seg, _capsule(r * 0.06 * (1.0 - j * 0.11) * tk, r * 0.48 * tk), tendril_mat, Vector3(0, -r * 0.21 * tk, 0))
				chain.append(seg)
				parent = seg
			root.tentacles.append(chain)

	# A void: a hole in the world where the body should be, ringed with light.
	if parts.has("void"):
		var vk := _k(float(parts["void"]["size"]))
		var mid_z: float = (head_z + back_z) * 0.5
		var hole := StandardMaterial3D.new()
		hole.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		hole.albedo_color = Color(0, 0, 0)
		_mesh(body, _sphere(r * 0.7 * vk), hole, Vector3(0, r * 0.2, mid_z))
		var ring := TorusMesh.new()
		ring.inner_radius = r * 0.72 * vk
		ring.outer_radius = r * 0.85 * vk
		_mesh(body, ring, _material(Color(0.4, 0.1, 0.6), Color(0.8, 0.4, 1.0), 2.0), Vector3(0, r * 0.2, mid_z), Vector3.ONE, Vector3(PI / 2, 0, 0))

	# Phase membrane: a translucent shimmer around the whole body.
	if parts.has("phase membrane"):
		var mk := _k(float(parts["phase membrane"]["size"]))
		var shimmer := StandardMaterial3D.new()
		shimmer.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		shimmer.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		shimmer.albedo_color = Color(0.75, 0.5, 1.0, 0.16)
		shimmer.cull_mode = BaseMaterial3D.CULL_DISABLED
		var length: float = absf(head_z - back_z) + head_r * 2.0
		_mesh(body, _sphere(1.0), shimmer, Vector3(0, 0, (head_z + back_z) * 0.5), Vector3(head_r * 1.6 * mk, head_r * 1.5 * mk, length * 0.65 * mk))
	return root


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
