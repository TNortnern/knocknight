extends RefCounted
## Punch exchange rules (pure, no nodes): when two fighters punch at once.
## Referenced with `const ExchangeScript := preload("res://scripts/combat/exchange.gd")` (no class_name on purpose).
##
## Real boxing logic, tuned for feel:
##  * A punch has phases: startup (hand not yet released) -> committed (travelling) -> contact (window open) -> recovery.
##    Hit in startup and you were beaten to the punch (interrupted, counts as a counter). Hit once the hand is released
##    and the punch keeps going: you take the damage and a flinch, and your punch lands weaker (the harder you were hit
##    and the lighter your own punch, the bigger the cut).
##  * Two fists landing within TRADE_WINDOW of each other are an exchange. The punch that lands at the better moment
##    (earlier, straighter / inside, cleaner, heavier, from the fresher and more forward fighter) wins it: bonus damage,
##    more rock; the other one lands weakened.
##  * Two straight punches meeting within CLASH_WINDOW glove-clash: both deflect, nobody is hurt.

const TRADE_WINDOW := 0.12        ## s: both fists land within this of each other
const CLASH_WINDOW := 0.035       ## s: straight punches arriving this close together meet glove to glove
const CLASH_POWER_RATIO := 1.8    ## a punch this much heavier goes through a clash (a power cross is not parried by a flick)
const COMMIT_FRAC := 0.30         ## of the time to contact: before this the hand is not released yet (startup)
const WIN_MULT := 1.2             ## trade winner: damage (counter-like)
const LOSE_MULT := 0.82           ## trade loser: damage
const WIN_ROCK := 1.2             ## trade winner: rock-meter gain
const CUT_K := 0.7                ## committed puncher hit: cut = CUT_K * hit total / own nominal total
const CUT_MIN := 0.10
const CUT_MAX := 0.60
const CUT_QUALITY := 0.5          ## share of the cut that also shifts the punch's aim / quality
const FLINCH_REF := 12.0          ## total damage that maps to flinch strength 1.0
const STAGGER_LIGHT := 0.07       ## s: no new punch right after a light flinch ...
const STAGGER_MEDIUM := 0.13      ## ... or a medium one (a flinch does not stop you moving or guarding)

const DAMAGE_SCALE := 0.55        ## = CombatRules.DAMAGE_SCALE


## Seconds of the strike clock until the hand is released (leaves the guard).
static func commit_t(a: Dictionary) -> float:
	var s: Dictionary = a["s"]
	return float(s["t_peak"]) * float(a["k"]) * COMMIT_FRAC


## "none" | "startup" | "committed" | "contact" | "recovery" for an attack dictionary (Fighter.atk).
static func phase(a: Dictionary) -> String:
	if a.is_empty():
		return "none"
	var s: Dictionary = a["s"]
	var k: float = a["k"]
	var t: float = a["t"]
	if t < commit_t(a):
		return "startup"
	if a["hit_done"] or t > float(s["w1"]) * k:
		return "recovery"
	if t < float(s["w0"]) * k:
		return "committed"
	return "contact"


## Seconds until the fist reaches contact (0 when the window is open or already past).
static func time_to_contact(a: Dictionary) -> float:
	var s: Dictionary = a["s"]
	return maxf(float(s["w0"]) * float(a["k"]) - float(a["t"]), 0.0)


static func is_straight(s: Dictionary) -> bool:
	return not s["is_leg"] and String(s["tag"]).contains("Jab")


## Inside (shorter, straighter path) beats outside: 1 jab / cross, 0.8 uppercut, 0.3 hook, a wide hook less.
static func inside_score(s: Dictionary) -> float:
	var tag := String(s["tag"])
	if s["is_leg"]:
		return 0.0
	if tag.contains("Jab"):
		return 1.0
	if tag.contains("Uppercut"):
		return 0.8
	var v := 0.3
	if String(s.get("klass", "")) == "wide":
		v -= 0.25
	elif String(s.get("klass", "")) == "tight":
		v += 0.2
	return v


