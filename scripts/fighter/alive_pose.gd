extends "res://scripts/fighter/pose_layer_base.gd"
## Liveliness pass: small continuous secondary motion so a fighter never stands like a statue between animation clips.
## Additive, after GuardStyle / PunchPose / DefencePose and before HitFlinch + PoseLimiter. Writes nothing when the fighter is
## down. Everything is scaled by `fresh` (stamina): tired fighters move less and slower. It is also scaled by what the fighter
## is doing (full in guard, a third while punching, almost nothing in a hurt episode).
##
##   weight shift : slow lateral hip transfer (plus a hair of vertical dip on the loaded side), feet planted by leg IK, the
##                  trunk counter-rolls; frequencies / phases / amplitudes are seeded per fighter
##   head tracking: the head turns / tilts toward the foe's head with a ~0.2 s lag (<= 22 deg), the trunk follows a little
##                  slower (<= 6 deg) so the lead shoulder stays toward the foe
##   guard micro  : both gloves drift a couple of centimetres (never static); the striking limb is left alone
##   anticipation : when the foe starts a punch within reach, 0.15-0.30 s later (slower when tired) the guard tightens
##                  (gloves pull to the chin, shoulders lift, chin tucks) for ~0.3 s
##   momentum lean: the trunk tilts into the direction of travel; an under-damped spring gives a small overshoot on stopping
## Diagnostics: w (activity weight), look (yaw, pitch rad), lean (pitch, roll), sway (m), ant (anticipation envelope).

var w := 0.0
var look := Vector2.ZERO
var lean := Vector2.ZERO          ## trunk (pitch, roll) from momentum
var sway := 0.0
var ant := 0.0

var _t := 0.0
var _seed_ph := Vector4.ZERO
var _freq := Vector3(0.42, 0.9, 0.31)
var _amp := 1.0
var _bounce_hz := 1.75
var bounce := 0.0                ## m the hips are sitting below the clip for the guard bounce (diagnostic)
var _trunk_yaw := 0.0
var _lean_v := Vector2.ZERO
var _v_prev := Vector3.ZERO
var _a_smooth := Vector3.ZERO
var _seen_serial := -1
var _ant_at := -1.0
var _ant_t := 99.0
var _ant_scale := 0.0
var _foe_head := -1
var _head_i := -1
var _head_rest := Basis.IDENTITY
var _rng := RandomNumberGenerator.new()
var trail := 0.0                  ## secondary motion: how far the head / gloves lag behind the shoulder turn (rad)
var _trail_h := 0.0               ## lagging copy of the shoulder-line yaw (under-damped spring)
var _trail_v := 0.0
var _trail_init := false
const BOUNCE := 0.014        ## m of guard bounce (hips down from the clip at the bottom of each beat)
const TRAIL_W := 13.0
const TRAIL_Z := 0.55
const TRAIL_HEAD := 0.35
const TRAIL_ARM := 0.22
const TRAIL_MAX := 0.16


func _init_seed() -> void:
	_rng.seed = 7001 + int(fighter.player_index) * 977 + hash(String(fighter.model)) % 1000
	_seed_ph = Vector4(_rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU, _rng.randf() * TAU)
	_freq = Vector3(_rng.randf_range(0.36, 0.55), _rng.randf_range(0.8, 1.15), _rng.randf_range(0.25, 0.4))
	_amp = _rng.randf_range(0.8, 1.25)
	_bounce_hz = _rng.randf_range(1.55, 1.95)


