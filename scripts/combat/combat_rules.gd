class_name CombatRules
extends RefCounted
## Pure, stateless combat maths from docs/gameplay-spec.md (sections 4, 5, 6). No nodes, easy to unit-test.

const DAMAGE_SCALE := 0.55   # was 0.7: fights ended in R1 at ~60-190 s with 2-3 knockdowns (fatigue pass)
## Stamina regen per second (fatigue pass: was a flat 22 / 11 guarding, which made stamina meaningless).
const STAMINA_REGEN := 34.0         ## standing off: not moving, hands down
const STAMINA_REGEN_MOVE := 19.5    ## walking / circling
const STAMINA_REGEN_GUARD := 13.0    ## holding block, slips and ducks
const STAMINA_REGEN_BUSY := 2.6     ## mid-strike
const GUARD_REGEN := 18.0
const HEALTH_REGEN := 1.75
const ROCK_OFFENCE_LOCK := 1.2
const FatigueScript := preload("res://scripts/combat/fatigue.gd")
const CommitmentScript := preload("res://scripts/combat/commitment.gd")

## Damage cap per target class (spec 5.1).
static func damage_cap(s: Dictionary) -> float:
	var zone: String = s["zone"]
	if zone == "leg":
		return 12.0
	var kick: bool = s["source"] == "leg"
	if zone == "head":
		if kick:
			return 18.0
		return 20.0 if s.get("power", false) else 14.0
	return 18.0 if kick else 14.0


## Reaction (hit-stun) length cap in seconds: jab 0.20, other hand 0.28, kick 0.34.
static func reaction_cap(s: Dictionary) -> float:
	if s["source"] == "leg":
		return 0.34
	return 0.20 if String(s["tag"]).contains("Jab") else 0.28


static func guard_loss(s: Dictionary) -> float:
	return clampf(float(s["block_damage"]) * 1.5 + 7.0, 13.0, 32.0)


## Outcome tail seconds (committed time after the action) for a missed / blocked strike.
static func outcome_tail(s: Dictionary, outcome: String) -> float:
	var heavy: bool = s["heavy"]
	match outcome:
		"missed":
			return 0.24 if heavy else (0.05 if s["source"] == "leg" else 0.06)
		"blocked":
			if s["source"] == "leg":
				return 0.06 if heavy else 0.04
			return 0.07 if heavy else 0.04
	return 0.0


## Damage for an unblocked (or blocked, ctx.blocked) strike. ctx keys (all optional):
## blocked, attacker_rocked, quality, counter, def_stamina_ratio, closing (m/s attacker towards foe),
## def_walk_into (m/s defender towards attacker), def_side_speed_dps (signed, + matches L/R strike),
## def_action, def_taunting, def_rocked, def_guarding, def_body_strike, smother (damage multiplier, body_contact.gd).
## Returns {total, bonus, num}.
static func compute_damage(s: Dictionary, ctx: Dictionary) -> Dictionary:
	var blocked: bool = ctx.get("blocked", false)
	var num: float = float(s["block_damage"] if blocked else s["damage"])
	if ctx.get("attacker_rocked", false):
		num *= 0.72
	var bonus := 0.10 * num
	var dir: String = s["dir"]
	var side: float = ctx.get("def_side_speed_dps", 0.0)
	if (dir == "L" or dir == "R") and absf(side) > 24.0:
		bonus += (0.20 if side > 0.0 else -0.20) * num
	var closing: float = ctx.get("closing", 0.0)
	if dir != "L" and dir != "R":
		if closing > 0.5:
			bonus += 0.20 * num
		elif closing < -0.5:
			bonus -= 0.20 * num
	var walk: float = ctx.get("def_walk_into", 0.0)
	if walk > 0.5:
		bonus += 0.20 * num
	elif walk < -0.5:
		bonus -= 0.20 * num
	if ctx.get("def_action", false):
		bonus += 0.30 * num
	if ctx.get("def_taunting", false):
		bonus += 1.00 * num
	if ctx.get("def_rocked", false) and not ctx.get("def_guarding", false):
		bonus += 0.15 * num
	if ctx.get("def_body_strike", false) and dir == "U":
		bonus += 0.50 * num
	var cap := damage_cap(s)
	bonus = minf(bonus, cap * 0.5)
	var q: float = ctx.get("quality", 1.0)
	var total := minf(num + bonus, cap) * DAMAGE_SCALE * (0.45 + 0.55 * q)
	if ctx.get("counter", false):
		var cm := 1.25
		if ctx.get("open", false):
			cm = CommitmentScript.OPEN_MULT   # whiffed puncher still recovering
		if ctx.get("punish", false):
			cm = CommitmentScript.PUNISH_MULT   # uppercut into a low / forward head
		total *= cm
	total *= 1.0 + 0.25 * (1.0 - clampf(ctx.get("def_stamina_ratio", 1.0), 0.0, 1.0))
	total *= FatigueScript.damage_mult(float(ctx.get("attacker_fatigue", 0.0)))   # tired arms hit softer
	total *= float(ctx.get("smother", 1.0))   # body contact: long punches are smothered in close (body_contact.gd)
	total *= float(ctx.get("power_mult", 1.0)) * float(ctx.get("trade_mult", 1.0))   # exchange: a punch hit in flight lands weaker; trade winner / loser
	return {"total": maxf(total, 0.0), "bonus": maxf(bonus, 0.0), "num": num}


