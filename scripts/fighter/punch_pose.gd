extends SkeletonModifier3D
## Procedural punch layer on top of the animation (runs after RockedPose / FistPose; scripts/combat/punch_variants.gd
## owns the variant choice and per-throw random numbers, stored in fighter.atk["var"]).
##
##   wind-up dip  : power punches (variant `dip`) sink at the hips and load the torso before the fist leaves,
##   torso turn   : spine yaw towards the punching side (variant `yaw` x the per-throw `yaw_mul`),
##   aim          : the punching arm is IK-nudged (<= 0.1 m, never along the punch) towards where the foe's head / body
##                  was when the punch was thrown (committed, not tracked: slips still work), so a punch at a tall, short or leaning foe does not always travel the same line,
##   overextension: after a whiff the trunk keeps going - forward lean plus a shoulder turn (`miss_lean`, `miss_yaw`);
##                  a missed wide hook rotates the torso through.
##   coil trim    : a clip whose shoulders turn far away before the punch (the lead body hook) keeps only `coil_keep` of
##                  that turn: measured from the animated pose every frame against the pose at the throw, so it is zero at
##                  the start and at contact and never pops.
## Same bone-restore pattern as RockedPose: skeleton-space delta rotations, bones put back to the animated pose each
## pass, and the modifier does nothing at all while every weight is ~0.

const PoseLimiter := preload("res://scripts/fighter/pose_limiter.gd")

var fighter: Node3D

## Diagnostics for tests / captures.
var w_ext := 0.0
var w_dip := 0.0
var w_miss := 0.0
var yaw_now := 0.0
var w_load := 0.0      ## wind-up in the hips / trunk (first ~0.1 s of a throw): the body loads while the glove is held
var hip_drive := 0.0   ## weight transfer: back to the rear leg while loading, forward through the punch
var coil_fix := 0.0    ## rad the trunk is turned back against the clip's own wind-up (strike `coil_keep` < 1)

const SPINE := [["abdomenLower", 0.30], ["abdomenUpper", 0.30], ["chestLower", 0.22], ["chestUpper", 0.18]]
const AIM_MAX := 0.18            ## m of sideways correction towards the foe's head / body (committed at the throw, not tracked)
const AIM_FACE := 0.04
const AIM_MAX_OLD := 0.045
const AIM_UP_OLD := 0.03
const AIM_MAX_HOOK := 0.14       ## hooks sweep in from the side: a smaller correction keeps the arc
const AIM_UP_HOOK := 0.03
const AIM_UP := 0.20             ## m of vertical correction: the jab clips end at chin / throat height, ~14 cm under the head centre
const LOAD_YAW := 0.085          ## rad (~5 deg) of counter-rotation while loading
const LOAD_BACK := 0.022         ## m the hips shift to the rear leg while loading
const DRIVE_FWD := 0.035         ## m the hips travel through the punch (weight onto the front foot; was 1.2 cm, invisible)
const DRIVE_FWD_UP := 0.012      ## uppercuts drive up through the legs, not forward: the extra travel jammed the glove into the chest at close range
## reach on straights (jab / cross / body jab): the chest leans in over the front foot at full extension, as in the reference. The clip's arm
## is already ~98 % straight at the peak; the extra reach (~8 cm) comes from the trunk. (Swinging the collar forward added < 1 cm on this rig.)
const REACH_LEAN := 0.22         ## rad of forward trunk lean at full extension
const OVER_POWER := 0.16         ## trunk over-rotation past the peak on power shots (share of the yaw)
const OVER_PLAIN := 0.07
const RISE_RATE := 30.0
const FALL_RATE := 10.0          ## trunk unwinds slower than it winds: the retraction is eased out
const NECK_LAG := 12.0

