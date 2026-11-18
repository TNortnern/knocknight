extends "res://scripts/fighter/pose_layer_base.gd"
## Analog lean (Fight Night style head movement). One 2-D value drives the whole upper body:
##   pos.x : + = lean to the fighter's left, - = right (slips)
##   pos.y : + = forward / down (bob, duck-in), - = back (pull / sway)        |pos| <= 1
## `target` is set by the fighter every physics tick (input while leaning, the held lean while punching, 0 otherwise); `pos` follows it
## on a critically damped spring (no overshoot, no snap). The Round 4 reference's rapid entry/release replaces the old forced hold.
## `speed` is the per-fighter head-movement
## stat (Roster.head_movement), tiredness and being rocked slow it down.
##
## Mechanics at |pos| = 1, calibrated against the Fight Night Round 4 short: trunk tilts sideways and forward, hips sink and
## shift over the loaded leg, feet retain their animated positions AND orientations, and the neck keeps the eyes on the foe.
## The pose starts from the normal guard rather than doubling an authored Proto slip with another procedural bend.
## A final neck / glove guard keeps the sum of every layer below (rocked, fatigue, duck clip, defence hinge) natural: the neck stays within
## NECK_* of the spine axis and the gloves are pulled to the face when a duck or lean has dragged them away.
##
## Order on the Skeleton3D: after DefencePose, before ContactPose / AlivePose / HitFlinch / PoseLimiter.

const D := PI / 180.0
const HitFitScript := preload("res://scripts/fighter/hit_fit.gd")
const BodyVolumes := preload("res://scripts/fighter/body_volumes.gd")
const BASE_W := 32.0        ## Round 4 short: a loaded slip and recovery each fit inside roughly 0.17 s (4.83 / 5.00 / 5.17 s).
const W_RELEASE := 0.72     ## forward / back leans return in ~0.25 s (a let-go stick, no pop)

## Lateral slip (Fight Night Round 4): a follow-through chain. The pelvis follows the (eased) stick closely; the lumbar spine, the
## thorax and finally the head follow it with increasing lag (head ~0.06 s after the chest, a little overshoot). The trunk side-bends,
## pitches towards the foe and turns a little to the slip side; the neck EXTENDS so the face stays up and toward the foe; the pelvis
## shifts opposite the head and sinks (knees flex, feet planted). Entry / return speed comes from the stick; the spring only eases it.
const W_SIDE := 22.0          ## side spring rate (critically damped): bottom ~0.18 s after a step, an S-curve without a pop
const LUMBAR_TAU := 0.018
const THORAX_TAU := 0.040
const HEAD_W := 32.0          ## head follower: underdamped spring on the thorax value (delay ~2*zeta/w ~ 0.055 s, ~7 % overshoot)
const HEAD_ZETA := 0.65
const SIDE_G0 := 0.36         ## a held slip keeps deepening for ~0.6 s: starts at this share of its full lateral depth (Round 4 clip A: trunk lean -10 -> -38 deg)
const REL_TAP := 1.5          ## a tap / flick (stick held < ~0.2 s) comes back as quickly as it went (clip C: a bob)
const REL_QUICK_LEFT_SCALE := 1.0    ## a quick slip to the left (clip B) is back to guard by about +0.9 s
const STICK_RIGHT_GAMMA := 0.62
const REL_HELD_RIGHT_SCALE := 0.55   ## a held slip to the right returns over about 0.55 s (Fight Night A: the roll is still -12 deg 0.35 s after the stick is released)
const SWITCH_RATE_SCALE := 0.85
const W_SIDE_RELEASE := 18.0   ## a let-go side slip is home (10 %) in ~0.2 s: slower than the entry, still no pop
const W_BACK_RELEASE := 20.0   ## lean back / forward bob
const HEAD_MOVE_SPREAD := 0.35 ## how much of the roster head-movement stat shows in the slip speed (0 = every fighter the same)
const CREEP_RATE := 10.0       ## a held slip is at its full depth ~0.1 s after the press (was a 0.6 s creep)
const REL_HELD := 0.27        ## a held lean comes back over ~0.4 s, eased
## Hip hinge: the forward pitch lives in the PELVIS (hip joint), a little in the lumbar spine and only a few degrees in the thorax, so the
## back stays flat and the head leads on a visible neck. Side-bend is pelvis roll + lumbar; the thorax stays almost rigid (no hump).
const HINGE_SHARE := 0.62
const HINGE_SHARE_DUCK := 0.80      ## the forward duck folds at the hip joint (thigh / pelvis), the back stays flat
const LUMBAR_SHARE_DUCK := 0.18
const THORAX_SHARE_DUCK := 0.10
const DUCK_TWIST_DEG := 16.0         ## spine yaw towards the slip side in the forward duck
const COLLAR_BACK_DEG := 8.0         ## forward duck: the shoulders are drawn back, flattening the upper-back hump
const HIP_FOLLOW_TAU_UP := 0.045     ## s: the pelvis / knees follow the lean a touch behind the trunk
const HIP_SHIFT_TAU_HELD := 0.10     ## s: after a held slip the pelvis stays shifted over the return (Fight Night A: still 55 % shifted 0.45 s after the release)
const HIP_FOLLOW_TAU_DOWN_SIDE := 0.06  ## s: a pure side slip (A, B) unfolds quicker than a forward duck
const HIP_FOLLOW_TAU_DOWN := 0.10    ## s: and unfold much later, so the legs are still about half bent when the trunk is back (clip C: +0.6 s)
const LUMBAR_SHARE := 0.25
const THORAX_SHARE := 0.13
const THORAX_PITCH_CAP_DEG := 6.0
const LUMBAR_ROLL_DEG := 6.0   ## slips to the fighter's right (clip A): more of the lean in the waist, the thorax counter-rolls
const LUMBAR_ROLL_LEFT_DEG := 8.0   ## slips to the left (clip B)
const THORAX_ROLL_START_DEG := 19.0
const THORAX_ROLL_DEG := -22.0   ## counter-roll: the shoulders stay nearly level while the whole trunk leans (Round 4: shoulder tilt only -10..-13 deg)
const SIDE_ROLL_DEG := 22.0   ## total side-bend at full input (pelvis + lumbar + thorax + dip, used by the head follower)
const SIDE_PITCH_DEG := 15.0          ## trunk forward pitch per unit of side lean, slips to the fighter's left (clip B)
const SIDE_PITCH_RIGHT_DEG := 25.0    ## slips to the right (clip A): the Fight Night trunk pitches -25 deg while the head stays up and the face shows
const HEAD_SIDE_PITCH_KEEP := 0.35    ## share of the side-lean trunk pitch the head keeps (the neck extends: face stays visible from the front)
const HEAD_FWD_PITCH_KEEP := 0.8      ## the head follows (and a little exceeds) the forward-duck pitch: neck flexes, head leads down and forward (clip C)
const NECK_FLEX_FWD_DEG := 5.0       ## forward duck (clip C): the neck flexes, head goes down and forward of the trunk (Fight Night neck angle 146 -> 118)
const NECK_FLEX_SIDE_RIGHT_DEG := 9.0   ## slips to the right (clip A): neck lateral flex toward the slip at the hold
const NECK_FLEX_SIDE_LEFT_DEG := 8.0     ## slips to the left (clip B): the same, smaller
const GLOVE_SHOULDER_ANCHOR := 0.65      ## share of the head's lateral offset from the shoulders the guard hands do not follow (no splay)
const NECK_PROTRACT_SIDE_RIGHT := 1.4 ## right slips (clip A): the head leads past the shoulders and sinks relative to them (Fight Night: head drops 0.16 cell, shoulders 0.09)
const NECK_PROTRACT_SIDE := 0.4       ## side-lean share of the neck protraction (the forward duck gets the rest)
const COLLAR_DEPRESS_DEG := 12.0  ## both shoulders are pulled down (no shrug / hump) as the slip deepens; the slip side a little more
const COLLAR_SLIP_EXTRA_DEG := 3.0  ## the trunk pitches toward the foe (the front view hides it)
const SIDE_SPINE_YAW_DEG := 6.0   ## towards the slip side
const SIDE_HIP_SHIFT_LEFT := 0.015   ## slips to the fighter's left (clips B, C): the pelvis travels about half the head's lateral travel
const SIDE_HIP_SHIFT := 0.14  ## pelvis travels WITH the head onto the slip-side leg (m); the knees bend, the feet stay planted
const SIDE_HIP_BACK := -0.05  ## the hips sit back as the trunk hinges forward
const SIDE_DROP := 0.05      ## hip sink (knees flex as the feet stay planted)
const SIDE_HIP_YAW_DEG := 12.0
const SIDE_HIP_ROLL_DEG := 30.0
const SIDE_HIP_ROLL_RIGHT_DEG := 23.0   ## right slips (clip A): less pelvis roll, so the trunk roll lands on -35 deg
const SIDE_HEAD_FOLLOW := 0.40 ## (unused by the stabilised head; kept for the y-lean neck rule)
const HEAD_ROLL_DEG := 6.0
const HEAD_ROLL_START_DEG := 15.0   ## world roll of the head at full slip (ear towards the slip-side shoulder); the head is stabilised, not carried
const HEAD_PITCH_KEEP := 0.65    ## share of the trunk's forward pitch the head keeps
const NECK_PROTRACT_DEG := 15.0
const HEAD_EXT_DEG := 7.0     ## chin lifted a little: face up and out at the foe
const SIDE_HEAD_PITCH_SHARE := -0.10  ## how much of the trunk pitch the head keeps in a slip (the neck extends the rest)
const ROLL_DEG := 20.0
const PITCH_SIDE_DEG := 35.0
const PITCH_FWD_DEG := 32.0
const PITCH_BACK_DEG := 36.0
const PULL_CHIN_LIFT_DEG := 12.0
const HIP_SIDE := 0.04
const HIP_SIDE_FWD := -0.09  ## hips sit behind the head as the trunk folds into the slip
const HIP_FWD := -0.03   ## hips sit back as the duck sinks (thigh angle reads from the flank)
const HIP_BACK := 0.12
const DROP_SIDE := 0.15
const DROP_FWD := 0.26
const DROP_BACK := 0.02