func _target_w() -> float:
	var f = fighter
	var t := 0.0
	match f.state:
		f.State.IDLE: t = 1.0
		f.State.ATTACK: t = 0.35
		f.State.SLIP, f.State.CROUCH: t = 0.3
		f.State.HIT: t = 0.15
		f.State.TAUNT: t = 0.6
		_: t = 0.0
	if f.hurt.active():
		t = minf(t, 0.2)
	return t


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or not _fighter_ok() or dt <= 0.0:
		return
	_ready_bones(sk)
	if _head_i < 0:
		_head_i = sk.find_bone("head")
		_head_rest = sk.get_bone_global_rest(_head_i).basis.orthonormalized()
		_init_seed()
	_restore(sk)
	var f = fighter
	dt = minf(dt, 0.05)
	_t += dt
	var fat: float = f.fatigue
	var fresh := 1.0 - 0.6 * fat
	w = lerpf(w, _target_w(), 1.0 - exp(-6.0 * dt))
	_update_anticipation(dt, fat)
	_update_lean(dt)
	if w < 0.003 and ant < 0.003 and lean.length() < 0.003:
		return
	_frame(sk)
	var pin := _pin_begin(sk)
	var feet := _feet_begin(sk)
	var tempo := 1.0 - 0.3 * fat

	# ---- weight shift (hips), feet planted
	var ph := _t * TAU * tempo
	var sw := sin(ph * _freq.x + _seed_ph.x) + 0.45 * sin(ph * _freq.z * 1.7 + _seed_ph.y)
	sway = 0.011 * _amp * fresh * w * sw
	var dip := -0.0035 * _amp * fresh * w * absf(sin(ph * _freq.x * 0.5 + _seed_ph.x * 0.5))
	# guard bounce: the reference fighters pump their knees in a steady ~1.7 Hz rhythm between exchanges (ours stood still on the clip's
	# legs). The hips only ever sit DOWN from the clip (knees bend, feet planted), fully in guard, fading out while punching / in a clinch.
	var calm: float = clampf((w - 0.4) / 0.6, 0.0, 1.0) * (1.0 - float(f.bc.contact_w) if f.bc != null else 1.0)
	bounce = BOUNCE * fresh * calm * (0.5 - 0.5 * cos(_t * TAU * _bounce_hz * tempo + _seed_ph.z))
	dip -= bounce
	var hip_d := _left * sway + _up * dip - _fwd * (0.004 * ant)
	_move_hip(sk, hip_d)
	_plant_feet(sk, feet)

	# ---- trunk: counter-roll to the sway, momentum lean, lead shoulder to the foe
	var counter := 0.030 * _amp * fresh * w * sw
	var yaw_err := 0.0
	var pitch_err := 0.0
	var tgt := _foe_target(sk)
	if tgt != Vector3.INF:
		var hd := sk.get_bone_global_pose(_head_i).origin
		var to := tgt - hd
		var hf := sk.get_bone_global_pose(_head_i).basis.orthonormalized() * (_head_rest.inverse() * _fwd)
		yaw_err = _signed_yaw(hf, to)
		pitch_err = _elev(hf) - _elev(to)
	var track := w * (0.35 if f.hurt.active() else 1.0)
	var ly := clampf(yaw_err * 0.55, -0.38, 0.38) * track
	var lp := clampf(pitch_err * 0.5, -0.17, 0.17) * track
	var rate := 5.0 * (1.0 - 0.3 * fat)
	look.x = lerpf(look.x, ly, 1.0 - exp(-rate * dt))
	look.y = lerpf(look.y, lp, 1.0 - exp(-rate * dt))
	var ty := clampf(yaw_err * 0.16, -0.10, 0.10) * track * (0.3 if f.state == f.State.ATTACK else 1.0)
	_trunk_yaw = lerpf(_trunk_yaw, ty, 1.0 - exp(-3.0 * dt))
	# gaze drift so the head is not locked
	var nz := Vector2(sin(_t * 1.3 + _seed_ph.z) + sin(_t * 2.9 + _seed_ph.w), sin(_t * 1.7 + _seed_ph.w)) * 0.006 * w
	var tuck := 0.07 * ant
	_rot_chain(sk, SPINE, lean.x + 0.03 * ant, _trunk_yaw, lean.y + counter)
	# the head counters part of the trunk lean / roll so the gaze stays level, and looks at the foe
	_rot_chain(sk, NECK, look.y + nz.y + tuck - 0.45 * lean.x, look.x + nz.x, -0.5 * (lean.y + counter))

	# ---- secondary motion: head and gloves trail the shoulder turn on a soft spring (never floppy: clamped, ~8 deg at most)
	var sl := _o(sk, "lShldrBend") - _o(sk, "rShldrBend")
	var yaw_ch := atan2(-sl.dot(_fwd), sl.dot(_left))
	if not _trail_init:
		_trail_h = yaw_ch
		_trail_v = 0.0
		_trail_init = true
	var nsub := maxi(1, int(ceilf(dt / 0.005)))
	var hs := dt / float(nsub)
	for si in nsub:
		_trail_v += (TRAIL_W * TRAIL_W * (yaw_ch - _trail_h) - 2.0 * TRAIL_Z * TRAIL_W * _trail_v) * hs
		_trail_h += _trail_v * hs
	trail = clampf(_trail_h - yaw_ch, -TRAIL_MAX, TRAIL_MAX) * clampf(w * 1.6, 0.0, 1.0) * (0.5 if f.state == f.State.ATTACK else 1.0) * (1.0 if _standing() else 0.0)
	_rot_chain(sk, NECK, 0.0, trail * TRAIL_HEAD, 0.0)
	var pin_side: String = String(pin.get("limb", "")).substr(0, 1)
	for sd in ["l", "r"]:
		if sd != pin_side:
			_rot_axis(sk, sd + "ShldrBend", _up, trail * TRAIL_ARM)

	# ---- shoulders / guard hands
	_guard(sk, pin, fresh)
	_pin_end(sk, pin)


func _foe_target(sk: Skeleton3D) -> Vector3:
	var foe = fighter.foe
	if foe == null or not is_instance_valid(foe) or foe.rig == null or foe.rig.skeleton == null:
		return Vector3.INF
	var fs: Skeleton3D = foe.rig.skeleton
	if _foe_head < 0:
		_foe_head = fs.find_bone("head")
	if _foe_head < 0:
		return Vector3.INF
	var wp: Vector3 = fs.global_transform * fs.get_bone_global_pose(_foe_head).origin
	return sk.global_transform.affine_inverse() * wp


