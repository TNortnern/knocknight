extends SkeletonModifier3D
## Shared helpers for the small additive pose layers (hit_flinch.gd, alive_pose.gd): skeleton-space delta rotations about
## fighter-frame axes (x = fighter's left, y = up, z = towards the foe), restore-to-animated-pose bookkeeping, two-bone IK,
## and "pinning" of the committed striking limb so an additive layer never moves a punch / kick that is already flying.

var fighter: Node3D

var _built := false
var _bone := {}
var _base_rot := {}
var _written_rot := {}
var _base_pos := {}
var _written_pos := {}
var _fwd := Vector3.BACK
var _left := Vector3.RIGHT
var _up := Vector3.UP

const BONES := ["hip", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "neckLower", "neckUpper", "head",
		"lCollar", "rCollar", "lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lHand", "rHand",
		"lThighBend", "rThighBend", "lShin", "rShin", "lFoot", "rFoot"]
## [bone, share] chains; the shares of each chain sum to 1
const SPINE := [["abdomenLower", 0.15], ["abdomenUpper", 0.20], ["chestLower", 0.30], ["chestUpper", 0.35]]
const NECK := [["neckLower", 0.30], ["neckUpper", 0.30], ["head", 0.40]]


func _ready_bones(sk: Skeleton3D) -> void:
	if _built:
		return
	_built = true
	for n in BONES:
		_bone[n] = sk.find_bone(n)


func _fighter_ok() -> bool:
	return fighter != null and is_instance_valid(fighter)


## True while the fighter is on its feet (the layers write nothing during falls / count / get-up / victory).
func _standing() -> bool:
	var f = fighter
	return not (f.state in [f.State.FALL, f.State.COUNT, f.State.GETUP, f.State.DOWN, f.State.WIN])


func _restore(sk: Skeleton3D) -> void:
	for i in _written_rot:
		if sk.get_bone_pose_rotation(i).is_equal_approx(_written_rot[i]):
			sk.set_bone_pose_rotation(i, _base_rot[i])
	for i in _written_pos:
		if sk.get_bone_pose_position(i).is_equal_approx(_written_pos[i]):
			sk.set_bone_pose_position(i, _base_pos[i])
	_base_rot.clear()
	_written_rot.clear()
	_base_pos.clear()
	_written_pos.clear()


func _frame(sk: Skeleton3D) -> void:
	var S := sk.global_transform.basis.orthonormalized().inverse()
	var fb: Basis = fighter.global_basis
	_fwd = (S * fb.z).normalized()
	_left = (S * fb.x).normalized()
	_up = (S * Vector3.UP).normalized()


func _o(sk: Skeleton3D, name: String) -> Vector3:
	return sk.get_bone_global_pose(_bone[name]).origin


func _set_rot(sk: Skeleton3D, i: int, q: Quaternion) -> void:
	if not _base_rot.has(i):
		_base_rot[i] = sk.get_bone_pose_rotation(i)
	sk.set_bone_pose_rotation(i, q)
	_written_rot[i] = sk.get_bone_pose_rotation(i)


func _rot_sk(sk: Skeleton3D, i: int, q: Quaternion) -> void:
	var p := sk.get_bone_parent(i)
	var pg := sk.get_bone_global_pose(p).basis.orthonormalized().get_rotation_quaternion() if p >= 0 else Quaternion.IDENTITY
	_set_rot(sk, i, (pg.inverse() * q * pg * sk.get_bone_pose_rotation(i)).normalized())


func _rot_axis(sk: Skeleton3D, name: String, axis: Vector3, angle: float) -> void:
	if absf(angle) < 1e-6 or _bone.get(name, -1) < 0:
		return
	_rot_sk(sk, _bone[name], Quaternion(axis.normalized(), angle))


## Rotates a chain with the angle split by the shares; pitch about the left axis (+ = fold forward), yaw about up (+ = turn
## to the fighter's left), roll about the forward axis (+ = top towards the fighter's right).
func _rot_chain(sk: Skeleton3D, chain: Array, pitch: float, yaw: float, roll: float) -> void:
	for e in chain:
		var sh: float = e[1]
		_rot_axis(sk, e[0], _left, pitch * sh)
		_rot_axis(sk, e[0], _up, yaw * sh)
		_rot_axis(sk, e[0], _fwd, roll * sh)


func _aim(sk: Skeleton3D, i: int, from: Vector3, to: Vector3) -> void:
	if from.length() < 1e-5 or to.length() < 1e-5:
		return
	_rot_sk(sk, i, Quaternion(from.normalized(), to.normalized()))