## A small extra shoulder dip at full input, without a second hip/waist displacement budget.
const DEPTH_DIP_DEG := 0.0
const SETTLED_GUARD_PITCH_DEG := 15.0  ## forward-set boxing guard; handed off to the analog lean as it deepens
const SETTLED_GUARD_HEAD_SHARE := 0.75  ## retain the opponent-facing head orientation as the torso folds
const COUNTER_PLANT := 0.85    ## share of the counter clip's foot travel that is cancelled (feet stay near the slip stance)
const COUNTER_REACH_NEAR := 0.80
const COUNTER_REACH_FAR := 0.95
const COUNTER_REACH_SHARE := 0.88
const CHEST := [["chestLower", 0.5], ["chestUpper", 0.5]]
const LUMBAR_ONLY := [["abdomenLower", 0.5], ["abdomenUpper", 0.5]]
const THORAX_ONLY := [["chestLower", 0.5], ["chestUpper", 0.5]]
const LUMBAR := [["abdomenLower", 0.15], ["abdomenUpper", 0.20]]
const THORAX := [["chestLower", 0.30], ["chestUpper", 0.35]]

## Round 6: the guard rides the body. The glove on the side AWAY from the slip drops to the belt line (Fight Night: ~0.75 torso lengths
## below the shoulder mid-point) and follows the trunk with a 2-3 frame lag (overlap); the slip-side glove tracks the head lower and a bit wider.
const GUARD_DROP_TAU_IN := 0.03   ## s: the trailing glove lags the trunk on entry (~2 frames at 30 fps)
const GUARD_DROP_TAU_OUT := 0.06   ## s: and lags a little more on the way back (it returns as the slip returns)
const GLOVE_FOLLOW_TAU := 0.045    ## s: low-pass of the glove goal in fighter space while the lean drives it (overlap / drag)
const BELT_BELOW_SHOULDERS := 0.32 ## m: trailing glove centre below the shoulder mid-point at full drop (0.75 torso lengths of ~0.45 m)
const BELT_FORWARD := 0.14         ## m: and this far in front of the shoulders
const BELT_SIDE := 0.05            ## m: and this far towards its own side of the body
const SIDE_TAP_SINK_EXTRA := 0.03  ## extra hip sink coefficient for a tap to the fighter's left (clip B: head drop 0.33 torso lengths)
const SIDE_G0_RIGHT := 0.62
const CREEP_RIGHT_BOOST := 1.3
const SLIP_RIGHT_HIP_RISE := 0.012    ## m: the pelvis rises a little in a slip to the right, so the shoulders sink about half as far as the head (Fight Night A: 0.09 vs 0.16 cell)
const SIDE_RIGHT_DROP_BONUS := 0.05   ## a slip to the right sinks as far as one to the left (a little further): Fight Night's head dips as much on either side
const SLIP_KNEE_FLEX := 0.035      ## m of extra hip sink, ramped with the lagged slip depth (both knees flex more as the slip deepens)
const THORAX_ROLL_RIGHT_HELD_DEG := -17.0   ## the counter-roll relaxes as the held slip deepens (the bowed trunk rolls the shoulders more)
const THORAX_ROLL_RIGHT_DEG := -40.0  ## slips to the fighter's right (clip A): the shoulder line stays level from the start (Fight Night: ~-10 deg throughout)
const DRIFT_ROLL_DEG := 1.6        ## hold drift: slow continuous sway of the lean (not a frozen pose)

const NECK_FWD := 24.0
const NECK_BACK := 38.0
const NECK_SIDE := 20.0

var pos := Vector2.ZERO
var deep_w := 0.0              ## |pos| that only falls slowly (~0.25 s): the pose limiter's deep allowance must not collapse while a side switch passes through centre
var vel := Vector2.ZERO
var seg_l := Vector2.ZERO     ## follow-through chain values (same units as pos): lumbar, thorax, head
var seg_c := Vector2.ZERO
var seg_h := Vector2.ZERO
var _head_v := Vector2.ZERO
var _hs := 0.0                ## lagged lateral lean for the pelvis shift (a held slip keeps its body shifted over the return)
var _sway_ref := 0.0          ## hip lateral (fighter space) when the slip started: the idle clip's own sway is cancelled from there
var _sway_have := false
var _hl := Vector2.ZERO        ## lagged lean (pelvis / knees): quick down, slow up
var _gb := 0.0                ## lagged belt-drop weight of the left glove (right slips and the forward duck; not clip B)
var _wr := 0.0                ## 1 for a slip to the fighter's right
var _gd := 0.0                ## 0..1 lagged slip depth that drives the guard drop and knee flex
var _gd_dir := 0.0            ## side of the last slip: + = lean to the fighter's left (so the trailing glove is the right one)
var _gl_mem := {}             ## per hand: low-passed glove goal in fighter space
var _pdt := 0.016
var _press_t := 0.0           ## how long the stick has been held out (|target| > 0.5)
var _last_press := 1.0
var _creep := 0.0             ## 0..1 slow deepening while the lean is held
var _hold_t := 0.0            ## time held at depth (slow settle / breathing)
var _clock := 0.0
var _side_hold_time := 0.0  ## continuous deep lateral input, used to relax a held guard
var _side_hold_dir := 0.0
var target := Vector2.ZERO
var speed := 1.0
var auth_k := 1.0            ## procedural lean over the current guard/punch; fades out only for a counter containing its own lean
var duck_w := 0.0            ## 0..1 weight of the authored duck / roll (set by the fighter), relaxes the neck limits
## diagnostics
var neck_cut := Vector2.ZERO  ## deg removed from the neck (pitch, roll) on the last pass
var glove_pull := 0.0
var guard_wrist_turn_deg := 0.0
var guard_wrist_angles := {}
var counter_entry_weight := 0.0
var counter_entry_drop := 0.0
var counter_reach_trim := 0.0
var straight_chamber_weight := 0.0

