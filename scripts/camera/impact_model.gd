extends RefCounted
## Impact / rocked camera presentation model. Faithful port of the web build's `web/js/impact.js` (ImpactState,
## CAMERA60, rockPushEnvelope, rockTiltEnvelope, pullbackEnvelope, cameraEnvelope, cue builder, shot selection).
## Pure data: feed it cues with consume(), advance with step(dt), read the public fields. No nodes, no signals.
##
## Output (after step): image_scale (1 = neutral, 1.28 = rock push-in), shift_x / shift_y (fractions of screen width /
## height; +x moves the image right, +y moves it down), roll_deg (+ = web rotateZ sign), blur (0..1 world smear),
## rock_focus (0..1 push-in weight), rock_phase, mode ("none"|"rock"|"big"|"medium").

# --- CAMERA60 (measured Fight Night image-space curves, copied from the web build) -------------------------
const PEAK := 0.094
const BIG_PEAK_MAX := 13.0
const ROCK_SCALE := 1.28
const ROCK_IN := 0.113
const ROCK_HOLD := 0.45
const ROCK_OUT := 0.8
const ROCK_TILT := 8.5
const ROCK_TILT_IN := 0.32
const ROCK_TILT_HOLD_START := 0.45
const ROCK_TILT_HOLD_END := 0.75
const ROCK_TROUGH := -7.0
const ROCK_TROUGH_AT := 1.4
const ROCK_SETTLE_AT := 2.4
const BLUR_FRAMES := 2
const BLUR_FRAME_TIME := 1.0 / 29.9
const BLUR_DURATION := 0.4
const MAX_ROLL := 13.4
const MAX_DT := 0.064
const BASE_FOV := 42.0
const RELEASE_TIME := 0.4   ## knockdown / KO takes the shot over: the effect is released over this long (web knockdownRelease)

var impulses: Array = []
var time := 0.0
var hits := 0
var image_scale := 1.0
var shift_x := 0.0
var shift_y := 0.0
var roll_deg := 0.0
var blur := 0.0
var rock_focus := 0.0
var rock_phase := "none"
var mode := "none"
var kick := 0.0
var pivot_victim := -1       ## fighter index of the newest rock victim (-1: none)
var blur_dir := Vector2(1, 0)
var _weight := 1.0            ## 1 = full effect; fades to 0 while released
var _releasing := false
var _release_age := 0.0
var _neutral := false


static func smooth_unit(v: float) -> float:
	var t := clampf(v, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)


static func camera_rise(t: float) -> float:
	if not (t > 1.0 / 30.0):
		return 0.43
	var u := clampf((t - 1.0 / 30.0) / (PEAK - 1.0 / 30.0), 0.0, 1.0)
	return 0.43 + 0.57 * (1.0 - pow(1.0 - u, 1.3))


static func camera_envelope(t: float) -> float:
	if not (t >= 0.0):
		return 0.0
	if t < PEAK:
		return camera_rise(t)
	if t < 0.28:
		return 1.0 - 0.5 * smooth_unit((t - PEAK) / (0.28 - PEAK))
	if t < 0.36:
		return 0.5 - 0.42 * smooth_unit((t - 0.28) / 0.08)
	if t < 0.48:
		return 0.08 * (1.0 - smooth_unit((t - 0.36) / 0.12))
	return 0.0


static func pullback_envelope(t: float) -> float:
	if not (t > 0.0):
		return 0.0
	if t < 0.05:
		return smooth_unit(t / 0.05)
	if t < 0.4:
		return 1.0
	if t < 0.8:
		return 1.0 - smooth_unit((t - 0.4) / 0.4)
	return 0.0


static func rock_push_envelope(t: float) -> float:
	if not (t > 0.0):
		return 0.0
	if t < ROCK_IN:
		return smooth_unit(t / ROCK_IN)
	if t < ROCK_HOLD:
		return 1.0
	if t < ROCK_OUT:
		return 1.0 - smooth_unit((t - ROCK_HOLD) / (ROCK_OUT - ROCK_HOLD))
	return 0.0


