extends SceneTree
## Generates the [input] section for project.godot (P1/P2 keyboard, pad 0/1) into _build/input_section.txt.
## godot --headless --path . --script res://tools/gen_input_map.gd ; then splice into project.godot.

const K := {
	"p1": {
		"move_left": [KEY_A], "move_right": [KEY_D], "move_up": [KEY_W], "move_down": [KEY_S, KEY_Z],
		"block": [KEY_SPACE], "body": [KEY_SHIFT], "duck": [KEY_CTRL, KEY_C, KEY_B],
		"slip_left": [KEY_Q], "slip_right": [KEY_E], "backstep": [KEY_G],
		"jab_l": [KEY_J], "jab_r": [KEY_K], "hook_l": [KEY_U], "hook_r": [KEY_I],
		"upper_l": [KEY_N], "upper_r": [KEY_M], "kick_l": [KEY_O], "kick_r": [KEY_P],
		"low_l": [KEY_COMMA], "low_r": [KEY_PERIOD], "spec": [KEY_F], "selected": [KEY_V],
		"taunt": [KEY_H], "stance": [KEY_X], "shell": [KEY_ALT], "power": [KEY_R], "lean": [KEY_TAB], "lean_back": [KEY_Y],
	},
	"p2": {
		"move_left": [KEY_LEFT], "move_right": [KEY_RIGHT], "move_up": [KEY_UP], "move_down": [KEY_DOWN, KEY_PAGEUP],
		"block": [KEY_ENTER, KEY_KP_ENTER], "body": [KEY_KP_9, KEY_9], "duck": [KEY_KP_MULTIPLY],
		"slip_left": [KEY_DELETE], "slip_right": [KEY_PAGEDOWN], "backstep": [KEY_END, KEY_KP_PERIOD],
		"jab_l": [KEY_KP_1, KEY_1], "jab_r": [KEY_KP_2, KEY_2], "hook_l": [KEY_KP_3, KEY_3], "hook_r": [KEY_KP_4, KEY_4],
		"upper_l": [KEY_KP_5, KEY_5], "upper_r": [KEY_KP_6, KEY_6], "kick_l": [KEY_KP_7, KEY_7], "kick_r": [KEY_KP_8, KEY_8],
		"low_l": [KEY_KP_SUBTRACT], "low_r": [KEY_KP_DIVIDE], "spec": [KEY_KP_0, KEY_0], "selected": [KEY_KP_ADD],
		"taunt": [KEY_HOME], "stance": [KEY_INSERT], "shell": [KEY_BACKSLASH], "power": [KEY_SLASH], "lean": [KEY_BRACKETRIGHT], "lean_back": [KEY_BRACKETLEFT],
	},
}
# right shift / right ctrl have no separate physical keycode in Godot 4.7 InputEventKey.location; location is set below.
const PAD_BUTTONS := {
	"pad_x": JOY_BUTTON_X, "pad_y": JOY_BUTTON_Y, "pad_a": JOY_BUTTON_A, "pad_b": JOY_BUTTON_B,
	"pad_lb": JOY_BUTTON_LEFT_SHOULDER, "pad_rb": JOY_BUTTON_RIGHT_SHOULDER,
	"shell": JOY_BUTTON_LEFT_SHOULDER, "power": JOY_BUTTON_RIGHT_STICK, "taunt": JOY_BUTTON_DPAD_UP, "stance": JOY_BUTTON_DPAD_DOWN, "selected": JOY_BUTTON_LEFT_STICK, "backstep": JOY_BUTTON_DPAD_RIGHT,
}
# action -> [axis, sign]
const PAD_AXES := {
	"move_left": [JOY_AXIS_LEFT_X, -1.0], "move_right": [JOY_AXIS_LEFT_X, 1.0],
	"move_up": [JOY_AXIS_LEFT_Y, -1.0], "move_down": [JOY_AXIS_LEFT_Y, 1.0],
	"slip_left": [JOY_AXIS_RIGHT_X, -1.0], "slip_right": [JOY_AXIS_RIGHT_X, 1.0],
	"duck": [JOY_AXIS_RIGHT_Y, 1.0],
	"body": [JOY_AXIS_TRIGGER_LEFT, 1.0], "block": [JOY_AXIS_TRIGGER_RIGHT, 1.0],
}


func _initialize() -> void:
	var out := ConfigFile.new()
	var names := {}
	for p in ["p1", "p2"]:
		var dev := 0 if p == "p1" else 1
		var actions: Dictionary = K[p].duplicate(true)
		for a in PAD_BUTTONS:
			if not actions.has(a):
				actions[a] = []
		for a in PAD_AXES:
			if not actions.has(a):
				actions[a] = []
		for a in actions:
			var events: Array = []
			for k in actions[a]:
				var ev := InputEventKey.new()
				ev.device = -1
				ev.physical_keycode = k
				events.append(ev)
			if p == "p2" and a == "body":
				var rs := InputEventKey.new()
				rs.device = -1
				rs.physical_keycode = KEY_SHIFT
				rs.location = KEY_LOCATION_RIGHT
				events.append(rs)
			if p == "p2" and a == "duck":
				var rc := InputEventKey.new()
				rc.device = -1
				rc.physical_keycode = KEY_CTRL
				rc.location = KEY_LOCATION_RIGHT
				events.append(rc)
			if p == "p1" and (a == "body" or a == "duck"):
				for e in events:
					if (e as InputEventKey).physical_keycode in [KEY_SHIFT, KEY_CTRL]:
						(e as InputEventKey).location = KEY_LOCATION_LEFT
			if PAD_BUTTONS.has(a):
				var jb := InputEventJoypadButton.new()
				jb.device = dev
				jb.button_index = PAD_BUTTONS[a]
				events.append(jb)
			if PAD_AXES.has(a):
				var jm := InputEventJoypadMotion.new()
				jm.device = dev
				jm.axis = PAD_AXES[a][0]
				jm.axis_value = PAD_AXES[a][1]
				events.append(jm)
			var dz := 0.4 if PAD_AXES.has(a) else 0.2
			ProjectSettings.set_setting("input/%s_%s" % [p, a], {"deadzone": dz, "events": events})
	ProjectSettings.save_custom("res://_build/input_section.tmp.godot")
	quit()
