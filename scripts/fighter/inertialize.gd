extends SkeletonModifier3D
## Inertialization layer: first modifier after the AnimationTree output, before every procedural layer.
##
## Every pass each animated bone's incoming local rotation is compared with last pass's incoming rotation. When it jumps (a new
## clip, a short crossfade, a state snap: the angular step exceeds what the bone was doing, or `trigger()` opened a sensitive
## window) the difference between what we showed last pass and what the animation now says is captured as an offset
## (rotation vector + velocity) and decayed to zero with a critically damped spring (~0.25 s). Output = offset * animated, so
## the pose is continuous through any transition without touching the clips. Positions are not inertialized (feet planting).
## The striking limb of a live punch only gets a fraction of the offset so the fist arrival time is unchanged.

var fighter: Node3D
var post := false                  ## second instance after PoseLimiter: smooths pops the procedural layers (IK flips) introduce
var post_peer = null               ## (first instance) the post instance, reset together
var pre = null                     ## the first instance (post mode compares its step with the animation's own)
var enabled := OS.get_environment("KN_INERT_OFF") == ""

const W_DEFAULT := 22.0
const W_HEAD := 18.0
const W_ARM := 26.0
const JUMP_ABS := 0.11             ## rad per physics frame (at 120 Hz ~ 13 rad/s) before a step counts as a jump on its own
const JUMP_REL := 2.5              ## ... and it must exceed this multiple of the bone's recent speed
const TRIG_ABS := 0.04            ## inside a trigger() window the absolute threshold drops to this
const HARD_CUT := 2.2              ## a step bigger than this (rad) is a teleport / re-spawn: no smoothing
const OFF_MAX := 1.2               ## rad, clamp of a captured offset
const DEFEND_KEEP := 0.35          ## share kept during a slip / duck: the head must leave the line as fast as the clip says (gameplay timing)
const STRIKE_KEEP := 0.35          ## share of the offset kept on the striking limb chain during a live punch

var jumps := 0                     ## diagnostics: bones that were caught jumping
var trig_window := 0.0
var dbg_in := {}                   ## bone -> incoming angular step this pass (diagnostics)
var max_off := 0.0                 ## diagnostics: largest offset magnitude now (rad)

var _built := false
var _bones: Array = []             ## animated bone indices
var _in_prev := {}                 ## bone -> Quaternion (incoming last pass)
var _ema := {}                     ## bone -> float rad/s
var _off := {}                     ## bone -> Vector3 rotvec
var _offv := {}                    ## bone -> Vector3
var _written := {}                 ## bone -> Quaternion written
var _base := {}                    ## bone -> Quaternion incoming
var _w := {}
var _strike_bones := {}
var _was_standing := false
var _last_frame := 0
var _k_def := 1.0
var _k_str := 1.0


## Forget everything (ragdoll start / end, state machine restart): no stale offset is ever applied to a new pose.
func reset() -> void:
	_in_prev.clear()
	_ema.clear()
	_off.clear()
	_offv.clear()
	_written.clear()
	_base.clear()
	_was_standing = false
	trig_window = 0.0
	max_off = 0.0
	_k_def = 1.0
	_k_str = 1.0


func _hard_cut() -> float:
	return 3.1 if post else HARD_CUT


func trigger(window := 0.06) -> void:
	trig_window = maxf(trig_window, window)


static func _rv(q: Quaternion) -> Vector3:
	q = q.normalized()
	if q.w < 0.0:
		q = Quaternion(-q.x, -q.y, -q.z, -q.w)
	var s := sqrt(q.x * q.x + q.y * q.y + q.z * q.z)
	if s < 1e-7:
		return Vector3(q.x, q.y, q.z) * 2.0
	var ang := 2.0 * atan2(s, q.w)
	return Vector3(q.x, q.y, q.z) / s * ang


static func _from_rv(v: Vector3) -> Quaternion:
	var a := v.length()
	if a < 1e-7:
		return Quaternion.IDENTITY
	return Quaternion(v / a, a)


func _build(sk: Skeleton3D) -> void:
	_built = true
	var names := {}
	var f = fighter
	var ap: AnimationPlayer = f.model_root.find_child("AnimationPlayer", true, false) if f != null and f.model_root != null else null
	if ap != null and ap.has_animation(&"KB_Idle_1"):
		var a := ap.get_animation(&"KB_Idle_1")
		for t in a.get_track_count():
			if a.track_get_type(t) == Animation.TYPE_ROTATION_3D:
				names[String(a.track_get_path(t)).get_slice(":", 1)] = true
	for i in sk.get_bone_count():
		if names.is_empty() or names.has(sk.get_bone_name(i)):
			var bn := sk.get_bone_name(i)
			if post and (bn.contains("Thigh") or bn.contains("Shin") or bn.contains("Foot")):
				continue   # the PoseLimiter's knee / hip budget is final: the legs are not smoothed after it
			_bones.append(i)
			var n := sk.get_bone_name(i)
			_w[i] = W_HEAD if n in ["head", "neckLower", "neckUpper"] else (W_ARM if (n.ends_with("Hand") or n.ends_with("ForearmBend") or n.ends_with("ShldrBend")) else W_DEFAULT)
	for n in ["Collar", "ShldrBend", "ForearmBend", "Hand"]:
		for s in ["l", "r"]:
			var i := sk.find_bone(s + n)
			if i >= 0:
				_strike_bones[s + "Hand"] = _strike_bones.get(s + "Hand", [])
				_strike_bones[s + "Hand"].append(i)


