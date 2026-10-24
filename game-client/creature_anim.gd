extends Node3D
## Procedural animation for a built creature: walking legs, flapping wings,
## waving tentacles and tail, snapping jaw, a gentle bob, bobbing spell foci.

var body: Node3D
var legs: Array = []
## Per-leg resting rotation.x and swing multiplier (arms holding gear rest
## forward and swing less). Missing entries mean 0 and 1.
var rest_x: Array = []
var swing: Array = []
var wings: Array = []
var wing_sides: Array = []
var tentacles: Array = []
var jaw: Node3D
var tail: Node3D
var blob := false
## Floating gear (spell foci): bobbed and spun.
var floaters: Array = []
var floater_y: Array = []
## Scales the tentacle/stem sway (plants use a small value).
var sway := 1.0
## Animation speed multiplier; 0 freezes the pose.
var pace := 1.0
var t := 0.0


func _process(delta: float) -> void:
	t += delta * pace
	for i in legs.size():
		var phase := 0.0 if (i / 2 + i % 2) % 2 == 0 else PI
		var rest: float = rest_x[i] if i < rest_x.size() else 0.0
		var mul: float = swing[i] if i < swing.size() else 1.0
		legs[i].rotation.x = rest + sin(t * 6.0 + phase) * 0.45 * mul
	for i in wings.size():
		wings[i].rotation.z = wing_sides[i] * (sin(t * 7.0) * 0.5 + 0.55)
	for chain in tentacles:
		for j in chain.size():
			chain[j].rotation.x = sin(t * 3.0 + j * 0.9) * 0.35 * sway
			chain[j].rotation.z = cos(t * 2.3 + j * 0.7) * 0.2 * sway
	if jaw:
		jaw.rotation.x = maxf(0.0, sin(t * 2.0)) * 0.25
	if tail:
		tail.rotation.y = sin(t * 4.0) * 0.4
	for i in floaters.size():
		var f: Node3D = floaters[i]
		f.position.y = float(floater_y[i]) + sin(t * 2.0 + i) * 0.02
		f.rotation.y = t * 1.5
	if body:
		body.position.y += sin(t * 6.0) * 0.0006
		if blob:
			var s := 1.0 + sin(t * 3.0) * 0.06
			body.scale = Vector3(s, 2.0 - s, s)
