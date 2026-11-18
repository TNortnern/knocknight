extends RefCounted
## Fighter roster. Every entry plays on one of the two M3DMale gameplay templates ("viper" / "anvil": animation, pose
## layers, hit / hurt / guard boxes, ragdoll, CPU style, guard style). Entries with a `skin` glb additionally show a
## Meshy-generated body that is retargeted onto that skeleton every physics tick (meshy_skin.gd).
## Preload this script, don't reference it by class name.

const CLASSIC_PATH := "res://assets/fighters/%s.glb"
const MESHY := "res://assets/fighters/meshy/%s.glb"

## Order = order in the setup screen.
const ORDER := ["meshy_viper", "meshy_anvil", "meshy_oak", "meshy_boxer1", "meshy_boxer2", "viper", "anvil"]

const DATA := {
	"meshy_viper": {"head_movement": 1.25, "mass": 0.90, "name": "Viper", "label": "Viper", "full": "Marco \"Viper\" Reyes", "template": "viper", "skin": "viper_alt",
		"style": "Tall technical out-boxer. Long reach, burgundy gloves, moves behind the jab."},
	"meshy_anvil": {"head_movement": 0.92, "mass": 1.10, "name": "Anvil", "label": "Anvil", "full": "Dante \"Anvil\" Okafor", "template": "anvil", "skin": "anvil",
		"style": "Southpaw pressure fighter. Stocky, broad shoulders, short beard, black gloves."},
	"meshy_oak": {"head_movement": 0.78, "mass": 1.30, "name": "Oak", "label": "Oak", "full": "Viktor \"Oak\" Hale", "template": "anvil", "skin": "oak",
		"style": "Heavy pressure fighter. Walks you down, trades in the pocket, hard to move."},
	"meshy_boxer1": {"head_movement": 1.00, "mass": 1.00, "name": "Boxer 1", "label": "Boxer 1", "full": "Boxer 1", "template": "viper", "skin": "boxer1",
		"style": "Balanced all-rounder. Stays on the outside, picks his shots."},
	"meshy_boxer2": {"head_movement": 0.95, "mass": 1.05, "name": "Boxer 2", "label": "Boxer 2", "full": "Boxer 2", "template": "anvil", "skin": "boxer2",
		"style": "Balanced pressure boxer. Sets a pace and keeps coming."},
	"viper": {"head_movement": 1.25, "mass": 0.90, "name": "Viper", "label": "Viper (Classic)", "full": "Marco Reyes", "template": "viper", "skin": "",
		"style": "Classic model. Tall technical striker, long reach, burgundy gloves."},
	"anvil": {"head_movement": 0.92, "mass": 1.10, "name": "Anvil", "label": "Anvil (Classic)", "full": "Dante Okafor", "template": "anvil", "skin": "",
		"style": "Classic model. Southpaw pressure fighter, stocky, black gloves."},
}


static func def(id: String) -> Dictionary:
	return DATA.get(id, DATA["viper"])


## Body weight class for the contact / push rules (scripts/fighter/body_contact.gd).
static func mass(id: String) -> float:
	return float(def(id).get("mass", 1.0))


## Head-movement stat (lean speed multiplier: how fast the upper body leans / slips; Viper highest).
static func head_movement(id: String) -> float:
	return float(def(id).get("head_movement", 1.0))


static func template(id: String) -> String:
	return String(def(id)["template"])


static func display_name(id: String) -> String:
	return String(DATA[id]["name"]) if DATA.has(id) else id.capitalize()


## glb of the gameplay (M3DMale) body for this fighter.
static func template_path(id: String) -> String:
	return CLASSIC_PATH % template(id)


## glb of the Meshy skin, "" for the classic models.
static func skin_path(id: String) -> String:
	var s := String(def(id)["skin"])
	return "" if s == "" else MESHY % s


## The fighter that auto-fills the opponent slot when the player picks `id` (never the same model).
static func auto_opponent(id: String) -> String:
	var i := ORDER.find(id)
	return ORDER[(maxi(i, 0) + 1) % ORDER.size()]
