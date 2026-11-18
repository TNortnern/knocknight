extends RefCounted
## CPU defence-family choices (called from CpuBrain). Picks a defence per incoming head strike type, scaled by difficulty:
##   straights  -> shell / high guard (the common answer), tilt behind the guard, sway (lean back), full slip
##   hooks      -> deep roll (skilled) / duck, shell (the shoulder takes it), high guard
##   uppercuts  -> guard, shell, sway, step back (ducking into an uppercut is a mistake)
##   head kicks -> duck, guard, shell, step back
## Easy CPUs mostly just block; hard CPUs use the whole family and pick the right tool more often. The choice only sets the
## input (FighterInput); whether it works is decided by the geometry of the head against the glove path.

const COUNTER_TAG := "RHook"
const STAMINA_NEEDED := {"shell": 0.0, "guard": 0.0, "tilt": 6.0, "slip": 10.0, "sway": 10.0, "roll": 14.0, "duck": 8.0, "step": 0.0}


static func skill(b: CpuBrain) -> float:
	return clampf(float(b.diff["slip"]) / 0.35, 0.2, 1.0)


## Exchange awareness (scripts/combat/exchange.gd). A hurt or gassed CPU does not swap punches: it never starts or meets a
## punch while the foe's is in the air. A healthy one occasionally steps in with a straight under a hook (inside beats outside).
static func hurt(b: CpuBrain) -> bool:
	return b.f.stats.head / maxf(b.f.stats.head_max, 1.0) < 0.40 or b.f.stats.stamina_ratio() < 0.25 or b.f.stats.rocked


static func avoids_trade(b: CpuBrain) -> bool:
	var foe: Fighter = b.f.foe
	if foe == null or not hurt(b) or foe.state != Fighter.State.ATTACK or foe.atk.is_empty():
		return false
	return not foe.atk["hit_done"] and foe.punch_phase() != "recovery"


## The foe just started `s`: step in with a straight under a head hook now and then (returns true when it set up the counter).
static func wants_trade(b: CpuBrain, s: Dictionary, gap: float) -> bool:
	if s["is_leg"] or s["zone"] != "head" or not String(s["tag"]).contains("Hook") or hurt(b) or gap < 0.66 or gap > 1.06:
		return false
	if b.f.state != Fighter.State.IDLE or b.f.stats.stamina < 30.0:
		return false
	var p := float(b.diff["meet"]) * (0.45 if String(s.get("klass", "")) == "wide" else 0.28)
	return b.rng.randf() < p


## Chooses a defence against head strike `s`; sets b._def_kind / _def_t / _def_slip. Returns true when it chose one.
static func pick_head(b: CpuBrain, s: Dictionary, _gap: float) -> bool:
	var tag: String = s["tag"]
	var dir: String = s["dir"]
	var sk := skill(b)
	var w := {}
	if s["is_leg"]:
		w = {"duck": 0.30, "guard": 0.30, "shell": 0.20, "step": 0.20}
	elif tag.contains("Uppercut") or dir == "U":
		w = {"guard": 0.35, "shell": 0.25, "sway": 0.25 * sk, "step": 0.15}
	elif tag.contains("Hook") or dir == "L" or dir == "R" or dir == "O":
		w = {"roll": 0.34 * sk, "duck": 0.12 * sk, "shell": 0.28, "guard": 0.26}
	else:
		w = {"shell": 0.30, "guard": 0.22, "tilt": 0.18 * sk, "sway": 0.12 * sk, "slip": 0.10 * sk}
	for k in w.keys():
		if b.f.stats.stamina < float(STAMINA_NEEDED[k]) + 4.0 and float(STAMINA_NEEDED[k]) > 0.0:
			w.erase(k)
	var total := 0.0
	for k in w:
		total += float(w[k])
	if total <= 0.0:
		return false
	var r := b.rng.randf() * total
	var pick := "guard"
	for k in w:
		r -= float(w[k])
		if r <= 0.0:
			pick = k
			break
	b._def_kind = pick
	# side: away from the incoming hand (attacker's left arrives on our right), sometimes wrong on easy
	var side := 1 if String(s["limb"]) == "L" else -1
	if b.rng.randf() > 0.55 + 0.4 * sk:
		side = -side
	b._def_slip = side
	var act := float(s["action"])
	match pick:
		"tilt", "slip", "sway":
			b._def_t = clampf(act * 0.95 + 0.08, 0.3, 0.8)    # stay out until the strike has whiffed (counter window)
		"roll", "duck":
			b._def_t = clampf(act * 0.85 + 0.10, 0.3, 0.8)
		"step":
			b._def_t = 0.3
	return true


## Writes the chosen defence into `inp`. Returns true when `kind` was one of ours.
static func apply(b: CpuBrain, kind: String, inp: FighterInput) -> bool:
	match kind:
		"shell":
			inp.block = true
			inp.shell = true
		"tilt":
			inp.block = true
			inp.slip = b._def_slip
		"slip":
			inp.slip = b._def_slip
		"sway":
			inp.lean = Vector2(float(b._def_slip) * 0.2, -1.0)   # pull the head straight back (analog lean), feet planted
		"roll":
			inp.duck = true
			inp.slip = b._def_slip
		_:
			return false
	return true


## After an evasion the next strike: the authored rear-hook counter (RHook) when slipped / swayed, else the usual choice.
static func counter_tag(b: CpuBrain, fallback: String) -> String:
	## Counter thrown from the held lean: rear hook / lead hook from a side slip, the straight (pull counter) after a lean back.
	var le: Dictionary = b.f.dm.last_evade
	if le.is_empty() or b.f._time - float(le["t"]) > 0.8 or not (le["kind"] in ["slip", "sway"]) or b.rng.randf() > 0.75:
		return fallback
	if le["kind"] == "sway":
		return "RJab"
	return COUNTER_TAG if b.rng.randf() < 0.65 else "LHook"
