extends "res://scripts/fighter/pose_layer_base.gd"
## Additive hit flinch: a spring-damper driven head / trunk / hip response layered on top of whatever the fighter is doing
## (idle, a committed punch, a reaction clip), so a landed or blocked shot is felt on the very first frame instead of waiting
## for a full-body clip to take over. Nothing here is a ragdoll: every channel is a damped angular spring that returns to the
## animated pose in about a quarter of a second.
##
##   kick(dir_world, punch_dir, zone, strength)   - angular impulse (see the table in _impulses)
##   head channel   : neckLower / neckUpper / head   (30 / 30 / 40 %)    - the fast one, peaks ~0.07 s
##   torso channel  : abdomen / chest chain          (15 / 20 / 30 / 35 %: chest > abdomen) - slower, peaks ~0.09 s
##   hip channel    : small weight shift / step back along the push (feet stay planted through two-bone leg IK)
## Springs: critically damped (zeta = 1: the head snaps to its peak in 1 / w0 ~ 55 ms and eases home without overshoot, < 5 % after 0.4 s) - firm,
## not floaty.
## Fresh fighters are stiff; tired / rocked ones are softer (lower w0, larger swing). Several hits accumulate but every
## channel is clamped. The committed striking limb is pinned (IK) so a punch that is already travelling still lands.
## Diagnostics: head / torso / hip vectors for tests.

## the head peaks at 1 / W (~80 ms) and is still a quarter of the way out after 0.3 s: the reference fighters stay displaced a beat after a
## clean shot instead of snapping straight back (was 18 / 14 / 12: home in ~0.2 s, read as a twitch)
const W_HEAD := 12.0
const W_TORSO := 10.0
const W_HIP := 9.0
const W_GUARD := 14.0
## critically damped: the impulse sets the snap, the spring brings everything home with no wobble (was zeta 0.5-0.6 = a floaty overshoot)
const Z_HEAD := 1.0
const Z_TORSO := 1.0
const Z_HIP := 1.0
const Z_GUARD := 1.0
## cascade: the head is hit first, the shoulders / trunk follow, the hips last (impulses are released with these delays)
const DELAY_TORSO := 0.045
const DELAY_HIP := 0.095
## clamps (rad) of the head [pitch, yaw, roll] and torso [pitch, yaw, roll] channels, and of the hip shift (m)
const HEAD_MAX := Vector3(0.62, 0.90, 0.40)
const TORSO_MAX := Vector3(0.55, 0.46, 0.34)
const HIP_MAX := 0.10
const GUARD_MAX := 1.0

## [pitch (+ = forward fold), yaw (+ = turn to the fighter's left), roll (+ = top to the fighter's right)] state, rad
var head := Vector3.ZERO
var torso := Vector3.ZERO
var hip := Vector3.ZERO          ## fighter-frame offset (x left, z forward), m  (y unused)
var _head_v := Vector3.ZERO
var _torso_v := Vector3.ZERO
var _hip_v := Vector3.ZERO
var guard_drop := Vector2.ZERO    ## (left glove, right glove) 0..1: how far the guard dropped on the hit side
var _guard_v := Vector2.ZERO
var _pend: Array = []            ## [release_time, channel (1 torso / 2 hip / 3 guard), Vector3]
var _clock := 0.0
var _flip := 1.0                 ## alternates the side of overhand flinches
var kicks := 0                   ## diagnostics: kicks received


## Peak of an impulse-driven damped spring (zeta < 1): peak = v / w0 * factor
static func _peak_factor(zeta: float) -> float:
	if zeta >= 0.999:
		return exp(-1.0)   # critically damped: x(t) = v t e^(-w t) peaks at t = 1 / w with v / w / e
	var s := sqrt(1.0 - zeta * zeta)
	return exp(-zeta / s * atan(s / zeta))


