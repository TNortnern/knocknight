class_name GuardStyle
extends SkeletonModifier3D
## Per-fighter guard variety and a living idle rhythm, layered on top of the AnimationTree pose.
##
## Runs as a SkeletonModifier3D after the AnimationTree (child of the Skeleton3D, after FistPose). Every frame it
##  1. steps a small state machine (guard variant, dwell timer, threat / action detection, rhythm phases),
##  2. blends the animated pose towards the variant pose by `weight` (0 = the untouched clip pose = the calibrated,
##     protective guard; 1 = full style),
##  3. writes only when weight > 0: hip bounce / level-change dip with planted feet (2-bone leg IK), trunk hinge and
##     shoulder roll, and two-bone arm IK that puts each glove at a head-relative goal.
## The layer yields (weight -> 0) within ~0.11 s whenever the foe starts a strike or closes inside `engage_in`, and
## within ~0.08 s for the fighter's own strikes, hits, defence moves, guard, knockdown, taunt, rocked, frozen.
## Offsets are all zero at weight 0, so the guard Area3Ds (riding the forearms) see the original pose before contact.

const STYLE_FOR_MODEL := {"viper": "keyshawn", "anvil": "tank"}
const VARIANTS := ["high", "feeler", "lead_low", "peek", "down"]
## Head-relative glove goals in the fighter frame (+x = fighter's left / lead side, +y up, +z forward), metres.
## [lead_hand, rear_hand, hip_drop, trunk_hinge_deg]
const POSES := {
	"high": [Vector3(0.10, -0.09, 0.26), Vector3(-0.10, -0.12, 0.17), 0.0, 0.0],
	"feeler": [Vector3(0.14, -0.40, 0.48), Vector3(-0.11, -0.12, 0.16), 0.0, 0.0],
	"lead_low": [Vector3(0.20, -0.36, 0.30), Vector3(-0.10, -0.10, 0.18), 0.0, 0.0],
	"peek": [Vector3(0.13, -0.02, 0.20), Vector3(-0.13, -0.03, 0.20), 0.05, 9.0],
	# "down" is only the quiet reset after a knockdown / rock / the opening bell (never part of the random rotation, never
	# picked mid-fight): the lead hand relaxes, the rear hand stays by the chin - the old both-hands-at-the-hips pose
	# read as the boxer randomly dropping his gloves.
	"down": [Vector3(0.24, -0.36, 0.20), Vector3(-0.12, -0.14, 0.17), 0.0, 0.0],
}
## dwell = [min, max] seconds per variant; weights per variant; bounce = skip-step amplitude (m, peak-to-peak
## ~ 2*bounce); dip_every = [min, max] seconds between level-change dips (0 = none); paw = lead-hand pawing amplitude.
const PROFILES := {
	"tank": {"dwell": [1.75, 2.25], "weights": {"high": 3.0, "feeler": 3.0, "lead_low": 1.5, "peek": 1.0, "down": 0.0},
		"bounce": 0.017, "bounce_hz": 2.0, "dip_every": [0.0, 0.0], "dip_depth": 0.0, "paw": 1.0, "roll": 3.5},
	"keyshawn": {"dwell": [1.1, 1.3], "weights": {"high": 2.0, "feeler": 1.5, "lead_low": 2.5, "peek": 2.0, "down": 0.0},
		"bounce": 0.0, "bounce_hz": 0.0, "dip_every": [2.2, 4.0], "dip_depth": 0.10, "paw": 0.35, "roll": 1.5},
}
const LOW_VARIANTS := ["feeler", "lead_low"]
const LOW_AFTER_THREAT := 2.5   ## s after an exchange before a low-hand variant may be picked again
const ENGAGE_IN := 1.10        ## inside this gap the layer is fully released (contact is possible)
const ENGAGE_OUT := 1.22       ## hysteresis: style only returns outside this gap
const DOWN_MIN_GAP := 1.5      ## hands-down only when the foe is this far
const THREAT_RELEASE := 0.11   ## s, weight 1 -> 0 on a foe threat
const OWN_RELEASE := 0.08      ## s, weight 1 -> 0 on own action / reaction
const RECOVER_HOLD := 0.30     ## s of calm before the style returns
const RECOVER_TIME := 0.55     ## s, weight 0 -> 1
const SPRING_W := 13.0         ## rad/s of the critically damped pose springs