var _feet_mem := {}
var _counter_w := 0.0
var _rest := Vector2.ZERO     ## neck vs spine angle (pitch, roll) of the idle guard
var _rest_set := false
var _last_body := {}
var _counter_body := {}
var _counter_serial := -1
var _settled_guard := 0.0
var _last_hands := {}
var _straight_entry := {}
var _straight_entry_serial := -1


func magnitude() -> float:
	return pos.length()


## Physics tick (fighter): spring towards the target.
func tick(dt: float) -> void:
	var f = fighter
	var slow := 1.0 - 0.25 * float(f.fatigue) - (0.25 if (f.hurt.active() or f.rocked) else 0.0)
	var k := lerpf(1.0, speed, HEAD_MOVE_SPREAD) * clampf(slow, 0.4, 1.2)
	var wy := BASE_W * k
	var wx := W_SIDE * k
	var tgt_x := target.x
	if tgt_x < 0.0:
		tgt_x = -pow(-tgt_x, STICK_RIGHT_GAMMA)   # slips to the right: front-loaded response (Fight Night A is a third of the way in by +0.2 s)
	# Fight Night quick slip: the same fast spring in, a slightly softer one out. A switch to the other side keeps the entry rate
	# (the target passes through centre, the spring never stops there).
	if absf(target.y) < absf(pos.y) - 0.02:
		wy = W_BACK_RELEASE * k
	if absf(tgt_x) < absf(pos.x) - 0.02:
		wx = W_SIDE_RELEASE * k
	var zx := 0.78 if absf(tgt_x) >= absf(pos.x) - 0.02 else 1.0   # a touch of overshoot on entry, critically damped on release
	if signf(tgt_x) * signf(pos.x) < 0.0 and absf(pos.x) > 0.15 and absf(tgt_x) > 0.3:
		wx *= SWITCH_RATE_SCALE   # a side-to-side switch: through centre in ~0.2 s without a stop (the head still never rests at centre)
	var n := maxi(1, int(ceilf(dt / 0.004)))
	var h := dt / float(n)
	var a_l := 1.0 - exp(-h / LUMBAR_TAU)
	var a_c := 1.0 - exp(-h / THORAX_TAU)
	var hw := HEAD_W * k
	for i in n:
		vel.x += (wx * wx * (tgt_x - pos.x) - 2.0 * zx * wx * vel.x) * h
		vel.y += (wy * wy * (target.y - pos.y) - 2.0 * wy * vel.y) * h
		pos += vel * h
		seg_l += (pos - seg_l) * a_l
		seg_c += (seg_l - seg_c) * a_c
		_head_v += (hw * hw * (seg_c - seg_h) - 2.0 * HEAD_ZETA * hw * _head_v) * h
		seg_h += _head_v * h
	_clock += dt
	deep_w = maxf(pos.length(), deep_w - dt / 0.25)
	var gt := smoothstep(0.08, 0.50, absf(pos.x)) * smoothstep(0.0, 0.08, absf(pos.x))
	var gtb := gt * lerpf(1.0, smoothstep(0.1, 0.4, pos.y), smoothstep(-0.05, 0.12, pos.x))
	_gb += (gtb - _gb) * (1.0 - exp(-dt / (GUARD_DROP_TAU_IN if gtb > _gb else GUARD_DROP_TAU_OUT)))
	for ax_i in 2:
		var tgt_i: float = pos[ax_i]
		var cur_i: float = _hl[ax_i]
		_hl[ax_i] = cur_i + (tgt_i - cur_i) * (1.0 - exp(-dt / (HIP_FOLLOW_TAU_UP if absf(tgt_i) > absf(cur_i) else lerpf(HIP_FOLLOW_TAU_DOWN_SIDE, HIP_FOLLOW_TAU_DOWN, smoothstep(0.1, 0.35, absf(_hl.y))))))
	var hs_tau := lerpf(HIP_FOLLOW_TAU_DOWN_SIDE, HIP_SHIFT_TAU_HELD, smoothstep(0.6, 0.95, _creep))
	_hs += (pos.x - _hs) * (1.0 - exp(-dt / (0.08 if absf(pos.x) > absf(_hs) else hs_tau)))
	_gd += (gt - _gd) * (1.0 - exp(-dt / (GUARD_DROP_TAU_IN if gt > _gd else GUARD_DROP_TAU_OUT)))
	if absf(pos.x) > 0.12:
		_gd_dir = signf(pos.x)
	if target.length() > 0.5:
		_press_t += dt
		_creep = move_toward(_creep, 1.0, dt * CREEP_RATE)
	else:
		if _press_t > 0.0:
			_last_press = _press_t
		_press_t = 0.0
		if pos.length() < 0.05:
			_creep = 0.0
	if absf(pos.x) > 0.8 and absf(target.x) > 0.5:
		_hold_t += dt
	else:
		_hold_t = move_toward(_hold_t, 0.0, dt * 2.5)
	if pos.length() > 1.05:
		pos = pos.normalized() * 1.05
	var held_dir := signf(target.x) if absf(target.x) > 0.6 else 0.0
	if held_dir != 0.0:
		if _side_hold_dir != 0.0 and held_dir != _side_hold_dir:
			_side_hold_time = 0.0
		_side_hold_dir = held_dir
	if held_dir != 0.0 and signf(pos.x) == held_dir and absf(pos.x) > 0.6:
		_side_hold_time = minf(_side_hold_time + dt, 0.30)
	else:
		_side_hold_time = move_toward(_side_hold_time, 0.0, dt * 3.0)
	if target == Vector2.ZERO and pos.length() < 0.004 and vel.length() < 0.02:
		pos = Vector2.ZERO
		vel = Vector2.ZERO
		seg_l = Vector2.ZERO
		seg_c = Vector2.ZERO
		seg_h = Vector2.ZERO
		_head_v = Vector2.ZERO


