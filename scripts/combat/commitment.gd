extends RefCounted
## Punch commitment (pure rules, no nodes): when the guard / feet may come back after a punch, how much a miss or a
## block costs, and who is "open" to a punish. Referenced with `const CommitmentScript := preload(...)`.
##
## A punch runs: startup -> extension -> retraction -> recovery. The hand cannot leave the punch for a block or a walk
## until `lock_time` (the end of the retraction); a miss overextends and adds `miss_extra`, a blocked punch `block_extra`.
## While a missed punch is still recovering the puncher is OPEN: a punch that lands then is a counter (OPEN_MULT damage,
## OPEN_ROCK rock gain). An uppercut that finds a head that is low or forward (body shot in flight, a duck, a lean, an
## overextended whiff) is a PUNISH (PUNISH_MULT, PUNISH_ROCK).
##
## Fraction of the action time A after which the guard / feet are free again (clean punch), by kind (PunchVariants.kind_of):
## jab 0.66 (~0.38 s), cross 0.95 (~0.55), hook 0.78 (~0.58), uppercut 0.89 (~0.62), body shots +10 %, loaded
## (power) versions ~x1.35 of those.

const PunchVariantsScript := preload("res://scripts/combat/punch_variants.gd")

const LOCK_FRAC := {"jab": 0.66, "hook": 0.78, "upper": 0.89, "bjab": 0.72, "bhook": 0.86, "bupper": 0.97}
const LOCK_FRAC_CROSS := 0.95
## loaded versions: std total x ~1.35 over their longer action
const LOCK_FRAC_POWER := {"jab": 0.66, "hook": 0.83, "upper": 0.97, "bjab": 0.77, "bhook": 0.91, "bupper": 1.0}
const LOCK_FRAC_OTHER := 0.95   # kicks, overhands, ...

const MISS_JAB := 0.10
const MISS_HOOK := 0.25
const MISS_UPPER := 0.30
const MISS_POWER := 0.40
const BLOCK_LIGHT := 0.08
const BLOCK_HEAVY := 0.12
const BLOCK_POWER := 0.15

const OPEN_MULT := 1.35     ## damage of a punch that lands on a puncher who whiffed and is still recovering (counter is 1.25)
const OPEN_ROCK := 1.4      ## rock-meter gain multiplier in that window (counter is 1.5)
const PUNISH_MULT := 1.5    ## uppercut into a low / forward head
const PUNISH_ROCK := 1.6   ## trimmed with OPEN_ROCK after merge: counters + guard pierces were stacking up to ~10 rocks a bout

const STAGGER_STEP_MEDIUM := 0.050   ## m: root impulse of a medium hit's stagger step
const STAGGER_STEP_HEAVY := 0.080


static func _base(s: Dictionary) -> String:
	return String(s.get("base_tag", s["tag"]))


static func is_cross(s: Dictionary) -> bool:
	var b := _base(s)
	return b.begins_with("R") and b.ends_with("Jab") and not b.contains("Body")


static func lock_frac(s: Dictionary) -> float:
	var kind := PunchVariantsScript.kind_of(_base(s))
	if kind == "":
		return LOCK_FRAC_OTHER
	if s.get("power", false):
		return float(LOCK_FRAC_POWER[kind])
	if kind == "jab" and is_cross(s):
		return LOCK_FRAC_CROSS
	return float(LOCK_FRAC[kind])


## Action seconds until the guard / feet may come back after a clean punch of action time `a` (already includes k).
static func lock_time(s: Dictionary, a: float) -> float:
	return a * lock_frac(s)


static func miss_extra(s: Dictionary) -> float:
	if s.get("power", false) or s.get("heavy", false) and not _base(s).contains("Hook") and not _base(s).contains("Uppercut"):
		return MISS_POWER
	var b := _base(s)
	if b.contains("Uppercut"):
		return MISS_UPPER
	if b.contains("Hook"):
		return MISS_HOOK
	if s.get("is_leg", false):
		return MISS_UPPER
	return MISS_JAB


static func block_extra(s: Dictionary) -> float:
	if s.get("power", false):
		return BLOCK_POWER
	var b := _base(s)
	if b.contains("Jab") and not b.contains("Body"):
		return BLOCK_LIGHT
	return BLOCK_HEAVY


## When the guard / feet may come back for the live attack `atk` (Fighter.atk): clean lock plus the miss / block penalty.
static func lock_end(atk: Dictionary) -> float:
	var s: Dictionary = atk["s"]
	var k: float = atk["k"]
	return lock_time(s, float(atk["A"])) + float(atk.get("pen", 0.0)) * k


## Sets the penalty of a finished outcome on the attack ("missed" | "blocked"), once.
static func note_outcome(atk: Dictionary, outcome: String) -> void:
	if atk.has("pen_set"):
		return
	var s: Dictionary = atk["s"]
	if outcome == "missed":
		atk["pen"] = miss_extra(s)
	elif outcome == "blocked":
		atk["pen"] = block_extra(s)
	else:
		return
	atk["pen_set"] = true


## Whiffed punch that is still recovering: the puncher cannot defend, anything that lands is an earned counter.
static func is_open(atk: Dictionary) -> bool:
	return not atk.is_empty() and (atk["outcome"] == "missed" or atk["outcome"] == "parried")


## A whiffed loaded punch (or any heavy one) cannot be chained out of: you are too far through it.
static func blocks_chain(atk: Dictionary) -> bool:
	return atk["outcome"] == "missed" and bool(atk["s"].get("power", false))
