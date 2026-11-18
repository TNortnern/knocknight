extends SkeletonModifier3D
## Final pose arbitration: the LAST pose layer before the ragdoll blend (child order on the Skeleton3D).
##
## Several layers each lower the hips / bend the trunk on top of clips that already crouch (punch wind-up dip, defence
## hinge, guard dip, fatigue sag, rocked fold, lunging body-shot clips). This modifier measures the pose they produced
## and pulls it back to a shared budget, so the sum can never exceed it:
##   * hip height   >= HIP_MIN (0.66 m standing); the deliberate deep moves (roll / duck, body-hurt fold) get their own,
##                     lower floor HIP_MIN_DEEP (0.50 m),
##   * knee height  >= KNEE_MIN: a knee never reaches the floor in a standing state (the knee is swung up along its
##                     circle with the hip and foot unchanged),
##   * trunk flexion <= TRUNK_MAX_DEG forward (the spine is un-hinged by the excess; deep moves get TRUNK_MAX_DEEP_DEG).
## Raising the hip keeps both feet planted (two-bone leg IK; if the leg cannot reach the planted foot any more, the foot
## slides horizontally towards the hip instead of lifting off the floor).
## The modifier is a no-op (writes nothing) while the pose is inside the budget, so it costs nothing in the normal guard.
## It only acts while the fighter is on its feet (IDLE / ATTACK / HIT / SLIP / CROUCH / TAUNT); falls, get-ups, victory
## and loss poses are authored clips and are left alone.

const HIP_MIN := 0.66
const HIP_MIN_DEEP := 0.50
const KNEE_MIN := 0.27
const KNEE_MIN_DEEP := 0.20
const TRUNK_MAX_DEG := 56.0
const TRUNK_MAX_DEEP_DEG := 82.0

var fighter: Node3D

## Diagnostics (tests / probes): what the last pass changed.
var hip_raised := 0.0       ## m the hips were lifted
var knee_lifted := false
var trunk_cut := 0.0        ## rad of forward flexion removed
var deep := 0.0             ## 0..1 allowance for deliberate deep poses

var _sk: Skeleton3D
var _idx := {}
var _dt := 0.008
var _pp := {"l": Vector3.ZERO, "r": Vector3.ZERO}   ## applied bend direction of each knee while it is being corrected (zero = the clip's own)
const SWING_RATE := 40.0
const KNEE_SLACK := 0.02
const KNEE_LEAD := 0.06
var _swing := {"l": 0.0, "r": 0.0}   ## held swing direction of each knee while the budget is correcting it


func _build() -> void:
	for n in ["hip", "abdomenLower", "chestUpper", "lThighBend", "rThighBend", "lShin", "rShin", "lFoot", "rFoot"]:
		_idx[n] = _sk.find_bone(n)


func _process_modification_with_delta(_delta: float) -> void:
	_dt = clampf(_delta, 0.001, 0.05)
	_sk = get_skeleton()
	hip_raised = 0.0
	knee_lifted = false
	trunk_cut = 0.0
	if _sk == null or fighter == null or not is_instance_valid(fighter):
		return
	if _idx.is_empty():
		_build()
	var f = fighter
	if not (f.state in [f.State.IDLE, f.State.ATTACK, f.State.HIT, f.State.SLIP, f.State.CROUCH, f.State.TAUNT]):
		return
	deep = _deep_allowance()
	if OS.get_environment("KN_DBGLIM") != "" and fighter.player_index == 0 and Engine.get_physics_frames() > 165 and Engine.get_physics_frames() < 600:
		print("PRE f", Engine.get_physics_frames(), " rkneeY ", snappedf(_world_y(_idx["rShin"]), 0.001), " hipY ", snappedf(_world_y(_idx["hip"]), 0.001), " st ", f.state_name)
	_limit_trunk()
	_limit_legs()