## Knocks the lean (a hit while leaning): `push` in the fighter frame (x left, y forward), magnitude ~0.3 = a clear shove.
func nudge(push: Vector2) -> void:
	vel += push * BASE_W * 0.9


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or not _fighter_ok():
		return
	_ready_bones(sk)
	_restore(sk)
	_pdt = clampf(dt, 0.001, 0.1)
	counter_reach_trim = 0.0
	straight_chamber_weight = 0.0
	if not _standing():
		_side_hold_time = 0.0
		_side_hold_dir = 0.0
		_last_body.clear()
		_counter_body.clear()
		_counter_serial = -1
		_settled_guard = 0.0
		_last_hands.clear()
		_gl_mem.clear()
		_straight_entry.clear()
		_straight_entry_serial = -1
		return
	_frame(sk)
	var f = fighter
	# The source starts and ends in the same compact asymmetric guard as the slip. Let it settle
	# at engagement range so entering/releasing a lean does not lift the lead glove to an earmuff.
	var neutral_guard: bool = f.rules == "boxing" and f.state in [f.State.IDLE, f.State.SLIP] and f.gap_to_foe() < 1.22 \
			and not f.inp.block and not f.hurt.active() and not f.stats.rocked and f.fatigue < 0.25
	_settled_guard = move_toward(_settled_guard, 1.0 if neutral_guard else 0.0, dt * 12.0)
	# Set the guarded torso forward, then hand its pitch over to the slip instead of stacking
	# both bends at full input. Keep the head closer to its original orientation as the torso moves.
	var guard_posture := _settled_guard * (1.0 - smoothstep(0.15, 0.80, pos.length()))
	_rot_chain(sk, SPINE, SETTLED_GUARD_PITCH_DEG * D * guard_posture, 0.0, 0.0)
	_rot_chain(sk, NECK, -SETTLED_GUARD_PITCH_DEG * SETTLED_GUARD_HEAD_SHARE * D * guard_posture, 0.0, 0.0)
	if f.state == f.State.ATTACK and not f.atk.is_empty() and f.atk["s"].has("counter_clip"):
		_plant_counter(sk)
	else:
		_feet_mem = _feet_begin(sk)   # (the feet of the lean / guard pose the counter starts from)
		_counter_w = 0.0
	var counter_hand := {}
	if f.state == f.State.ATTACK and not f.atk.is_empty() and (f.atk["s"].has("counter_clip") or String(f.atk["tag"]).contains("Jab")):
		counter_hand = {"pose": sk.get_bone_global_pose(_bone[String(f.atk["limb"])])}
		if not f.atk["s"].has("counter_clip"):
			counter_hand["pose"] = _straight_chamber_target(sk, counter_hand["pose"])
	var m := pos.length()
	if m > 0.004 or _hl.length() > 0.01:
		_apply_lean(sk)
	_counter_entry(sk, counter_hand)
	if m > 0.004 and not counter_hand.is_empty() and not f.atk["s"].has("counter_clip"):
		# Jabs and crosses thrown from a slip retain the animation's target lane. Rotating the
		# whole arm with the trunk otherwise turns a head jab into a downward body punch.
		_keep_striking_hand(sk, String(f.atk["limb"]), counter_hand["pose"], false)
	_guard_neck_and_gloves(sk, m)
	_last_body = {"hip": fighter.to_local(sk.global_transform * _o(sk, "hip")),
		"head": fighter.to_local(sk.global_transform * _o(sk, "head"))}
	var to_fighter := fighter.global_transform.affine_inverse() * sk.global_transform
	for hand in ["lHand", "rHand"]:
		_last_hands[hand] = to_fighter * sk.get_bone_global_pose(_bone[hand])


## A counter leaves the actual loaded guard, rather than first visiting the jab clip's high
## idle wrist. Store the incoming hand in fighter space so root movement does not drag it.
func _straight_chamber_target(sk: Skeleton3D, authored: Transform3D) -> Transform3D:
	var f = fighter
	if not bool(f.atk.get("counter", false)) or String(f.atk["s"].get("zone", "")) != "head":
		_straight_entry.clear()
		_straight_entry_serial = -1
		return authored
	var hand: String = f.atk["limb"]
	if int(f.atk["serial"]) != _straight_entry_serial:
		_straight_entry_serial = int(f.atk["serial"])
		_straight_entry.clear()
		if pos.length() > 0.35 and _last_hands.has(hand):
			_straight_entry["pose"] = _last_hands[hand]
	if _straight_entry.is_empty():
		return authored
	var peak: float = float(f.atk["s"]["t_peak"]) * float(f.atk["k"])
	var u := smoothstep(peak * 0.05, peak * 0.65, float(f.atk["t"]))
	straight_chamber_weight = 1.0 - u
	if u >= 0.999:
		return authored
	var incoming: Transform3D = sk.global_transform.affine_inverse() * fighter.global_transform * (_straight_entry["pose"] as Transform3D)
	var a := incoming.basis.orthonormalized().get_rotation_quaternion()
	var b := authored.basis.orthonormalized().get_rotation_quaternion()
	return Transform3D(Basis(a.slerp(b, u)), incoming.origin.lerp(authored.origin, u))


## The counter clips start from a shallower authored slip than the calibrated analog pose. Keep the incoming
## loaded body through startup, then release it continuously as the counter uncoils. The striking glove stays
## on the clip's full transform, so this changes the body transition rather than retargeting the live punch.
func _counter_entry(sk: Skeleton3D, counter_hand: Dictionary) -> void:
	var f = fighter
	counter_entry_weight = 0.0
	counter_entry_drop = 0.0
	if f.state != f.State.ATTACK or f.atk.is_empty() or not f.atk["s"].has("counter_clip"):
		_counter_serial = -1
		_counter_body.clear()
		return
	if int(f.atk["serial"]) != _counter_serial:
		_counter_serial = int(f.atk["serial"])
		_counter_body = _last_body.duplicate()
	if _counter_body.is_empty():
		return
	var peak: float = float(f.atk["s"]["t_peak"]) * float(f.atk["k"])
	var t: float = f.atk["t"]
	var w := 1.0 - smoothstep(peak * 0.22, peak * 0.82, t)
	counter_entry_weight = w
	if w < 0.001:
		return
	var hand: String = f.atk["limb"]
	var hand_idx: int = _bone[hand]
	var hand_pose: Transform3D = counter_hand.get("pose", sk.get_bone_global_pose(hand_idx))
	var feet := _feet_begin(sk)
	var feet_q := {}
	for side in ["l", "r"]:
		feet_q[side] = sk.get_bone_global_pose(_bone[side + "Foot"]).basis.orthonormalized().get_rotation_quaternion()
	var inv := sk.global_transform.affine_inverse()
	var hip_goal: Vector3 = inv * f.to_global(_counter_body["hip"])
	var head_goal: Vector3 = inv * f.to_global(_counter_body["head"])
	var hip := _o(sk, "hip")
	var head := _o(sk, "head")
	var body_now := head - hip
	var body_goal := head_goal - hip_goal
	var offset := (hip_goal - hip).limit_length(0.22) * w
	# _move_hip writes relative to the layer's original pose: include any existing analog lean offset.
	var hip_idx: int = _bone["hip"]
	var before := sk.get_bone_pose_position(hip_idx)
	var parent := sk.get_bone_parent(hip_idx)
	var pb := Basis.IDENTITY if parent < 0 else sk.get_bone_global_pose(parent).basis.orthonormalized()
	if not _base_pos.has(hip_idx):
		_base_pos[hip_idx] = before
	sk.set_bone_pose_position(hip_idx, before + pb.inverse() * offset)
	_written_pos[hip_idx] = sk.get_bone_pose_position(hip_idx)
	counter_entry_drop = -offset.dot(_up)
	if body_now.length() > 0.001 and body_goal.length() > 0.001:
		var q := Quaternion(body_now.normalized(), body_goal.normalized()).normalized()
		var angle := q.get_angle()
		if angle > 0.001:
			_rot_sk(sk, _bone["abdomenLower"], Quaternion(q.get_axis().normalized(), minf(angle, deg_to_rad(24.0)) * w))
	_plant_feet(sk, feet)
	for side in ["l", "r"]:
		var idx: int = _bone[side + "Foot"]
		var cur := sk.get_bone_global_pose(idx).basis.orthonormalized().get_rotation_quaternion()
		_rot_sk(sk, idx, (feet_q[side] as Quaternion) * cur.inverse())
	_keep_striking_hand(sk, hand, hand_pose)


