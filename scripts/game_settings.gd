class_name GameSettings
extends RefCounted
## Tiny persistent settings store (user://settings.cfg). Only used for options the player picks on the setup screen.
##
## movement_mode: how the move keys / stick map to the ring
##   "fighter" - W / up = toward the opponent, S = away, A / D = circle left / right around him (camera independent)
##   "camera"  - W = away from the camera, A / D = screen left / right (relative to the camera's current yaw)

const PATH := "user://settings.cfg"
const MODES := ["fighter", "camera"]
const DEFAULT_MODE := "fighter"


static func movement_mode(player_index: int) -> String:
	var cf := ConfigFile.new()
	if cf.load(PATH) != OK:
		return DEFAULT_MODE
	var v := String(cf.get_value("controls", "movement_mode_p%d" % (player_index + 1), DEFAULT_MODE))
	return v if v in MODES else DEFAULT_MODE


static func set_movement_mode(player_index: int, mode: String) -> void:
	if not (mode in MODES):
		return
	var cf := ConfigFile.new()
	cf.load(PATH)   # keep other keys; a missing file is fine
	cf.set_value("controls", "movement_mode_p%d" % (player_index + 1), mode)
	cf.save(PATH)
