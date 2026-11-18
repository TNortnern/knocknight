class_name HumanController
extends RefCounted
## Turns InputMap actions (`p1_*` / `p2_*`, keyboard + gamepad) into a FighterInput.
## Slip left/right are screen-relative on the keyboard (Q = screen left) and converted to the fighter's frame
## by Fighter.apply_input using which way the fighter faces.

var prefix := "p1"
var boxing := false
var _last_tap := {}
var _prev := {}
var _slip_pref := 1   ## the side pressed last: with both slip keys down (a quick Q -> E switch) that side wins, the head never stops at centre


func _init(p_prefix := "p1") -> void:
	prefix = p_prefix


func _a(name: String) -> String:
	return "%s_%s" % [prefix, name]


func _edge(name: String) -> bool:
	var down := Input.is_action_pressed(_a(name))
	var was: bool = _prev.get(name, false)
	_prev[name] = down
	return down and not was


func poll(into: FighterInput) -> void:
	into.clear()
	var mv := Vector2(
		Input.get_action_strength(_a("move_right")) - Input.get_action_strength(_a("move_left")),
		Input.get_action_strength(_a("move_up")) - Input.get_action_strength(_a("move_down")))
	into.move = mv.limit_length(1.0)
	into.block = Input.is_action_pressed(_a("block"))
	into.body = Input.is_action_pressed(_a("body")) or Input.get_action_strength(_a("body")) > 0.4
	into.duck = Input.is_action_pressed(_a("duck"))
	into.shell = InputMap.has_action(_a("shell")) and Input.is_action_pressed(_a("shell"))
	# slip: screen-space sign; Fighter converts (stored as screen-left = +1 like "left" in the key name)
	var sl := Input.is_action_pressed(_a("slip_left"))
	var sr := Input.is_action_pressed(_a("slip_right"))
	if _edge("slip_left"):
		_slip_pref = 1
	if _edge("slip_right"):
		_slip_pref = -1
	into.slip = _slip_pref if (sl and sr) else ((1 if sl else 0) - (1 if sr else 0))
	into.lean_mod = InputMap.has_action(_a("lean")) and Input.is_action_pressed(_a("lean"))
	# analog lean: right stick (side + back / forward), or the lean-back shortcut key
	var dev := int(prefix.substr(1)) - 1
	var rx := Input.get_joy_axis(dev, JOY_AXIS_RIGHT_X)
	var ry := Input.get_joy_axis(dev, JOY_AXIS_RIGHT_Y)
	var lv := Vector2(-rx if absf(rx) > 0.15 else 0.0, ry if (ry < -0.15 or (ry > 0.15 and not into.duck)) else 0.0)
	if InputMap.has_action(_a("lean_back")) and Input.is_action_pressed(_a("lean_back")):
		lv.y = -1.0
	into.lean = lv.limit_length(1.0)
	into.backstep = _edge("backstep")
	into.taunt = _edge("taunt")
	into.shove = InputMap.has_action(_a("shove")) and _edge("shove")
	var spec := Input.is_action_pressed(_a("spec"))
	var lb := Input.is_action_pressed(_a("pad_lb"))
	var rb := Input.is_action_pressed(_a("pad_rb"))
	var body := into.body
	# power modifier (R / R3): a punch thrown while it is held is the loaded version (see scripts/combat/punch_variants.gd);
	# a plain tap is the standard punch, which turns into a flick / tight chain on a quick re-tap and a step-in / pull-back
	# jab when you move towards / away from the foe.
	var power := InputMap.has_action(_a("power")) and Input.is_action_pressed(_a("power"))
	# keyboard strike keys
	var table := [
		["jab_l", "L", "Jab"], ["jab_r", "R", "Jab"], ["hook_l", "L", "Hook"], ["hook_r", "R", "Hook"],
		["upper_l", "L", "Uppercut"], ["upper_r", "R", "Uppercut"], ["kick_l", "L", "Kick"], ["kick_r", "R", "Kick"],
		["low_l", "L", "Low"], ["low_r", "R", "Low"],
	]
	for e in table:
		if _edge(e[0]):
			var tag := StrikeDB.resolve_tag(e[1], e[2], body, spec)
			if boxing and tag.ends_with("Kick"):
				tag = e[1] + ("Body" if body else "") + "Jab"
			into.strikes.append(_with_power(tag, power))
	# gamepad face buttons: X/Y jabs, A/B round kicks, LB = hooks, RB = uppercuts (LB + A/B = low kick)
	var face := [["pad_x", "L", false], ["pad_y", "R", false], ["pad_a", "L", true], ["pad_b", "R", true]]
	for e in face:
		if _edge(e[0]):
			var tag := ""
			if e[2]:
				tag = StrikeDB.resolve_tag(e[1], "Low" if lb else "Kick", body, false)
				if boxing:
					tag = e[1] + ("Body" if body else "") + "Jab"
			else:
				tag = StrikeDB.resolve_tag(e[1], "Hook" if lb else ("Uppercut" if rb else "Jab"), body, false)
			into.strikes.append(_with_power(tag, power))


## "LJab" -> "LJab@power" while the power modifier is held (hand strikes only).
func _with_power(tag: String, power: bool) -> String:
	if power and (tag.contains("Jab") or tag.contains("Hook") or tag.contains("Uppercut")):
		return tag + "@power"
	return tag
