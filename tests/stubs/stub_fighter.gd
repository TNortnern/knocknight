extends CharacterBody3D
## Stand-in fighter for presentation work. Same public surface the real fighter exposes
## (health/stamina/guard, display_name, stats_changed) plus a capsule mesh.

signal stats_changed

var health_max := 100.0
var stamina_max := 100.0
var guard_max := 100.0
var health := 100.0
var stamina := 100.0
var guard := 100.0
var display_name := "Fighter"
var tint := Color.RED


func setup(p_name: String, p_tint: Color) -> void:
	display_name = p_name
	tint = p_tint


func _ready() -> void:
	collision_layer = 2
	collision_mask = 1
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.3
	shape.height = 1.8
	col.shape = shape
	col.position.y = 0.9
	add_child(col)
	var mi := MeshInstance3D.new()
	var mesh := CapsuleMesh.new()
	mesh.radius = 0.3
	mesh.height = 1.8
	mi.mesh = mesh
	mi.position.y = 0.9
	var mat := StandardMaterial3D.new()
	mat.albedo_color = tint
	mat.roughness = 0.6
	mi.material_override = mat
	add_child(mi)
	var nose := MeshInstance3D.new()
	var nm := BoxMesh.new()
	nm.size = Vector3(0.12, 0.12, 0.3)
	nose.mesh = nm
	nose.position = Vector3(0, 1.5, 0.3)
	nose.material_override = mat
	add_child(nose)


func set_stat(stat: String, value: float) -> void:
	set(stat, value)
	stats_changed.emit()
