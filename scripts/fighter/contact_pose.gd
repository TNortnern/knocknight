extends SkeletonModifier3D
## Upper-body reaction to body contact (runs after every other pose layer, before pose_limiter.gd). Reads Fighter.bc.
##
##   pressing   the presser leans into the foe (trunk forward, shoulder in, head to the side so the heads pass cheek to cheek)
##   pressed    the fighter being driven back / leaned on braces: trunk goes back, shoulders ride up, chin tucks
##   inside     chest to chest both fighters bend sideways so the heads pass cheek to cheek (the one holding the inside
##              position, bc.inside_pos, bends further), gloves go tight to the chin; a fighter framing puts his lead forearm
##              on the foe's chest / shoulder; two pressing fighters strain (a small tremor on the trunk)
##   bump       a driver stopped dead by a collision recoils, one who overextended falls forward onto the foe's shoulder
##   shove      the shover's gloves go to the foe's chest (two-hand push) while the trunk drives forward; the shoved fighter's
##              trunk and head snap back and the spring rings out
## The trunk is a spring-damper (`_x`, `_v`), so it overshoots and settles instead of following the contact weights
## linearly. The lean is capped by the measured chest-to-chest distance, so the chests never interpenetrate.
## Same technique as fatigue_pose.gd: skeleton-space delta rotations on top of the animated pose, undone at the start of
## every pass; the modifier writes nothing while there is no contact.

var fighter: Node3D
var post_clear := false   ## a second instance placed after every other pose layer: final head-glove / forearm-hull clearance

var lean := 0.0          ## rad, trunk flexion added by this layer (+ forward). Diagnostics for tests.
var shove_w := 0.0       ## 0..1 shove arm envelope
var lat := 0.0           ## rad, sideways bend added by this layer (diagnostics)
var last_forearm_pen_before := 0.0   ## m: deepest eligible forearm-hull penetration at the start of this GloveClear tick
var last_forearm_pen_after := 0.0    ## m: deepest eligible forearm-hull penetration after this GloveClear tick
var correction_count := 0            ## cumulative elbow IK corrections that actually moved an elbow
var recovery_glove_count := 0         ## cumulative recovery-only glove withdrawals that actually moved a wrist

const LEAN_PRESS := 0.30      ## rad at full push
const LEAN_BRACE := -0.22
const LATERAL := 0.27         ## rad of sideways trunk bend that puts the head beside the foe's head
const K := 80.0               ## spring stiffness
const C := 9.5                ## damping (zeta ~0.53: one visible overshoot)
const GLOVE_R := 0.075          ## glove sphere radius used against the foe's hulls
const HULL_GAP := 0.52             ## only in a clinch (root gap): at punching range the guard belongs to the guard styles
const HULL_MARGIN := 0.0             ## the glove rests ON the hull: any clearance lifts the glove off the body, the contact gap opens, contact drops, the push stops and the glove sinks back (a loop)
const GUARD_CLEAR := 0.17      ## m a resting glove keeps from the foe's head (leaning through a trade must not park it in his face)
const POST_CLEAR := 0.17       ## m the last layer keeps a non-punching glove from the foe's head bone (head hull ~0.10)
const FOREARM_R := 0.058       ## m forearms in the fitted hit data are 5.2-5.7 cm thick
const FOREARM_MIN_PEN := 0.012 ## ignore fitted-hull grazing; correct only visible forearm penetration
const RECOVERY_GLOVE_MAX := 0.10    ## m: largest wrist withdrawal from its authored recovery path
const RECOVERY_GLOVE_STEP := 0.03   ## m: hard cap on wrist movement in one physics tick
const RECOVERY_GLOVE_W := 28.0      ## rad/s: critical spring for the world-space withdrawal offset
const LIVE_ELBOW_MAX := 0.135       ## m: largest outward elbow pole offered to a live strike
const LIVE_ELBOW_STEP := 0.022      ## m: hard cap on live elbow pole movement in one tick
const LIVE_ELBOW_W := 30.0          ## rad/s: critical spring for the live elbow pole offset
const MIN_CHEST := 0.55       ## m chest-to-chest the lean never closes below
const SPINE := [["abdomenLower", 0.20], ["abdomenUpper", 0.30], ["chestLower", 0.28], ["chestUpper", 0.22]]