## Nominal total damage of a perfect hit of `s` (before bonuses), the "mass" of the punch.
static func nominal(s: Dictionary) -> float:
	return float(s["damage"]) * DAMAGE_SCALE


## A fighter's side of an exchange as seen "now" (when `ttc` seconds remain until the fist lands).
## f: the Fighter. Keys read: atk, stats, _closing_speed.
static func side_of(f, ttc: float, quality: float) -> Dictionary:
	var a: Dictionary = f.atk
	var s: Dictionary = a["s"]
	var k: float = a["k"]
	var tp := maxf(float(s["t_peak"]) * k, 0.01)
	return {
		"ttc": ttc,
		"elapsed": float(a["t"]),
		"progress": clampf(float(a["t"]) / tp, 0.0, 1.1),
		"inside": inside_score(s),
		"hook": not is_straight(s) and not s["is_leg"],
		"quality": quality * (1.0 - float(a.get("q_pen", 0.0))),
		"power": nominal(s) * float(a.get("power_mult", 1.0)),
		"stamina": f.stats.stamina_ratio(),
		"momentum": clampf(f._closing_speed, -2.0, 2.0) * 0.5,
	}


## Positive: side `a` wins the exchange; negative: `b` does. About +-0.5 is a decisive margin.
static func margin(a: Dictionary, b: Dictionary) -> float:
	var m := 0.0
	m += clampf((float(b["ttc"]) - float(a["ttc"])) / TRADE_WINDOW, -1.0, 1.0) * 0.40   # lands earlier = beat to the punch
	m += (float(a["inside"]) - float(b["inside"])) * 0.30                                 # inside beats outside
	if a["hook"] and b["hook"]:
		m += clampf((float(a["elapsed"]) - float(b["elapsed"])) / TRADE_WINDOW, -1.0, 1.0) * 0.15   # hook vs hook: thrown earlier
	m += (float(a["quality"]) - float(b["quality"])) * 0.30                               # cleaner contact
	m += (float(a["progress"]) - float(b["progress"])) * 0.15                             # closer to full extension
	var pa: float = a["power"]
	var pb: float = b["power"]
	m += clampf((pa - pb) / maxf(maxf(pa, pb), 0.1), -1.0, 1.0) * 0.20                    # mass
	m += (float(a["stamina"]) - float(b["stamina"])) * 0.15                               # tired arms lose trades
	m += (float(a["momentum"]) - float(b["momentum"])) * 0.10                             # the man moving in carries weight
	return m


## Force cut (0..CUT_MAX) a committed punch takes from a hit of `incoming_total` damage.
static func power_cut(incoming_total: float, own_strike: Dictionary) -> float:
	return clampf(CUT_K * incoming_total / maxf(nominal(own_strike), 1.0), CUT_MIN, CUT_MAX)


## Flinch strength 0..1 of a hit of `total` damage.
static func flinch_strength(total: float) -> float:
	return clampf(total / FLINCH_REF, 0.08, 1.0)


## Two straight head punches that arrive together deflect each other. a / b: attack dictionaries.
static func clashes(a: Dictionary, b: Dictionary) -> bool:
	var sa: Dictionary = a["s"]
	var sb: Dictionary = b["s"]
	if not (is_straight(sa) and is_straight(sb)) or sa["zone"] != "head" or sb["zone"] != "head":
		return false
	if b["hit_done"] or a["hit_done"]:
		return false
	# A missed punch can remain in the attack state while it recovers, with hit_done still false.
	# It must not be reclassified as a simultaneous clash when the other fighter counters.
	if phase(a) == "recovery" or phase(b) == "recovery":
		return false
	if String(a.get("outcome", "pending")) != "pending" or String(b.get("outcome", "pending")) != "pending":
		return false
	if absf(time_to_contact(a) - time_to_contact(b)) > CLASH_WINDOW:
		return false
	var pa := nominal(sa) * float(a.get("power_mult", 1.0))
	var pb := nominal(sb) * float(b.get("power_mult", 1.0))
	return maxf(pa, pb) <= CLASH_POWER_RATIO * minf(pa, pb)
