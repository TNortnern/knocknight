extends RefCounted
## Stamina / fatigue maths (pure, stateless). Preload it: `const FatigueScript := preload("res://scripts/combat/fatigue.gd")`.
##
## `level(ratio)` turns the stamina ratio (0..1 of the current max) into a fatigue level 0..1:
## 0 above SOFT (42 %), ~0.5 at 20 %, 1 at empty. Everything the player can feel hangs off that one number:
## slower strikes, weaker damage, longer stamina locks, slower footwork, lower gloves + heavy breathing (fatigue_pose.gd),
## no power shots below POWER_CUTOFF, a flashing HUD bar.

const SOFT := 0.42             ## stamina ratio where tiredness starts
const POWER_CUTOFF := 0.20     ## below this ratio no hook / uppercut / kick can be thrown (jabs only)
const COST_MULT := 1.15        ## every strike costs this x its strike-table stamina
const POWER_COST_MULT := 1.15  ## extra on hooks / uppercuts / kicks (the table values are for a different, regen-heavy economy)
const WHIFF_EXTRA := 0.50      ## a punch that finds nothing costs this x its base cost on top (landed < whiffed)
const SLOW_MAX := 0.65         ## strike time x (1 + SLOW_MAX x level): 1.0 .. 1.65
const DAMAGE_LOSS := 0.34      ## outgoing damage x (1 - DAMAGE_LOSS x level)
const MOVE_LOSS := 0.30        ## footwork speed x (1 - MOVE_LOSS x level)


static func level(ratio: float) -> float:
	return clampf((SOFT - ratio) / SOFT, 0.0, 1.0)


static func action_scale(lvl: float) -> float:
	return 1.0 + SLOW_MAX * lvl


static func damage_mult(lvl: float) -> float:
	return 1.0 - DAMAGE_LOSS * lvl


static func move_scale(lvl: float) -> float:
	return 1.0 - MOVE_LOSS * lvl


static func is_power(s: Dictionary) -> bool:
	return bool(s.get("heavy", false)) or bool(s.get("is_leg", false)) or bool(s.get("power", false))


## Stamina paid when a strike starts.
static func strike_cost(s: Dictionary) -> float:
	return float(s["stamina"]) * COST_MULT * (POWER_COST_MULT if is_power(s) else 1.0)


## Extra stamina paid when the strike turns out to be a whiff.
static func whiff_cost(s: Dictionary) -> float:
	return strike_cost(s) * WHIFF_EXTRA


## Seconds the regen stays locked after throwing (power shots lock longer; tired arms lock longer still).
static func strike_lock(s: Dictionary, lvl: float) -> float:
	return (0.9 if is_power(s) else 0.6) * (1.0 + 0.8 * lvl)


## Stamina drained by a guarded strike.
static func block_cost(s: Dictionary) -> float:
	return 1.0 + 0.25 * float(s["block_damage"])


## Stamina drained by an unblocked hit (body shots take the wind out of you). Head shots cost nothing: the owner
## found head shots draining the defender's tank unplayable.
static func hit_cost(total: float, zone: String) -> float:
	if zone == "head":
		return 0.0
	return (1.5 + 0.35 * total) * (1.8 if zone == "body" else 1.0)


static func blocks_power(ratio: float, s: Dictionary) -> bool:
	return ratio < POWER_CUTOFF and is_power(s)