## master switch (A/B comparisons, tests that need the raw clip pose)
static var enabled := true

var fighter: Node3D                  ## the Fighter (typed loosely: Fighter is declared later in the load order)
var style_name := "tank"
var variant := "down"                ## current guard variant
var variant_log: Array = []          ## [[time_s, variant], ...] every change (tests, debugging)
var weight := 0.0                    ## 0..1 style amount (smoothed); exactly 0 means the layer writes nothing
var hip_offset := 0.0                ## metres, vertical hip offset currently applied (bounce + dip - drop)
var record := false                  ## tests: capture final bone world positions each frame into `snap`
var snap := {}                       ## bone name -> world position, valid after this modifier ran (Skeleton3D.get_bone_global_pose
									 ## re-derives the pre-modifier pose outside the modifier pass, so tests must read this)
var threat := false                  ## foe threatening / contact range right now

var _profile: Dictionary
var _rng := RandomNumberGenerator.new()
var _time := 0.0
var _dwell_left := 1.4
var _calm_t := 0.0
var _w := 0.0                        ## linear ramp behind `weight`
var _lead := Vector3(0.10, -0.09, 0.26)
var _lead_v := Vector3.ZERO
var _rear := Vector3(-0.10, -0.12, 0.17)
var _rear_v := Vector3.ZERO
var _drop := 0.0
var _drop_v := 0.0
var _hinge := 0.0
var _hinge_v := 0.0
var _bounce_phase := 0.0
var _bounce_hz := 2.0
var _paw_phase := 0.0
var _roll_phase := 0.0
var _dip_t := -1.0
var _dip_next := 3.0
var _was_disturbed := false         ## (the opening hands-down comes from set_style)
var _prev_rocked := false
var _since_threat := 99.0            ## s since the foe last threatened (exchange range / punching)
var _was_threat := false
var _prev_frozen := false
var _sk: Skeleton3D
var _idx := {}
var _gait := 0.0                     ## 0 standing .. 1 walking (damps the bounce)


static func attach(p_fighter: Node3D, sk: Skeleton3D) -> GuardStyle:
	var gs := GuardStyle.new()
	gs.name = "GuardStyle"
	gs.fighter = p_fighter
	gs.set_style(STYLE_FOR_MODEL.get(p_fighter.get("template"), "tank"))
	# the AnimationTree (a Fighter child, default priority 0) must write its pose BEFORE the skeleton runs its modifiers
	sk.process_physics_priority = 100
	sk.add_child(gs)
	return gs


func set_style(p_style: String) -> void:
	style_name = p_style if PROFILES.has(p_style) else "tank"
	_profile = PROFILES[style_name]
	var idx: int = fighter.get("player_index") if fighter != null else 0
	var h: int = hash("%s/%d/%s" % [fighter.get("model") if fighter != null else "", idx, style_name])
	_rng.seed = h
	_bounce_phase = _rng.randf() * TAU
	_paw_phase = _rng.randf() * TAU
	_roll_phase = _rng.randf() * TAU
	_bounce_hz = _profile["bounce_hz"] * _rng.randf_range(0.93, 1.07)
	_dip_next = _rng.randf_range(1.5, 3.5)
	_enter("down", _rng.randf_range(1.1, 1.5))


# ------------------------------------------------------------------ state machine
func _enter(v: String, dwell := -1.0) -> void:
	variant = v
	var d: Array = _profile["dwell"]
	_dwell_left = dwell if dwell > 0.0 else _rng.randf_range(d[0], d[1])
	variant_log.append([_time, v])


func _pick_variant(far: bool) -> String:
	var wts: Dictionary = _profile["weights"]
	var total := 0.0
	for k in VARIANTS:
		if k == variant or k == "down" or float(wts[k]) <= 0.0:
			continue
		total += wts[k]
	var r := _rng.randf() * total
	for k in VARIANTS:
		if k == variant or k == "down" or float(wts[k]) <= 0.0:
			continue
		if k in LOW_VARIANTS and _since_threat < LOW_AFTER_THREAT:
			continue   # just out of an exchange: no low-hand variant yet
		r -= wts[k]
		if r <= 0.0:
			return k
	return "high" if variant != "high" else "peek"