## 0..1: how much of the lower floor the current move is entitled to (deliberate duck / deep roll / body-hurt fold).
func _deep_allowance() -> float:
	var f = fighter
	var d := 0.0
	if f.state == f.State.CROUCH:
		d = 1.0
	if f.dm != null and f.dm.pose != null:
		d = maxf(d, clampf(float(f.dm.pose.hinge) * 1.5, 0.0, 1.0))
	if f.lean_pose != null:
		d = maxf(d, clampf(float(f.lean_pose.deep_w) * 0.7, 0.0, 1.0))   # a full slip / lean shares the deep budget (hip floor 0.55, trunk 76 deg)
	if f._rocked_pose != null:
		d = maxf(d, clampf(float(f._rocked_pose.w_body) * 1.5, 0.0, 1.0))
	return d


func _gpos(i: int) -> Vector3:
	return _sk.get_bone_global_pose(i).origin


func _world_y(i: int) -> float:
	return (_sk.global_transform * _gpos(i)).y


## fighter-frame direction -> skeleton space
func _to_sk(v: Vector3) -> Vector3:
	return (_sk.global_basis.inverse() * (fighter.global_basis * v)).normalized()


func _parent_q(i: int) -> Quaternion:
	var p := _sk.get_bone_parent(i)
	return Quaternion.IDENTITY if p < 0 else _sk.get_bone_global_pose(p).basis.orthonormalized().get_rotation_quaternion()


func _rot_global(i: int, dq: Quaternion) -> void:
	var pq := _parent_q(i)
	_sk.set_bone_pose_rotation(i, (pq.inverse() * dq * pq * _sk.get_bone_pose_rotation(i)).normalized())


func _arc(a: Vector3, b: Vector3) -> Quaternion:
	var an := a.normalized()
	var bn := b.normalized()
	var d := an.dot(bn)
	if d > 0.99999:
		return Quaternion.IDENTITY
	if d < -0.99999:
		var ax := an.cross(Vector3.UP)
		if ax.length() < 0.01:
			ax = an.cross(Vector3.RIGHT)
		return Quaternion(ax.normalized(), PI)
	return Quaternion(an.cross(bn).normalized(), acos(clampf(d, -1.0, 1.0)))


# ------------------------------------------------------------------ trunk
func _limit_trunk() -> void:
	var up := _to_sk(Vector3.UP)
	var fwd := _to_sk(Vector3.BACK)     # +z of the fighter = towards the foe
	var left := _to_sk(Vector3.RIGHT)   # +x of the fighter = its left
	var v := _gpos(_idx["chestUpper"]) - _gpos(_idx["hip"])
	var pitch := atan2(v.dot(fwd), v.dot(up))
	var cap := deg_to_rad(lerpf(TRUNK_MAX_DEG, TRUNK_MAX_DEEP_DEG, deep))
	if pitch <= cap:
		return
	trunk_cut = pitch - cap
	# rotate the whole spine about the lowest spine bone's origin, back about the fighter's left axis
	_rot_global(_idx["abdomenLower"], Quaternion(left, -trunk_cut))