static func strength_of(s: Dictionary, total: float) -> String:
	if s.get("force_heavy", false) and total >= 4.0:   # loaded power punch variants always land as "heavy" (camera kick, sound, HUD)
		return "heavy"
	if total >= 9.5 or (s["source"] == "leg" and total >= 6.0):
		return "heavy"
	if total >= 5.0:
		return "medium"
	return "light"


## Rocked trigger (spec 5.4, retuned in the fatigue pass: the spec's 12.5 / meter 34 / 5 per s decay almost never
## fired in a real fight). A clean power shot (RHook 9.8, counter hooks 12) rocks outright, an accumulating meter
## (hooks count 1.35x, counters 1.5x, see rock_gain) rocks after a good exchange, and a hurt head rocks easily.
const ROCK_TOTAL := 8.4             ## single clean hit that rocks (a full-quality RHook, or a walked-into / tired-defender hook)
const ROCK_COUNTER_TOTAL := 7.0     ## ... when it is an earned counter (any decent counter hook)
const ROCK_METER := 40.0            ## accumulated "stun" that rocks
const ROCK_METER_DECAY := 3.0       ## per second (was 5)
const ROCK_GRACE := 14.0             ## s after recovering from a rock before the next one can start
const ROCK_HEAD_RATIO := 0.28       ## head / head_max at or below this: every clean head hit rocks (was 0.28)

static func should_rock(total: float, rock_meter: float, head: float, head_max: float, counter := false) -> bool:
	return total >= (ROCK_COUNTER_TOTAL if counter else ROCK_TOTAL) or rock_meter >= ROCK_METER or (head_max > 0.0 and head / head_max <= ROCK_HEAD_RATIO)


## How much a clean head hit adds to the rock meter.
static func rock_gain(total: float, s: Dictionary, counter: bool) -> float:
	var g := total
	if s.get("heavy", false) or s.get("power", false):
		g *= 1.35
	if counter:
		g *= 1.5
	return g


static func rock_severity(total: float, rock_meter: float, head: float, head_max: float) -> float:
	var ratio := head / maxf(head_max, 1.0)
	return clampf(total / 45.0 + rock_meter / 100.0 + 0.25 * (1.0 - ratio), 0.35, 1.0)


static func rock_duration(severity: float) -> float:
	return 3.2 + 2.8 * severity


## Knockdown assessment (spec 5.3). ev keys: power, kick, speed, quality, launch_stamina_ratio,
## head_ratio, exposed. True when a clean head hit knocks the defender down.
const KD_HEAD_RATIO := 0.28         ## head/100 below which a power shot floors an unrocked fighter (spec 0.50)
const KD_LAUNCH_STAMINA := 0.30     ## attacker needs this much stamina to throw a flooring shot (spec 0.55; fatigue now bites first)
const FLASH_KO_RATIO := 0.22        ## flash / follow-up KO only when the head is nearly gone (spec 0.40)

## Centredness a power shot needs to floor someone. Was 0.80; the punch-variety pose layer (wind-up dip, torso turn)
## lands clean power hooks at ~0.76, so 0.80 made knockdowns all but impossible.
const KD_MIN_QUALITY := 0.70

static func assess_knockdown(ev: Dictionary) -> bool:
	if not ev.get("power", false) or ev.get("grace", false):   # grace: just got up from a knockdown
		return false
	var min_speed := 3.0 if ev.get("kick", false) else 2.2
	var hr: float = ev.get("head_ratio", 1.0)
	# fatigue pass: a power shot floors a fighter who is already hurt (rocked) or whose head is nearly gone,
	# not just anyone under 50 % head (that dropped CPUs twice inside 25 s). Pass "rocked" in ev.
	var vulnerable: bool = hr < KD_HEAD_RATIO or (hr < 0.65 and ev.get("rocked", false))
	return ev.get("speed", 0.0) >= min_speed \
		and ev.get("quality", 0.0) >= KD_MIN_QUALITY \
		and ev.get("launch_stamina_ratio", 1.0) >= KD_LAUNCH_STAMINA \
		and vulnerable \
		and ev.get("exposed", false)


static func flash_ko_chance(head_ratio: float, stamina_ratio: float, balance: float) -> float:
	return clampf(0.18 + 0.20 * (1.0 - head_ratio / 0.4) + 0.12 * (1.0 - stamina_ratio) + 0.10 * (1.0 - balance), 0.05, 0.60)


## Reaction clip name for strike direction `dir` (F/L/R/U/O). Names are real animation names.
static func hit_clip(dir: String, kind: String) -> String:
	var d3 := dir if dir in ["F", "L", "R"] else "F"
	match kind:
		"punch":
			return "%s head punch" % d3
		"kick":
			return "%s head kick" % dir
		"break":
			return "%s head punch Break" % d3
		"stun":
			return "%s head Stun" % dir
		"ko":
			return "%s head KO" % dir
		"body_kick":
			return "%s body kick" % d3
		"body_break":
			return "%s body kick Break" % d3
		"body_pko":
			return "%s body PKO" % d3
		"body_ko":
			return "%s body KO" % d3
	return "F head punch"