func _foe_threat(gap: float) -> bool:
	var foe: Node3D = fighter.get("foe")
	if foe == null:
		return false
	var limit := ENGAGE_OUT if weight < 0.999 or threat else ENGAGE_IN
	if gap < limit:
		return true
	if int(foe.get("state")) == Fighter.State.ATTACK:
		return true
	if gap < 1.9 and float(fighter.get("_closing_speed")) > 1.3:
		return true
	return false


func _own_busy() -> bool:
	var f = fighter
	if int(f.state) != Fighter.State.IDLE:
		return true
	return f.guard_on or f.stats.rocked or f.frozen or f.input_locked


func _step(dt: float) -> void:
	_time += dt
	var f = fighter
	var gap: float = f.gap_to_foe()
	# --- forced resets: hands-down after a knockdown / get-up / rocked / freeze / round start
	var disturbed: bool = int(f.state) in [Fighter.State.FALL, Fighter.State.COUNT, Fighter.State.GETUP, Fighter.State.DOWN, Fighter.State.WIN] \
		or f.stats.rocked or f.frozen
	if _was_disturbed and not disturbed:
		_enter("down", _rng.randf_range(1.1, 1.5))
	_was_disturbed = disturbed
	# --- weight target
	threat = _foe_threat(gap)
	if threat:
		_since_threat = 0.0
	else:
		_since_threat += dt
	if _was_threat and not threat and variant in LOW_VARIANTS:
		_enter("high", _rng.randf_range(1.6, 2.2))   # coming out of an exchange the hands return to a high guard, not a low one
	_was_threat = threat
	var busy := _own_busy()
	if busy:
		_calm_t = 0.0
	elif threat:
		_calm_t = 0.0
	else:
		_calm_t += dt
	var rate := 1.0 / RECOVER_TIME
	var target := 1.0
	if busy:
		target = 0.0
		rate = 1.0 / OWN_RELEASE
	elif threat:
		target = 0.0
		rate = 1.0 / THREAT_RELEASE
	elif _calm_t < RECOVER_HOLD:
		target = 0.0
		rate = 1.0 / RECOVER_TIME
	_w = move_toward(_w, target, rate * dt)
	weight = _w * _w * (3.0 - 2.0 * _w)
	if _w <= 0.0:
		weight = 0.0
	# --- variant timer runs only while the layer is live
	if weight > 0.5 and not threat:
		_dwell_left -= dt
		if _dwell_left <= 0.0:
			_enter(_pick_variant(gap >= DOWN_MIN_GAP))
	if variant == "down" and gap < DOWN_MIN_GAP - 0.1 and not _dwell_hold():
		_enter(_pick_variant(false))
	# --- springs towards the variant pose
	var pose: Array = POSES[variant]
	var k := SPRING_W
	_lead_v += (pose[0] - _lead) * k * k * dt - _lead_v * 2.0 * k * dt
	_lead += _lead_v * dt
	_rear_v += (pose[1] - _rear) * k * k * dt - _rear_v * 2.0 * k * dt
	_rear += _rear_v * dt
	_drop_v += (pose[2] - _drop) * k * k * dt - _drop_v * 2.0 * k * dt
	_drop += _drop_v * dt
	_hinge_v += (pose[3] - _hinge) * k * k * dt - _hinge_v * 2.0 * k * dt
	_hinge += _hinge_v * dt
	# --- rhythm clocks
	var speed := Vector2(f.velocity.x, f.velocity.z).length()
	_gait = lerpf(_gait, clampf(speed / 0.5, 0.0, 1.0), 1.0 - exp(-8.0 * dt))
	_bounce_phase += TAU * _bounce_hz * dt
	_paw_phase += TAU * 2.0 * dt * (1.0 + 0.04 * sin(_time * 0.7))
	_roll_phase += TAU * 0.9 * dt
	var de: Array = _profile["dip_every"]
	if de[1] > 0.0:
		if _dip_t >= 0.0:
			_dip_t += dt
			if _dip_t > 0.42:
				_dip_t = -1.0
				_dip_next = _rng.randf_range(de[0], de[1])
		elif weight > 0.5 and not threat and variant != "down":
			_dip_next -= dt
			if _dip_next <= 0.0:
				_dip_t = 0.0


