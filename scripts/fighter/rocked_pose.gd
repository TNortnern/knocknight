extends SkeletonModifier3D
## Procedural "hurt" pose on top of the animation (runs after the AnimationTree, like FistPose).
##
##   HEAD daze : upright, flat-footed, gloves dropped to the belt, chin up, a small non-circular sway
##               (springs + random stumble impulses, randomised per episode), then the guard comes back.
##   BODY hurt : waist fold + knee dip, hand clutching the hit flank, the other glove low by the knee.
##
## Everything is computed in skeleton space with skeleton-space delta rotations about bone origins, so it does not
## depend on the Daz bone axes. Bones are restored to the animated pose at the start of every pass (the animation
## does not key every bone), and when all weights are ~0 the modifier does nothing at all (no pops on enter/exit).
## State comes from `hurt` (HurtState); `fighter` supplies the facing (fighters face the foe, forward = +Z of the node).

const HurtStateScript := preload("res://scripts/combat/hurt_state.gd")
var hurt: HurtStateScript
var fighter: Node3D

## Diagnostics for tests / debugging.
var w_daze := 0.0
var w_body := 0.0
var collapse := 0.0
var fold := 0.0

const SPINE := [["abdomenLower", 0.30], ["abdomenUpper", 0.30], ["chestLower", 0.22], ["chestUpper", 0.18]]

var _built := false
var _bone := {}                       ## name -> index
var _base_rot := {}                   ## idx -> Quaternion (animated pose before our write)
var _written_rot := {}                ## idx -> Quaternion (what we wrote)
var _base_pos := {}
var _written_pos := {}
var _st := {}                         ## spring states: key -> Vector2(x, v)
var _rng := RandomNumberGenerator.new()
var _episode := -1
var _catch_t := 0.5
var _t_prev := 0.0

# frame axes in skeleton space
var _fwd := Vector3.BACK
var _left := Vector3.RIGHT
var _up := Vector3.UP


func _build(sk: Skeleton3D) -> void:
	_built = true
	for n in ["hip", "pelvis", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "neckLower", "neckUpper", "head",
			"lCollar", "rCollar", "lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lHand", "rHand",
			"lThighBend", "rThighBend", "lShin", "rShin", "lFoot", "rFoot"]:
		_bone[n] = sk.find_bone(n)
	_rng.seed = 7919 + int(get_instance_id() % 100000)


# ------------------------------------------------------------------ main pass
func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or hurt == null or fighter == null:
		return
	if not _built:
		_build(sk)
	_restore(sk)
	_update_model(dt)
	if w_daze < 0.002 and w_body < 0.002:
		w_daze = 0.0
		w_body = 0.0
		return
	_apply(sk)


## Put every bone we wrote last pass back to its animated value (unless the animation overwrote it since).
func _restore(sk: Skeleton3D) -> void:
	for i in _written_rot:
		var cur := sk.get_bone_pose_rotation(i)
		if cur.is_equal_approx(_written_rot[i]):
			sk.set_bone_pose_rotation(i, _base_rot[i])
	for i in _written_pos:
		var curp := sk.get_bone_pose_position(i)
		if curp.is_equal_approx(_written_pos[i]):
			sk.set_bone_pose_position(i, _base_pos[i])
	_base_rot.clear()
	_written_rot.clear()
	_base_pos.clear()
	_written_pos.clear()


func _spring(key: String, target: float, k: float, zeta: float, dt: float) -> float:
	var s: Vector2 = _st.get(key, Vector2.ZERO)
	var c := 2.0 * zeta * sqrt(k)
	s.y += (k * (target - s.x) - c * s.y) * dt
	s.x += s.y * dt
	_st[key] = s
	return s.x


func _kick(key: String, impulse: float) -> void:
	var s: Vector2 = _st.get(key, Vector2.ZERO)
	s.y += impulse
	_st[key] = s


func _follow(cur: float, target: float, rate: float, dt: float) -> float:
	return lerpf(cur, target, 1.0 - exp(-rate * dt))