## Impact power 0..1 of a blow for the reaction springs: the punch (jab .6, cross .78, hook .85, uppercut .9, power shot ~1), the cleanliness of the
## contact, a little of the damage, the outcome (kind) and the situation (counter / lost trade hit harder). Independent of whether the damage
## happened to round to nothing.
static func impact_power(s: Dictionary, kind: String, quality: float, total: float, counter: bool, lost_trade: bool, leaking: bool) -> float:
	var tag := String(s.get("base_tag", s["tag"]))
	var p := 0.6
	if tag.contains("Uppercut"):
		p = 0.9
	elif tag.contains("Hook"):
		p = 0.85
	elif tag.begins_with("R") and tag.contains("Jab"):
		p = 0.78
	if s.get("power", false) or s.get("heavy", false):
		p = maxf(p, 0.98)
	if kind == "body":
		p *= 0.92
	p *= lerpf(0.8, 1.0, clampf(quality, 0.0, 1.0)) * lerpf(0.85, 1.15, clampf(total / 10.0, 0.0, 1.0))
	if kind == "block":
		p *= 0.75 if leaking else 0.55
	elif kind == "glance":
		p *= 0.4
	if counter:
		p *= 1.2
	if lost_trade:
		p *= 1.15
	return clampf(p, 0.15, 1.0)


func active() -> bool:
	return head.length() + torso.length() + hip.length() * 10.0 + _head_v.length() * 0.05 + _torso_v.length() * 0.05 + guard_drop.length() + _pend.size() > 0.004


## dir_world: unit vector from the victim toward the attacker (fighter.dir_from(att)); punch_dir "F"/"L"/"R"/"U"/"O";
## zone "head"/"body"/"leg"; strength 0..1
func kick(dir_world: Vector3, punch_dir: String, zone: String, strength: float) -> void:
	if not _fighter_ok() or not _standing():
		return
	var s := clampf(strength, 0.0, 1.0)
	if s <= 0.001:
		return
	var local: Vector3 = fighter.global_basis.inverse() * dir_world
	local.y = 0.0
	local = local.normalized() if local.length() > 0.001 else Vector3.BACK
	var push := -local                      # the way the blow pushes the victim (fighter frame, x left / z forward)
	var gain: float = 1.0 + 0.35 * fighter.fatigue + (0.25 if (fighter.hurt.active() or fighter.rocked) else 0.0)
	var imp := _impulses(punch_dir, zone, push)
	if fighter.state == fighter.State.ATTACK:
		imp[1] = (imp[1] as Vector3) * 0.5      # a committed punch keeps its line: the trunk gives half as much (the slower springs held the
		imp[2] = (imp[2] as Vector3) * 0.35     # shoulder back while the arm straightened, past what the pinned arm can reach) and the hips barely give
	# peak angle a -> initial angular velocity v = a * w0 / pf
	_head_v += imp[0] * s * gain * W_HEAD / _peak_factor(Z_HEAD)
	_pend.append([_clock + DELAY_TORSO, 1, imp[1] * s * gain * W_TORSO / _peak_factor(Z_TORSO)])
	_pend.append([_clock + DELAY_HIP, 2, imp[2] * s * gain * W_HIP / _peak_factor(Z_HIP)])
	# the guard drops a little on the side the blow came from (medium and harder shots), then recovers
	if s > 0.35:
		var side := 1 if push.x > 0.0 else 0     # pushed to the fighter's left: the right glove took it (index 1)
		var gv := Vector2.ZERO
		gv[side] = 0.55 * s
		_pend.append([_clock + DELAY_TORSO, 3, Vector3(gv.x, gv.y, 0.0) * W_GUARD / _peak_factor(Z_GUARD)])
	kicks += 1