static func rock_tilt_envelope(t: float) -> float:
	if not (t > ROCK_TILT_IN):
		return 0.0
	if t < ROCK_TILT_HOLD_START:
		return ROCK_TILT * smooth_unit((t - ROCK_TILT_IN) / (ROCK_TILT_HOLD_START - ROCK_TILT_IN))
	if t <= ROCK_TILT_HOLD_END:
		return ROCK_TILT
	if t < ROCK_TROUGH_AT:
		return ROCK_TILT + (ROCK_TROUGH - ROCK_TILT) * smooth_unit((t - ROCK_TILT_HOLD_END) / (ROCK_TROUGH_AT - ROCK_TILT_HOLD_END))
	if t < ROCK_SETTLE_AT:
		return ROCK_TROUGH * (1.0 - smooth_unit((t - ROCK_TROUGH_AT) / (ROCK_SETTLE_AT - ROCK_TROUGH_AT)))
	return 0.0


static func blur_envelope(t: float) -> float:
	if t < BLUR_FRAME_TIME * BLUR_FRAMES:
		return 1.0
	if t < BLUR_FRAME_TIME * 4.0:
		return 0.18
	if t < BLUR_DURATION:
		return 0.07 * (1.0 - smooth_unit((t - BLUR_FRAME_TIME * 4.0) / (BLUR_DURATION - BLUR_FRAME_TIME * 4.0)))
	return 0.0


## Camera profile per cue kind (web cameraProfileFor). dir_sign = +1 when the punch travels to screen-right.
static func profile_for(kind: String, quality: float, dir_sign: float) -> Dictionary:
	var q := clampf(quality, 0.0, 1.0)
	var p := {"kind": "light", "rank": 0, "roll": 0.0, "sx": 0.0, "sy": 0.0, "pull": 0.0, "blur": 0.0, "dir": dir_sign, "life": 0.26}
	match kind:
		"rock":
			p.merge({"kind": "rock", "rank": 4, "roll": 12.0 + q, "sx": -(0.02 + 0.02 * q) * dir_sign, "sy": 0.05 + 0.02 * q,
				"pull": 0.034 + 0.015 * q, "blur": 0.95, "life": 2.5}, true)
		"big":   # strong clean hit / counter: stays deliberately calmer than a rock (max 3 deg, sub-1.2% shift, no blur)
			p.merge({"kind": "big", "rank": 3, "roll": 1.5 + 0.5 * q, "sx": -(0.002 + 0.002 * q) * dir_sign, "sy": 0.002 + 0.002 * q,
				"pull": 0.004 + 0.004 * q, "life": 0.9}, true)
		"medium":
			p.merge({"kind": "medium", "rank": 1, "roll": 0.25 + 0.15 * q, "sx": -0.001 * dir_sign, "sy": 0.0015,
				"pull": 0.003 + 0.002 * q, "life": 0.9}, true)
	return p


