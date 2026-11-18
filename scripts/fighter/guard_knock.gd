extends "res://scripts/fighter/pose_layer_base.gd"
## Glove knock: the gloves are physically pushed by what hits them. Additive layer (after HitFlinch, before the pose limiter):
## each hand carries a fighter-frame offset (x left, y up, z forward, m) driven by a critically damped spring; the hand is
## re-solved there with two-bone IK from the shoulder, so the guard Area3Ds riding the forearms move with the gloves.
##
##   knock(dir_world, s, strength)  a punch landed on the guard: the hit glove goes back toward the face (-z) and to the side
##                                  (hooks wrap inward, uppercuts lift), 4 cm (jab) .. 10 cm (heavy), the other glove 60 %.
##                                  A power shot also knocks both gloves outward (the guard opens briefly).
##   parry(side, dir_world)         the defender's glove swipes the punch off line: out to the side and forward ~14 cm.
##   swat(side, dir_world, dist)    the ATTACKER's punching hand is batted aside by a parry (slower spring, the committed
##                                  punch pin is deliberately overridden).
## Spring: w = 16 rad/s, zeta = 1: a 10 cm knock peaks at ~62 ms and is under 1.5 % (1.5 mm) after 0.4 s.

const W := 16.0
const W_SWAT := 11.0
const E := 2.718281828
const MAX_OFF := 0.16

var off := {"l": Vector3.ZERO, "r": Vector3.ZERO}   ## fighter-frame glove offsets (diagnostics / tests)
var knocks := 0
var parries := 0
var record := false
var snap := {}                                        ## "lHand" / "rHand" world positions after this layer ran (tests)
var snap_pre := {}                                    ## ... and before it moved them (the knock's own displacement = snap - snap_pre)
var _vel := {"l": Vector3.ZERO, "r": Vector3.ZERO}
var _w := {"l": W, "r": W}
var _force := {"l": 0.0, "r": 0.0}                    ## s left of an overriding swat (the hand is the committed punching hand)


func active() -> bool:
	for k in ["l", "r"]:
		if (off[k] as Vector3).length() + (_vel[k] as Vector3).length() * 0.02 > 0.0006:
			return true
	return false


func _local(dir_world: Vector3) -> Vector3:
	var local: Vector3 = fighter.global_basis.inverse() * dir_world
	local.y = 0.0
	return local.normalized() if local.length() > 0.001 else Vector3.BACK


func _impulse(side: String, peak: Vector3, w := W) -> void:
	_w[side] = w
	_vel[side] = (_vel[side] as Vector3) + peak * w * E


## A punch hit the guard. strength 0..1 (damage), s = strike row.
func knock(dir_world: Vector3, s: Dictionary, strength: float) -> void:
	if not _fighter_ok() or not _standing():
		return
	var st := clampf(strength, 0.0, 1.0)
	var peak := lerpf(0.04, 0.10, st)
	var dir := String(s.get("dir", "F"))
	var limb := String(s.get("limb", "L"))
	var hit := "r" if limb == "L" else "l"      # an attacker's left lands on the defender's right glove
	var lat := 1.0 if limb == "L" else -1.0     # ... and pushes it inward (+x for the right glove)
	for side in ["l", "r"]:
		var share := 1.0 if side == hit else 0.6
		var v := Vector3(0.0, 0.0, -0.85 * peak)
		match dir:
			"L", "R", "O":
				v.x = lat * peak * 0.9 * (1.0 if side == hit else 0.5)
				v.z = -0.55 * peak
			"U":
				v.y = 0.8 * peak
				v.z = -0.45 * peak
			_:
				v.x = lat * peak * 0.25
		if String(s.get("zone", "head")) == "body":
			v.y = -0.5 * peak    # elbows / gloves pushed down onto the ribs
		_impulse(side, v * share)
	if s.get("power", false):                    # heavy loaded shot: the guard is knocked open
		_impulse("l", Vector3(0.06, 0.01, 0.0))
		_impulse("r", Vector3(-0.06, 0.01, 0.0))
	knocks += 1


## Parry swipe by `side` glove ("l" / "r") against a punch coming from dir_world.
func parry(side: String, dir_world: Vector3) -> void:
	if not _fighter_ok() or not _standing():
		return
	var out := 1.0 if side == "l" else -1.0
	_impulse(side, Vector3(out * 0.13, 0.025, 0.07))
	_impulse("r" if side == "l" else "l", Vector3(0.0, 0.0, -0.025))   # the other glove tucks in
	parries += 1


## The attacker's `limb` ("lHand" / "rHand") is batted away from the foe's guard.
func swat(limb: String, away_world: Vector3, dist: float) -> void:
	if not _fighter_ok() or not limb.ends_with("Hand"):
		return
	var side := limb.substr(0, 1)
	var local := _local(away_world)
	var v := Vector3(local.x * dist, 0.02, local.z * dist * 0.3)
	_impulse(side, v, W_SWAT)
	_force[side] = 0.45


func _process_modification_with_delta(dt: float) -> void:
	var sk := get_skeleton()
	if sk == null or not _fighter_ok():
		return
	_ready_bones(sk)
	_restore(sk)
	if not _standing():
		for k in ["l", "r"]:
			off[k] = Vector3.ZERO
			_vel[k] = Vector3.ZERO
		return
	dt = minf(dt, 0.05)
	for k in ["l", "r"]:
		var w: float = _w[k]
		var o: Vector3 = off[k]
		var v: Vector3 = _vel[k]
		var n := maxi(1, int(ceilf(dt / 0.004)))
		var h := dt / float(n)
		for i in n:
			v += (-w * w * o - 2.0 * w * v) * h
			o += v * h
		o = o.limit_length(MAX_OFF)
		off[k] = o
		_vel[k] = v
		_force[k] = maxf(float(_force[k]) - dt, 0.0)
		if o.length() < 0.0006 and v.length() < 0.01:
			off[k] = Vector3.ZERO
			_vel[k] = Vector3.ZERO
			_w[k] = W
	if record:
		snap_pre = {}
		for n in ["lHand", "rHand"]:
			snap_pre[n] = sk.global_transform * sk.get_bone_global_pose(sk.find_bone(n)).origin
	if not active():
		if record:
			_record(sk)
		return
	_frame(sk)
	var f = fighter
	for k in ["l", "r"]:
		var o: Vector3 = off[k]
		if o.length() < 0.0006:
			continue
		var limb: String = k + "Hand"
		if f.state == f.State.ATTACK and f.atk.has("limb") and String(f.atk["limb"]) == limb and float(_force[k]) <= 0.0:
			continue   # the committed punch is never moved by a knock
		var hand := _o(sk, limb)
		var elbow := _o(sk, k + "ForearmBend")
		var target := hand + _left * o.x + _up * o.y + _fwd * o.z
		# the elbow flares a little with a sideways knock
		_ik2(sk, k + "ShldrBend", k + "ForearmBend", limb, target, elbow + _left * o.x * 0.5)
	if record:
		_record(sk)


func _record(sk: Skeleton3D) -> void:
	for n in ["lHand", "rHand", "head"]:
		var i := sk.find_bone(n)
		snap[n] = sk.global_transform * sk.get_bone_global_pose(i).origin