## Every landed blow, whatever its outcome (scripts/fighter/fighter.gd `_react`): an impulse into the head / neck / upper-spine / hip springs at the
## contact point. kind: "head" | "body" | "block" | "glance". power 0..1 comes from the punch (jab .55 .. power hook 1.0), the quality of the contact
## and the outcome, NOT from the damage (a blocked or glancing shot does little damage but is still felt). `off` = the contact point relative to the
## target's centre in the fighter frame (x left, y up, z forward): a chin shot snaps the head back more than one on the crown, a blow left of
## centre turns it the other way. Table at power 1:
##   head, straight   pitch -0.52 (30 deg back), spine -0.16        head, hook   yaw +-0.78 (45 deg), roll -+0.28, spine yaw +-0.20
##   head, uppercut   pitch -0.62 (chin up),     spine -0.20        body shot    spine pitch +0.55 (folds), head nods +0.22, hips back
##   block            the same direction at ~50 % on the head, 80 % on the trunk: the head nods / turns a little, the weight shifts, the struck glove is
##                    driven back by guard_knock.gd
func impact(dir_world: Vector3, punch_dir: String, zone: String, kind: String, power: float, off := Vector3.ZERO) -> void:
	if not _fighter_ok() or not _standing():
		return
	var s := clampf(power, 0.0, 1.0)
	if s <= 0.001:
		return
	var local: Vector3 = fighter.global_basis.inverse() * dir_world
	local.y = 0.0
	local = local.normalized() if local.length() > 0.001 else Vector3.BACK
	var push := -local
	var gain: float = 1.0 + 0.35 * fighter.fatigue + (0.25 if (fighter.hurt.active() or fighter.rocked) else 0.0)
	var imp := _impact_table(punch_dir, zone, kind, push, off)
	if fighter.state == fighter.State.ATTACK:
		imp[1] = (imp[1] as Vector3) * 0.5
		imp[2] = (imp[2] as Vector3) * 0.35
	_head_v += imp[0] * s * gain * W_HEAD / _peak_factor(Z_HEAD)
	_pend.append([_clock + DELAY_TORSO, 1, imp[1] * s * gain * W_TORSO / _peak_factor(Z_TORSO)])
	_pend.append([_clock + DELAY_HIP, 2, imp[2] * s * gain * W_HIP / _peak_factor(Z_HIP)])
	if s > 0.3 and kind != "glance":
		var side := 1 if push.x > 0.0 else 0     # pushed to the fighter's left: the right glove took it (index 1)
		var gv := Vector2.ZERO
		gv[side] = 0.5 * s
		_pend.append([_clock + DELAY_TORSO, 3, Vector3(gv.x, gv.y, 0.0) * W_GUARD / _peak_factor(Z_GUARD)])
	kicks += 1


func _impact_table(dir: String, zone: String, kind: String, push: Vector3, off: Vector3) -> Array:
	var h := Vector3.ZERO
	var t := Vector3.ZERO
	var p := Vector3.ZERO
	var scale := 1.0
	var t_scale := 1.0
	var p_scale := 1.0
	if kind == "block":
		scale = 0.5      # the head nods / turns about half as far as on a clean shot ...
		t_scale = 0.8    # ... the trunk takes most of it and the weight shifts
	elif kind == "glance":
		scale = 0.5
		t_scale = 0.5
	if zone == "head" or kind == "block" and zone != "body":
		var chin := clampf(-off.y * 8.0, -0.4, 0.6)   # contact below the head centre: more snap back; on the crown: less
		match dir:
			"L", "R":
				var sg := 1.0 if dir == "L" else -1.0
				h = Vector3(0.10, 0.78 * sg, -0.28 * sg)
				t = Vector3(0.04, 0.34 * sg, -0.16 * sg)   # the shoulders turn with the head
				h.x += -0.25 * chin
			"U":
				h = Vector3(-0.62 * (1.0 + 0.4 * chin), 0.05, 0.0)
				t = Vector3(-0.30, 0.0, 0.0)
			"O":
				_flip = -_flip
				h = Vector3(0.40, 0.30 * _flip, -0.14 * _flip)
				t = Vector3(0.20, 0.08 * _flip, 0.0)
			_:
				h = Vector3(-0.52 * (1.0 + chin), 0.0, 0.0)
				t = Vector3(-0.28, 0.0, 0.0)   # the chest goes back with the head
				h.y += -1.4 * off.x   # a straight left of centre turns the face to the right
		h.z += -0.14 * push.x
		h.y += 0.10 * push.x * (1.0 if dir in ["F", "U"] else 0.0)
		p = Vector3(push.x, 0.0, push.z) * 0.075   # the weight rocks back onto the rear foot
	else:
		match dir:
			"L", "R":
				var sg2 := 1.0 if dir == "L" else -1.0
				t = Vector3(0.30, 0.30 * sg2, -0.34 * sg2)    # wraps around the hook
				h = Vector3(0.14, 0.10 * sg2, -0.12 * sg2)
			_:
				t = Vector3(0.55, 0.0, 0.0)                    # folds over the belt line shot
				h = Vector3(0.22, 0.0, 0.0)
				t.y += -1.2 * off.x
				t.z += 0.8 * off.x
		p = Vector3(push.x, 0.0, push.z) * 0.090
	return [h * scale, t * t_scale, p * p_scale * (1.0 if kind == "block" else scale)]