# ------------------------------------------------------------------ hips / knees
func _limit_legs() -> void:
	var hip: int = _idx["hip"]
	var hip_min := lerpf(HIP_MIN, HIP_MIN_DEEP, deep)
	var knee_min := lerpf(KNEE_MIN, KNEE_MIN_DEEP, deep)
	var delta := hip_min - _world_y(hip)
	var need_knee := false
	var snap := {}
	for side in ["l", "r"]:
		var t: int = _idx[side + "ThighBend"]
		var s: int = _idx[side + "Shin"]
		var fo: int = _idx[side + "Foot"]
		var a := _gpos(t)
		var b := _gpos(s)
		var c := _gpos(fo)
		snap[side] = {"goal": c, "foot_q": _sk.get_bone_global_pose(fo).basis.orthonormalized().get_rotation_quaternion(), "knee": b, "root": a}
		if _world_y(s) < knee_min + KNEE_LEAD:
			need_knee = true
	if delta <= 0.0005 and not need_knee and _pp["l"] == Vector3.ZERO and _pp["r"] == Vector3.ZERO:
		_swing["l"] = 0.0
		_swing["r"] = 0.0
		return
	if delta > 0.0005:
		hip_raised = delta
		var pq := _parent_q(hip)
		_sk.set_bone_pose_position(hip, _sk.get_bone_pose_position(hip) + pq.inverse() * (_to_world_up_sk() * delta))
	for side in ["l", "r"]:
		var e: Dictionary = snap[side]
		var s: int = _idx[side + "Shin"]
		var knee_low := (_sk.global_transform * (e["knee"] as Vector3)).y < knee_min + KNEE_LEAD
		if delta <= 0.0005 and not knee_low and _pp[side] == Vector3.ZERO:
			continue
		_solve_leg(side, e["goal"], (e["knee"] as Vector3) - (e["root"] as Vector3), knee_min)
		var fo: int = _idx[side + "Foot"]
		var cur := _sk.get_bone_global_pose(fo).basis.orthonormalized().get_rotation_quaternion()
		_rot_global(fo, (e["foot_q"] as Quaternion) * cur.inverse())


## world up as a skeleton-space direction
func _to_world_up_sk() -> Vector3:
	return (_sk.global_basis.inverse() * Vector3.UP).normalized()


## Swing angle (rad, signed) of the knee about the hip-foot axis, from the clip's bend `pp0` towards "up" (`pup`, `phi` away), the least
## that lifts it to `ymin` (world); 0 when it is already clear.
func _swing_for(a: Vector3, dir: Vector3, along: float, h: float, pp0: Vector3, pup: Vector3, phi: float, ymin: float) -> float:
	if (_sk.global_transform * (a + dir * along + pp0 * h)).y >= ymin:
		return 0.0
	if (_sk.global_transform * (a + dir * along + pup * h)).y < ymin:
		return phi
	var lo := 0.0
	var hi := 1.0
	for it in 14:
		var mid := 0.5 * (lo + hi)
		if (_sk.global_transform * (a + dir * along + pp0.rotated(dir, phi * mid) * h)).y >= ymin:
			hi = mid
		else:
			lo = mid
	return phi * hi