## Two-bone IK: put the `end` bone at `target`, bending the `mid` joint towards `pole_pt`.
func _ik2(sk: Skeleton3D, root: String, mid: String, end: String, target: Vector3, pole_pt: Vector3) -> void:
	var a := _o(sk, root)
	var b := _o(sk, mid)
	var c := _o(sk, end)
	var l1 := a.distance_to(b)
	var l2 := b.distance_to(c)
	var tv := target - a
	if tv.length() < 1e-4 or l1 < 1e-4 or l2 < 1e-4:
		return
	var d := clampf(tv.length(), absf(l1 - l2) + 0.004, l1 + l2 - 0.004)
	var dir := tv.normalized()
	var pv := pole_pt - a
	pv -= dir * pv.dot(dir)
	if pv.length() < 1e-4:
		pv = (b - a) - dir * (b - a).dot(dir)
	if pv.length() < 1e-5:
		return
	pv = pv.normalized()
	var ca := clampf((l1 * l1 + d * d - l2 * l2) / (2.0 * l1 * d), -1.0, 1.0)
	var sa := sqrt(1.0 - ca * ca)
	var nb := a + dir * (ca * l1) + pv * (sa * l1)
	_aim(sk, _bone[root], b - a, nb - a)
	var b2 := _o(sk, mid)
	var c2 := _o(sk, end)
	_aim(sk, _bone[mid], c2 - b2, (a + dir * d) - b2)


## Pins: remember where the striking hand / foot is (skeleton space) before the layer moves the body.
func _pin_begin(sk: Skeleton3D) -> Dictionary:
	var f = fighter
	var pin := {}
	if f.state == f.State.ATTACK and f.atk.has("limb"):
		var limb: String = f.atk["limb"]
		if _bone.get(limb, -1) >= 0:
			pin["limb"] = limb
			pin["pos"] = _o(sk, limb)
			pin["elbow_or_knee"] = _o(sk, _mid_of(limb))
	return pin


func _mid_of(limb: String) -> String:
	return limb.substr(0, 1) + ("ForearmBend" if limb.ends_with("Hand") else "Shin")


func _root_of(limb: String) -> String:
	return limb.substr(0, 1) + ("ShldrBend" if limb.ends_with("Hand") else "ThighBend")


## Puts the pinned limb end back where it was (two-bone IK from the moved shoulder / hip).
func _pin_end(sk: Skeleton3D, pin: Dictionary) -> void:
	if pin.is_empty():
		return
	var limb: String = pin["limb"]
	var cur_mid := _o(sk, _mid_of(limb))
	_ik2(sk, _root_of(limb), _mid_of(limb), limb, pin["pos"], cur_mid)


## Plants the feet: legs re-solved so both feet stay at their animated positions after the hips moved.
func _plant_feet(sk: Skeleton3D, feet: Dictionary) -> void:
	for s in ["l", "r"]:
		if not feet.has(s):
			continue
		var mid := _o(sk, s + "Shin")
		if feet.has("t" + s):
			# knee pole: the knee bends towards where the toes point (over the toes, no knock-knee / bowing when the hips shift or roll)
			var hip_p := _o(sk, s + "ThighBend")
			var line_mid := (hip_p + (feet[s] as Vector3)) * 0.5
			mid = mid.lerp(line_mid + (feet["t" + s] as Vector3) * 0.5, float(feet.get("pw", 1.0)))
		_ik2(sk, s + "ThighBend", s + "Shin", s + "Foot", feet[s], mid)


func _feet_begin(sk: Skeleton3D) -> Dictionary:
	return {"l": _o(sk, "lFoot"), "r": _o(sk, "rFoot")}


## Like _feet_begin, plus the toe direction of each foot so _plant_feet bends the knee towards the toes (weight `pole_w`, 0 = the animated knee).
func _feet_begin_poled(sk: Skeleton3D, pole_w: float) -> Dictionary:
	var out := _feet_begin(sk)
	out["pw"] = pole_w
	for s in ["l", "r"]:
		var mt := sk.find_bone(s + "Metatarsals")
		if mt >= 0:
			var toe := sk.get_bone_global_pose(mt).origin - (out[s] as Vector3)
			toe -= _up * toe.dot(_up)
			if toe.length() > 1e-4:
				out["t" + s] = toe.normalized()
	return out


func _move_hip(sk: Skeleton3D, delta_sk: Vector3) -> void:
	var hip: int = _bone["hip"]
	if not _base_pos.has(hip):
		_base_pos[hip] = sk.get_bone_pose_position(hip)
	var parent := sk.get_bone_parent(hip)
	var pb := Basis.IDENTITY if parent < 0 else sk.get_bone_global_pose(parent).basis.orthonormalized()
	sk.set_bone_pose_position(hip, _base_pos[hip] + pb.inverse() * delta_sk)
	_written_pos[hip] = sk.get_bone_pose_position(hip)
