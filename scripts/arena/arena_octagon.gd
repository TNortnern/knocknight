class_name ArenaOctagon
extends Arena
## Octagon cage using the original game's octagon.glb. The model is scaled so the cage
## apothem is 4.1 m (spec section 7) and lifted so the canvas top is at y = 0.
## Colliders: floor box + 8 wall boxes whose inner faces sit at WALL_LIMIT (3.8 m, the
## fighter root limit: apothem 4.1 minus 0.30 wall clearance).

const APOTHEM := 4.1
const WALL_LIMIT := 3.8
const GLB := "res://assets/arena/octagon.glb"
## Rotate the 8 wall planes if the model's flats are not on the X/Z axes.
@export var wall_yaw_degrees := 0.0

var _model_aabb := AABB()


func _ready() -> void:
	super()
	kind = "octagon"


const CAPSULE_TRIM := 0.24   ## the fighter capsule shrank from 0.36 to 0.12 m radius (fighter.tscn): the colliders move in so the roots stop where they used to


func get_bounds_half() -> float:
	return WALL_LIMIT


func _build_collision() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = WORLD_LAYER
	floor_body.collision_mask = 0
	var fs := CollisionShape3D.new()
	var fb := BoxShape3D.new()
	fb.size = Vector3(APOTHEM * 2.4, 1.0, APOTHEM * 2.4)
	fs.shape = fb
	fs.position = Vector3(0, -0.5, 0)
	floor_body.add_child(fs)
	add_child(floor_body)

	var walls := StaticBody3D.new()
	walls.name = "RingWalls"
	walls.collision_layer = WORLD_LAYER
	walls.collision_mask = 0
	var thick := 0.5
	var height := 3.0
	var side := 2.0 * WALL_LIMIT * tan(PI / 8.0) + 2.0 * thick
	for i in 8:
		var ang := deg_to_rad(wall_yaw_degrees) + i * PI / 4.0
		var n := Vector3(cos(ang), 0, sin(ang))
		var cs := CollisionShape3D.new()
		cs.name = "Wall%d" % i
		var bs := BoxShape3D.new()
		bs.size = Vector3(thick, height, side)
		cs.shape = bs
		cs.position = n * (WALL_LIMIT - CAPSULE_TRIM + thick * 0.5) + Vector3(0, height * 0.5, 0)
		cs.rotation.y = -ang
		walls.add_child(cs)
	add_child(walls)


func _build_venue() -> void:
	kind = "octagon"
	var res := load(GLB) as PackedScene
	if res == null:
		push_error("octagon.glb missing")
		return
	var model := res.instantiate() as Node3D
	model.name = "OctagonModel"
	var floor_mi := _find_mesh(model, "octagon_floor")
	var cage_mi := _find_mesh(model, "octagon_cage")
	var fx := _to_root(floor_mi, model) * floor_mi.get_aabb()
	var cx := _to_root(cage_mi, model) * cage_mi.get_aabb()
	var half := maxf(cx.size.x, cx.size.z) * 0.5
	var s := APOTHEM / half
	var centre := cx.get_center()
	model.scale = Vector3(s, s, s)
	model.position = Vector3(-centre.x * s, -(fx.position.y + fx.size.y) * s, -centre.z * s)
	add_child(model)
	_model_aabb = cx


func _build_crowd() -> void:
	pass  # the glb already carries its own seating


func _find_mesh(root: Node, nm: String) -> MeshInstance3D:
	for c in root.find_children(nm + "*", "MeshInstance3D", true, false):
		return c as MeshInstance3D
	return null


func _to_root(n: Node3D, root: Node3D) -> Transform3D:
	var t := Transform3D()
	var cur: Node3D = n
	while cur != null and cur != root:
		t = cur.transform * t
		cur = cur.get_parent() as Node3D
	return t