var _frame_tgt := Vector3.INF
var _gfix_w := {}
var _gfix_last := {}
var _gfix := {}          ## hand name -> target (skeleton space) for a glove that would sit in the foe's face
var _foe_final_sk: Skeleton3D
var _foe_final := {}     ## foe bone index -> world Transform3D captured inside its final skeleton_updated signal
var _recovery_glove_target := {"l": Vector3.ZERO, "r": Vector3.ZERO}   ## world offset targets
var _recovery_glove_vel := {"l": Vector3.ZERO, "r": Vector3.ZERO}      ## world offset velocities
var _recovery_glove_offset := {"l": Vector3.ZERO, "r": Vector3.ZERO}   ## applied world offsets
var _live_elbow_vel := {"l": Vector3.ZERO, "r": Vector3.ZERO}          ## skeleton-space pole velocities
var _live_elbow_offset := {"l": Vector3.ZERO, "r": Vector3.ZERO}       ## skeleton-space pole offsets
var _built := false
var _bone := {}
var _base_rot := {}
var _written_rot := {}
var _base_pose := {}
var _written_pose := {}
var _x := 0.0
var _v := 0.0
var _side := 0.0
var _lat := 0.0          ## sideways trunk bend (rad, about the facing axis)
var _tremor := 0.0       ## straining trunk tremor (rad)
var _tight := 0.0        ## 0..1 gloves tight to the chin
var _frame := 0.0        ## 0..1 lead forearm on the foe
var _ph := 0.0
var _yaw := 0.0
var _snap := 0.0         ## head / neck snap (rad, + = back), driven by the shove kick
var _snap_v := 0.0
var _fwd := Vector3.BACK
var _left := Vector3.RIGHT
var _up := Vector3.UP


func _build(sk: Skeleton3D) -> void:
	_built = true
	for n in ["hip", "abdomenLower", "abdomenUpper", "chestLower", "chestUpper", "neckLower", "neckUpper", "head",
			"lCollar", "rCollar", "lShldrBend", "rShldrBend", "lForearmBend", "rForearmBend", "lHand", "rHand"]:
		_bone[n] = sk.find_bone(n)


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or fighter == null or not is_instance_valid(fighter):
		return
	if not _built:
		_build(sk)
	_restore(sk)
	if post_clear:
		_post_clear(sk, dt)
		return
	var bc = fighter.bc
	var f = fighter
	var standing: bool = f.state in [f.State.IDLE, f.State.ATTACK, f.State.SLIP, f.State.HIT, f.State.CROUCH, f.State.TAUNT] \
			and not f._ragdoll.active
	if not standing or bc == null:
		_decay(dt)
		return
	# one-shot kicks from a shove (shover forward, shoved back)
	if absf(bc.kick) > 0.01:
		if bc.kick > 0.0:
			_v += 2.4 * bc.kick
		else:
			_v += -6.5 * absf(bc.kick)
			_snap_v += 7.0 * absf(bc.kick)
		bc.kick = 0.0
	# targets
	var punching: bool = f.state == f.State.ATTACK
	var cw: float = (1.0 - (0.75 if punching else 0.0)) * (0.0 if f.state in [f.State.SLIP, f.State.CROUCH] else 1.0)   # a slip / duck owns the whole upper body
	var hurt_on: bool = f.hurt.active()
	var target: float = (LEAN_PRESS * bc.press_w + LEAN_BRACE * bc.pressed_w) * cw
	if bc.stumble_t > 0.0:
		target += 0.22 * smoothstep(0.0, 0.15, bc.stumble_t)   # overextended: falling onto the foe
	if hurt_on:
		target *= 0.3
	# never closer than MIN_CHEST chest to chest: measure the foe's chest and cap a forward lean
	var d := _chest_dist(sk)
	if d > 0.0 and target > 0.0:
		target *= clampf((d - MIN_CHEST) / 0.06, 0.0, 1.0)
		if d < MIN_CHEST and _x > 0.0:
			_x = lerpf(_x, 0.0, 0.5)
			_v = minf(_v, 0.0)
	_v += (K * (target - _x) - C * _v) * dt
	_x += _v * dt
	_snap_v += (60.0 * (0.0 - _snap) - 8.0 * _snap_v) * dt
	_snap += _snap_v * dt
	var side_t: float = bc.side_sign * 0.30 * bc.press_w * cw
	var yaw_t: float = bc.side_sign * 0.16 * bc.press_w * cw
	# inside fighting: heads pass cheek to cheek (sideways trunk bend), the head-position winner bends further
	var in_c: float = bc.contact_w * cw * (0.0 if punching else 1.0)   # a punch straightens up: the head goes where the punch takes it (a body-shot thrower's head comes forward onto the uppercut)
	var lat_t: float = bc.side_sign * (LATERAL + 0.12 * bc.inside_pos) * (0.65 + 0.35 * bc.press_w) * in_c
	if bc.stumble_t > 0.0:
		lat_t = bc.side_sign * 0.42 * in_c
	if hurt_on:
		lat_t *= 0.4
	_lat = lerpf(_lat, lat_t, 1.0 - exp(-(16.0 if punching else 7.0) * dt))
	lat = _lat
	var foe_bc = f.foe.bc if f.foe != null else null
	var strain: float = 0.0
	if foe_bc != null:
		strain = clampf(bc.press_w * foe_bc.press_w * 2.0 + 0.5 * bc.pressed_w * foe_bc.press_w, 0.0, 1.0)
	_ph += dt * 46.0
	_tremor = 0.022 * strain * sin(_ph) * cw
	var tight_t: float = bc.contact_w * cw * (0.0 if (f.state == f.State.ATTACK or bc.shove_t > 0.0 or hurt_on or f.stats.rocked) else 1.0)
	_tight = lerpf(_tight, tight_t * (1.0 - bc.frame_w), 1.0 - exp(-10.0 * dt))
	_frame = lerpf(_frame, bc.frame_w * cw * (0.0 if hurt_on else 1.0), 1.0 - exp(-10.0 * dt))
	_side = lerpf(_side, side_t, 1.0 - exp(-8.0 * dt))
	_yaw = lerpf(_yaw, yaw_t, 1.0 - exp(-8.0 * dt))
	var shove_target := 0.0
	if bc.shove_t > 0.0:
		var el: float = 1.0 - bc.shove_t / bc.SHOVE_LOCK   # 0..1 through the shove
		shove_target = smoothstep(0.0, 0.25, el) * (1.0 - smoothstep(0.55, 1.0, el))
	shove_w = lerpf(shove_w, shove_target, 1.0 - exp(-30.0 * dt))
	lean = _x
	_gfix = _guard_targets(sk)
	if absf(_x) < 0.004 and absf(_side) < 0.004 and absf(_snap) < 0.004 and shove_w < 0.01 and _gfix.is_empty() and float(_gfix_w.get("lHand", 0.0)) < 0.01 and float(_gfix_w.get("rHand", 0.0)) < 0.01 \
			and absf(_lat) < 0.004 and _tight < 0.01 and _frame < 0.01:
		return
	_apply(sk)