func _keep_striking_hand(sk: Skeleton3D, hand: String, hand_pose: Transform3D, exact_origin := true) -> void:
	var hand_idx: int = _bone[hand]
	var mid := _o(sk, _mid_of(hand))
	var goal := hand_pose.origin
	var f = fighter
	if not exact_origin and bool(f.atk.get("counter", false)) and String(f.atk["s"].get("zone", "")) == "head":
		# The close Round 4 counter drives from a flexed elbow rather than locking the arm.
		# Shorten only a near-range counter's extension along its existing lane; the collision
		# system still decides whether the resulting glove path reaches the opponent.
		var near := 1.0 - smoothstep(COUNTER_REACH_NEAR, COUNTER_REACH_FAR, f.gap_to_foe())
		var shoulder := _o(sk, _root_of(hand))
		var arm_len := shoulder.distance_to(mid) + mid.distance_to(_o(sk, hand))
		var v := goal - shoulder
		var cap := arm_len * lerpf(0.992, COUNTER_REACH_SHARE, near)
		var distance := v.length()
		if near > 0.001 and distance > cap - 0.02:
			var limit := lerpf(distance, minf(distance, cap), smoothstep(cap - 0.02, cap + 0.02, distance))
			goal = shoulder + v.normalized() * limit
			counter_reach_trim = distance - limit
	_ik2(sk, _root_of(hand), _mid_of(hand), hand, goal, mid)
	var current_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
	_rot_sk(sk, hand_idx, hand_pose.basis.orthonormalized().get_rotation_quaternion() * current_q.inverse())
	if not exact_origin:
		return # Ordinary lean punches respect the arm's reachable length rather than extending a wrist bone.
	# A nearly straight arm can make the IK clamp by millimetres. Preserve the hand origin exactly as well.
	if not _base_pos.has(hand_idx):
		_base_pos[hand_idx] = sk.get_bone_pose_position(hand_idx)
	var hand_parent := sk.get_bone_parent(hand_idx)
	var parent_pose := sk.get_bone_global_pose(hand_parent) if hand_parent >= 0 else Transform3D.IDENTITY
	var hand_local := parent_pose.affine_inverse() * hand_pose
	sk.set_bone_pose_position(hand_idx, hand_local.origin)
	_written_pos[hand_idx] = sk.get_bone_pose_position(hand_idx)


## The authored DEF_counter_* clips step into a wide lunge (rear leg stretched far back): keep the feet near where the slip had them,
## the hips follow the clip (knees take the difference), so the counter punches from the slip stance without the big stride.
func _plant_counter(sk: Skeleton3D) -> void:
	if _feet_mem.is_empty():
		return
	_counter_w = move_toward(_counter_w, COUNTER_PLANT, 0.2)
	var cur := _feet_begin(sk)
	var tgt := {}
	for s in ["l", "r"]:
		tgt[s] = (cur[s] as Vector3).lerp(_feet_mem[s], _counter_w)
	_plant_feet(sk, tgt)