## Map a Match.hit_landed info dictionary to the web cue classes. Returns {kind, sweat, spit, kick, pulse, fx, head, body, block}.
## kind: "none" (blocked / knockdown / leg), "rock", "big", "medium", "light".
static func cue_for_hit(info: Dictionary) -> Dictionary:
	var zone := String(info.get("zone", "head"))
	var head := zone == "head"
	var blocked := bool(info.get("blocked", false))
	var counter := bool(info.get("counter", false))
	var strength := String(info.get("strength", "light"))
	var quality := clampf(float(info.get("quality", 1.0)), 0.0, 1.0)
	var down := bool(info.get("knockdown", false)) or bool(info.get("ko", false))
	var cue := {"kind": "none", "sweat": 0, "spit": 0, "kick": 0.0, "pulse": 0.0, "head": head, "body": not head and not blocked,
		"block": blocked, "quality": quality, "fx": 0.0, "klass": 3}
	if blocked:
		cue["klass"] = 1
		cue["kick"] = 0.10
		return cue
	if bool(info.get("guard_break", false)):
		cue["klass"] = 5
		cue["kind"] = "medium"
		cue["kick"] = 0.4
		cue["fx"] = 0.68
		return cue
	var rock := head and bool(info.get("rocked", false)) and not down
	var heavy := strength == "heavy" or rock
	var exceptional := down
	var klass := 7 if bool(info.get("ko", false)) else (6 if down else (4 if counter else 3))
	cue["klass"] = klass
	var significant := counter or exceptional or heavy
	cue["sweat"] = (28 if exceptional else (22 if counter else (26 if rock else (18 if heavy else 5)))) if head else 0
	cue["spit"] = ((5 if exceptional else (4 if (counter or rock) else 3)) if (head and quality >= 0.6 and significant) else 0)
	cue["kick"] = 1.0 if exceptional else (((0.96 if counter else 0.90)) if rock else (0.88 if counter else (0.58 if heavy else (0.28 if head else 0.18))))
	cue["pulse"] = 1.0 if exceptional else (0.8 if rock else (0.7 if counter else (0.35 if heavy else 0.0)))
	# camera class
	if exceptional:
		cue["kind"] = "none"   # knockdown / KO: the camera's knockdown mode owns the shot
	elif rock:
		cue["kind"] = "rock"
	elif counter or (strength == "heavy"):
		cue["kind"] = "big"
	elif strength == "medium":
		cue["kind"] = "medium"
	else:
		cue["kind"] = "light"
	# screen-impact strength (web _strengthFor)
	var base := 0.82 if counter else 0.58
	if exceptional:
		base = 0.94 if klass == 6 else 0.96
	var level_term := 0.14 if (not counter and not exceptional and strength == "heavy") else 0.0
	cue["fx"] = clampf(base + quality * 0.04 + level_term + (0.04 if rock else 0.0) + (0.02 if head else 0.0), 0.0, 1.0)
	return cue


func reset() -> void:
	impulses.clear()
	time = 0.0
	hits = 0
	pivot_victim = -1
	_weight = 1.0
	_releasing = false
	_release_age = 0.0
	_neutral = false
	_sample()


func active() -> bool:
	return not impulses.is_empty()


## Hand the shot over to the knockdown / KO camera: the effect fades over RELEASE_TIME instead of snapping.
func release() -> void:
	if not impulses.is_empty() and not _releasing:
		_releasing = true
		_release_age = 0.0


## cue: {attacker:int, kind:String, quality:float, dir_sign:float, [dx, dy]}. Returns false when it created no shot
## (kind without a camera profile, or a duplicate rock for the same victim within 0.3 s).
func consume(cue: Dictionary) -> bool:
	var kind := String(cue.get("kind", "none"))
	if kind != "rock" and kind != "big" and kind != "medium":
		return false
	var attacker := int(cue.get("attacker", 0))
	var dir_sign := signf(float(cue.get("dir_sign", 1.0)))
	if dir_sign == 0.0:
		dir_sign = 1.0
	if kind == "rock":
		for s in impulses:
			if s["camera"]["kind"] == "rock" and s["attacker"] == attacker and time - float(s["born"]) < 0.3:
				return false   # hit_landed + fighter_state_changed describe the same rock
	var camera := profile_for(kind, float(cue.get("quality", 1.0)), dir_sign)
	impulses.append({"age": 0.0, "attacker": attacker, "born": time, "camera": camera,
		"dx": float(cue.get("dx", dir_sign)), "dy": float(cue.get("dy", 0.0))})
	if impulses.size() > 6:
		impulses.remove_at(0)
	_releasing = false
	_release_age = 0.0
	_weight = 1.0
	hits += 1
	_neutral = false
	_sample()
	return true