func _decay(dt: float) -> void:
	_x = lerpf(_x, 0.0, 1.0 - exp(-10.0 * dt))
	_v = 0.0
	_side = lerpf(_side, 0.0, 1.0 - exp(-10.0 * dt))
	_yaw = lerpf(_yaw, 0.0, 1.0 - exp(-10.0 * dt))
	_lat = lerpf(_lat, 0.0, 1.0 - exp(-10.0 * dt))
	_tremor = 0.0
	_tight = 0.0
	_frame = 0.0
	_frame_tgt = Vector3.INF
	lat = _lat
	_snap = lerpf(_snap, 0.0, 1.0 - exp(-10.0 * dt))
	_snap_v = 0.0
	shove_w = 0.0
	lean = _x


## Horizontal chest-to-chest distance to the foe (0 when unknown).
func _chest_dist(sk: Skeleton3D) -> float:
	var foe = fighter.foe
	if foe == null or foe.rig == null or foe.rig.skeleton == null or fighter.gap_to_foe() > 1.1:
		return 0.0
	var fsk: Skeleton3D = foe.rig.skeleton
	var i: int = _bone["chestUpper"]
	var j := fsk.find_bone("chestUpper")
	if i < 0 or j < 0:
		return 0.0
	var a: Vector3 = sk.global_transform * sk.get_bone_global_pose(i).origin
	var b: Vector3 = fsk.global_transform * fsk.get_bone_global_pose(j).origin
	return Vector2(a.x - b.x, a.z - b.z).length()


## The foe's upper chest in this skeleton's space (Vector3.INF when unknown).
func _foe_chest(sk: Skeleton3D) -> Vector3:
	var foe = fighter.foe
	if foe == null or foe.rig == null or foe.rig.skeleton == null:
		return Vector3.INF
	var fsk: Skeleton3D = foe.rig.skeleton
	var j := fsk.find_bone("chestUpper")
	if j < 0:
		return Vector3.INF
	return sk.global_transform.affine_inverse() * (fsk.global_transform * fsk.get_bone_global_pose(j).origin)


## Gloves of a fighter who is not punching that would end inside GUARD_CLEAR of the foe's head: pulled back out along the
## line from the head (elbow follows through the IK).
func _guard_targets(sk: Skeleton3D) -> Dictionary:
	var out := {}
	var f = fighter
	var foe = f.foe
	if foe == null or shove_w > 0.5 or f.gap_to_foe() > 1.15 or foe.rig == null or foe.rig.skeleton == null:
		return out
	var fsk: Skeleton3D = foe.rig.skeleton
	var hi := fsk.find_bone("head")
	if hi < 0:
		return out
	var head: Vector3 = fsk.global_transform * fsk.get_bone_global_pose(hi).origin
	var inv := sk.global_transform.affine_inverse()
	var punching: bool = f.state == f.State.ATTACK
	var hitting := String(f.atk.get("limb", "")) if punching and not f.atk.is_empty() else ""
	for n in ["lHand", "rHand"]:
		if n == hitting:
			continue   # the punching glove goes where the punch goes (its own hit volume does the work)
		var h: Vector3 = sk.global_transform * _o(sk, n)
		var moved := h
		# a resting glove keeps clear of the foe's face ...
		if not punching and not (n == "lHand" and _frame > 0.5):
			var d := h.distance_to(head)
			if d < GUARD_CLEAR and d > 0.001:
				moved = head + (h - head) / d * GUARD_CLEAR
		# ... and every glove stays outside the foe's torso / head hulls (clinch: no glove inside the chest)
		if f.gap_to_foe() < HULL_GAP and f.bc.contact_w > 0.3 and foe.state != foe.State.ATTACK:   # (never re-aim a guard into an incoming punch)
			moved = _hull_clear(foe, moved)
		if moved.distance_to(h) > 0.002:
			out[n] = inv * moved
	return out