func _restore(sk: Skeleton3D) -> void:
	for i in _written:
		if sk.get_bone_pose_rotation(i).is_equal_approx(_written[i]):
			sk.set_bone_pose_rotation(i, _base[i])
	_written.clear()
	_base.clear()


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or fighter == null or not is_instance_valid(fighter) or dt <= 0.0:
		return
	if not _built:
		_build(sk)
	# the modifier was paused (ragdoll holds every layer): whatever we remember is from another pose
	var frame := Engine.get_physics_frames()
	if frame - _last_frame > 3:
		reset()
	_last_frame = frame
	_restore(sk)
	var f = fighter
	var standing: bool = not (f.state in [f.State.FALL, f.State.COUNT, f.State.GETUP, f.State.DOWN, f.State.WIN])
	var dtc := minf(dt, 0.05)
	if trig_window > 0.0:
		trig_window -= dt
	var keep_limb := ""
	if f.state == f.State.ATTACK and f.atk.has("limb") and not (f.atk.get("s", {}) as Dictionary).get("is_leg", false):
		keep_limb = String(f.atk["limb"])
	_k_def = move_toward(_k_def, DEFEND_KEEP if f.state in [f.State.SLIP, f.State.CROUCH] else 1.0, 8.0 * dtc)   # eased: the share never jumps
	_k_str = move_toward(_k_str, STRIKE_KEEP if keep_limb != "" else 1.0, 8.0 * dtc)
	var keep_all := _k_def
	var strike_set: Array = _strike_bones.get(keep_limb, [])
	var e := {}
	max_off = 0.0
	for i in _bones:
		var q: Quaternion = sk.get_bone_pose_rotation(i)
		var prev: Quaternion = _in_prev.get(i, q)
		_in_prev[i] = q
		if not standing or not enabled or not _was_standing:
			_off[i] = Vector3.ZERO
			_offv[i] = Vector3.ZERO
			_ema[i] = 0.0
			continue
		var d := prev.angle_to(q)
		if not post:
			dbg_in[i] = d
		var speed := d / dt
		var ema: float = _ema.get(i, 0.0)
		var expected := ema * dt
		var thr_abs := TRIG_ABS if trig_window > 0.0 else JUMP_ABS
		var thr_rel := 2.0 if trig_window > 0.0 else JUMP_REL
		# a live punch owns its own acceleration (the strike clip is retimed every tick, the chain moves with it): nothing is captured while attacking

		var no_capture: bool = keep_limb != ""
		var jump_now := false
		if post:
			var din: float = pre.dbg_in.get(i, 0.0) if pre != null else 0.0
			# (a deliberate fast slip / switch moves the trunk a few degrees per physics frame by design: that is not an IK flip)
			var post_thr := 0.30 if f.state in [f.State.SLIP, f.State.CROUCH] else 0.16
			jump_now = d > post_thr and d > 3.0 * din + 0.12 and d < _hard_cut()
		else:
			jump_now = not no_capture and d > thr_abs and d > thr_rel * expected + 0.5 * thr_abs and d < _hard_cut()
		if jump_now:
			# capture: what we showed last pass (prev input with its decayed offset) against the new input
			var keep_i: float = minf(_k_str, keep_all) if strike_set.has(i) else keep_all
			var shown: Quaternion = _from_rv((_off[i] if _off.has(i) else Vector3.ZERO) * keep_i) * prev
			var off_q: Quaternion = shown * q.inverse()
			var rv := _rv(off_q)
			var om := 3.0 if post else OFF_MAX
			if rv.length() > om:
				rv = rv.normalized() * om
			rv /= maxf(keep_i, 0.1)       # the shown offset is the stored one times keep_i: store it so the output is continuous
			_off[i] = rv
			_offv[i] = (_offv.get(i, Vector3.ZERO) as Vector3) * 0.5
			jumps += 1
		elif d >= _hard_cut():
			_off[i] = Vector3.ZERO
			_offv[i] = Vector3.ZERO
		else:
			_ema[i] = lerpf(ema, speed, 1.0 - exp(-15.0 * dt))
		# critically damped decay
		var x: Vector3 = _off.get(i, Vector3.ZERO)
		var v: Vector3 = _offv.get(i, Vector3.ZERO)
		if x.length_squared() > 1e-8 or v.length_squared() > 1e-6:
			var w: float = _w[i]
			var ex := exp(-w * dtc)
			var c := v + x * w
			x = (x + c * dtc) * ex
			v = (v - c * (w * dtc)) * ex
			_off[i] = x
			_offv[i] = v
			var xo := x * keep_all
			if strike_set.has(i):
				xo = x * minf(_k_str, keep_all)
			max_off = maxf(max_off, xo.length())
			var out := _from_rv(xo) * q
			_base[i] = q
			sk.set_bone_pose_rotation(i, out)
			_written[i] = sk.get_bone_pose_rotation(i)
		else:
			_off[i] = Vector3.ZERO
			_offv[i] = Vector3.ZERO
	_was_standing = standing