func _apply_lean(sk: Skeleton3D) -> void:
	if auth_k < 0.01:
		return
	_frame(sk)
	var lean_k := auth_k
	var f = fighter
	if f.state == f.State.ATTACK and not f.atk.is_empty() and not f.atk["s"].has("counter_clip") and String(f.atk["tag"]).contains("Jab"):
		# A jab/cross uncoils out of its loaded slip as the hand extends. Keeping the full trunk
		# fold under a head-height wrist target exhausts reach and kinks the shoulder silhouette.
		var peak: float = float(f.atk["s"]["t_peak"]) * float(f.atk["k"])
		var t: float = f.atk["t"]
		var marked_head: bool = bool(f.atk.get("counter", false)) and String(f.atk["s"].get("zone", "")) == "head"
		var rise := smoothstep(peak * (0.05 if marked_head else 0.15), peak * (0.40 if marked_head else 0.95), t)
		var reload := smoothstep(float(f.atk["A"]) * 0.65, float(f.atk["A"]) * 0.98, t)
		# The primary Round 4 counter stays low through extension. A marked counter retains
		# more of that loaded pose; an ordinary straight still unwinds more fully.
		var unwind := 0.60 if bool(f.atk.get("counter", false)) else 0.85
		lean_k *= 1.0 - unwind * rise * (1.0 - reload)
	# creep: a held slip keeps deepening (lateral terms only); a tap stays at its shallower initial depth
	# slips to the fighter's right (clip A) start deeper and deepen faster: the Fight Night trunk lean is -27 deg by +0.6 s of a held slip
	var wr := 1.0 - smoothstep(-0.05, 0.12, pos.x)
	_wr = wr
	var gx := lerpf(lerpf(SIDE_G0, SIDE_G0_RIGHT, wr), 1.0, clampf(_creep * lerpf(1.0, CREEP_RIGHT_BOOST, wr), 0.0, 1.0))
	var P := Vector2(pos.x * gx, pos.y)
	var SL := Vector2(seg_l.x * gx, seg_l.y)
	var SC := Vector2(seg_c.x * gx, seg_c.y)
	var SH := Vector2(seg_h.x * gx, seg_h.y)
	var x := P.x * lean_k
	var ax := absf(x)
	var yf := maxf(pos.y, 0.0) * lean_k
	var yb := maxf(-pos.y, 0.0) * lean_k
	var dk := clampf(lean_k, 0.0, 1.0)
	var feet := _feet_begin_poled(sk, smoothstep(0.02, 0.20, maxf(pos.length(), _hl.length())))   # knees over the toes as the slip engages (no knee jump at its onset)
	var foot_rot := {}
	for side in ["l", "r"]:
		foot_rot[side] = sk.get_bone_global_pose(_bone[side + "Foot"]).basis.orthonormalized().get_rotation_quaternion()
	var head_q0 := sk.get_bone_global_pose(_bone["head"]).basis.orthonormalized().get_rotation_quaternion()
	var sgn := signf(x)
	var settle := smoothstep(0.0, 0.55, _hold_t) * smoothstep(0.7, 1.0, ax)
	var breath := sin(_clock * 4.6) * smoothstep(0.7, 1.0, ax)
	# pelvis: shifts onto the slip-side leg, sinks a little (knees flex), hinges forward, rolls with the lean
	var sink_pos := smoothstep(-0.05, 0.12, SC.x)   # 1 for a slip to the fighter's left (clip B), 0 to the right (clip A)
	var drift := (sin(_clock * 1.7) * 0.6 + sin(_clock * 2.9 + 1.3) * 0.4) * smoothstep(0.55, 1.0, ax)
	# pelvis / knees follow the LAGGED lean: quick down, slow to unfold (the legs are still part bent when the trunk is back up)
	var hsink_pos := smoothstep(-0.05, 0.12, _hl.x)
	var hpx := _hl.x * gx * lean_k
	var hax := absf(hpx)
	var hyf := maxf(_hl.y, 0.0) * lean_k
	var hyb := maxf(-_hl.y, 0.0) * lean_k
	var tap_sink := 0.10 * lerpf(1.0, 1.0, hsink_pos) + SIDE_TAP_SINK_EXTRA * hsink_pos * (1.0 - smoothstep(0.1, 0.4, _hl.y))
	# the idle clip's own lateral sway pushes the hips the wrong way before / after a slip: hold the hip where it was when the slip started
	var hip_lat: float = fighter.to_local(sk.global_transform * _o(sk, "hip")).x
	var e_sw := smoothstep(0.03, 0.40, maxf(absf(pos.x), absf(_hs)))
	if e_sw < 0.002 or not _sway_have:
		_sway_ref = hip_lat
		_sway_have = true
	var sway_fix := -(hip_lat - _sway_ref) * e_sw
	var hsx := _hs * gx * lean_k
	var hv := lerpf(x, hsx, 0.6)   # one variable, one piecewise-linear coefficient: the pelvis shift is continuous when a switch passes through centre
	var d := _left * (maxf(hv, 0.0) * SIDE_HIP_SHIFT_LEFT + minf(hv, 0.0) * SIDE_HIP_SHIFT + sway_fix) + _fwd * (hax * SIDE_HIP_BACK + hyf * HIP_FWD - hyb * HIP_BACK) 			- _up * (hax * lerpf(tap_sink - 0.10 * wr, SIDE_DROP * (1.0 + SIDE_RIGHT_DROP_BONUS * wr), _creep) + _gd * (SLIP_KNEE_FLEX * (1.0 + SIDE_RIGHT_DROP_BONUS * wr)) * dk + settle * 0.008 + breath * 0.005 + hyf * DROP_FWD + hyb * DROP_BACK)
	_move_hip(sk, d)
	var pf_pelvis := _pitch_fwd(P) * lean_k * D
	var fy := smoothstep(0.12, 0.45, P.y) * dk     # the forward duck folds at the hip joint, not the back
	var hinge := lerpf(HINGE_SHARE, HINGE_SHARE_DUCK, fy)
	var lumbar_share := lerpf(LUMBAR_SHARE, LUMBAR_SHARE_DUCK, fy)
	var thorax_share := lerpf(THORAX_SHARE, THORAX_SHARE_DUCK, fy)
	_rot_axis(sk, "hip", _left, pf_pelvis * hinge)
	_rot_axis(sk, "hip", _up, x * SIDE_HIP_YAW_DEG * D)
	_rot_axis(sk, "hip", _fwd, -x * lerpf(SIDE_HIP_ROLL_DEG, SIDE_HIP_ROLL_RIGHT_DEG, wr) * D)
	_plant_feet(sk, feet)
	for side in ["l", "r"]:
		var idx: int = _bone[side + "Foot"]
		var cur := sk.get_bone_global_pose(idx).basis.orthonormalized().get_rotation_quaternion()
		_rot_sk(sk, idx, (foot_rot[side] as Quaternion) * cur.inverse())
	# hold drift: the lean keeps breathing a little
	var hold_roll := -sgn * (settle * 2.0 + breath * 1.4 + drift * DRIFT_ROLL_DEG) * D * dk
	var hold_pitch := (settle * 1.2 + breath * 0.8) * D * dk
	var pf_l := _pitch_fwd(SL) * lean_k * D
	var pf_c := _pitch_fwd(SC) * lean_k * D
	var pb_l := _pitch_back(SL) * lean_k * D
	var pb_c := _pitch_back(SC) * lean_k * D
	var pl := pf_l * lumbar_share - pb_l * 0.35 + hold_pitch
	var pc := minf(pf_c * thorax_share, THORAX_PITCH_CAP_DEG * D) - pb_c * 0.65
	var rl := -_side(SL.x, LUMBAR_ROLL_LEFT_DEG, -LUMBAR_ROLL_DEG) * lean_k * D + hold_roll
	var thorax_roll_l := lerpf(THORAX_ROLL_START_DEG, THORAX_ROLL_DEG, _creep)
	var thorax_roll_r := lerpf(THORAX_ROLL_RIGHT_DEG, THORAX_ROLL_RIGHT_HELD_DEG, _creep)
	# the counter-roll of the shoulders, one piecewise-linear function of the (lagged) chest value: no jump when a switch passes centre
	var rc := -(maxf(SC.x, 0.0) * thorax_roll_l + minf(SC.x, 0.0) * thorax_roll_r) * lean_k * D
	# forward duck: the hip leads a twist that opens the chest towards the foe / camera (the back stops being the visible mass)
	var duck_twist := signf(P.x if absf(P.x) > 0.05 else 1.0) * DUCK_TWIST_DEG * D * fy
	var yl := SL.x * lean_k * SIDE_SPINE_YAW_DEG * D * 0.6 + duck_twist * 0.4
	var yc := SC.x * lean_k * SIDE_SPINE_YAW_DEG * D * 0.4 + duck_twist * 0.6
	_rot_chain(sk, LUMBAR_ONLY, pl, yl, rl)
	_rot_chain(sk, THORAX_ONLY, pc, yc, rc)
	# slipping-side shoulder dips below the other
	var dip := -signf(SC.x) * smoothstep(0.0, 1.0, absf(SC.x)) * dk * DEPTH_DIP_DEG * D
	_rot_chain(sk, CHEST, 0.0, 0.0, dip)
	# shoulders down (no shrug): depress both collars (left collar down = negative roll about the forward axis, right collar down = positive)
	var cw := smoothstep(0.0, 0.8, absf(SC.x)) * dk
	var slip_left := signf(SC.x)
	_rot_axis(sk, "lCollar", _fwd, -(COLLAR_DEPRESS_DEG + maxf(slip_left, 0.0) * COLLAR_SLIP_EXTRA_DEG) * cw * D)
	_rot_axis(sk, "rCollar", _fwd, (COLLAR_DEPRESS_DEG + maxf(-slip_left, 0.0) * COLLAR_SLIP_EXTRA_DEG) * cw * D)
	_rot_axis(sk, "lCollar", _left, -COLLAR_BACK_DEG * fy * D)
	_rot_axis(sk, "rCollar", _left, -COLLAR_BACK_DEG * fy * D)
	# neck: legacy rule for forward / back leans, then (lateral slips) the stabilised head
	var hx := SH.x * lean_k
	var hy := SH.y * lean_k
	var trunk_pitch := pf_pelvis * hinge + pl + pc
	var trunk_roll := -x * lerpf(SIDE_HIP_ROLL_DEG, SIDE_HIP_ROLL_RIGHT_DEG, wr) * D + rl + rc + dip
	var share := lerpf(SIDE_HEAD_PITCH_SHARE, 0.80, clampf(absf(hy) * 1.2, 0.0, 1.0))
	var head_pitch := _seg_pitch(SH, lean_k) * share
	var neck_pitch := head_pitch - trunk_pitch - maxf(-hy, 0.0) * PULL_CHIN_LIFT_DEG * D
	# the head leads the chest sideways: the neck flexes toward the slip side on top of the (lagged) head follower, so the head sinks and
	# tilts relative to the shoulder line (Fight Night A: eye line -26 deg against a shoulder line of -10 deg)
	var neck_flex := -(maxf(hx, 0.0) * NECK_FLEX_SIDE_LEFT_DEG + minf(hx, 0.0) * NECK_FLEX_SIDE_RIGHT_DEG) * D
	var neck_roll := -hx * SIDE_ROLL_DEG * D * SIDE_HEAD_FOLLOW - trunk_roll + neck_flex
	var neck_yaw := -(x * SIDE_HIP_YAW_DEG * D + 0.65 * yc + 0.35 * yl) * 0.9
	_rot_chain(sk, NECK, neck_pitch, neck_yaw, neck_roll)
	# Stabilised head: roll / yaw follow the lagged head value (guard orientation + a small ear-to-shoulder tilt), but the head keeps
	# most of the trunk's forward pitch (chin slightly tucked, eyes up) and the neck protracts so the head LEADS past the shoulder line.
	var w_lat := smoothstep(0.03, 0.40, absf(hx) + absf(hy) * 0.8)
	if w_lat > 0.001:
		var fwd_head := (_side(SH.x, SIDE_PITCH_DEG, SIDE_PITCH_RIGHT_DEG) * HEAD_SIDE_PITCH_KEEP + maxf(SH.y, 0.0) * PITCH_FWD_DEG * HEAD_FWD_PITCH_KEEP) * lean_k * D
		var q_t := Quaternion(_fwd, -hx * lerpf(HEAD_ROLL_START_DEG, HEAD_ROLL_DEG, _creep) * D) * Quaternion(_left, fwd_head - absf(hx) * HEAD_EXT_DEG * D) * head_q0
		var q_now := sk.get_bone_global_pose(_bone["head"]).basis.orthonormalized().get_rotation_quaternion()
		var delta := (q_t * q_now.inverse()).normalized()
		var ang := delta.get_angle()
		if ang > 0.0005:
			if ang > PI:
				ang -= TAU
			var axis := delta.get_axis().normalized()
			for e in NECK:
				_rot_sk(sk, _bone[e[0]], Quaternion(axis, ang * w_lat * float(e[1])))
		# neck protraction: the two lower neck bones lean forward, the head bone gives the angle back (head moves forward, same orientation)
		var prot_p := _side(SH.x, SIDE_PITCH_DEG * NECK_PROTRACT_SIDE, SIDE_PITCH_DEG * NECK_PROTRACT_SIDE_RIGHT) + maxf(SH.y, 0.0) * PITCH_FWD_DEG * 0.4
		var prot := NECK_PROTRACT_DEG * lerpf(1.0, 1.4, 1.0 - smoothstep(-0.05, 0.12, SH.x)) * D * w_lat * clampf(prot_p * lean_k / 30.0, 0.0, 1.2)
		_rot_axis(sk, "neckLower", _left, prot)
		_rot_axis(sk, "neckUpper", _left, prot)
		_rot_axis(sk, "head", _left, -2.0 * prot)
		var flex := NECK_FLEX_FWD_DEG * D * w_lat * clampf(maxf(SH.y, 0.0) * lean_k / 0.55, 0.0, 1.0)
		_rot_axis(sk, "neckLower", _left, flex)
		_rot_axis(sk, "neckUpper", _left, flex)
		_rot_axis(sk, "head", _left, -flex * 0.9)