## Peak angles at strength 1: [head Vector3(pitch, yaw, roll), torso Vector3, hip Vector3(x, 0, z) in m]
func _impulses(dir: String, zone: String, push: Vector3) -> Array:
	var h := Vector3.ZERO
	var t := Vector3.ZERO
	var p := Vector3.ZERO
	if zone == "head":
		match dir:
			"L", "R":
				var sg := 1.0 if dir == "L" else -1.0     # a left hook turns the head to the victim's left
				h = Vector3(0.04, 0.60 * sg, -0.14 * sg)
				t = Vector3(0.0, 0.11 * sg, -0.05 * sg)
			"U":
				h = Vector3(-0.44, 0.04, 0.0)
				t = Vector3(-0.09, 0.0, 0.0)
			"O":
				_flip = -_flip
				h = Vector3(0.28, 0.20 * _flip, -0.10 * _flip)
				t = Vector3(0.12, 0.05 * _flip, 0.0)
			_:
				h = Vector3(-0.19, 0.0, 0.0)
				t = Vector3(-0.05, 0.0, 0.0)
		# an off-axis blow adds a sideways tilt
		h.z += -0.12 * push.x
		h.y += 0.10 * push.x * (1.0 if dir in ["F", "U"] else 0.0)
		p = Vector3(push.x, 0.0, push.z) * 0.028
	elif zone == "body":
		match dir:
			"L", "R":
				var sg2 := 1.0 if dir == "L" else -1.0
				t = Vector3(0.14, 0.14 * sg2, -0.20 * sg2)    # bends around the hook
				h = Vector3(0.10, 0.06 * sg2, -0.08 * sg2)
			_:
				t = Vector3(0.30, 0.0, 0.0)                    # folds over the belt line shot
				h = Vector3(0.12, 0.0, 0.0)
		p = Vector3(push.x, 0.0, push.z) * 0.044
	else:
		t = Vector3(0.04, 0.0, -0.10 * push.x)
		h = Vector3(0.02, 0.0, 0.0)
		p = Vector3(push.x, 0.0, push.z) * 0.020
	return [h, t, p]


