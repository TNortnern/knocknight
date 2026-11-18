extends RefCounted
## Punch variety: picks a concrete variant (data/punch_variants.json, layered on strike_table.json by StrikeDB) for a
## base punch tag, rolls the per-throw randomness and applies the step / miss behaviour of the variant.
## Referenced from fighter.gd / cpu code with `const PunchVariantsScript := preload(...)` (no class_name on purpose).
##
## A strike request is a base tag with an optional intent hint: "LJab" (tap), "LJab@power" (power modifier held),
## "LJab@quick" (CPU / chained), "LJab@step", "LJab@pull", "LJab@wide" ... or an already concrete variant tag
## ("LJab~flick"). Classes: std, flick, pull, lunge | tight, wide | rise | power (body shots).
## "LJab@aim" (tests): exactly that tag with no jitter, but aimed at the target like a real throw.

const SPEED_JITTER := 0.06   ## per-throw action-time variation, +-6 %

## kind of a base tag: jab (head jab / cross), hook, upper, bjab, bhook, bupper, "" (kicks, overhand, backfist ...)
static func kind_of(base: String) -> String:
	if base.length() < 4 or base.contains("~"):
		return ""
	var rest := base.substr(1)
	match rest:
		"Jab": return "jab"
		"Hook": return "hook"
		"Uppercut": return "upper"
		"BodyJab": return "bjab"
		"BodyHook": return "bhook"
		"BodyUppercut": return "bupper"
	return ""


## Hint -> class for a kind (the "power" hint means the kind's own loaded version).
static func class_for_hint(kind: String, hint: String) -> String:
	match hint:
		"power", "hold":
			match kind:
				"jab": return "lunge"
				"hook": return "wide"
				"upper": return "rise"
				_: return "power"
		"quick":
			match kind:
				"jab": return "flick"
				"hook": return "tight"
				_: return "std"
		"step": return "lunge" if kind == "jab" else "std"
	return hint if hint != "" else "std"


static func _meta(f: Node) -> Dictionary:
	if not f.has_meta("pv"):
		# own RNG: variant choice must not perturb the fighter's / brain's random sequences (other systems and tests lean on them)
		var r := RandomNumberGenerator.new()
		r.seed = 7001 + int(f.player_index) * 131
		f.set_meta("pv", {"last_tag": "", "last_start": -9.0, "last_class": "", "last_kind": "", "hist": {}, "rng": r})
	return f.get_meta("pv")


## Candidate tags of `klass` for `base` (std includes the base row itself).
static func candidates(base: String, klass: String) -> Array:
	var out := []
	if klass == "std":
		out.append(base)
	for t in StrikeDB.variant_tags(base):
		if StrikeDB.variant_row(t)["class"] == klass:
			out.append(t)
	return out


## Concrete variant tag for a strike request (see header). `f` is the throwing Fighter.
static func resolve(f: Node, request: String) -> String:
	var base := StrikeDB.strip_hint(request)
	var hint := request.substr(base.length() + 1) if request.length() > base.length() else ""
	var kind := kind_of(base)
	var m := _meta(f)
	m["literal"] = false
	m["aimed"] = false
	if hint == "aim" and kind != "":
		m["literal"] = true
		m["aimed"] = true
		return base
	if kind == "" or not StrikeDB.variant_row(base).is_empty():
		m["literal"] = kind != ""
		return base   # kicks / overhands / backfists / explicit variants keep their tag
	if hint == "" and f.external_input != null:
		m["literal"] = true
		return base   # scripted input (tests, replays) throws exactly the tag it names; "LJab@auto" asks for the human-style choice
	var klass := ""
	if hint != "" and hint != "auto":
		klass = class_for_hint(kind, hint)
	else:
		klass = _auto_class(f, kind, m)
	var cand := candidates(base, klass)
	if cand.is_empty():
		cand = candidates(base, "std")
	# never the exact same clip twice in a row when there is an alternative
	var hist: Dictionary = m["hist"]
	var last_clip: String = hist.get(base, "")
	if cand.size() > 1:
		var alt := cand.filter(func(t): return String(StrikeDB.get_strike(t)["clip"]) != last_clip)
		if not alt.is_empty():
			cand = alt
	return cand[(m["rng"] as RandomNumberGenerator).randi() % cand.size()]