func _update_model(dt: float) -> void:
	var live := hurt.active() and not hurt.suppress
	if hurt.episode != _episode and hurt.active():
		_episode = hurt.episode
		_rng.seed = hash([hurt.episode, get_instance_id()])
		_catch_t = hurt.catch_t
		_st.clear()
	var head := live and hurt.is_head()
	var body := live and hurt.is_body()
	var daze_target := hurt.onset() if head else 0.0
	var body_target := 0.0
	if body:
		var T := maxf(hurt.body_len, 0.2)
		body_target = minf(smoothstep(0.0, 1.0, hurt.t / 0.22), 1.0 - smoothstep(0.0, 1.0, (hurt.t - (T - 0.32)) / 0.32))
	var fade := 16.0 if live else 26.0
	w_daze = _follow(w_daze, daze_target, fade, dt)
	w_body = _follow(w_body, body_target, 22.0 if live else 26.0, dt)
	# gloves: down for the whole daze (half way up when the player holds block), back over GUARD_RETURN afterwards
	var col_t := w_daze * (1.0 - hurt.guard_return()) * (0.5 if hurt.guard_up else 1.0)
	collapse = _follow(collapse, col_t, 12.0, dt)
	fold = w_body
	# sway: two detuned sines drive springs, plus random "stumble" impulses (never a clean circle)
	var sev := hurt.severity
	var t := hurt.t
	var amp := (0.5 + 0.5 * sev) * hurt.sway_amp
	var f := hurt.sway_freq
	var roll_t := hurt.sway_sign * amp * (0.050 * sin(1.35 * f * t + hurt.sway_phase) + 0.025 * sin(2.9 * f * t + 1.7 * hurt.sway_phase))
	var pitch_t := amp * (0.035 * sin(1.05 * f * t + hurt.sway_phase + 1.9) + 0.012)
	if head and t < hurt.daze_len:
		_catch_t -= dt
		if _catch_t <= 0.0:
			_catch_t = _rng.randf_range(0.5, 0.95) * hurt.catch_gap_scale
			_kick("roll", _rng.randf_range(0.5, 0.9) * amp * (1.0 if _rng.randf() < 0.5 else -1.0))
			_kick("pitch", _rng.randf_range(-0.4, 0.5) * amp)
			_kick("yaw", _rng.randf_range(-0.35, 0.35) * amp)
	if not head:
		roll_t = 0.0
		pitch_t = 0.0
	_spring("roll", roll_t, 55.0, 0.40, dt)
	_spring("pitch", pitch_t, 55.0, 0.45, dt)
	_spring("yaw", 0.045 * hurt.sway_sign * amp * sin(0.8 * f * t + 2.0 * hurt.sway_phase) if head else 0.0, 45.0, 0.5, dt)
	_t_prev = t


# ------------------------------------------------------------------ helpers
func _o(sk: Skeleton3D, name: String) -> Vector3:
	return sk.get_bone_global_pose(_bone[name]).origin


func _set_rot(sk: Skeleton3D, i: int, q: Quaternion) -> void:
	if not _base_rot.has(i):
		_base_rot[i] = sk.get_bone_pose_rotation(i)
	sk.set_bone_pose_rotation(i, q)
	_written_rot[i] = sk.get_bone_pose_rotation(i)


## Rotate bone `i` (and everything below it) by the skeleton-space rotation `q` about the bone's origin.
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


