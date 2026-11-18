extends RefCounted
## CPU footwork (one instance per brain, CpuBrain.fw). want() returns the world-space step the CPU should take this tick;
## the brain feeds it to FighterInput.move, so the real locomotion (walk / strafe blend clips) does the rest, no teleporting.
## Plans (each held for a second or so, then re-chosen from the situation):
##   set    hold the style's range with small corrections; give ground along an ANGLE when crowded (never straight back)
##   circle step around the foe (either direction, biased toward a wandering ring anchor so the pair uses the whole ring)
##   out    step out of range along an angle after a burst
##   in     step in to striking range
##   cut    foe is circling: step forward on its side of the orbit and cut the ring off
##   pivot  trapped on the ropes / in a corner: circle toward the open ring
##   feint  quick dip + half step in, then out (non-damaging; invites the foe to react)
## Style numbers come from cpu_style.gd, rests / bursts from cpu_pace.gd.

const RING := 3.2
var kind := "set"
var t := 0.0
var sgn := 1.0
var slip := 0          ## feint dip for the brain to put on FighterInput.slip
var feint_cd := 1.5
var post_burst := false
var anchor := Vector3.ZERO
var anchor_t := 0.0
var _el := 0.0
var _jit := 0.0
var dist_total := 0.0  ## stats (m walked / m walked sideways), for tools / tests
var dist_lat := 0.0


static func _lat(to_foe: Vector3) -> Vector3:
	return Vector3(-to_foe.z, 0, to_foe.x)


func want(b, gap: float, to_foe: Vector3, dt: float, resting: bool, opening: bool) -> Vector3:
	var f = b.f
	var st: Dictionary = b.style
	slip = 0
	t -= dt
	_el += dt
	feint_cd -= dt
	anchor_t -= dt
	if anchor_t <= 0.0:
		anchor = Vector3(b.rng.randf_range(-2.0, 2.0), 0, b.rng.randf_range(-2.0, 2.0))
		anchor_t = b.rng.randf_range(6.0, 11.0)
	var p: Vector3 = f.global_position
	var target: float = float(st["gap"]) + _jit + (0.10 if opening else 0.0)
	if t <= 0.0 or _done(gap, target) or (post_burst and kind != "out"):
		_choose(b, gap, to_foe, p, target, resting, opening)
	var lat := _lat(to_foe)
	var w := Vector3.ZERO
	var rad := to_foe * clampf((gap - target) * 1.5, -0.5, 0.6 * float(st["adv"]) + 0.15)
	match kind:
		"set":
			if gap > target + 0.06:
				w = rad * (1.0 if gap > target + 0.2 else 0.8)
			elif gap < target - 0.12:
				w = -to_foe * 0.5 * float(st["backoff"]) + lat * sgn * 0.45 * float(st["backoff"])
			else:
				w = lat * sgn * 0.18
		"circle":
			w = lat * sgn * 0.9 + rad * 0.8
		"pivot":
			w = lat * sgn * 1.0 + rad * 0.6
		"out":
			w = -to_foe * 0.75 + lat * sgn * 0.6
		"in":
			w = to_foe * 0.9 + lat * sgn * 0.25
		"cut":
			w = to_foe * 0.55 * float(st["adv"]) + lat * sgn * 0.65
		"feint":
			if _el < 0.16:
				w = to_foe * 0.8
				slip = int(sgn)
			else:
				w = -to_foe * 0.6
	# at punching range boxers barely orbit: damp the sideways part (the pair's line was spinning ~36 deg/s and no
	# steady camera could stay side-on); at range they still circle freely
	var lat_part := lat * w.dot(lat)
	w += lat_part * (lerpf(0.5, 0.9, clampf((gap - 1.0) / 1.0, 0.0, 1.0)) - 1.0)
	# ropes: never walk into them, drift inward when close
	var edge := maxf(absf(p.x), absf(p.z))
	if edge > 2.6 and kind != "pivot":
		w += Vector3(-p.x, 0, -p.z).normalized() * 0.35
	if p.x * w.x > 0.0 and absf(p.x) > RING - 0.3:
		w.x *= 0.25
	if p.z * w.z > 0.0 and absf(p.z) > RING - 0.3:
		w.z *= 0.25
	return w


