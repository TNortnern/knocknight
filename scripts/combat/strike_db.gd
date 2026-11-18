class_name StrikeDB
extends RefCounted
## Strike catalog: data/strike_table.json (strikes.json merged with the spec timing table)
## plus data/strike_measure.json (active window measured from the animated fist/foot, clip seconds).

static var _table: Dictionary = {}
static var _measure: Dictionary = {}
static var _variants: Dictionary = {}   ## data/punch_variants.json: "LJab~flick" -> overrides on the base row (see tools/gen_punch_variants.py)
static var _loaded := false

const CORE_HAND := ["LJab", "RJab", "LHook", "RHook", "LUppercut", "RUppercut"]
const CORE_BODY := ["LBodyJab", "RBodyJab", "LBodyHook", "RBodyHook", "LBodyUppercut", "RBodyUppercut"]

static func _ensure() -> void:
	if _loaded:
		return
	_loaded = true
	_table = JSON.parse_string(FileAccess.get_file_as_string("res://data/strike_table.json"))
	_measure = JSON.parse_string(FileAccess.get_file_as_string("res://data/strike_measure.json"))
	var vtxt := FileAccess.get_file_as_string("res://data/punch_variants.json")
	if vtxt != "":
		_variants = JSON.parse_string(vtxt)

## "LJab@power" -> "LJab": an input hint (see scripts/combat/punch_variants.gd) rides behind the base tag.
static func strip_hint(tag: String) -> String:
	var i := tag.find("@")
	return tag if i < 0 else tag.substr(0, i)

static func has_strike(tag: String) -> bool:
	_ensure()
	tag = strip_hint(tag)
	return _table.has(tag) or _variants.has(tag)

## Variant keys of a base strike ("LJab" -> ["LJab~flick", ...]).
static func variant_tags(base: String) -> Array:
	_ensure()
	var out := []
	for k in _variants:
		if _variants[k]["base"] == base:
			out.append(k)
	return out

static func variant_row(tag: String) -> Dictionary:
	_ensure()
	return _variants.get(tag, {})

## Table row (variant rows are the base row with the variant's overrides and multipliers applied).
static func _row(tag: String) -> Dictionary:
	if _table.has(tag):
		return (_table[tag] as Dictionary).duplicate()
	var v: Dictionary = _variants.get(tag, {})
	if v.is_empty():
		return {}
	var s: Dictionary = (_table[v["base"]] as Dictionary).duplicate()
	var a0: float = s["action"]
	var a: float = v.get("action", a0)
	s["tag"] = tag
	s["base_tag"] = v["base"]
	s["klass"] = v["class"]
	s["clip"] = v["clip"]
	s["action"] = a
	s["recoil"] = v.get("recoil", float(s["recoil"]) * a / a0)
	s["chain"] = v.get("chain", float(s["chain"]) * a / a0)
	s["damage"] = float(s["damage"]) * float(v.get("dmg", 1.0))
	s["block_damage"] = float(s["block_damage"]) * float(v.get("dmg", 1.0))
	s["stamina"] = float(s["stamina"]) * float(v.get("sta", 1.0))
	s["reach"] = v.get("reach", s["reach"])
	s["power"] = v.get("power", false)
	s["force_heavy"] = s["power"]
	for k in ["pf", "lunge", "lunge_t", "yaw", "dip", "hang", "miss_tail", "miss_lean", "miss_yaw", "range"]:
		if v.has(k):
			s[k] = v[k]
	return s

static func all_tags() -> Array:
	_ensure()
	return _table.keys()

## Contact (fist/foot at full extension) is reachable by a defender only if it is not instant: the source clips
## reach their peak 0.05-0.1 s after the first frame, the spec timings (and human feel) want ~0.25-0.5 s.
## So the clip is played through a TIME REMAP: clip time 0..peak is stretched (slow wind-up easing into the snap)
## so the peak lands at `t_peak` (action seconds), then peak..len is squeezed into the rest of the action.
## Contact floors by family (seconds from strike start, at k = 1): jab, hook/uppercut, kick.
const PEAK_FLOOR := {"jab": 0.26, "hook": 0.32, "upper": 0.34, "other": 0.30, "round": 0.48, "front": 0.44, "low": 0.36}
## Hand-strike tempo: the way OUT of a hand strike (contact floor / `pf`, c0) x this. The owner's reference (Tale of the
## Tape) lands a jab ~0.1 s after the glove leaves the guard, holds it 0.05-0.15 s, is back in guard by ~0.3-0.35 s and
## double jabs ~0.35 s apart. So only the snap out is quick: the hold and the way back keep the spec's time (action,
## chain, recoil), which scaled with the rest made every punch rubber-band back at 3-4x mocap speed (turbo). Kicks keep
## the spec timings.
const HAND_TEMPO := {"jab": 0.65, "hook": 0.75, "upper": 0.75, "other": 0.8}
## The glove holds at full extension this long (action seconds) before coming back; a variant's own `hang` wins if longer.
## Fighter varies it per throw (PunchVariants roll `hold`).
const HOLD := {"jab": 0.06, "hook": 0.07, "upper": 0.07, "other": 0.06}
## After the hold the glove comes back on a Hermite curve: leaves at RETURN_IN x the average return rate (no snap off the
## hold) and settles into the guard at RETURN_OUT x.
const RETURN_IN := 0.45
const RETURN_OUT := 0.5
const CLIP_SPEEDUP := 1.5   ## a clip's own wind-up may play at most this x faster than authored before contact
## Share of the clip's trunk counter-rotation (the shoulders turning away before the punch) that is kept; PunchPose
## turns the rest back. The lead body hook clip coils the shoulders 65 deg the wrong way (the rear one only 27 deg).
const COIL_KEEP := {"LBodyHook": 0.4, "LBodyHook~power": 0.6}
const WINDUP_EASE := 2.7    ## max ease: the pre-peak curve arrives at contact at `ease` x its average rate (accelerating into contact)
## The pre-contact curve leaves the guard at START_RATE x its average rate, so the glove moves on the first frame (the old
## pure power curve sat still for the first ~0.15 s of a jab, then snapped: a hitch, not a punch).
const START_RATE := 0.55
const HANG_CREEP := 0.05    ## share of the post-peak clip that plays during a variant's `hang`
const PEAK_RATE := 1.1      ## the fist never moves faster than this x the clip speed at contact (keeps hit speed / quality sane)