var _built := false
var _bone := {}
var _base_rot := {}
var _written_rot := {}
var _base_pos := {}
var _written_pos := {}
var _last_s: Dictionary = {}
var _last_var: Dictionary = {}
var _last_limb := "lHand"
var _neck_c := 0.0
var _dt := 0.008
var _fwd := Vector3.BACK
var _left := Vector3.RIGHT
var _up := Vector3.UP


func _build(sk: Skeleton3D) -> void:
	_built = true
	for n in ["hip", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "neckLower", "neckUpper", "head",
			"lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lHand", "rHand",
			"lThighBend", "rThighBend", "lShin", "rShin", "lFoot", "rFoot"]:
		_bone[n] = sk.find_bone(n)


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or fighter == null:
		return
	if not _built:
		_build(sk)
	_restore(sk)
	_dt = clampf(dt, 0.001, 0.05)
	_update_weights(dt)
	if w_ext < 0.002 and w_dip < 0.002 and w_miss < 0.002 and w_load < 0.002:
		w_ext = 0.0
		w_dip = 0.0
		w_miss = 0.0
		w_load = 0.0
		hip_drive = 0.0
		_neck_c = 0.0
		yaw_now = 0.0
		return
	_apply(sk)


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


static func _follow(cur: float, target: float, rate: float, dt: float) -> float:
	return lerpf(cur, target, 1.0 - exp(-rate * dt))


func _update_weights(dt: float) -> void:
	var f = fighter
	var ext_t := 0.0
	var dip_t := 0.0
	var miss_t := 0.0
	var load_t := 0.0
	var drive_t := 0.0
	var live: bool = f.state == f.State.ATTACK and not f.atk.is_empty() and not (f.atk["s"] as Dictionary).get("is_leg", false)
	if live:
		var s: Dictionary = f.atk["s"]
		_last_s = s
		_last_var = f.atk["var"]
		_last_limb = f.atk["limb"]
		if not _last_var.has("aim_pt"):
			# the aim is committed at the start of the throw (where the foe's head / body IS now), never tracked live:
			# a slip, duck or step that moves the target away still makes the punch miss
			_last_var["aim_pt"] = _target_point(String(s.get("zone", "head")))
		if not _last_var.has("coil0"):
			_last_var["coil0"] = _shoulder_yaw(get_skeleton())
		var k: float = f.atk["k"]
		var t: float = f.atk["t"]
		var tp: float = float(s["t_peak"]) * k
		var h: float = float(s.get("hang", 0.0)) * k
		var a: float = f.atk["A"]
		var power: bool = float(s.get("dip", 0.0)) > 0.0 or s.get("heavy", false)
		var ov := OVER_POWER if power else OVER_PLAIN
		# wind-up: the body loads over the first ~0.1 s (peak ~0.05 s) while the glove is still held back
		load_t = smoothstep(0.0, 0.04, t) * (1.0 - smoothstep(0.05, 0.11, t)) * (1.0 if power else 0.7)
		if String(s.get("zone", "head")) == "body":
			load_t *= 0.4      # body shots fold forward onto the target: they barely load back
		if t <= tp:
			ext_t = smoothstep(0.0, 1.0, t / maxf(tp, 0.05))
			drive_t = -load_t + ext_t * 0.6
			dip_t = sin(clampf(t / maxf(tp, 0.05), 0.0, 1.0) * PI) * float(s.get("dip", 0.0)) * float(_last_var.get("dip_mul", 1.0))
		elif t <= tp + h:
			ext_t = 1.0 + ov * sin(clampf((t - tp) / maxf(h, 0.04), 0.0, 1.0) * PI * 0.5)    # over-rotates through the hold
			drive_t = 0.6
		else:
			var u := smoothstep(0.0, 1.0, (t - tp - h) / maxf(a - tp - h, 0.05))
			ext_t = (1.0 + ov) * (1.0 - u)
			drive_t = 0.6 * (1.0 - u)
		if f.atk["outcome"] == "missed":
			miss_t = 1.0
	# pose polish: the wind-up dip yields to a duck / deep roll (those already lower the hips) and to an already low
	# stance (PoseLimiter owns the shared hip budget)
	var duck := 0.0
	if f.state == f.State.CROUCH:
		duck = 1.0
	elif f.dm != null and f.dm.pose != null:
		duck = clampf(float(f.dm.pose.hinge) * 1.5, 0.0, 1.0)
	dip_t *= 1.0 - duck
	w_ext = _follow(w_ext, ext_t, RISE_RATE if ext_t > w_ext else FALL_RATE, dt)
	w_load = _follow(w_load, load_t, 40.0, dt)
	if live and (String((f.atk["s"] as Dictionary).get("zone", "head")) == "body" or String((f.atk["s"] as Dictionary).get("dir", "F")) == "U"):
		drive_t = minf(drive_t, 0.0)
	hip_drive = _follow(hip_drive, drive_t, 16.0, dt)
	w_dip = _follow(w_dip, dip_t, 30.0, dt)
	w_miss = _follow(w_miss, miss_t, 12.0 if miss_t > 0.0 else 7.0, dt)


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