func step(dt: float) -> void:
	if not is_finite(dt) or dt <= 0.0:
		return
	dt = minf(dt, MAX_DT)
	time += dt
	for s in impulses:
		s["age"] += dt
	if _releasing:
		_release_age += dt
		_weight = 1.0 - smooth_unit(_release_age / RELEASE_TIME)
		if _release_age >= RELEASE_TIME:
			impulses.clear()
			_releasing = false
			_weight = 1.0
	if not impulses.is_empty():
		var keep: Array = []
		for s in impulses:
			if s["age"] < s["camera"]["life"]:
				keep.append(s)
		impulses = keep
	_sample()


func _newer(a: Dictionary, b: Variant) -> bool:
	return b == null or a["born"] > b["born"] or (a["born"] == b["born"] and a["attacker"] < b["attacker"])


func _sample() -> void:
	if impulses.is_empty():
		if _neutral:
			return
		_neutral = true
	else:
		_neutral = false
	var selected: Variant = null
	var selected_strength := -1.0
	var rock_shot: Variant = null
	for s in impulses:
		var cam: Dictionary = s["camera"]
		var env := camera_envelope(s["age"])
		var strength: float = cam["roll"] * env
		if cam["kind"] == "rock" and _newer(s, rock_shot):
			rock_shot = s
		if cam["rank"] <= 0:
			continue
		if strength > selected_strength + 1e-9 or (absf(strength - selected_strength) <= 1e-9 and (selected == null or cam["rank"] > selected["camera"]["rank"])):
			selected = s
			selected_strength = strength
	var roll := 0.0
	var sx := 0.0
	var sy := 0.0
	var scale := 1.0
	var b := 0.0
	var k := 0.0
	var focus := 0.0
	var m := "none"
	if selected != null:
		var cam: Dictionary = selected["camera"]
		var env := camera_envelope(selected["age"])
		roll = cam["roll"] * env * cam["dir"]
		sx = cam["sx"] * env
		sy = cam["sy"] * env
		scale = 1.0 - cam["pull"] * pullback_envelope(selected["age"])
		b = cam["blur"] * blur_envelope(selected["age"])
		blur_dir = Vector2(selected["dx"], selected["dy"]).normalized() if Vector2(selected["dx"], selected["dy"]).length() > 1e-6 else Vector2(cam["dir"], 0)
		k = clampf(selected_strength / BIG_PEAK_MAX, 0.0, 1.0)
		m = cam["kind"]
	rock_phase = "none"
	if rock_shot != null:
		var age: float = rock_shot["age"]
		focus = rock_push_envelope(age)
		# The early pull-back is visible before the push-in but is gone by the .113 s scale target, so the held scale is exactly 1.28.
		var rock_pull: float = rock_shot["camera"]["pull"] * pullback_envelope(age) * (1.0 - smooth_unit(age / ROCK_IN))
		scale = 1.0 + (ROCK_SCALE - 1.0) * focus - rock_pull
		roll += rock_tilt_envelope(age) * rock_shot["camera"]["dir"]
		if age < ROCK_SETTLE_AT:
			m = "rock" if focus > 0.0 else (m if selected != null else "rock")
		rock_phase = "push" if age < ROCK_IN else ("hold" if age < ROCK_HOLD else ("release" if age < ROCK_OUT else ("tilt" if age < ROCK_SETTLE_AT else "none")))
		pivot_victim = 1 - int(rock_shot["attacker"])
	else:
		pivot_victim = -1
	roll = clampf(roll, -MAX_ROLL, MAX_ROLL)
	# release weight (knockdown / KO takes over)
	image_scale = lerpf(1.0, scale, _weight)
	shift_x = sx * _weight
	shift_y = sy * _weight
	roll_deg = roll * _weight
	blur = b * _weight
	rock_focus = focus * _weight
	kick = k * _weight
	mode = m


static func fov_for_scale(base_fov: float, scale: float) -> float:
	return rad_to_deg(2.0 * atan(tan(deg_to_rad(base_fov) * 0.5) / clampf(scale, 0.35, 1.45)))