func _integrate(dt: float, soft: float) -> void:
	var n := maxi(1, int(ceilf(dt / 0.0042)))
	var h := dt / float(n)
	var wh := W_HEAD * soft
	var wt := W_TORSO * soft
	var wp := W_HIP * soft
	var wg := W_GUARD * soft
	_clock += dt
	var k := 0
	while k < _pend.size():
		var e: Array = _pend[k]
		if _clock >= float(e[0]):
			var v: Vector3 = e[2]
			match int(e[1]):
				1: _torso_v += v
				2: _hip_v += v
				_: _guard_v += Vector2(v.x, v.y)
			_pend.remove_at(k)
		else:
			k += 1
	for i in n:
		_head_v += (-wh * wh * head - 2.0 * Z_HEAD * wh * _head_v) * h
		_torso_v += (-wt * wt * torso - 2.0 * Z_TORSO * wt * _torso_v) * h
		_hip_v += (-wp * wp * hip - 2.0 * Z_HIP * wp * _hip_v) * h
		_guard_v += (-wg * wg * guard_drop - 2.0 * Z_GUARD * wg * _guard_v) * h
		head += _head_v * h
		torso += _torso_v * h
		hip += _hip_v * h
		guard_drop += _guard_v * h
	guard_drop = guard_drop.clamp(Vector2(-0.2, -0.2), Vector2(GUARD_MAX, GUARD_MAX))
	head = _clamp_axes(head, _head_v, HEAD_MAX)
	_head_v = _kill_out(head, _head_v, HEAD_MAX)
	torso = _clamp_axes(torso, _torso_v, TORSO_MAX)
	_torso_v = _kill_out(torso, _torso_v, TORSO_MAX)
	hip.x = clampf(hip.x, -HIP_MAX, HIP_MAX)
	hip.z = clampf(hip.z, -HIP_MAX, HIP_MAX)


func _clamp_axes(v: Vector3, _vel: Vector3, m: Vector3) -> Vector3:
	return Vector3(clampf(v.x, -m.x, m.x), clampf(v.y, -m.y, m.y), clampf(v.z, -m.z, m.z))


func _kill_out(v: Vector3, vel: Vector3, m: Vector3) -> Vector3:
	var o := vel
	if absf(v.x) >= m.x - 1e-4 and signf(vel.x) == signf(v.x):
		o.x = 0.0
	if absf(v.y) >= m.y - 1e-4 and signf(vel.y) == signf(v.y):
		o.y = 0.0
	if absf(v.z) >= m.z - 1e-4 and signf(vel.z) == signf(v.z):
		o.z = 0.0
	return o


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or not _fighter_ok():
		return
	_ready_bones(sk)
	_restore(sk)
	if not _standing():
		head = Vector3.ZERO; torso = Vector3.ZERO; hip = Vector3.ZERO
		_head_v = Vector3.ZERO; _torso_v = Vector3.ZERO; _hip_v = Vector3.ZERO
		guard_drop = Vector2.ZERO; _guard_v = Vector2.ZERO; _pend.clear()
		return
	# stiffer when fresh, softer when tired or rocked
	var soft: float = 1.0 - 0.22 * fighter.fatigue - (0.12 if (fighter.hurt.active() or fighter.rocked) else 0.0)
	_integrate(minf(dt, 0.05), soft)
	if not active():
		head = Vector3.ZERO; torso = Vector3.ZERO; hip = Vector3.ZERO
		_head_v = Vector3.ZERO; _torso_v = Vector3.ZERO; _hip_v = Vector3.ZERO
		guard_drop = Vector2.ZERO; _guard_v = Vector2.ZERO; _pend.clear()
		return
	_frame(sk)
	var pin := _pin_begin(sk)
	var feet := _feet_begin(sk)
	# hips first (weight shift / step), legs re-planted, then the trunk and neck on top of the final hip
	var moved_hip := hip.length() > 0.0005
	if moved_hip:
		var d := _left * hip.x + _fwd * hip.z
		_move_hip(sk, d)
		_plant_feet(sk, feet)
	_rot_chain(sk, SPINE, torso.x, torso.y, torso.z)
	_rot_chain(sk, NECK, head.x, head.y, head.z)
	# guard drop: the glove on the hit side sags (never the striking limb)
	if guard_drop.length() > 0.01:
		var pinned: String = String(pin.get("limb", "")).substr(0, 1)
		for si in 2:
			var sd := "l" if si == 0 else "r"
			if sd == pinned or guard_drop[si] < 0.01:
				continue
			var hand := _o(sk, sd + "Hand")
			var elbow := _o(sk, sd + "ForearmBend")
			_ik2(sk, sd + "ShldrBend", sd + "ForearmBend", sd + "Hand", hand - _up * 0.085 * guard_drop[si] + _fwd * 0.02 * guard_drop[si], elbow)
	_pin_end(sk, pin)