## Side-dependent magnitude of a lateral value (left slips weigh `a_left`, right slips `a_right`), continuous through zero.
func _side(v: float, a_left: float, a_right: float) -> float:
	return maxf(v, 0.0) * a_left + maxf(-v, 0.0) * a_right


func _pitch_fwd(v: Vector2) -> float:
	return _side(v.x, SIDE_PITCH_DEG, SIDE_PITCH_RIGHT_DEG) + maxf(v.y, 0.0) * PITCH_FWD_DEG


func _pitch_back(v: Vector2) -> float:
	return maxf(-v.y, 0.0) * PITCH_BACK_DEG


func _seg_pitch(v: Vector2, lean_k: float) -> float:
	return (absf(v.x) * SIDE_PITCH_DEG + maxf(v.y, 0.0) * PITCH_FWD_DEG - maxf(-v.y, 0.0) * PITCH_BACK_DEG) * D * lean_k


## Neck stays in line with the spine, gloves stay in front of the face - however many layers stacked on top of each other.
func _guard_neck_and_gloves(sk: Skeleton3D, m: float) -> void:
	neck_cut = Vector2.ZERO
	glove_pull = 0.0
	guard_wrist_turn_deg = 0.0
	guard_wrist_angles.clear()
	var f = fighter
	var w := clampf(maxf(m, duck_w), 0.0, 1.0)
	var calm: bool = f.state == f.State.IDLE and m < 0.02 and duck_w < 0.02 and not f.hurt.active() and f.fatigue < 0.25
	if w < 0.05 and not (calm or not _rest_set):
		if _settled_guard > 0.01:
			_pull_gloves(sk, _settled_guard)
		return
	_frame(sk)
	var spine := _o(sk, "chestUpper") - _o(sk, "abdomenLower")
	var neck := _o(sk, "head") - _o(sk, "neckLower")
	if spine.length() < 1e-4 or neck.length() < 1e-4:
		return
	# neck direction in the spine's own frame: pitch = tilt forward / down, roll = tilt to the fighter's left (+)
	var u := spine.normalized()
	var l := (_left - u * u.dot(_left)).normalized()
	var fw := l.cross(u)
	var rel := Vector2(atan2(neck.dot(fw), neck.dot(u)), atan2(neck.dot(l), neck.dot(u)))
	if calm or not _rest_set:
		# the idle guard defines "in line": the neck / spine angle of this rig at rest (the bone origins are not collinear)
		_rest = rel if not _rest_set else _rest.lerp(rel, 0.05)
		_rest_set = true
	if w < 0.05:
		if _settled_guard > 0.01:
			_pull_gloves(sk, _settled_guard)
		return
	rel -= _rest
	var fwd_max := NECK_FWD * D
	var back_max := NECK_BACK * D
	var side_max := NECK_SIDE * D
	var ex_p := 0.0
	if rel.x > fwd_max:
		ex_p = rel.x - fwd_max
	elif rel.x < -back_max:
		ex_p = rel.x + back_max
	var ex_r := 0.0
	if absf(rel.y) > side_max:
		ex_r = rel.y - signf(rel.y) * side_max
	if absf(ex_p) > 1e-4 or absf(ex_r) > 1e-4:
		ex_p *= w
		ex_r *= w
		neck_cut = Vector2(rad_to_deg(ex_p), rad_to_deg(ex_r))
		# the neck chain only (the head follows it): pitch back about the left axis, roll back about the forward axis
		_rot_chain(sk, NECK, -ex_p, 0.0, ex_r)
	_pull_gloves(sk, maxf(w, _settled_guard))


