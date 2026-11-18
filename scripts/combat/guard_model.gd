extends RefCounted
## Guard coverage model (pure, no nodes): how much of a blocked punch gets through a raised guard, and whether a
## fresh block press is a parry. Preloaded by fighter.gd, the CPU and the tests (no class_name on purpose).
##
## A raised guard covers LANES. The punch's lane comes from its direction: straights -> "front", hooks / overhands -> "side"
## (temples), uppercuts -> "gap" (the opening between the gloves). Body shots against a body guard use the BODY table.
## Each (style, lane) has a cover value 0..1; leak = 1 - cover plus penalties:
##   hook class      wide hooks go around a guard (-0.32 side cover), tight ones do not (+0.12), overhands come over (-0.22)
##   setness         a guard raised < SET_TIME ago is not set yet: + SET_LEAK * (1 - age / SET_TIME)
##   guard meter     below 40 % the block is soft: up to +0.35
##   fatigue         + 0.18 * fatigue
##   heavy / power   + 0.08 for loaded punches
##   guard stagger   + 0.22 for STAGGER s after a heavy shot knocked the gloves open
##   graze           the fist reached the forearm edge, not the glove: up to +0.15
## leak < FULL_LEAK -> "full" (chip damage only); < PIERCE_LEAK -> "partial" (30-60 % of the damage + a flinch);
## otherwise "pierce" (70-90 % of the damage, a clean hit that rocks at reduced gain).

const SET_TIME := 0.15
const SET_LEAK := 0.45
const FULL_LEAK := 0.30
const PIERCE_LEAK := 0.55
const STAGGER := 0.25
const PARRY_COOLDOWN := 0.6     ## s: a block press within this of the previous press cannot parry (no mashing)
const PARRY_MIN := 0.03         ## s: a press this late is just too late to parry
const PARRY_WINDOW := 0.12      ## s: width of the parry window after PARRY_MIN (narrower when tired)
const PARRY_COST := 7.0         ## stamina
const PARRY_PUNISH := 0.30      ## s added to the attacker's recovery
const PIERCE_ROCK := 0.6        ## rock-meter share of a pierced shot

## [front, side, gap]
const COVER := {
	"high": [0.95, 0.82, 0.50],
	"peek": [0.93, 0.60, 0.62],
	"shell": [0.90, 0.72, 0.58],
	"long": [0.85, 0.50, 0.58],
}
const BODY_COVER := [0.92, 0.85, 0.75]


## "front" | "side" | "gap" from the strike row
static func lane_of(s: Dictionary) -> String:
	match String(s.get("dir", "F")):
		"L", "R", "O":
			return "side"
		"U":
			return "gap"
	return "front"


static func lane_index(lane: String) -> int:
	return 0 if lane == "front" else (1 if lane == "side" else 2)


## Block style of a fighter: "high" (tank), "peek" (keyshawn), "shell" (shoulder roll), "long" (lead hand low).
static func style_of(f) -> String:
	if f.dm.shell_on:
		return "shell"
	var gs = f.guard_style
	if gs != null:
		if f.block_variant == "lead_low":
			return "long"
		if f.block_variant == "peek":
			return "peek"
		return "peek" if gs.style_name == "keyshawn" else "high"
	return "high"


static func cover_of(style: String, lane: String, s: Dictionary, body_guard: bool) -> float:
	var li := lane_index(lane)
	var c: float
	if body_guard:
		c = BODY_COVER[li]
	else:
		c = float((COVER.get(style, COVER["high"]) as Array)[li])
	var limb := String(s.get("limb", "L"))
	var dir := String(s.get("dir", "F"))
	if lane == "side" and not body_guard:
		var klass := String(s.get("klass", "std"))
		if klass == "wide":
			c -= 0.32
		elif klass == "tight":
			c += 0.12
		if dir == "O":
			c -= 0.22
		# an attacker's right hook lands on the defender's lead (left) side
		if style == "long":
			c += 0.20 if limb == "L" else -0.10
		elif style == "shell":
			c += 0.06 if limb == "L" else -0.22
	elif lane == "front" and style == "shell" and not body_guard:
		c += 0.05 if limb == "R" else -0.08   # rear straights are covered by the shoulder
	return c


## p: {style, age (s since the guard went up), guard_ratio, fatigue, graze (0..1), open (stagger left, s), body_guard}
## Returns {kind: "full"|"partial"|"pierce", leak, frac}. frac = share of the unblocked damage that gets through.
static func assess(s: Dictionary, p: Dictionary) -> Dictionary:
	var lane := lane_of(s)
	var leak := 1.0 - cover_of(String(p.get("style", "high")), lane, s, bool(p.get("body_guard", false)))
	leak = maxf(leak, 0.04)
	var age := float(p.get("age", 9.0))
	leak += SET_LEAK * (1.0 - clampf(age / SET_TIME, 0.0, 1.0))
	var gr := float(p.get("guard_ratio", 1.0))
	leak += 0.35 * clampf((0.4 - gr) / 0.4, 0.0, 1.0)
	leak += 0.18 * float(p.get("fatigue", 0.0))
	if s.get("heavy", false) or s.get("power", false):
		leak += 0.08
	if float(p.get("open", 0.0)) > 0.0:
		leak += 0.22
	leak += 0.15 * clampf((float(p.get("graze", 0.0)) - 0.7) / 0.3, 0.0, 1.0)
	var kind := "full"
	var frac := 0.0
	if leak >= PIERCE_LEAK:
		kind = "pierce"
		frac = 0.70 + 0.20 * clampf((leak - PIERCE_LEAK) / 0.35, 0.0, 1.0)
	elif leak >= FULL_LEAK:
		kind = "partial"
		frac = 0.30 + 0.30 * (leak - FULL_LEAK) / (PIERCE_LEAK - FULL_LEAK)
	return {"kind": kind, "leak": leak, "frac": frac, "lane": lane}


## Can this strike be parried at all? Jabs / straights and ordinary hooks to the head; not loaded (power / wide) punches,
## uppercuts, body shots or kicks.
static func parryable(s: Dictionary) -> bool:
	if s.get("is_leg", false) or String(s.get("zone", "head")) != "head":
		return false
	if s.get("power", false) or String(s.get("klass", "std")) in ["wide", "lunge", "rise", "power"]:
		return false
	return String(s.get("dir", "F")) in ["F", "L", "R"]


## Parry window [lo, hi] of the guard age at contact; tired fighters get a narrower window, hooks a tighter one.
static func parry_window(s: Dictionary, fatigue: float) -> Vector2:
	var w := PARRY_WINDOW * (1.0 - 0.45 * clampf(fatigue, 0.0, 1.0))
	if String(s.get("dir", "F")) != "F":
		w *= 0.8
	return Vector2(PARRY_MIN, PARRY_MIN + w)


static func is_parry(s: Dictionary, age: float, fatigue: float, press_ok: bool, stamina: float) -> bool:
	if not press_ok or stamina < PARRY_COST or not parryable(s):
		return false
	var w := parry_window(s, fatigue)
	return age >= w.x and age <= w.y
