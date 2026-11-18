extends RefCounted
## Per-fighter CPU fighting style (footwork + pacing knobs). Preload, don't reference by class name.
## Keyed by the fighter's model so every match-up has a visible contrast: viper is an out-boxer (holds the edge of jab
## range, circles, steps out along an angle after a combo, feints and paws), anvil a pressure fighter (walks the foe down,
## cuts off the ring, stays in the pocket, backs off rarely and short).
##   gap      preferred root gap to the foe (m); jab band is ~0.93, pocket < 0.9
##   rest     x the rest between bursts (bigger = fewer strikes per minute)
##   burst    pool the burst size (strikes before a reset) is drawn from
##   circle   weight of circling plans;  out  weight / chance of stepping out after a burst;  cut  cut-off-the-ring weight
##   adv      advance speed scale;  backoff  how readily it gives ground when crowded;  feint / paw  feint + range-finder rates

const STYLES := {
	"viper": {"name": "out-boxer", "gap": 0.95, "rest": 1.15, "burst": [2, 2, 3, 3, 4], "circle": 1.8, "out": 1.4, "cut": 0.5,
		"adv": 0.85, "backoff": 1.3, "feint": 1.5, "paw": 1.4},
	"anvil": {"name": "pressure", "gap": 0.84, "rest": 1.12, "burst": [2, 3, 3, 3, 4], "circle": 0.7, "out": 0.35, "cut": 1.7,
		"adv": 1.2, "backoff": 0.35, "feint": 0.8, "paw": 0.6},
}
const DEFAULT := {"name": "balanced", "gap": 0.92, "rest": 1.0, "burst": [2, 3, 3, 4], "circle": 1.0, "out": 0.8, "cut": 1.0,
	"adv": 1.0, "backoff": 0.8, "feint": 1.0, "paw": 1.0}


static func of(model: String) -> Dictionary:
	return STYLES.get(model, DEFAULT)