## Last word on the gloves and forearms: hit flinch, guard knock and the lean layers run after the resting-glove clearance, and
## the foe's body also moves into an arm (a punch lunging in). Non-striking gloves keep their old head clearance. A forearm that
## has visibly crossed a foe's final-pose head / torso hull bends its elbow outward. A live strike keeps its complete hand
## transform while that elbow moves; only recovery may withdraw the wrist along the final hull normal.
func _post_clear(sk: Skeleton3D, dt: float) -> void:
	last_forearm_pen_before = 0.0
	last_forearm_pen_after = 0.0
	var f = fighter
	if f._ragdoll.active or f.state in [f.State.FALL, f.State.COUNT, f.State.GETUP, f.State.DOWN, f.State.WIN]:
		_reset_recovery_gloves()
		_reset_live_elbows()
		return
	var foe = f.foe
	if foe == null or foe.rig == null or foe.rig.skeleton == null or f.gap_to_foe() > 1.15:
		_reset_recovery_gloves()
		_reset_live_elbows()
		return
	var fsk: Skeleton3D = foe.rig.skeleton
	_bind_foe_final(fsk)
	if _foe_final.is_empty():
		_reset_recovery_gloves()
		_reset_live_elbows()
		return
	var S := sk.global_transform.basis.inverse()
	var fb: Basis = f.global_basis
	_fwd = (S * fb.z).normalized()
	_left = (S * fb.x).normalized()
	_up = (S * Vector3.UP).normalized()
	var head := _foe_final_head(sk)
	if head != Vector3.INF and f.state != f.State.ATTACK:
		for n in ["lHand", "rHand"]:
			var h := _o(sk, n)
			var d := h.distance_to(head)
			if d < POST_CLEAR and d > 0.001:
				var s2: String = String(n).substr(0, 1)
				_ik2(sk, "%sShldrBend" % s2, "%sForearmBend" % s2, String(n), head + (h - head) / d * POST_CLEAR, _o(sk, "%sForearmBend" % s2))
	# Elbow clearance keeps the authored glove goal. A recovering strike gets the bounded second-stage withdrawal below;
	# a live strike gets a smoothed elbow-only solve with its full hand transform restored after IK.
	var diag_before := 0.0
	var diag_after := 0.0
	var moved := 0
	for s0 in ["l", "r"]:
		var hand_n := "%sHand" % s0
		var live := _arm_is_live_strike(f, hand_n)
		if not live:
			_reset_live_elbow(s0)
		var result := _clear_forearm(sk, foe, s0, dt, _arm_is_recovering(f, hand_n), live)
		diag_before = maxf(diag_before, float(result["before"]))
		diag_after = maxf(diag_after, float(result["after"]))
		moved += int(result["corrections"])
		recovery_glove_count += int(result["glove_moves"])
	last_forearm_pen_before = diag_before
	last_forearm_pen_after = diag_after
	correction_count += moved


## The own hand / elbow is read after every earlier modifier; opponent hulls come from its last skeleton_updated pose, never
## from the animation pose visible outside that signal.
func _bind_foe_final(fsk: Skeleton3D) -> void:
	if fsk == _foe_final_sk:
		return
	if _foe_final_sk != null and is_instance_valid(_foe_final_sk) and _foe_final_sk.skeleton_updated.is_connected(_capture_foe_final):
		_foe_final_sk.skeleton_updated.disconnect(_capture_foe_final)
	_foe_final_sk = fsk
	_foe_final.clear()
	if not fsk.skeleton_updated.is_connected(_capture_foe_final):
		fsk.skeleton_updated.connect(_capture_foe_final)


func _capture_foe_final() -> void:
	if _foe_final_sk == null or not is_instance_valid(_foe_final_sk) or fighter == null:
		return
	var foe = fighter.foe
	if foe == null or foe.rig == null or foe.rig.skeleton != _foe_final_sk:
		return
	var bones := {}
	for hu in foe.rig.hurtboxes:
		if hu == null or hu.is_guard or hu.shape_node == null:
			continue
		var bn := String(hu.limb)
		var bi := _foe_final_sk.find_bone(bn)
		if bi >= 0:
			bones[bi] = true
	var out := {}
	for bi in bones:
		out[bi] = _foe_final_sk.global_transform * _foe_final_sk.get_bone_global_pose(bi)
	_foe_final = out


func _foe_final_head(sk: Skeleton3D) -> Vector3:
	if _foe_final_sk == null:
		return Vector3.INF
	var hi := _foe_final_sk.find_bone("head")
	if hi < 0 or not _foe_final.has(hi):
		return Vector3.INF
	return sk.global_transform.affine_inverse() * ((_foe_final[hi] as Transform3D).origin)


## The striking hand remains on its authored live path. Only the elbow may leave it to clear a foe hull.
func _arm_is_live_strike(f, hand_n: String) -> bool:
	return (f.state == f.State.ATTACK and not f.atk.is_empty()
			and String(f.atk.get("limb", "")) == hand_n and f.punch_phase() != "recovery")


func _arm_is_recovering(f, hand_n: String) -> bool:
	return (f.state == f.State.ATTACK and not f.atk.is_empty()
			and String(f.atk.get("limb", "")) == hand_n and f.punch_phase() == "recovery")


