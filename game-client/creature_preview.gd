extends SubViewportContainer
## A small turntable that shows a species' procedurally built 3D model.

const CreatureBuilder := preload("res://creature_builder.gd")

var viewport: SubViewport
var stage: Node3D
var camera: Camera3D
var creature: Node3D
var angle := 0.0
var shown_id := -1


func _ready() -> void:
	stretch = true
	viewport = SubViewport.new()
	viewport.own_world_3d = true
	viewport.msaa_3d = Viewport.MSAA_4X
	add_child(viewport)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.11, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.35, 0.42)
	var we := WorldEnvironment.new()
	we.environment = env
	viewport.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 35, 0)
	viewport.add_child(sun)
	stage = Node3D.new()
	viewport.add_child(stage)
	var ground := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.6
	disc.bottom_radius = 1.6
	disc.height = 0.04
	ground.mesh = disc
	var gm := ShaderMaterial.new()
	gm.shader = preload("res://shaders/creature.gdshader")
	gm.set_shader_parameter("base_color", Color(0.25, 0.27, 0.3))
	ground.material_override = gm
	ground.position.y = -0.02
	viewport.add_child(ground)
	camera = Camera3D.new()
	camera.fov = 35.0
	viewport.add_child(camera)


func show_species(detail: Dictionary, sheet: Dictionary = {}) -> void:
	var key := hash([int(detail["id"]), sheet.get("gear", [])])
	if key == shown_id:
		return
	shown_id = key
	if creature:
		creature.queue_free()
	creature = CreatureBuilder.build(detail, sheet)
	stage.add_child(creature)
	# Fit the model to the turntable.
	var box := CreatureBuilder.bounds(creature)
	var extent: float = max(box.size.x, max(box.size.y, box.size.z))
	var s: float = 1.8 / max(extent, 0.01)
	creature.scale = Vector3.ONE * s
	creature.position = Vector3(-box.get_center().x * s, -box.position.y * s, -box.get_center().z * s)


func _process(delta: float) -> void:
	if camera == null:
		return
	angle += delta * 0.4
	camera.position = Vector3(sin(angle) * 3.6, 1.6, cos(angle) * 3.6)
	camera.look_at(Vector3(0, 0.6, 0), Vector3.UP)
