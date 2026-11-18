extends SkeletonModifier3D
## Procedural tiredness on top of the animation (runs after the AnimationTree, FistPose, GuardStyle and RockedPose).
##
##   fatigue  0..1 from Fighter.fatigue (stamina ratio under 42 %):
##     gloves sag (hands drop and the elbows fall), shoulders slump, trunk hunches, head hangs forward
##     breathing: chest / shoulders heave with a rate and depth that grow with the fatigue (about 0.9 -> 1.7 Hz)
##
## Same technique as rocked_pose.gd: skeleton-space delta rotations, bones restored to the animated pose at the start of every
## pass, and the modifier does nothing at all (no cost, no pop) when the fighter is fresh. While a hurt episode (rocked / body)
## or a knockdown drives the body it fades out. During a strike the gloves only droop a little so the punch still lands
## where the animation says.
## Diagnostics: `droop`, `breath` (current weights) for tests / debugging.

var fighter: Node3D

var droop := 0.0       ## 0..1 current glove / posture sag weight
var breath := 0.0      ## 0..1 current breathing depth weight

var _built := false
var _bone := {}
var _base_rot := {}
var _written_rot := {}
var _phase := 0.0
var _fwd := Vector3.BACK
var _left := Vector3.RIGHT
var _up := Vector3.UP

const SPINE := [["abdomenLower", 0.30], ["abdomenUpper", 0.30], ["chestLower", 0.22], ["chestUpper", 0.18]]


func _build(sk: Skeleton3D) -> void:
	_built = true
	for n in ["abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "neckLower", "neckUpper", "head",
			"lCollar", "rCollar", "lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lHand", "rHand"]:
		_bone[n] = sk.find_bone(n)
	_phase = float(get_instance_id() % 628) * 0.01


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or fighter == null or not is_instance_valid(fighter):
		return
	if not _built:
		_build(sk)
	_restore(sk)
	var lvl: float = fighter.fatigue
	var sname: String = fighter.state_name
	var down := sname in ["fall", "count", "getup", "down", "win"]
	var hurt_on: bool = fighter.hurt.active()
	var droop_t := smoothstep(0.10, 0.60, lvl)
	if down or hurt_on:
		droop_t = 0.0
	elif sname == "attack":
		droop_t *= 0.3
	droop_t *= fighter.defence_damp   # leaning / ducking: no extra hunch / neck drop on top of the defence pose
	var breath_t := smoothstep(0.03, 0.5, lvl) if not down else 0.0
	droop = lerpf(droop, droop_t, 1.0 - exp(-5.0 * dt))
	breath = lerpf(breath, breath_t, 1.0 - exp(-3.0 * dt))
	if droop < 0.002 and breath < 0.002:
		droop = 0.0
		breath = 0.0
		return
	_phase += dt * TAU * (0.9 + 0.8 * lvl)
	_apply(sk)


func _restore(sk: Skeleton3D) -> void:
	for i in _written_rot:
		if sk.get_bone_pose_rotation(i).is_equal_approx(_written_rot[i]):
			sk.set_bone_pose_rotation(i, _base_rot[i])
	_base_rot.clear()
	_written_rot.clear()


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
	_set_rot(sk, i, pg.inverse() * q * pg * sk.get_bone_pose_rotation(i))


func _rot_axis(sk: Skeleton3D, name: String, axis: Vector3, angle: float) -> void:
	if absf(angle) < 1e-5:
		return
	_rot_sk(sk, _bone[name], Quaternion(axis.normalized(), angle))


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


func _apply(sk: Skeleton3D) -> void:
	var S := sk.global_transform.basis.inverse()
	var fb: Basis = fighter.global_basis
	_fwd = (S * fb.z).normalized()
	_left = (S * fb.x).normalized()
	_up = (S * Vector3.UP).normalized()
	var lvl: float = fighter.fatigue
	var b := sin(_phase)
	# a breath is a quick lift and a slow release: skew the sine so the inhale is faster
	var heave := (b + 0.35 * sin(2.0 * _phase + 0.6)) * breath
	# -- trunk: hunch forward with the fatigue, chest heaves with each breath (left axis, + = forward fold)
	var hunch := 0.06 * droop
	var chest := -0.075 * heave * (0.6 + 0.8 * lvl)
	for e in SPINE:
		var nm: String = e[0]
		var share: float = e[1]
		_rot_axis(sk, nm, _left, share * hunch + (share * 1.8 * chest if nm.begins_with("chest") else 0.0))
	_rot_axis(sk, "neckLower", _left, 0.04 * droop + 0.25 * chest)
	_rot_axis(sk, "head", _left, 0.06 * droop - 0.15 * chest)
	# -- shoulders: slump when tired, lift with every breath
	var sag := 0.06 * droop
	var lift := 0.05 * heave
	_rot_axis(sk, "lCollar", _fwd, -sag + lift)
	_rot_axis(sk, "rCollar", _fwd, sag - lift)
	# -- gloves sag: the hands fall towards the belt and the elbows hang
	if droop > 0.01:
		var hipc := _o(sk, "abdomenLower")
		for s in ["l", "r"]:
			var sgn := 1.0 if s == "l" else -1.0
			var hand_n := "%sHand" % s
			var src := _o(sk, hand_n)
			var shoulder := _o(sk, "%sShldrBend" % s)
			var elbow := _o(sk, "%sForearmBend" % s)
			# belt-height target a little in front of the body; glove height drops by up to ~0.30 m
			var low := hipc + _up * (0.13 + 0.05 * (1.0 if s == "l" else 0.0)) + _fwd * (0.20 + 0.06 * (1.0 if s == "l" else 0.0)) + _left * sgn * 0.17
			var tgt := src.lerp(low, 0.75 * droop)
			tgt += _up * (0.012 * sin(_phase * 0.5 + sgn) * droop)   # gloves wobble a little
			var pole := elbow.lerp(shoulder - _up * 0.26 + _left * sgn * 0.12, clampf(droop * 1.1, 0.0, 1.0))
			_ik2(sk, "%sShldrBend" % s, "%sForearmBend" % s, hand_n, tgt, pole)