func _dwell_hold() -> bool:
	return _dwell_left > 0.0


# ------------------------------------------------------------------ pose application
func _process_modification_with_delta(delta: float) -> void:
	_sk = get_skeleton()
	if _sk == null or fighter == null or not is_instance_valid(fighter):
		return
	if not enabled:
		weight = 0.0
		hip_offset = 0.0
		return
	if _idx.is_empty():
		_build_indices()
	if delta > 0.0:
		_step(minf(delta, 0.05))
	if weight <= 0.0:
		hip_offset = 0.0
	else:
		_apply(weight)
	if record:
		_record()


func _build_indices() -> void:
	for n in ["hip", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "head", "lCollar", "rCollar",
			"lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lHand", "rHand",
			"lThighBend", "rThighBend", "lShin", "rShin", "lFoot", "rFoot"]:
		_idx[n] = _sk.find_bone(n)


## fighter-frame vector -> skeleton space
func _to_sk(v: Vector3) -> Vector3:
	return _sk.global_basis.inverse() * (fighter.global_basis * v)


func _gpos(i: int) -> Vector3:
	return _sk.get_bone_global_pose(i).origin


func _parent_q(i: int) -> Quaternion:
	var p := _sk.get_bone_parent(i)
	return Quaternion.IDENTITY if p < 0 else _sk.get_bone_global_pose(p).basis.get_rotation_quaternion()


## Pre-multiply a skeleton-space rotation onto a bone's global rotation (about its own origin).
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


## Analytic two-bone IK in skeleton space: root/mid bone rotations so that `end` reaches `goal`, knee/elbow towards `pole`.
func _two_bone(i_root: int, i_mid: int, i_end: int, goal: Vector3, pole: Vector3) -> void:
	var a := _gpos(i_root)
	var b := _gpos(i_mid)
	var c := _gpos(i_end)
	var l1 := a.distance_to(b)
	var l2 := b.distance_to(c)
	var to_goal := goal - a
	var d := clampf(to_goal.length(), absf(l1 - l2) + 0.01, l1 + l2 - 0.002)
	var dir := to_goal.normalized()
	var p := pole - dir * pole.dot(dir)
	if p.length() < 0.001:
		p = (b - a) - dir * (b - a).dot(dir)
	p = p.normalized()
	var along := (l1 * l1 - l2 * l2 + d * d) / (2.0 * d)
	var h := sqrt(maxf(l1 * l1 - along * along, 0.0))
	var b2 := a + dir * along + p * h
	var g2 := a + dir * d
	_rot_global(i_root, _arc(b - a, b2 - a))
	var c_now := _gpos(i_end)
	var b_now := _gpos(i_mid)
	_rot_global(i_mid, _arc(c_now - b_now, g2 - b_now))


