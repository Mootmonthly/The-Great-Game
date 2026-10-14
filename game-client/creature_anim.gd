extends Node3D
## Procedural animation for a built creature: walking legs, flapping wings,
## waving tentacles and tail, snapping jaw, a gentle bob.

var body: Node3D
var legs: Array = []
var wings: Array = []
var wing_sides: Array = []
var tentacles: Array = []
var jaw: Node3D
var tail: Node3D
var blob := false
## Animation speed multiplier; 0 freezes the pose.
var pace := 1.0
var t := 0.0


func _process(delta: float) -> void:
	t += delta * pace
	for i in legs.size():
		var phase := 0.0 if (i / 2 + i % 2) % 2 == 0 else PI
		legs[i].rotation.x = sin(t * 6.0 + phase) * 0.45
	for i in wings.size():
		wings[i].rotation.z = wing_sides[i] * (sin(t * 7.0) * 0.5 + 0.55)
	for chain in tentacles:
		for j in chain.size():
			chain[j].rotation.x = sin(t * 3.0 + j * 0.9) * 0.35
			chain[j].rotation.z = cos(t * 2.3 + j * 0.7) * 0.2
	if jaw:
		jaw.rotation.x = maxf(0.0, sin(t * 2.0)) * 0.25
	if tail:
		tail.rotation.y = sin(t * 4.0) * 0.4
	if body:
		body.position.y += sin(t * 6.0) * 0.0006
		if blob:
			var s := 1.0 + sin(t * 3.0) * 0.06
			body.scale = Vector3(s, 2.0 - s, s)