func _signed_yaw(a: Vector3, b: Vector3) -> float:
	var ah := a - _up * a.dot(_up)
	var bh := b - _up * b.dot(_up)
	if ah.length() < 1e-4 or bh.length() < 1e-4:
		return 0.0
	ah = ah.normalized()
	bh = bh.normalized()
	return atan2(ah.cross(bh).dot(_up), ah.dot(bh))


func _elev(v: Vector3) -> float:
	var h := (v - _up * v.dot(_up)).length()
	return atan2(v.dot(_up), maxf(h, 1e-4))


func _update_anticipation(dt: float, fat: float) -> void:
	var f = fighter
	var foe = f.foe
	if foe != null and is_instance_valid(foe) and foe.state == foe.State.ATTACK and foe.atk.has("serial"):
		var ser: int = foe.atk["serial"]
		if ser != _seen_serial:
			_seen_serial = ser
			var gap: float = (foe.global_position - f.global_position).length()
			_ant_scale = 1.0 if gap < 2.3 else 0.0
			# reaction time 0.15-0.25 s, worse when tired
			_ant_at = _t + (0.15 + 0.10 * _rng.randf()) * (1.0 + 0.7 * fat)
			_ant_t = 99.0
	if _ant_at >= 0.0 and _t >= _ant_at:
		_ant_at = -1.0
		_ant_t = 0.0
	var env := 0.0
	if _ant_t < 90.0:
		_ant_t += dt
		env = smoothstep(0.0, 0.07, _ant_t) * exp(-maxf(_ant_t - 0.07, 0.0) / 0.13)
		if _ant_t > 1.0:
			_ant_t = 99.0
	var calm := 1.0 if f.state in [f.State.IDLE, f.State.SLIP, f.State.CROUCH] else 0.4
	ant = env * _ant_scale * (0.25 if f.hurt.active() else 1.0) * calm


func _update_lean(dt: float) -> void:
	var f = fighter
	var vel := Vector3(f.velocity.x, 0.0, f.velocity.z)
	var vl: Vector3 = f.global_basis.inverse() * vel       # x left, z forward
	var acc := (vl - _v_prev) / dt
	_v_prev = vl
	_a_smooth = _a_smooth.lerp(acc, 1.0 - exp(-14.0 * dt))
	var k := 1.0 if f.state == f.State.IDLE else (0.5 if f.state == f.State.ATTACK else 0.3)
	if f.hurt.active():
		k *= 0.3
	var pitch_t := clampf(0.045 * vl.z + 0.0065 * _a_smooth.z, -0.14, 0.14) * k
	var roll_t := clampf(-(0.04 * vl.x + 0.0065 * _a_smooth.x), -0.12, 0.12) * k
	# under-damped spring (w 10, zeta 0.5): a stop overshoots by ~15 %
	var wn := 10.0
	var z := 0.5
	var tgt := Vector2(pitch_t, roll_t)
	var n := maxi(1, int(ceilf(dt / 0.005)))
	var h := dt / float(n)
	for i in n:
		_lean_v += (wn * wn * (tgt - lean) - 2.0 * z * wn * _lean_v) * h
		lean += _lean_v * h


func _guard(sk: Skeleton3D, pin: Dictionary, fresh: float) -> void:
	var pinned_side: String = String(pin.get("limb", "")).substr(0, 1)
	var head_o := _o(sk, "head")
	var foe_head := _foe_target(sk)
	for s in ["l", "r"]:
		var sg := 1.0 if s == "l" else -1.0
		var idx := 0.0 if s == "l" else 1.7
		var amp := 0.028 * _amp * fresh * w
		var a1 := sin(_t * 1.9 + _seed_ph.x + idx) + 0.5 * sin(_t * 3.3 + _seed_ph.y * 2.0 + idx)
		var a2 := sin(_t * 1.4 + _seed_ph.w + idx * 2.0) + 0.5 * sin(_t * 2.7 + _seed_ph.z + idx)
		if s != pinned_side:
			_rot_axis(sk, s + "ShldrBend", _up, amp * a1)
			_rot_axis(sk, s + "ShldrBend", _left, amp * a2)
			_rot_axis(sk, s + "ForearmBend", _left, amp * 1.2 * a1)
		if ant > 0.003:
			_rot_axis(sk, s + "Collar", _fwd, sg * 0.06 * ant)   # shoulders lift
			if s != pinned_side:
				var hand := _o(sk, s + "Hand")
				var elbow := _o(sk, s + "ForearmBend")
				var tgt := hand + (head_o - hand) * 0.11 * ant + _up * 0.02 * ant - _fwd * 0.02 * ant
				_ik2(sk, s + "ShldrBend", s + "ForearmBend", s + "Hand", tgt, elbow)
		# the secondary motion never pushes a glove into the foe's head (stays >= 0.13 m away, like the base animation)
		if foe_head != Vector3.INF and s != pinned_side:
			var hp := _o(sk, s + "Hand")
			var away := hp - foe_head
			if away.length() < 0.13 and away.length() > 1e-4:
				_ik2(sk, s + "ShldrBend", s + "ForearmBend", s + "Hand", foe_head + away.normalized() * 0.13, _o(sk, s + "ForearmBend"))