static func _family(tag: String, is_leg: bool) -> String:
	if is_leg:
		if tag.contains("Low"):
			return "low"
		if tag.contains("Front"):
			return "front"
		return "round"
	if tag.contains("Jab"):
		return "jab"
	if tag.contains("Hook"):
		return "hook"
	if tag.contains("Uppercut"):
		return "upper"
	return "other"

## Returns a fresh Dictionary: table row + `clip_len`, `clip_peak`, `t_peak` (target contact time, action seconds),
## `peak`, `w0`, `w1` (active window in ACTION seconds, through the time remap), `heavy`, `is_leg`.
static func get_strike(tag: String) -> Dictionary:
	_ensure()
	tag = strip_hint(tag)
	var s: Dictionary = _row(tag)
	if s.is_empty():
		return {}
	var m: Dictionary = _measure.get(tag, {})
	s["is_leg"] = s["source"] == "leg"
	var fam := _family(tag, s["is_leg"])
	var clip_len: float = m.get("len", float(s["action"]))
	var cpeak: float = clampf(float(m.get("peak", float(s["c0"]) * clip_len / float(s["action"]))), 0.04, clip_len * 0.9)
	var tempo: float = 1.0 if s["is_leg"] else HAND_TEMPO[fam]
	if tempo != 1.0:
		for k in ["c0", "pf"]:
			if s.has(k):
				s[k] = float(s[k]) * tempo
		s["hang"] = maxf(float(s.get("hang", 0.0)), HOLD[fam])
	var a: float = s["action"]
	# variants set their own contact time (a flick lands before the table's c0, a lunge after it)
	var floor_t: float = float(s["pf"]) if s.has("pf") else maxf(PEAK_FLOOR[fam] * tempo, float(s["c0"]))
	var t_peak := maxf(floor_t, cpeak / (CLIP_SPEEDUP if tempo != 1.0 else 1.25))
	t_peak = minf(t_peak, minf(float(s["chain"]) - 0.04, a * 0.72))
	s["clip_len"] = clip_len
	s["clip_peak"] = cpeak
	s["t_peak"] = t_peak
	s["ease"] = clampf(PEAK_RATE * t_peak / cpeak, 1.0, WINDUP_EASE)
	s["peak"] = t_peak
	s["w0"] = maxf(0.0, action_time(s, float(m.get("w0", s["c0"]))) - 0.015)
	s["w1"] = minf(a, maxf(action_time(s, float(m.get("w1", s["c1"]))) + 0.03, t_peak + 0.07))
	s["heavy"] = is_heavy(s)
	s["coil_keep"] = COIL_KEEP.get(tag, 1.0)
	s["tempo"] = tempo
	return s

## Share (0..1) of the pre-contact clip shown after `u` (0..1) of the time to contact: a Hermite curve leaving at START_RATE and
## arriving at `ease` (both x the average rate). Monotonic for every ease up to WINDUP_EASE.
static func windup_curve(s: Dictionary, u: float) -> float:
	u = clampf(u, 0.0, 1.0)
	var u2 := u * u
	var u3 := u2 * u
	return (-2.0 * u3 + 3.0 * u2) + START_RATE * (u3 - 2.0 * u2 + u) + float(s["ease"]) * (u3 - u2)