func _reset_recovery_glove(side: String) -> void:
	_recovery_glove_target[side] = Vector3.ZERO
	_recovery_glove_vel[side] = Vector3.ZERO
	_recovery_glove_offset[side] = Vector3.ZERO


func _reset_recovery_gloves() -> void:
	for side in ["l", "r"]:
		_reset_recovery_glove(side)


func _reset_live_elbow(side: String) -> void:
	_live_elbow_vel[side] = Vector3.ZERO
	_live_elbow_offset[side] = Vector3.ZERO


func _reset_live_elbows() -> void:
	for side in ["l", "r"]:
		_reset_live_elbow(side)


## Bends one elbow away from the deepest foe hull crossed by its forearm segment. The wrist remains the IK goal, so a glove
## resting on an actual target does not teleport. Two bounded passes cover the common case where the first elbow arc still
## grazes a rounded torso corner. A live strike uses one smoothed pole solve and restores the exact hand global pose; recovery
## may then add a bounded world-space withdrawal without changing the glove's global facing.
func _clear_forearm(sk: Skeleton3D, foe, side: String, dt: float, may_withdraw: bool, wrist_locked: bool) -> Dictionary:
	var shoulder := "%sShldrBend" % side
	var elbow := "%sForearmBend" % side
	var hand := "%sHand" % side
	var goal := _o(sk, hand)
	var hit := _forearm_hit(sk, foe, elbow, hand)
	var before := 0.0 if hit.is_empty() else float(hit["depth"])
	var corrections := 0
	if wrist_locked:
		# Never let a stale recovery offset move the live wrist.
		_reset_recovery_glove(side)
		var wanted := Vector3.ZERO
		if not hit.is_empty():
			wanted = _elbow_push(sk, hit, goal, shoulder, elbow)
		var push := _step_live_elbow(side, wanted, dt)
		if not hit.is_empty() or push.length() > 0.0005:
			var e := _o(sk, elbow)
			var hand_idx: int = _bone[hand]
			var hand_pose := sk.get_bone_global_pose(hand_idx)
			_ik2(sk, shoulder, elbow, hand, goal, e + push)
			_hold_global_pose(sk, hand_idx, hand_pose)
			if _o(sk, elbow).distance_to(e) > 0.0005:
				corrections += 1
			hit = _forearm_hit(sk, foe, elbow, hand)
	else:
		for _pass in 2:
			if hit.is_empty():
				break
			var e := _o(sk, elbow)
			var push := _elbow_push(sk, hit, goal, shoulder, elbow)
			if push.length() < 0.0005:
				break
			var hand_idx: int = _bone[hand]
			var glove_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
			_ik2(sk, shoulder, elbow, hand, goal, e + push)
			if _o(sk, elbow).distance_to(e) > 0.0005:
				corrections += 1
			# The elbow solve must not twist the glove around the forearm: preserve its global facing independently of the elbow arc.
			var solved_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
			_rot_sk(sk, hand_idx, glove_q * solved_q.inverse())
			hit = _forearm_hit(sk, foe, elbow, hand)
	var glove_moves := 0
	if not wrist_locked:
		var desired := Vector3.ZERO
		if may_withdraw and not hit.is_empty() and float(hit["depth"]) > FOREARM_MIN_PEN:
			var n_world := (hit["normal"] as Vector3).normalized()
			desired = n_world * clampf(float(hit["depth"]) + 0.012, 0.025, RECOVERY_GLOVE_MAX)
		var offset := _step_recovery_glove(side, desired, dt)
		if offset.length() > 0.0005:
			var hand_idx: int = _bone[hand]
			var goal_world := sk.global_transform * goal
			var shifted_world := goal_world + offset
			var glove_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
			var old_hand := _o(sk, hand)
			_ik2(sk, shoulder, elbow, hand, sk.global_transform.affine_inverse() * shifted_world, _o(sk, elbow))
			if _o(sk, hand).distance_to(old_hand) > 0.0005:
				glove_moves = 1
			var solved_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
			_rot_sk(sk, hand_idx, glove_q * solved_q.inverse())
			hit = _forearm_hit(sk, foe, elbow, hand)
	return {
		"before": before,
		"after": 0.0 if hit.is_empty() else float(hit["depth"]),
		"corrections": corrections,
		"glove_moves": glove_moves,
	}


## Pole displacement from the deepest hull crossing, in skeleton space. The radial term keeps the elbow on the outward side
## of a rounded shoulder instead of flipping through the hull normal.
func _elbow_push(sk: Skeleton3D, hit: Dictionary, goal: Vector3, shoulder: String, elbow: String) -> Vector3:
	var e := _o(sk, elbow)
	var axis := (goal - _o(sk, shoulder)).normalized()
	var n: Vector3 = (sk.global_transform.basis.inverse() * (hit["normal"] as Vector3)).normalized()
	var p := sk.global_transform.affine_inverse() * (hit["point"] as Vector3)
	var radial := e - p
	if radial.length() > 0.001:
		n = (n * 0.65 + radial.normalized() * 0.35).normalized()
	n -= axis * n.dot(axis)
	if n.length() < 0.001:
		n = axis.cross(_up)
	if n.length() < 0.001:
		return Vector3.ZERO
	var push := clampf(0.050 + float(hit["depth"]) * 1.25, 0.050, 0.135)
	return n.normalized() * push