## A glove that ended up far from the face (duck clip, tired drop on top of a lean) is eased back towards the chin / cheek.
func _pull_gloves(sk: Skeleton3D, w: float) -> void:
	var fit: Dictionary = HitFitScript.FIT.get(fighter.model, {})
	var head := _o(sk, "head")
	if fit.has("head"):
		head = sk.get_bone_global_pose(_bone["head"]) * (fit["head"]["off"] as Vector3)
	var pulled := 0.0
	var own_body := BodyVolumes.build(sk, fighter.model)   # the fighter's own torso hulls: no glove goal is placed inside them
	var sm_g := (_o(sk, "lShldrBend") + _o(sk, "rShldrBend")) * 0.5
	head -= _left * ((head - sm_g).dot(_left) * GLOVE_SHOULDER_ANCHOR * _gd)   # the hands ride with the chest, not out at the head
	for s in ["l", "r"]:
		var hand: String = s + "Hand"
		var el: String = s + "ForearmBend"
		if _bone.get(hand, -1) < 0:
			continue
		var fg = fighter
		if fg.state == fg.State.ATTACK and String(fg.atk.get("limb", "")) == hand:
			_gl_mem.erase(hand)
			continue   # the striking hand is the punch's, not the guard's
		var wrist := _o(sk, hand)
		var glove_off := Vector3.ZERO
		if fit.has(hand):
			glove_off = sk.get_bone_global_pose(_bone[hand]).basis * (fit[hand]["off"] as Vector3)
		var g := wrist + glove_off
		var rel := g - head
		var fwd := rel.dot(_fwd)
		var up := rel.dot(_up)
		var side := rel.dot(_left)
		# Round 4's unblocked lean keeps an asymmetric boxing guard: rear hand by the cheek,
		# lead hand can ride at the chest. Pulling BOTH hands to the same chin box erased that silhouette.
		var blocking: bool = fg.inp.block and fg.stats.guard_lock <= 0.0 and fg.stats.guard > 0.0
		var lead: bool = s == "l"
		var cheek_w := 0.0
		var tf := clampf(fwd, 0.08, 0.43 if lead and not blocking else 0.32)
		var tu := clampf(up, -0.38 if lead and not blocking else -0.18, 0.10)
		var ts := clampf(side, -0.29, 0.29)
		if not blocking and (pos.length() > 0.01 or _settled_guard > 0.01) and duck_w < 0.5:   # (a ducked slip keeps the duck's own guard, hands at the face)
			# Explicit free-hand silhouette: a compact rear guard and a lower lead elbow. Bounds alone never
			# relaxed an already-high idle lead hand, which made every lean read as the same earmuff block.
			var rearward := clampf(-pos.y, 0.0, 1.0)
			var low_hand_w := 1.0 if lead else 0.0
			var compact := smoothstep(0.55, 1.0, pos.length())
			# The near-frontal source keeps the cheek/jaw readable beside the rear glove.
			ts = lerpf(ts, 0.07 if lead else -0.13, 0.9) * lerpf(1.0, 0.62, _gd)   # tighter to the head while slipping (no splay)
			# A sustained lateral slip lets the low hand settle; short slips retain the compact guard.
			var held_drop := 0.03 * smoothstep(0.10, 0.22, _side_hold_time)
			var low_y := lerpf(-0.40, -0.27 - held_drop, compact) + rearward * 0.04
			tu = lerpf(tu, lerpf(lerpf(-0.13, -0.26, compact), low_y, low_hand_w), 0.95)
			tf = lerpf(tf, lerpf(lerpf(0.24, 0.13, compact), lerpf(0.22, 0.12, compact), low_hand_w), 0.95)
			if not lead:
				# In a deep side slip the high glove stays beside the face, rather than
				# continuing to reach forward as the head drops. Shallow and backward leans
				# keep their existing guard; the blend follows the analog lateral input.
				var close_guard := smoothstep(0.50, 0.90, absf(pos.x)) * (1.0 - rearward)
				tf = lerpf(tf, 0.03, close_guard)
			# The pull keeps an open probing lead glove while the rear glove guards below the chin.
			# Blend from the lateral guard rather than bringing both fists back into an earmuff.
			tf = lerpf(tf, 0.40 if lead else 0.25, rearward)
			tu = lerpf(tu, -0.02 if lead else -0.20, rearward)
			if not lead and _gd_dir < 0.0:
				# slip to the right (clip A): the right glove stays at the cheek / shoulder through the hold; only the left glove sinks to the belt
				cheek_w = _gd * (1.0 - rearward)
				tu = lerpf(tu, -0.09, cheek_w)
				ts = lerpf(ts, -0.10, cheek_w)
				tf = lerpf(tf, -0.01, cheek_w)
		var err := Vector3(ts - side, tu - up, tf - fwd)
		if err.length() < 0.02 and blocking:
			continue
		var goal := g + _left * err.x + _up * err.y + _fwd * err.z * 1.0
		var k := clampf(w * 1.0, 0.0, 1.0)
		# Round 6: the fighter's LEFT (lead) glove sinks to the belt line in a slip to either side (clip A: the glove away from the slip,
		# clip B: the slip-side glove; the right glove stays up beside the face), with the lagged slip depth; it rides the trunk
		# (anchored to the shoulder mid-point, so it follows the lean) instead of staying parked at the chin.
		var drop_w := 0.0
		var side_sign := 1.0 if s == "l" else -1.0     # + = this is the fighter's left hand
		var shoulder_mid := (_o(sk, "lShldrBend") + _o(sk, "rShldrBend")) * 0.5
		if not blocking and side_sign > 0.0 and duck_w < 0.5:
			drop_w = _gb
			var belt := shoulder_mid - _up * BELT_BELOW_SHOULDERS + _fwd * BELT_FORWARD + _left * (side_sign * BELT_SIDE)
			goal = goal.lerp(belt, drop_w)
		if not blocking and w > 0.05 and _gd > 0.05:
			# hold drift of the guard hands (small continuous sway, not a frozen pose)
			goal += _left * (sin(_clock * 2.3 + (0.0 if lead else 1.9)) * 0.012 * _gd) + _up * (sin(_clock * 1.9 + (0.7 if lead else 2.6)) * 0.008 * _gd)
		# overlap: the glove goal is low-passed in fighter space while the lean drives it, so the hands trail the trunk by 2-3 frames
		var lag_k := clampf(k * 2.0, 0.0, 1.0)
		var goal_c := g.lerp(goal, k)
		if not blocking and lag_k > 0.0:
			var gl: Vector3 = fighter.to_local(sk.global_transform * goal_c)
			if _gl_mem.has(hand):
				var a := 1.0 - (1.0 - (1.0 - exp(-_pdt / GLOVE_FOLLOW_TAU))) * lag_k
				gl = (_gl_mem[hand] as Vector3).lerp(gl, a)
			_gl_mem[hand] = gl
			goal_c = sk.global_transform.affine_inverse() * fighter.to_global(gl)
		else:
			_gl_mem.erase(hand)
		if not blocking and not own_body.is_empty():
			goal_c = BodyVolumes.push_out(own_body, goal_c, 0.085, 0.012, false)
		var tgt := goal_c - glove_off
		var hand_idx: int = _bone[hand]
		var glove_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
		var elbow := _o(sk, el)
		if not blocking and duck_w < 0.5:
			var elbow_drop := lerpf(0.48, 0.34, smoothstep(0.55, 1.0, pos.length())) if lead else lerpf(0.36, 0.24, cheek_w)
			var elbow_goal := head + _left * ((0.16 if lead else -0.16) * lerpf(1.0, lerpf(0.6, 0.7, 1.0 - cheek_w) , _gd)) - _up * elbow_drop + _fwd * 0.07
			if drop_w > 0.0:
				var belt_elbow := shoulder_mid + _left * (side_sign * 0.09) - _up * 0.26 - _fwd * 0.03   # elbow pinned in
				elbow_goal = elbow_goal.lerp(belt_elbow, drop_w)
			elbow = elbow.lerp(elbow_goal, clampf(w * 0.7, 0.0, 0.7))
		_ik2(sk, s + "ShldrBend", el, hand, tgt, elbow)
		# Moving the elbow changes the inherited wrist rotation. Keep the guard's glove facing the opponent,
		# rather than letting the two-bone solve twist its cuff/knuckles through a right angle.
		var solved_q := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
		_rot_sk(sk, hand_idx, glove_q * solved_q.inverse())
		if not blocking and fit.has(hand):
			# A global wrist orientation copied from the high idle guard leaves a low glove cocked
			# across its forearm. Reorient its measured cuff-to-knuckle axis towards the forearm,
			# with a small upward boxing-guard bend. Keep the visible glove centre at the same goal.
			var local_axis: Vector3 = fit[hand]["axis"]
			var axis := (Basis(glove_q) * local_axis).normalized()
			var forearm := (_o(sk, hand) - _o(sk, el)).normalized()
			var upright := (_fwd * 0.60 + _up * 0.80).normalized()
			var desired := forearm.lerp(upright, 0.08).normalized()
			var turn := Quaternion(axis, desired).normalized()
			# The relaxed low hand straightens with the forearm; as the slip compacts, retain a little
			# more upward wrist bend on the lead side. The rear hand stays aligned with its guard forearm.
			var max_turn := lerpf(55.0, 45.0, smoothstep(0.55, 1.0, pos.length())) if lead else 55.0
			var angle := minf(turn.get_angle(), deg_to_rad(max_turn)) * k
			guard_wrist_angles[hand] = {"requested": rad_to_deg(turn.get_angle()), "applied": rad_to_deg(angle)}
			if angle > 0.001:
				var facing := (Quaternion(turn.get_axis().normalized(), angle) * glove_q).normalized()
				var offset := Basis(facing) * (fit[hand]["off"] as Vector3)
				var centre := goal_c
				_ik2(sk, s + "ShldrBend", el, hand, centre - offset, _o(sk, el))
				var q_now := sk.get_bone_global_pose(hand_idx).basis.orthonormalized().get_rotation_quaternion()
				_rot_sk(sk, hand_idx, facing * q_now.inverse())
				guard_wrist_turn_deg = maxf(guard_wrist_turn_deg, rad_to_deg(angle))
		pulled = maxf(pulled, err.length())
	glove_pull = pulled
