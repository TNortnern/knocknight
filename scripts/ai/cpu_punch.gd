extends RefCounted
## CPU punch-variant choice (scripts/combat/punch_variants.gd defines the variants). Called by CpuBrain wherever it
## throws a base punch: returns the tag with a class hint ("LJab@lunge"), picked from the situation:
## gap (step-in jab / wide hook from distance), foe guard (probe with flicks, go around with wide hooks, to the body),
## stamina (no loaded punches when tired), a hurt foe (press with power), follow-ups in a combo (flick / tight).

const PunchVariantsScript := preload("res://scripts/combat/punch_variants.gd")
static var _rngs := {}   # per brain, own deterministic rng: the brain's decision sequence stays untouched


static func _hi(base: String, klass: String) -> float:
	var c: Array = PunchVariantsScript.candidates(base, klass)
	if c.is_empty():
		return 0.0
	var row := StrikeDB.variant_row(c[0])
	if row.has("range"):
		return float(row["range"][1])
	return 1.1   # the base strike


## Weighted pick among {class: weight}, dropping classes that cannot reach `gap`.
static func _rng_of(brain) -> RandomNumberGenerator:
	var id: int = brain.get_instance_id()
	if not _rngs.has(id):
		var r := RandomNumberGenerator.new()
		r.seed = 9901 + int(brain.f.player_index) * 77
		_rngs[id] = r
	return _rngs[id]


static func _weighted(brain, base: String, gap: float, w: Dictionary) -> String:
	var total := 0.0
	var ok := {}
	for k in w:
		if PunchVariantsScript.candidates(base, k).is_empty():
			continue
		if gap > _hi(base, k) - 0.06:
			continue
		ok[k] = w[k]
		total += w[k]
	if total <= 0.0:
		return "std"
	var r: float = _rng_of(brain).randf() * total
	for k in ok:
		r -= ok[k]
		if r <= 0.0:
			return k
	return "std"


static func pick(brain, tag: String, gap: float, foe_hurt: bool, follow_up := false) -> String:
	var kind := PunchVariantsScript.kind_of(tag)
	if kind == "":
		return tag
	var f = brain.f
	var foe = f.foe
	var stam: float = f.stats.stamina_ratio()
	var tired := stam < 0.40
	var guarding: bool = foe != null and foe.guard_on and not foe.guard_body   # a raised HEAD guard: go around it with wide hooks, split it with uppercuts
	# Loaded punches are a choice, not the default: they hit 1.4-1.45x and cost 1.3-1.5x stamina, and a CPU
	# that threw them half the time gassed itself in ~12 s and finished fights inside round 1.
	var w := {}
	match kind:
		"jab":
			if follow_up:
				w = {"flick": 0.7, "std": 0.3}
			elif foe_hurt and not tired:
				w = {"lunge": 0.35, "std": 0.4, "flick": 0.25}
			elif gap > 1.02:
				w = {"lunge": 0.16, "std": 0.84} if not tired else {"std": 1.0}
			else:
				w = {"std": 0.50, "flick": 0.28 if not guarding else 0.4, "lunge": 0.0 if tired else 0.03, "pull": 0.08}
				if foe != null and foe.state == Fighter.State.ATTACK:
					w["pull"] = 0.30
		"hook":
			if follow_up:
				w = {"tight": 0.55, "std": 0.3, "wide": 0.15}
			elif foe_hurt and not tired:
				w = {"wide": 0.40, "std": 0.4, "tight": 0.2}
			else:
				w = {"std": 0.40, "tight": 0.12 if guarding else 0.28, "wide": 0.0 if tired else (0.20 if guarding else 0.07)}
		"upper":
			w = {"std": 0.55, "rise": 0.0 if tired else (0.5 if foe_hurt else (0.20 if guarding else 0.10))}
		_:
			w = {"std": 0.65, "power": 0.0 if tired else (0.45 if foe_hurt else 0.08)}
	return "%s@%s" % [tag, _weighted(brain, tag, gap, w)]