func _set_global_basis(sk: Skeleton3D, i: int, b: Basis) -> void:
	var p := sk.get_bone_parent(i)
	var pg := sk.get_bone_global_pose(p).basis.orthonormalized() if p >= 0 else Basis.IDENTITY
	_set_rot(sk, i, (pg.inverse() * b.orthonormalized()).get_rotation_quaternion())


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


## Yaw (rad) of the animated shoulder line in the fighter's frame: atan2(forward, left) of lShoulder - rShoulder.
## A left punch loads by turning it negative, a right punch positive.
func _shoulder_yaw(sk: Skeleton3D) -> float:
	var S := sk.global_transform.basis.inverse()
	var fb := fighter.global_basis
	var sh := _o(sk, "lShldrBend") - _o(sk, "rShldrBend")
	return atan2(sh.dot((S * fb.z).normalized()), sh.dot((S * fb.x).normalized()))


## World position of the foe's hurtbox for `zone` (head / body), or Vector3.INF.
func _target_point(zone: String) -> Vector3:
	var foe = fighter.foe
	if foe == null:
		return Vector3.INF
	for hu in foe.rig.hurtboxes:
		if hu.zone == zone and not hu.is_guard and hu.shape_node != null:
			return hu.shape_node.global_position
	return Vector3.INF