static func _auto_class(f: Node, kind: String, m: Dictionary) -> String:
	var recent: bool = f._time - float(m["last_start"]) <= 1.0 and m["last_kind"] in ["jab", "hook", "upper"]
	var fwd := 0.0
	var mv: Vector2 = f.inp.move
	if mv.length() > 0.4 and f.foe != null:
		fwd = Vector3(mv.x, 0, -mv.y).normalized().dot(f.dir_to_foe())
	var gap: float = f.gap_to_foe()
	if kind == "jab":
		if recent and m["last_class"] not in ["lunge", "wide", "rise"]:
			return "flick"    # tap, tap: double / triple jab
		if fwd > 0.55 and gap > 0.92:
			return "lunge"    # stepping in while jabbing
		if fwd < -0.55 and gap < 1.25:
			return "pull"     # pulling back while jabbing
	elif kind == "hook" and recent and m["last_class"] not in ["lunge", "wide", "rise"]:
		return "tight"
	return "std"


static func note_start(f: Node, tag: String) -> void:
	var m := _meta(f)
	var s := StrikeDB.get_strike(tag)
	var base := String(s.get("base_tag", tag))
	m["last_tag"] = tag
	m["last_start"] = f._time
	m["last_class"] = String(s.get("klass", "std"))
	m["last_kind"] = kind_of(base)
	(m["hist"] as Dictionary)[base] = s["clip"]


## Per-throw randomness: speed +-6 %, torso rotation, aim noise, overextension amount, how long the glove holds at full
## extension (StrikeDB.HOLD x 0.7-1.7: the reference's jabs hold 0.05-0.15 s). Stored in atk["var"].
static func roll(f: Node, _s: Dictionary) -> Dictionary:
	var r: RandomNumberGenerator = _meta(f)["rng"]
	if _meta(f).get("literal", false):   # scripted literal tags: deterministic timing and pose (no jitter, no aim)
		return {"speed": 1.0, "yaw_mul": 1.0, "aim_noise": Vector2.ZERO, "lean_mul": 1.0, "dip_mul": 1.0, "hold": 1.0,
			"literal": not _meta(f).get("aimed", false)}
	return {
		"speed": 1.0 + r.randf_range(-SPEED_JITTER, SPEED_JITTER),
		"yaw_mul": r.randf_range(0.75, 1.3),
		"aim_noise": Vector2(r.randf_range(-0.025, 0.025), r.randf_range(-0.02, 0.02)),
		"lean_mul": r.randf_range(0.8, 1.25),
		"dip_mul": r.randf_range(0.8, 1.2),
		"hold": r.randf_range(0.7, 1.7),
	}


## After Fighter._start_lunge: variants override the step (distance, duration; negative = pull back, 0 = none).
static func after_start(f: Node, s: Dictionary) -> void:
	f._lunge_dur = 0.24
	if not s.has("lunge"):
		return
	var d: float = s["lunge"]
	var dur: float = s.get("lunge_t", 0.24)
	f._lunge_dur = dur
	var gap: float = f.gap_to_foe()
	if d > 0.0:
		d = minf(d, maxf(gap - 0.76, 0.0))
		f._lunge_dist = d
		f._lunge_left = dur if d > 0.01 else 0.0
	elif d < 0.0:
		f._lunge_dist = d
		f._lunge_left = dur
	else:
		f._lunge_left = 0.0
	f._lunge_t = 0.0


## Extra committed recovery after a whiff (power punches overextend), added to CombatRules.outcome_tail.
static func tail_extra(s: Dictionary, outcome: String) -> float:
	return float(s.get("miss_tail", 0.0)) if outcome == "missed" else 0.0


## A whiffed power punch carries the fighter forward a little (stumble) - the counter window is the longer tail.
static func on_miss(f: Node, s: Dictionary) -> void:
	var lean := float(s.get("miss_lean", 0.0))
	if lean <= 0.0 or f.foe == null:
		return
	if f.gap_to_foe() > 0.66:
		f.apply_impulse(f.dir_to_foe(), 0.045 * lean)