func _apply(w: float) -> void:
	var f = fighter
	var prof := _profile
	var up_sk := _to_sk(Vector3.UP).normalized()
	# ---- rhythm: bounce / dip / drop (metres, + up)
	var bounce := 0.0
	if prof["bounce"] > 0.0:
		bounce = prof["bounce"] * (0.5 + 0.5 * sin(_bounce_phase)) * (1.0 - 0.7 * _gait)
	var dip := 0.0
	if _dip_t >= 0.0:
		dip = -float(prof["dip_depth"]) * sin(PI * clampf(_dip_t / 0.42, 0.0, 1.0))
	hip_offset = (bounce + dip - _drop) * w
	var hinge_rad := deg_to_rad(_hinge) * w + deg_to_rad(absf(dip) / 0.1 * 6.0) * w
	# ---- remember planted feet (skeleton space) before the hip moves
	var feet := {}
	for side in ["l", "r"]:
		var t: int = _idx[side + "Thigh" + "Bend"]
		var s: int = _idx[side + "Shin"]
		var fo: int = _idx[side + "Foot"]
		var a0 := _gpos(t)
		var b0 := _gpos(s)
		var c0 := _gpos(fo)
		var dir0 := (c0 - a0).normalized()
		var pole0 := (b0 - a0) - dir0 * (b0 - a0).dot(dir0)
		feet[side] = [c0, _sk.get_bone_global_pose(fo).basis.get_rotation_quaternion(), pole0]
	# ---- hip vertical offset
	var hip: int = _idx["hip"]
	var pq := _parent_q(hip)
	var delta_sk := up_sk * hip_offset
	_sk.set_bone_pose_position(hip, _sk.get_bone_pose_position(hip) + pq.inverse() * delta_sk)
	# ---- trunk: hinge (forward lean) shared over the spine, head keeps looking at the foe; shoulder roll
	var side_axis := _to_sk(Vector3.RIGHT).normalized()   # fighter +x is its left
	if absf(hinge_rad) > 0.0001:
		var shares := {"abdomenLower": 0.4, "abdomenUpper": 0.3, "chestLower": 0.3}
		for n in shares:
			_rot_global(_idx[n], Quaternion(side_axis, hinge_rad * shares[n]))
		_rot_global(_idx["head"], Quaternion(side_axis, -hinge_rad * 0.7))
	var roll := deg_to_rad(float(prof["roll"])) * sin(_roll_phase) * w
	if absf(roll) > 0.0001:
		_rot_global(_idx["chestUpper"], Quaternion(up_sk, roll) * Quaternion(_to_sk(Vector3.BACK).normalized(), roll * 0.5))
	# ---- legs: re-plant both feet
	for side in ["l", "r"]:
		var fe: Array = feet[side]
		_two_bone(_idx[side + "ThighBend"], _idx[side + "Shin"], _idx[side + "Foot"], fe[0], fe[2])
		var fo: int = _idx[side + "Foot"]
		var cur := _sk.get_bone_global_pose(fo).basis.get_rotation_quaternion()
		_rot_global(fo, (fe[1] as Quaternion) * cur.inverse())
	# ---- arms: gloves to head-relative goals, blended from the animated hand position by weight
	var head_p := _gpos(_idx["head"])
	var paw := Vector3.ZERO
	var paw_amp: float = prof["paw"]
	if paw_amp > 0.0:
		var ph := 0.5 + 0.5 * sin(_paw_phase)
		paw = Vector3(0.0, 0.025 * ph, 0.06 * ph) * paw_amp * (1.0 if variant != "down" else 0.3)
	for side in ["l", "r"]:
		var sgn := 1.0 if side == "l" else -1.0
		var off: Vector3 = (_lead + paw) if side == "l" else _rear
		var goal := head_p + _to_sk(off)
		var hand: int = _idx[side + "Hand"]
		var hp := _gpos(hand)
		goal = hp.lerp(goal, w)
		var elbow := _gpos(_idx[side + "ForearmBend"])
		var sh := _gpos(_idx[side + "ShldrBend"])
		var hint := _to_sk(Vector3(0.7 * sgn, -0.8, -0.35)).normalized()
		var anim_pole := (elbow - sh).normalized()
		var pole := (anim_pole * (1.0 - 0.6 * w) + hint * (0.6 * w)).normalized()
		var hand_q := _sk.get_bone_global_pose(hand).basis.get_rotation_quaternion()
		var fore_q := _sk.get_bone_global_pose(_idx[side + "ForearmBend"]).basis.get_rotation_quaternion()
		_two_bone(_idx[side + "ShldrBend"], _idx[side + "ForearmBend"], hand, goal, pole)
		# fist orientation: follow the forearm change by 60 %
		var fore_q2 := _sk.get_bone_global_pose(_idx[side + "ForearmBend"]).basis.get_rotation_quaternion()
		var dq := (fore_q2 * fore_q.inverse())
		var part := Quaternion.IDENTITY.slerp(dq, 0.6)
		var want := part * hand_q
		_rot_global(hand, want * _sk.get_bone_global_pose(hand).basis.get_rotation_quaternion().inverse())



func _record() -> void:
	for n in ["head", "lHand", "rHand", "hip", "lFoot", "rFoot", "lForearmBend", "rForearmBend", "chestUpper"]:
		var i := _sk.find_bone(n)
		snap[n] = _sk.global_transform * _sk.get_bone_global_pose(i).origin