# ------------------------------------------------------------------ pose
func _apply(sk: Skeleton3D) -> void:
	var S := sk.global_transform.basis.inverse()
	var fb := fighter.global_basis
	_fwd = (S * fb.z).normalized()
	_left = (S * fb.x).normalized()
	_up = (S * Vector3.UP).normalized()
	var dd: float = fighter.defence_damp   # leaning / ducking: the daze sway must not break the neck on top of the lean
	var wd := w_daze * dd
	var wb := w_body * dd
	var sev := hurt.severity
	var side := hurt.side

	# originals (the animated pose) for the foot / knee anchors
	var foot_o := {"l": _o(sk, "lFoot"), "r": _o(sk, "rFoot")}
	var knee_o := {"l": _o(sk, "lShin"), "r": _o(sk, "rShin")}
	var foot_b := {"l": sk.get_bone_global_pose(_bone["lFoot"]).basis, "r": sk.get_bone_global_pose(_bone["rFoot"]).basis}

	var roll: float = (_st.get("roll", Vector2.ZERO) as Vector2).x * wd
	var pitch: float = (_st.get("pitch", Vector2.ZERO) as Vector2).x * wd
	var yaw: float = (_st.get("yaw", Vector2.ZERO) as Vector2).x * wd

	# -- pelvis: tiny weight shift in the daze, a real drop + sit-back in the body fold
	var drop := 0.012 * wd + (0.13 + 0.07 * sev) * wb
	var back := 0.05 * wb
	var shift := roll * 0.30 + (-side * 0.03 * wb)
	var hip_i: int = _bone["hip"]
	var off := -_up * drop - _fwd * back + _left * shift
	if off.length() > 0.0005:
		if not _base_pos.has(hip_i):
			_base_pos[hip_i] = sk.get_bone_pose_position(hip_i)
		sk.set_bone_pose_position(hip_i, sk.get_bone_pose_position(hip_i) + off)
		_written_pos[hip_i] = sk.get_bone_pose_position(hip_i)
		for s in ["l", "r"]:
			var thigh := "%sThighBend" % s
			var pole: Vector3 = (knee_o[s] as Vector3).lerp((knee_o[s] as Vector3) + _fwd * 0.35 + _up * 0.1, clampf(wb * 1.5, 0.0, 1.0))
			_ik2(sk, thigh, "%sShin" % s, "%sFoot" % s, foot_o[s], pole)
			_set_global_basis(sk, _bone["%sFoot" % s], foot_b[s])

	# -- trunk
	var fold_total := (0.80 + 0.30 * sev) * wb
	for e in SPINE:
		var nm: String = e[0]
		var share: float = e[1]
		_rot_axis(sk, nm, _left, share * (fold_total + pitch))
		_rot_axis(sk, nm, _fwd, share * (roll - side * 0.16 * wb))
		_rot_axis(sk, nm, _up, share * (yaw + side * 0.12 * wb))
	# -- neck / head: chin up in the daze, tucked in the fold
	var chin := -(0.13 + 0.08 * sev) * hurt.chin_amp * wd
	var tuck := 0.30 * wb
	_rot_axis(sk, "neckLower", _left, 0.35 * (chin + tuck))
	_rot_axis(sk, "neckUpper", _left, 0.30 * (chin + tuck))
	_rot_axis(sk, "head", _left, 0.35 * (chin + tuck))
	_rot_axis(sk, "head", _fwd, -0.5 * roll)
	# -- shoulders sag
	var sag := 0.07 * maxf(collapse, wb)
	_rot_axis(sk, "lCollar", _fwd, -sag)
	_rot_axis(sk, "rCollar", _fwd, sag)

	# -- arms
	var hipw := _o(sk, "hip")
	var clutch_side := "l" if side > 0.0 else "r"
	for s in ["l", "r"]:
		var sgn := 1.0 if s == "l" else -1.0
		var hand_n := "%sHand" % s
		var src := _o(sk, hand_n)
		var shoulder := _o(sk, "%sShldrBend" % s)
		var elbow_src := _o(sk, "%sForearmBend" % s)
		var lead := 1.0 if s == "l" else 0.0
		var asym := hurt.glove_asym * 0.04 * sgn
		var belt := hipw + _up * (0.03 + 0.07 * lead + asym) + _fwd * (0.17 + 0.07 * lead) + _left * sgn * 0.16
		var belt_pole := shoulder - _up * 0.26 + _left * sgn * 0.11 - _fwd * 0.04
		var tgt := src.lerp(belt, collapse)
		var pole := elbow_src.lerp(belt_pole, clampf(collapse * 1.2, 0.0, 1.0))
		var arm_w := collapse
		if wb > 0.001:
			var cl_t: Vector3
			var cl_pole: Vector3
			if s == clutch_side:
				cl_t = _o(sk, "abdomenUpper") + _fwd * 0.15 - _up * 0.03 + _left * sgn * 0.05
				cl_pole = shoulder - _up * 0.20 + _fwd * 0.10 + _left * sgn * 0.08
			else:
				cl_t = _o(sk, "%sShin" % s) + _up * 0.14 + _fwd * 0.10 + _left * sgn * 0.02
				cl_pole = shoulder - _up * 0.22 + _fwd * 0.05 + _left * sgn * 0.12
			tgt = tgt.lerp(cl_t, wb)
			pole = pole.lerp(cl_pole, clampf(wb * 1.2, 0.0, 1.0))
			arm_w = maxf(arm_w, wb)
		if arm_w > 0.003:
			_ik2(sk, "%sShldrBend" % s, "%sForearmBend" % s, hand_n, tgt, pole)