func _done(gap: float, target: float) -> bool:
	match kind:
		"out":
			return gap > target + 0.42 or _el > 1.1
		"in":
			return gap < target + 0.08
		"feint":
			return _el > 0.38
	return false


func _pick(b, w: Dictionary) -> String:
	var total := 0.0
	for k in w:
		total += float(w[k])
	var r: float = b.rng.randf() * total
	for k in w:
		r -= float(w[k])
		if r <= 0.0:
			return k
	return "set"


## Circling direction: usually toward the ring anchor (so the fight travels around the ring), sometimes against.
func _pick_sign(b, p: Vector3, to_foe: Vector3, toward := 0.65) -> float:
	var lat := _lat(to_foe)
	var d := anchor - p
	d.y = 0
	var s := 1.0 if lat.dot(d) >= 0.0 else -1.0
	return s if b.rng.randf() < toward else -s


func _choose(b, gap: float, to_foe: Vector3, p: Vector3, target: float, resting: bool, opening: bool) -> void:
	var st: Dictionary = b.style
	var feet: float = float(b.diff["feet"])
	_el = 0.0
	_jit = b.rng.randf_range(-0.05, 0.05)
	var lat := _lat(to_foe)
	var edge := maxf(absf(p.x), absf(p.z))
	var trapped := edge > 2.4 and to_foe.dot(Vector3(p.x, 0, p.z).normalized()) < 0.1
	var foe_lat: float = b.f.foe.velocity.dot(lat)
	var was_post := post_burst
	post_burst = false
	if trapped and b.rng.randf() < 0.85:
		kind = "pivot"
		t = b.rng.randf_range(0.9, 1.6)
		var inward := Vector3(-p.x, 0, -p.z)
		sgn = 1.0 if lat.dot(inward) >= 0.0 else -1.0
		return
	if was_post and b.pace.resting and b.rng.randf() < clampf(float(st["out"]) * 0.7 * feet, 0.0, 0.95):
		kind = "out"
		t = b.rng.randf_range(0.5, 0.9)
		sgn = _pick_sign(b, p, to_foe)
		return
	if absf(foe_lat) > 0.5 and gap < 1.8 and b.rng.randf() < clampf(float(st["cut"]) * 0.45 * feet, 0.0, 0.9):
		kind = "cut"
		t = b.rng.randf_range(0.7, 1.4)
		sgn = signf(foe_lat)
		return
	var w := {"set": 1.0 if not resting else 0.55}
	w["circle"] = float(st["circle"]) * (0.45 if not resting else 1.0) * feet * (1.4 if opening else 1.0)
	if resting:
		w["out"] = float(st["out"]) * 0.35 * feet
		if feint_cd <= 0.0 and gap > 0.85 and gap < 1.4:
			w["feint"] = float(st["feint"]) * 0.9 * (2.2 if opening else 1.0)
	if gap > target + 0.25:
		w["in"] = 1.6 if not resting else 0.5
	kind = _pick(b, w)
	match kind:
		"set":
			t = b.rng.randf_range(0.5, 1.1)
			sgn = _pick_sign(b, p, to_foe, 0.5)
		"circle":
			t = b.rng.randf_range(1.0, 2.6)
			sgn = _pick_sign(b, p, to_foe)
		"out":
			t = b.rng.randf_range(0.5, 0.9)
			sgn = _pick_sign(b, p, to_foe)
		"in":
			t = 1.0
			sgn = _pick_sign(b, p, to_foe, 0.5)
		"feint":
			t = 0.4
			sgn = 1.0 if b.rng.randf() < 0.5 else -1.0
			feint_cd = b.rng.randf_range(1.45, 2.4) + (1.5 if not opening else 0.0)


## Called by the brain after the step was applied (stats only).
func note_motion(f, to_foe: Vector3, dt: float) -> void:
	var v := Vector3(f.velocity.x, 0, f.velocity.z)
	var sp := v.length()
	dist_total += sp * dt
	dist_lat += absf(v.dot(_lat(to_foe))) * dt