func _apply(sk: Skeleton3D) -> void:
	var S := sk.global_transform.basis.inverse()
	var fb := fighter.global_basis
	_fwd = (S * fb.z).normalized()
	_left = (S * fb.x).normalized()
	_up = (S * Vector3.UP).normalized()
	var s := _last_s
	var pv := _last_var
	var lefty := _last_limb == "lHand"
	var sgn := -1.0 if lefty else 1.0   # +yaw about up turns the left shoulder back: left punches turn negative
	var side_nm := "l" if lefty else "r"
	# -- coil trim (read before this layer moves anything): the share of the clip's wind-up turn beyond `coil_keep`
	coil_fix = 0.0
	var keep := float(s.get("coil_keep", 1.0))
	if keep < 1.0 and pv.has("coil0") and fighter.state == fighter.State.ATTACK and not fighter.atk.is_empty():
		var turn := wrapf(_shoulder_yaw(sk) - float(pv["coil0"]), -PI, PI)
		var tp := float(s["t_peak"]) * float(fighter.atk["k"])
		# a wind-up only: gone by contact (the clip has unwound by then anyway), so the retraction is the clip's own
		coil_fix = maxf(0.0, turn * sgn) * (1.0 - keep) * (1.0 - smoothstep(tp * 0.7, tp, float(fighter.atk["t"])))
	# -- wind-up dip: hips sink and the trunk loads back, feet stay put (two-bone leg IK)
	var hand_pin := Vector3.INF     # the punching glove is held where the clip put it while the body loads
	var off_pin := Vector3.INF      # the other glove stays at the chin through the turn
	var lefty0 := _last_limb == "lHand"
	var hit_n := "lHand" if lefty0 else "rHand"
	var off_n := "rHand" if lefty0 else "lHand"
	if w_load > 0.01:
		hand_pin = _o(sk, hit_n)
	if w_ext > 0.01 or w_load > 0.01:
		off_pin = _o(sk, off_n)
	if w_dip > 0.004 or absf(hip_drive) > 0.02:
		var foot_o := {"l": _o(sk, "lFoot"), "r": _o(sk, "rFoot")}
		var knee_o := {"l": _o(sk, "lShin"), "r": _o(sk, "rShin")}
		var foot_b := {"l": sk.get_bone_global_pose(_bone["lFoot"]).basis, "r": sk.get_bone_global_pose(_bone["rFoot"]).basis}
		var hip_i: int = _bone["hip"]
		# pose polish: never dip below the shared hip floor (clip + earlier layers may already be low)
		var headroom := maxf((sk.global_transform * sk.get_bone_global_pose(hip_i).origin).y - PoseLimiter.HIP_MIN - 0.03, 0.0)
		var dipk := minf(1.0, headroom / maxf(0.075 * w_dip, 0.0001))
		var off := -_up * (0.075 * w_dip * dipk) - _fwd * (0.02 * w_dip * dipk)
		var drive := DRIVE_FWD_UP if String(s.get("dir", "F")) == "U" else DRIVE_FWD
		off += _fwd * (drive * hip_drive if hip_drive > 0.0 else LOAD_BACK * hip_drive)   # weight back to the rear leg, then through
		if not _base_pos.has(hip_i):
			_base_pos[hip_i] = sk.get_bone_pose_position(hip_i)
		sk.set_bone_pose_position(hip_i, sk.get_bone_pose_position(hip_i) + off)
		_written_pos[hip_i] = sk.get_bone_pose_position(hip_i)
		for sd in ["l", "r"]:
			var pole: Vector3 = knee_o[sd]   # exactly the clip's knee: the solve at zero hip offset reproduces the animated leg (no pop when the layer switches on)
			_ik2(sk, "%sThighBend" % sd, "%sShin" % sd, "%sFoot" % sd, foot_o[sd], pole)
			_set_global_basis(sk, _bone["%sFoot" % sd], foot_b[sd])
	# -- trunk: load back (dip), turn into the punch, overextend after a whiff
	var ym := float(pv.get("yaw_mul", 1.0))
	var yaw_deg := float(s.get("yaw", 0.0)) * ym + (ym - 1.0) * 8.0
	var yaw := deg_to_rad(yaw_deg) * w_ext * sgn
	yaw += deg_to_rad(float(s.get("miss_yaw", 0.0)) * ym) * w_miss * sgn
	yaw -= LOAD_YAW * w_load * sgn * (1.0 if float(s.get("dip", 0.0)) > 0.0 else 0.75)
	yaw += coil_fix * sgn   # the load turned the shoulder line by -sgn: turn the trimmed part back (+yaw lowers it)
	var pitch := -0.16 * w_dip + float(s.get("miss_lean", 0.0)) * float(pv.get("lean_mul", 1.0)) * 0.55 * w_miss
	var reach := minf(w_ext, 1.0) if String(s.get("dir", "F")) == "F" and String(s.get("zone", "head")) in ["head", "body"] else 0.0
	pitch += REACH_LEAN * reach
	yaw_now = yaw
	for e in SPINE:
		_rot_axis(sk, e[0], _left, e[1] * pitch)
		_rot_axis(sk, e[0], _up, e[1] * yaw)
	if reach > 0.001:   # the punching arm keeps its line: the lean carries the shoulder (and fist) forward instead of tipping the fist down onto the chest
		_rot_axis(sk, side_nm + "ShldrBend", _left, -REACH_LEAN * reach)
	# the eyes stay on the target while the shoulders turn
	# (a lagging counter-turn: the head rides with the trunk first, then settles on the target)
	_neck_c = _follow(_neck_c, -0.30 * yaw, NECK_LAG, _dt)
	_rot_axis(sk, "neckLower", _up, _neck_c)
	_rot_axis(sk, "neckUpper", _up, _neck_c)
	_rot_axis(sk, "head", _up, _neck_c * 0.85)
	if hand_pin != Vector3.INF:
		var hp := _o(sk, hit_n)
		var fa := "%sForearmBend" % hit_n.substr(0, 1)
		_ik2(sk, "%sShldrBend" % hit_n.substr(0, 1), fa, hit_n, hp.lerp(hand_pin, minf(w_load * 1.6, 1.0)), _o(sk, fa))
	if off_pin != Vector3.INF:
		var op := _o(sk, off_n)
		var fo := "%sForearmBend" % off_n.substr(0, 1)
		_ik2(sk, "%sShldrBend" % off_n.substr(0, 1), fo, off_n, op.lerp(off_pin, 0.75 * minf(maxf(w_ext, w_load), 1.0)), _o(sk, fo))
	# -- aim: nudge the punching hand towards where the foe's head / body really is (not along the punch)
	var zone := String(s.get("zone", "head"))
	if w_ext > 0.01 and (zone == "head" or zone == "body") and not pv.get("literal", false):
		var tp_world: Vector3 = pv.get("aim_pt", Vector3.INF)
		if tp_world != Vector3.INF:
			var tgt_sk := sk.global_transform.affine_inverse() * tp_world
			var hand_n := "%sHand" % side_nm
			var hand := _o(sk, hand_n)
			var delta := tgt_sk - hand
			delta -= _fwd * delta.dot(_fwd)
			var ny: Vector2 = pv.get("aim_noise", Vector2.ZERO)
			delta += _left * ny.x + _up * ny.y
			var hook: bool = String(s["dir"]) in ["L", "R", "O"]
			if zone == "head" and not hook:
				delta -= _up * AIM_FACE          # at the face / jaw, not the crown of the head capsule
			# uppercuts travel up into the target; keep their own rise, only correct sideways
			if String(s["dir"]) == "U":
				delta -= _up * delta.dot(_up)
			# lateral up to AIM_MAX, vertical only AIM_UP (a ducked head must still be missed by a high punch)
			var dv := delta.dot(_up)
			var dl := delta - _up * dv
			var corr: Vector3
			if hook:
				# hooks: the first AIM_MAX_OLD / AIM_UP_OLD of correction are exactly the classic (tuned) ones, a head that is further
				# off (a slip, a duck, a lean) is followed up to AIM_MAX_HOOK / AIM_UP_HOOK more
				var base := (dl.limit_length(AIM_MAX_OLD) + _up * clampf(dv, -AIM_UP_OLD, AIM_UP_OLD)) * minf(w_ext, 1.0) * 0.75
				var extra_l := (dl - dl.limit_length(AIM_MAX_OLD)).limit_length(AIM_MAX_HOOK)
				var extra_v := clampf(dv - clampf(dv, -AIM_UP_OLD, AIM_UP_OLD), -AIM_UP_HOOK, AIM_UP_HOOK)
				corr = base + (extra_l + _up * extra_v) * smoothstep(0.0, 1.0, minf(w_ext, 1.0)) * 0.9
			else:
				corr = (dl.limit_length(AIM_MAX) + _up * clampf(dv, -AIM_UP, AIM_UP)) * smoothstep(0.0, 1.0, minf(w_ext, 1.0)) * 0.92
			if corr.length() > 0.004:
				var shoulder := "%sShldrBend" % side_nm
				var fore := "%sForearmBend" % side_nm
				_ik2(sk, shoulder, fore, hand_n, hand + corr, _o(sk, fore))
