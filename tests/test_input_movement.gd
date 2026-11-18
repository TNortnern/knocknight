extends SceneTree
# InputMap + human controller + movement/physics test.
# godot --headless --path . --script res://tests/test_input_movement.gd

var failures := 0


func check(ok: bool, msg: String) -> void:
	if ok:
		print("  ok   ", msg)
	else:
		print("  FAIL ", msg)
		failures += 1


func key_event(code: Key, pressed: bool, loc: KeyLocation = KEY_LOCATION_UNSPECIFIED) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.location = loc
	ev.pressed = pressed
	return ev


func press(code: Key, loc: KeyLocation = KEY_LOCATION_UNSPECIFIED) -> void:
	Input.parse_input_event(key_event(code, true, loc))
	Input.flush_buffered_events()


func release(code: Key, loc: KeyLocation = KEY_LOCATION_UNSPECIFIED) -> void:
	Input.parse_input_event(key_event(code, false, loc))
	Input.flush_buffered_events()


func _initialize() -> void:
	print("== InputMap actions from project.godot")
	var needed := ["move_left", "move_right", "move_up", "move_down", "block", "body", "duck", "slip_left", "slip_right", "backstep",
		"jab_l", "jab_r", "hook_l", "hook_r", "upper_l", "upper_r", "kick_l", "kick_r", "low_l", "low_r", "spec", "selected",
		"taunt", "stance", "pad_x", "pad_y", "pad_a", "pad_b", "pad_lb", "pad_rb"]
	var missing := []
	for p in ["p1", "p2"]:
		for a in needed:
			if not InputMap.has_action("%s_%s" % [p, a]):
				missing.append("%s_%s" % [p, a])
	check(missing.is_empty(), "all %d P1/P2 actions defined (missing %s)" % [needed.size() * 2, str(missing)])
	var has_pad := false
	for e in InputMap.action_get_events("p1_block"):
		if e is InputEventJoypadMotion and (e as InputEventJoypadMotion).axis == JOY_AXIS_TRIGGER_RIGHT:
			has_pad = true
	check(has_pad, "p1_block bound to RT on the gamepad")
	var pad2 := false
	for e in InputMap.action_get_events("p2_pad_x"):
		if e is InputEventJoypadButton and (e as InputEventJoypadButton).device == 1:
			pad2 = true
	check(pad2, "P2 gamepad actions use device 1")

	print("== keyboard events -> strike tags")
	var hc := HumanController.new("p1")
	var fi := FighterInput.new()
	press(KEY_J)
	hc.poll(fi)
	check(fi.strikes == ["LJab"], "J -> LJab (%s)" % str(fi.strikes))
	hc.poll(fi)
	check(fi.strikes.is_empty(), "held key does not auto-repeat")
	release(KEY_J)
	hc.poll(fi)
	press(KEY_SHIFT, KEY_LOCATION_LEFT)
	press(KEY_I)
	hc.poll(fi)
	check(fi.body and fi.strikes == ["RBodyHook"], "LShift + I -> RBodyHook (%s)" % str(fi.strikes))
	release(KEY_I)
	hc.poll(fi)
	press(KEY_O)
	hc.poll(fi)
	check(fi.strikes == ["LBodyRoundKick"], "body + O -> LBodyRoundKick (%s)" % str(fi.strikes))
	release(KEY_O)
	release(KEY_SHIFT, KEY_LOCATION_LEFT)
	hc.poll(fi)
	press(KEY_F)
	press(KEY_P)
	hc.poll(fi)
	check(fi.strikes == ["RFrontKick"], "F (spec) + P -> RFrontKick (%s)" % str(fi.strikes))
	release(KEY_P)
	release(KEY_F)
	hc.poll(fi)
	press(KEY_COMMA)
	hc.poll(fi)
	check(fi.strikes == ["LLowKick"], "comma -> LLowKick")
	release(KEY_COMMA)
	hc.poll(fi)
	hc.boxing = true
	press(KEY_P)
	hc.poll(fi)
	check(fi.strikes == ["RJab"], "boxing rules turn a kick key into a jab (%s)" % str(fi.strikes))
	release(KEY_P)
	hc.boxing = false
	press(KEY_Q)
	press(KEY_SPACE)
	hc.poll(fi)
	check(fi.slip == 1 and fi.block, "Q = slip left (+1), Space = block")
	release(KEY_Q)
	release(KEY_SPACE)
	var hc2 := HumanController.new("p2")
	press(KEY_KP_3)
	hc2.poll(fi)
	check(fi.strikes == ["LHook"], "P2 Numpad3 -> LHook (%s)" % str(fi.strikes))
	release(KEY_KP_3)
	press(KEY_LEFT)
	hc2.poll(fi)
	check(fi.move.x < -0.9, "P2 Left arrow moves left")
	release(KEY_LEFT)
	hc2.poll(fi)
	var jb := InputEventJoypadButton.new()
	jb.device = 0
	jb.button_index = JOY_BUTTON_X
	jb.pressed = true
	Input.parse_input_event(jb)
	Input.flush_buffered_events()
	hc.poll(fi)
	check(fi.strikes == ["LJab"], "pad X (device 0) -> P1 LJab (%s)" % str(fi.strikes))
	var jb_up := jb.duplicate() as InputEventJoypadButton
	jb_up.pressed = false
	Input.parse_input_event(jb_up)
	Input.flush_buffered_events()
	hc.poll(fi)

	print("== human-driven fighter moves and is stopped by the other fighter / ring walls")
	var m: Match = load("res://scenes/match.tscn").instantiate()
	m.setup({"mode": "exhibition", "p1_controller": "human", "p2_controller": "dummy", "rounds": 1, "round_seconds": 120.0, "intro_delay": 0.0})
	get_root().add_child(m)
	await process_frame
	var f: Array = m.get_fighters()
	for i in 60:
		await physics_frame
	var x0: float = f[0].global_position.x
	press(KEY_W)   # default movement mode "fighter": W = toward the foe
	for i in 120:
		await physics_frame
	var dx: float = f[0].global_position.x - x0
	check(f[0].movement_mode == "fighter", "default movement mode is fighter-relative")
	check(dx > 1.0 and dx < 1.5, "holding W for 1 s moves P1 %.2f m toward the foe (walk 1.25 m/s)" % dx)
	for i in 360:
		await physics_frame
	var gap: float = (f[1].global_position - f[0].global_position).length()
	check(gap > 0.24 and gap < 0.5, "walking into the opponent: bodies stop at %.2f m (the pressing pair settles at body contact 0.42 m; capsules 0.24 m)" % gap)
	check(f[1].global_position.x > 1.15 + 0.02, "the opponent is physically shoved back (x %.2f)" % f[1].global_position.x)
	release(KEY_W)
	press(KEY_S)
	for i in 120 * 7:
		await physics_frame
	check(f[0].global_position.x > -3.25 and f[0].global_position.x < -3.0, "S walks away until the ring wall at x = %.2f (limit 3.2)" % f[0].global_position.x)
	release(KEY_S)
	var z0: float = f[0].global_position.z
	press(KEY_D)   # fighter faces +X: his right is world +Z; D circles around the foe, never toward / away from him
	for i in 60:
		await physics_frame
	check(f[0].global_position.z - z0 > 0.5, "D circles to the fighter's right (dz %.2f)" % (f[0].global_position.z - z0))
	release(KEY_D)
	press(KEY_A)
	for i in 240:
		await physics_frame
	check(f[0].global_position.z - z0 < -0.5, "A circles to the fighter's left")
	release(KEY_A)
	await physics_frame
	check(f[0].state_name == "idle", "idle state after releasing keys (%s)" % f[0].state_name)
	press(KEY_J)
	for i in 3:
		await physics_frame
	release(KEY_J)
	check(f[0].state == Fighter.State.ATTACK, "pressing J starts an ATTACK on the real fighter")

	print("== movement modes vs camera yaw")
	var cam := Camera3D.new()
	m.add_child(cam)
	cam.make_current()
	var p0 := f[0] as Fighter
	await _release_all(f)
	for i in 90:
		await physics_frame   # let the J punch finish
	for yaw in [0.0, 1.0, 2.5, -1.7]:
		cam.global_transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(0, 1.5, 0))
		p0.movement_mode = "fighter"
		p0.global_position = Vector3(-2.0, 0, 0.5)
		p0.velocity = Vector3.ZERO
		f[1].global_position = Vector3(1.0, 0, -0.5)
		var g0: float = (f[1].global_position - p0.global_position).length()
		press(KEY_W)
		for i in 30:
			await physics_frame
		release(KEY_W)
		var g1: float = (f[1].global_position - p0.global_position).length()
		check(g1 < g0 - 0.2, "fighter mode, camera yaw %.1f: W closes the gap (%.2f -> %.2f)" % [yaw, g0, g1])
		await _settle(p0)
		p0.movement_mode = "camera"
		p0.global_position = Vector3(-2.0, 0, 0.5)
		f[1].global_position = Vector3(2.5, 0, -2.5)
		var s0: Vector3 = p0.global_position
		var fwd := -cam.global_basis.z
		fwd.y = 0.0
		fwd = fwd.normalized()
		press(KEY_W)
		for i in 30:
			await physics_frame
		release(KEY_W)
		var d: Vector3 = p0.global_position - s0
		d.y = 0.0
		check(d.length() > 0.2 and d.normalized().dot(fwd) > 0.97, "camera mode, camera yaw %.1f: W moves along camera forward (dot %.2f)" % [yaw, d.normalized().dot(fwd)])
		await _settle(p0)
		var s1: Vector3 = p0.global_position
		var rgt := fwd.cross(Vector3.UP)
		press(KEY_D)
		for i in 30:
			await physics_frame
		release(KEY_D)
		var d2: Vector3 = p0.global_position - s1
		d2.y = 0.0
		check(d2.length() > 0.2 and d2.normalized().dot(rgt) > 0.97, "camera mode, camera yaw %.1f: D moves camera-right (dot %.2f)" % [yaw, d2.normalized().dot(rgt)])
		await _settle(p0)
	p0.movement_mode = "fighter"

	if failures == 0:
		print("PASS: input and movement")
		quit(0)
	else:
		print("FAIL: %d check(s) failed" % failures)
		quit(1)


func _release_all(_f: Array) -> void:
	for k in [KEY_W, KEY_A, KEY_S, KEY_D]:
		release(k)
	for i in 5:
		await physics_frame


func _settle(p: Fighter) -> void:
	for i in 30:
		await physics_frame