## Two-bone leg solve: foot to `goal` (pulled in horizontally when out of reach), knee swung along its circle towards
## `pole0` first, then upwards until the knee clears `knee_min` (world height).
func _solve_leg(side: String, goal: Vector3, pole0: Vector3, knee_min: float) -> void:
	var ti: int = _idx[side + "ThighBend"]
	var si: int = _idx[side + "Shin"]
	var fi: int = _idx[side + "Foot"]
	var a := _gpos(ti)
	var b := _gpos(si)
	var c := _gpos(fi)
	var l1 := a.distance_to(b)
	var l2 := b.distance_to(c)
	var up := _to_world_up_sk()
	var v := goal - a
	var reach := (l1 + l2) * 0.992
	if v.length() > reach:
		var vy := v.dot(up)
		var hv := v - up * vy
		vy = clampf(vy, -reach * 0.98, reach * 0.98)
		var hl := sqrt(maxf(reach * reach - vy * vy, 0.0))
		v = (hv.normalized() * hl if hv.length() > 0.0001 else Vector3.ZERO) + up * vy
	var d := clampf(v.length(), absf(l1 - l2) + 0.01, reach)
	var dir := v.normalized()
	var along := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(l1 * l1 - along * along, 0.0))
	var goal2 := a + dir * d
	# The knee sits on a circle around the hip-foot axis. Start from the clip's own knee (pole0 = its bend direction) and
	# rotate it round that axis the short way towards "up" only as far as the floor budget needs (bisected): the correction
	# is continuous in the clip pose, so a knee that starts a hair below the floor moves a hair, never across the circle.
	var pp0 := pole0 - dir * pole0.dot(dir)
	if pp0.length() < 0.001:
		pp0 = (up - dir * up.dot(dir))
	pp0 = pp0.normalized()
	var pup := up - dir * up.dot(dir)
	pup = pup.normalized() if pup.length() > 0.001 else pp0
	var phi := atan2(pp0.cross(pup).dot(dir), pp0.dot(pup))   # signed angle about dir, |phi| <= PI
	# a knee at the bottom of its circle (phi ~ +-PI: the clip's trailing knee near the floor) can go either way round: pick the
	# side that swings it forward (knees bend forward) and hold it, so the choice never flips between frames
	var sgn: float = 0.0
	var held: Vector3 = _pp[side]
	if held != Vector3.ZERO and held.cross(pp0).length() > 0.02:
		# a correction is already running: keep the side the knee is actually on (the bend direction itself is continuous)
		var hp := held - dir * held.dot(dir)
		sgn = signf(pp0.cross(hp).dot(dir))
	if sgn == 0.0:
		if absf(phi) < 2.9:
			sgn = signf(phi)
		else:
			var fwd_sk := _to_sk(Vector3.BACK)
			var test_a := pp0.rotated(dir, 0.5)
			var test_b := pp0.rotated(dir, -0.5)
			sgn = 1.0 if test_a.dot(fwd_sk) >= test_b.dot(fwd_sk) else -1.0
	if sgn != 0.0 and signf(phi) != sgn:
		phi = phi - TAU * signf(phi)
	var need := _swing_for(a, dir, along, h, pp0, pup, phi, knee_min + KNEE_LEAD)   # starts early: the swing ramps in before the budget is hit
	var need_floor := _swing_for(a, dir, along, h, pp0, pup, phi, knee_min - KNEE_SLACK)   # what must happen at once
	# the knee near the bottom of its circle needs a big swing for a few mm of clearance: the applied swing follows the need
	# at a bounded angular rate, both ways, but never lets the knee sink more than KNEE_SLACK below the budget
	# The applied bend direction follows the target direction at a bounded angular rate (in the plane round the hip-foot
	# axis, from where it was LAST frame, not from the clip), both ways, so the knee never jumps however the clip moves;
	# it is forced to the budget direction only if it would sink more than KNEE_SLACK below the floor.
	var target := pp0.rotated(dir, need) if need != 0.0 else pp0
	var prev: Vector3 = _pp[side]
	var pp := target
	if prev != Vector3.ZERO:
		prev = prev - dir * prev.dot(dir)
		if prev.length() > 0.01:
			prev = prev.normalized()
			var da := atan2(prev.cross(target).dot(dir), prev.dot(target))
			if absf(da) > 3.0:
				da = absf(da) * (sgn if sgn != 0.0 else 1.0)
			var step := SWING_RATE * _dt
			pp = target if absf(da) <= step else prev.rotated(dir, signf(da) * step)
	var kn := a + dir * along + pp * h
	if (_sk.global_transform * kn).y < knee_min - KNEE_SLACK:
		pp = pp0.rotated(dir, need_floor) if need_floor != 0.0 else pp0
		kn = a + dir * along + pp * h
	_pp[side] = pp if pp.angle_to(pp0) > 1e-3 else Vector3.ZERO
	var knee := kn
	if (_sk.global_transform * knee).y < knee_min - 0.001:
		knee_lifted = true
	elif (b - knee).length() > 0.002:
		knee_lifted = true
	if OS.get_environment("KN_DBGLIM") != "" and side == "r" and Engine.get_physics_frames() > 168 and Engine.get_physics_frames() < 180:
		print("SEQ f", Engine.get_physics_frames(), " phi ", snappedf(phi, 0.01), " sgn ", sgn, " need ", snappedf(need, 0.01), " nf ", snappedf(need_floor, 0.01), " prev ", prev, " target ", target, " pp ", pp, " kneeY ", snappedf((_sk.global_transform * kn).y, 0.001))
	_rot_global(ti, _arc(b - a, knee - a))
	var b2 := _gpos(si)
	var c2 := _gpos(fi)
	_rot_global(si, _arc(c2 - b2, goal2 - b2))