## Critical spring for the live elbow pole. The finite spring and per-tick displacement cap make hull entry and release
## continuous, including when the deepest contact switches around the foe's neck / shoulder.
func _step_live_elbow(side: String, desired: Vector3, dt: float) -> Vector3:
	var target := desired.limit_length(LIVE_ELBOW_MAX)
	var x: Vector3 = _live_elbow_offset[side]
	var v: Vector3 = _live_elbow_vel[side]
	if dt <= 0.0:
		return x
	var start := x
	var n := maxi(1, int(ceilf(dt / 0.004)))
	var h := dt / float(n)
	for _i in n:
		v += (LIVE_ELBOW_W * LIVE_ELBOW_W * (target - x) - 2.0 * LIVE_ELBOW_W * v) * h
		x += v * h
	var delta := x - start
	if delta.length() > LIVE_ELBOW_STEP:
		x = start + delta.normalized() * LIVE_ELBOW_STEP
		v = (x - start) / dt
	if x.length() > LIVE_ELBOW_MAX:
		x = x.limit_length(LIVE_ELBOW_MAX)
		v = v.limit_length(LIVE_ELBOW_MAX / dt)
	if target.is_zero_approx() and x.length() < 0.0005:
		x = Vector3.ZERO
		v = Vector3.ZERO
	_live_elbow_offset[side] = x
	_live_elbow_vel[side] = v
	return x


## Critical spring in world space. The integrated frame displacement is capped at RECOVERY_GLOVE_STEP, including a target
## reversal, so changing the hull normal cannot snap the hand.
func _step_recovery_glove(side: String, desired_world: Vector3, dt: float) -> Vector3:
	var target := desired_world.limit_length(RECOVERY_GLOVE_MAX)
	_recovery_glove_target[side] = target
	var x: Vector3 = _recovery_glove_offset[side]
	var v: Vector3 = _recovery_glove_vel[side]
	if dt <= 0.0:
		return x
	var start := x
	var n := maxi(1, int(ceilf(dt / 0.004)))
	var h := dt / float(n)
	for _i in n:
		v += (RECOVERY_GLOVE_W * RECOVERY_GLOVE_W * (target - x) - 2.0 * RECOVERY_GLOVE_W * v) * h
		x += v * h
	var delta := x - start
	if delta.length() > RECOVERY_GLOVE_STEP:
		x = start + delta.normalized() * RECOVERY_GLOVE_STEP
		v = (x - start) / dt
	if x.length() > RECOVERY_GLOVE_MAX:
		x = x.limit_length(RECOVERY_GLOVE_MAX)
		v = v.limit_length(RECOVERY_GLOVE_MAX / dt)
	_recovery_glove_offset[side] = x
	_recovery_glove_vel[side] = v
	return x


func _forearm_hit(sk: Skeleton3D, foe, elbow: String, hand: String) -> Dictionary:
	var a: Vector3 = sk.global_transform * _o(sk, elbow)
	var b: Vector3 = sk.global_transform * _o(sk, hand)
	var span := a.distance_to(b)
	if span < 0.05:
		return {}
	var samples := clampi(int(ceil(span / 0.025)), 6, 18)
	var best := {}
	for hu in foe.rig.hurtboxes:
		if hu == null or hu.is_guard or hu.shape_node == null or hu.shape_node.shape == null or not (hu.zone == "head" or hu.zone == "body"):
			continue
		var xf: Transform3D
		if hu.has_meta("vis_mount"):
			xf = hu.shape_node.global_transform   # rides the visible skeleton: the mount only moves inside the foe's skeleton_updated, so this IS its final pose
		else:
			var hi := _foe_final_sk.find_bone(String(hu.limb))
			if hi < 0 or not _foe_final.has(hi):
				continue
			xf = (_foe_final[hi] as Transform3D) * hu.transform * hu.shape_node.transform
		for k in samples + 1:
			var t := lerpf(0.035, 0.86, float(k) / float(samples))
			var q := a.lerp(b, t)
			var d := _hull_sdf(hu, xf, q)
			var depth := FOREARM_R - d
			if depth > FOREARM_MIN_PEN and (best.is_empty() or depth > float(best["depth"])):
				best = {"depth": depth, "point": q, "hull": hu, "xf": xf}
	if best.is_empty():
		return {}
	return {
		"depth": best["depth"],
		"point": best["point"],
		"normal": _hull_normal(best["hull"], best["xf"] as Transform3D, best["point"] as Vector3),
	}


func _hull_sdf(hu, xf: Transform3D, p: Vector3) -> float:
	return _shape_sdf(hu.shape_node.shape, xf.affine_inverse() * p, hu.corner)