## Share (0..1) of the post-contact clip played after `v` (0..1) of the retraction time. A Hermite curve that starts at the
## rate the extension arrived with (no velocity jump at contact) and eases out to rest: the glove comes back fast, then settles
## (FNC: retraction 0.13-0.37 s, eased out). Same total time, same end points as the old straight line.
static func retract_curve(s: Dictionary, v: float) -> float:
	v = clampf(v, 0.0, 1.0)
	var tp: float = s["t_peak"]
	var cp: float = s["clip_peak"]
	var a: float = s["action"]
	var rest := maxf(float(s["clip_len"]) - cp, 0.001)
	var r0 := cp * float(s["ease"]) / maxf(tp, 0.01)          # clip seconds per second at contact
	var m0 := clampf(r0 * (a - tp) / rest, 0.6, 2.6)
	var v2 := v * v
	var v3 := v2 * v
	return (v3 - 2.0 * v2 + v) * m0 + (-2.0 * v3 + 3.0 * v2)


## Share (0..1) of the post-hold clip played after `v` (0..1) of the time from the end of the hold to the end of the action.
static func return_curve(v: float) -> float:
	v = clampf(v, 0.0, 1.0)
	var v2 := v * v
	var v3 := v2 * v
	return (v3 - 2.0 * v2 + v) * RETURN_IN + (-2.0 * v3 + 3.0 * v2) + (v3 - v2) * RETURN_OUT


## Clip seconds shown at action time `t` (already divided by the rocked slow-down factor k).
static func clip_time(s: Dictionary, t: float) -> float:
	var tp: float = s["t_peak"]
	var cp: float = s["clip_peak"]
	var a: float = s["action"]
	if t <= 0.0:
		return 0.0
	if t <= tp:
		return cp * windup_curve(s, t / tp)
	if t >= a:
		return s["clip_len"]
	var h: float = s.get("hang", 0.0)   # variants: the fist lingers at full extension (follow-through) before recovering
	if h > 0.0:
		var cp2 := cp + HANG_CREEP * (float(s["clip_len"]) - cp)
		if t <= tp + h:
			return cp + (cp2 - cp) * (t - tp) / h
		return cp2 + (float(s["clip_len"]) - cp2) * return_curve((t - tp - h) / maxf(a - tp - h, 0.001))
	return cp + (float(s["clip_len"]) - cp) * retract_curve(s, (t - tp) / maxf(a - tp, 0.001))

## Inverse of clip_time: action seconds (k = 1) at which the animation shows clip second `tau`.
static func action_time(s: Dictionary, tau: float) -> float:
	var tp: float = s["t_peak"]
	var cp: float = s["clip_peak"]
	var a: float = s["action"]
	if tau <= cp:
		var want := clampf(tau / cp, 0.0, 1.0)
		var lo0 := 0.0
		var hi0 := 1.0
		for i in 18:
			var mid0 := 0.5 * (lo0 + hi0)
			if windup_curve(s, mid0) < want:
				lo0 = mid0
			else:
				hi0 = mid0
		return tp * 0.5 * (lo0 + hi0)
	var h: float = s.get("hang", 0.0)
	if h > 0.0:
		var cp2 := cp + HANG_CREEP * (float(s["clip_len"]) - cp)
		if tau <= cp2:
			return tp + h * (tau - cp) / maxf(cp2 - cp, 0.001)
		var want2 := clampf((tau - cp2) / maxf(float(s["clip_len"]) - cp2, 0.001), 0.0, 1.0)
		var lo2 := 0.0
		var hi2 := 1.0
		for i in 18:
			var mid2 := 0.5 * (lo2 + hi2)
			if return_curve(mid2) < want2:
				lo2 = mid2
			else:
				hi2 = mid2
		return minf(a, tp + h + 0.5 * (lo2 + hi2) * (a - tp - h))
	var target := clampf((tau - cp) / maxf(float(s["clip_len"]) - cp, 0.001), 0.0, 1.0)
	var lo := 0.0
	var hi := 1.0
	for i in 18:
		var mid := 0.5 * (lo + hi)
		if retract_curve(s, mid) < target:
			lo = mid
		else:
			hi = mid
	return minf(a, tp + 0.5 * (lo + hi) * (a - tp))

## Playback rate (clip s per real s) at action time t for a strike played with slow-down k.
static func clip_rate(s: Dictionary, t: float, k: float, dt: float) -> float:
	return (clip_time(s, (t + dt) / k) - clip_time(s, t / k)) / maxf(dt, 0.0001)

static func is_heavy(s: Dictionary) -> bool:
	var tag: String = s["tag"]
	if s["source"] == "leg":
		return true
	if s.has("klass"):
		# variants: the loaded power versions are heavy; "std" alternates behave like their base; flick / tight / pull are not
		return s.get("force_heavy", false) or (s["klass"] == "std" and (tag.contains("Hook") or tag.contains("Uppercut")))
	return tag.contains("Hook") or tag.contains("Uppercut") or s.get("power", false) or float(s["damage"]) >= 20.0

## Build the strike tag for a keyboard/pad combination. side "L"/"R"; kind "Jab","Hook","Uppercut","Round","Low".
static func resolve_tag(side: String, kind: String, body: bool, spec: bool) -> String:
	match kind:
		"Jab", "Hook", "Uppercut":
			return side + ("Body" if body else "") + kind
		"Kick":
			var base := "Front" if spec else "Round"
			return side + ("Body" if body else "") + base + "Kick"
		"Low":
			return side + "LowKick"
	return ""
