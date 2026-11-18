extends SkeletonModifier3D
## Last modifier on the skeleton. After a ragdoll fall it blends from the captured ragdoll pose (world transforms kept
## by Ragdoll.capture_pose) into whatever the animation + pose layers produce, so the fighter can stand up out of a
## physics fall without a pop. weight 1 = ragdoll pose, 0 = animation. Inactive (and free) at weight 0.

var ragdoll          ## Ragdoll (scripts/fighter/ragdoll.gd)
var weight := 0.0 :
	set(v):
		weight = v
		active = v > 0.001
var duration := 0.4
var _t := 0.0
var _running := false


func _init() -> void:
	active = false


## Start the blend (the saved pose must exist).
func start(secs: float) -> void:
	duration = maxf(secs, 0.05)
	_t = 0.0
	_running = true
	weight = 1.0


func _process_modification_with_delta(delta: float) -> void:
	var sk := get_skeleton()
	if sk == null or ragdoll == null or weight <= 0.001:
		return
	var saved: Dictionary = ragdoll.saved_pose()
	if saved.is_empty():
		weight = 0.0
		return
	if _running:
		_t += delta
		var k := clampf(_t / duration, 0.0, 1.0)
		weight = 1.0 - (k * k * (3.0 - 2.0 * k))   # smoothstep ease
		if k >= 1.0:
			_running = false
			weight = 0.0
			return
	var inv := sk.global_transform.affine_inverse()
	var w := weight
	# bones are ordered parent before child, so one pass keeps parents already blended
	for i in sk.get_bone_count():
		if not saved.has(i):
			continue
		var par := sk.get_bone_parent(i)
		var cap_global: Transform3D = inv * (saved[i] as Transform3D)
		var cap_local := cap_global
		if par >= 0 and saved.has(par):
			cap_local = (inv * (saved[par] as Transform3D)).affine_inverse() * cap_global
		var cur_q := sk.get_bone_pose_rotation(i)
		var cap_q := cap_local.basis.orthonormalized().get_rotation_quaternion()
		sk.set_bone_pose_rotation(i, cur_q.slerp(cap_q, w))
		if par < 0:
			sk.set_bone_pose_position(i, sk.get_bone_pose_position(i).lerp(cap_local.origin, w))