func _hull_normal(hu, xf: Transform3D, p: Vector3) -> Vector3:
	var e := 0.004
	var g := Vector3(
		_hull_sdf(hu, xf, p + Vector3(e, 0, 0)) - _hull_sdf(hu, xf, p - Vector3(e, 0, 0)),
		_hull_sdf(hu, xf, p + Vector3(0, e, 0)) - _hull_sdf(hu, xf, p - Vector3(0, e, 0)),
		_hull_sdf(hu, xf, p + Vector3(0, 0, e)) - _hull_sdf(hu, xf, p - Vector3(0, 0, e)))
	return g.normalized() if g.length() > 1e-6 else Vector3.UP


## Same signed-distance math as HitAreas.Hurtbox.sdf, but with a transform built from the foe's final-pose bone signal.
func _shape_sdf(shape: Shape3D, q: Vector3, corner: float) -> float:
	if shape is CapsuleShape3D:
		var cs := shape as CapsuleShape3D
		q.y -= clampf(q.y, -maxf(cs.height * 0.5 - cs.radius, 0.0), maxf(cs.height * 0.5 - cs.radius, 0.0))
		return q.length() - cs.radius
	if shape is SphereShape3D:
		return q.length() - (shape as SphereShape3D).radius
	if shape is BoxShape3D:
		var half := (shape as BoxShape3D).size * 0.5 - Vector3(corner, corner, corner)
		var d := q.abs() - half
		return Vector3(maxf(d.x, 0.0), maxf(d.y, 0.0), maxf(d.z, 0.0)).length() + minf(maxf(d.x, maxf(d.y, d.z)), 0.0) - corner
	return 9.0


## `p` (skeleton space) pushed out of GUARD_CLEAR around the foe's head bone.
func _clear_of_head(sk: Skeleton3D, p: Vector3) -> Vector3:
	var foe = fighter.foe
	if foe == null or foe.rig == null or foe.rig.skeleton == null:
		return p
	var fsk: Skeleton3D = foe.rig.skeleton
	var hi := fsk.find_bone("head")
	if hi < 0:
		return p
	var head: Vector3 = sk.global_transform.affine_inverse() * (fsk.global_transform * fsk.get_bone_global_pose(hi).origin)
	var d := p.distance_to(head)
	if d < GUARD_CLEAR and d > 0.001:
		return head + (p - head) / d * GUARD_CLEAR
	return p


## Pushes the glove sphere centre `p` (world) out of the foe's head / body capsules, along the hull normal.
func _hull_clear(foe, p: Vector3) -> Vector3:
	var q := p
	for hu in foe.rig.hurtboxes:
		if hu.is_guard or hu.shape_node == null or not (hu.zone == "head" or hu.zone == "body"):
			continue
		var d: float = hu.sdf(q)
		var need := GLOVE_R + HULL_MARGIN
		if d < need:
			q += hu.normal_at(q) * (need - d)
	return q


func _restore(sk: Skeleton3D) -> void:
	for i in _written_rot:
		if sk.get_bone_pose_rotation(i).is_equal_approx(_written_rot[i]):
			sk.set_bone_pose_rotation(i, _base_rot[i])
	_base_rot.clear()
	_written_rot.clear()
	for i in _written_pose:
		if sk.get_bone_pose(i).is_equal_approx(_written_pose[i]):
			sk.set_bone_pose(i, _base_pose[i])
	_base_pose.clear()
	_written_pose.clear()


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


## Restores both the hand origin and facing after an elbow solve. The pose is recorded so the temporary hand correction does
## not accumulate into the next live frame.
func _hold_global_pose(sk: Skeleton3D, i: int, pose: Transform3D) -> void:
	if not _base_pose.has(i):
		_base_pose[i] = sk.get_bone_pose(i)
	sk.set_bone_global_pose(i, pose)
	_written_pose[i] = sk.get_bone_pose(i)


func _rot_axis(sk: Skeleton3D, name: String, axis: Vector3, angle: float) -> void:
	if absf(angle) < 1e-5:
		return
	_rot_sk(sk, _bone[name], Quaternion(axis.normalized(), angle))


func _aim(sk: Skeleton3D, i: int, from: Vector3, to: Vector3) -> void:
	if from.length() < 1e-5 or to.length() < 1e-5:
		return
	_rot_sk(sk, i, Quaternion(from.normalized(), to.normalized()))


## Two-bone IK (see fatigue_pose.gd): put `end` at `target`, bending `mid` towards `pole_pt`.
func _ik2(sk: Skeleton3D, root: String, mid: String, end: String, target: Vector3, pole_pt: Vector3) -> void:
	var a := _o(sk, root)
	var b := _o(sk, mid)
	var c := _o(sk, end)
	var l1 := a.distance_to(b)
	var l2 := b.distance_to(c)
	var tv := target - a
	if tv.length() < 1e-4 or l1 < 1e-4 or l2 < 1e-4:
		return
	var d := clampf(tv.length(), absf(l1 - l2) + 0.004, (l1 + l2) * 0.985)   # never a fully straight arm: the elbow angle is hypersensitive there (pop)
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
	# -- trunk: spring flexion spread over the spine, yaw (shoulder in) on the upper chest
	for e in SPINE:
		var nm: String = e[0]
		var share: float = e[1]
		_rot_axis(sk, nm, _left, share * (_x + _tremor))
		_rot_axis(sk, nm, _fwd, share * _lat)
		if nm.begins_with("chest"):
			_rot_axis(sk, nm, _up, share * _yaw * 2.0)
	# neck / head: keep the eyes on the foe (counter most of the flexion), head to the side, snap back on a shove
	_rot_axis(sk, "neckLower", _left, -0.35 * _x + 0.45 * _snap)
	_rot_axis(sk, "head", _left, -0.30 * _x + 0.55 * _snap)
	_rot_axis(sk, "neckUpper", _fwd, 0.5 * _side)
	_rot_axis(sk, "head", _fwd, 0.5 * _side)
	# -- bracing: shoulders ride up
	var brace := clampf(-_x / 0.12, 0.0, 1.0)
	_rot_axis(sk, "lCollar", _fwd, 0.07 * brace)
	_rot_axis(sk, "rCollar", _fwd, -0.07 * brace)
	# -- gloves tight to the chin, elbows in (inside fighting)
	if _tight > 0.01:
		var hd := _o(sk, "head")
		for s0 in ["l", "r"]:
			var sg := 1.0 if s0 == "l" else -1.0
			var hn := "%sHand" % s0
			var shl := _o(sk, "%sShldrBend" % s0)
			var elb := _o(sk, "%sForearmBend" % s0)
			var tg := hd + _fwd * 0.10 + _left * sg * 0.08 - _up * 0.12
			var pl := shl - _up * 0.30 + _fwd * 0.02
			_ik2(sk, "%sShldrBend" % s0, "%sForearmBend" % s0, hn, _o(sk, hn).lerp(tg, 0.6 * _tight), elb.lerp(pl, 0.7 * _tight))
	# -- frame: the lead forearm on the foe's chest / shoulder
	if _frame > 0.01:
		var fp := _foe_chest(sk)
		if fp != Vector3.INF:
			var mine := _o(sk, "chestUpper")
			var towards := (mine - fp)
			towards.y = 0.0
			towards = towards.normalized() if towards.length() > 1e-4 else -_fwd
			var tgt_f := fp + towards * (0.19 + GLOVE_R + HULL_MARGIN) - _up * 0.02   # on the surface of the foe's chest hull, not inside it
			if _frame_tgt == Vector3.INF:
				_frame_tgt = tgt_f
			_frame_tgt = _frame_tgt.lerp(tgt_f, 1.0 - exp(-14.0 * get_physics_process_delta_time()))   # the foe moves: the framing glove follows softly
			tgt_f = _frame_tgt
			var shl2 := _o(sk, "lShldrBend")
			var elb2 := _o(sk, "lForearmBend")
			var pole2 := shl2 + _left * 0.28 - _up * 0.12
			_ik2(sk, "lShldrBend", "lForearmBend", "lHand", _o(sk, "lHand").lerp(tgt_f, _frame), elb2.lerp(pole2, 0.6 * _frame))
	# -- gloves kept out of the foe's face (measured again now that the tight guard / frame moved them)
	if _tight > 0.01 or _frame > 0.01:
		_gfix = _guard_targets(sk)
	# (the correction fades in / out instead of switching: a glove never pops when the foe's head passes close)
	for n in ["lHand", "rHand"]:
		var live: bool = _gfix.has(n)
		if live:
			_gfix_last[n] = _gfix[n]
		var gw: float = _gfix_w.get(n, 0.0)
		gw = move_toward(gw, 1.0 if live else 0.0, 20.0 * get_physics_process_delta_time())
		_gfix_w[n] = gw
		if gw < 0.01 or not _gfix_last.has(n):
			continue
		var s2: String = String(n).substr(0, 1)
		var hnow := _o(sk, n)
		_ik2(sk, "%sShldrBend" % s2, "%sForearmBend" % s2, String(n), hnow.lerp(_gfix_last[n], gw), _o(sk, "%sForearmBend" % s2))
	# -- shove: both gloves to the foe's chest (two-hand push), elbows wide
	if shove_w > 0.01:
		var chest := _o(sk, "chestUpper")
		for s in ["l", "r"]:
			var sgn := 1.0 if s == "l" else -1.0
			var hand_n := "%sHand" % s
			var src := _o(sk, hand_n)
			var shoulder := _o(sk, "%sShldrBend" % s)
			var elbow := _o(sk, "%sForearmBend" % s)
			var tgt := chest + _fwd * 0.42 + _left * sgn * 0.14 - _up * 0.02
			tgt = _clear_of_head(sk, tgt)   # in a clinch the foe's head sits beside the chest: the two-hand push must not land in his face
			var pole := shoulder + _left * sgn * 0.30 - _up * 0.12
			_ik2(sk, "%sShldrBend" % s, "%sForearmBend" % s, hand_n, _clear_of_head(sk, src.lerp(tgt, shove_w)), elbow.lerp(pole, 0.6 * shove_w))   # (the resting glove's own clearance is off during a shove: the fade in and out must not sweep it through his face)
