extends SceneTree
## Windowed: real main.tscn, P1 (scripted) lands a power hook (head) or a body hook on P2; saves cropped frames along the
## hurt episode to _build/shots/rocked_head_NN.png / rocked_body_NN.png.
## godot --path . --script res://tests/capture_rocked.gd [-- body|head|both]

func _initialize() -> void:
	_run.call_deferred()


func _shot(name: String, n: int, t: Fighter) -> void:
	await process_frame
	await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var cam := root.get_viewport().get_camera_3d()
	var c := cam.unproject_position(t.global_position + Vector3(0, 0.95, 0))
	var sz := Vector2i(360, 480)
	var r := Rect2i(Vector2i(int(c.x), int(c.y)) - sz / 2, sz)
	r.position.x = clampi(r.position.x, 0, img.get_width() - sz.x)
	r.position.y = clampi(r.position.y, 0, img.get_height() - sz.y)
	img.get_region(r).save_png("res://_build/shots/rocked_%s_%02d.png" % [name, n])


func _episode(kind: String) -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": "anvil", "rules": "kickboxing", "rounds": 1,
		"round_seconds": 180.0, "arena": "ring", "intro_delay": 0.0})
	var f: Array = main.current_match.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	f[0].global_position = Vector3(-0.45, 0, 0)
	f[1].global_position = Vector3(0.45, 0, 0)
	for i in 300:
		await physics_frame
	var t: Fighter = f[1]
	var times: Array
	if kind == "head":
		t.stats.rock_meter = 40.0
		f[0].external_input.strikes.append("RHook")
		times = [0.0, 0.12, 0.25, 0.4, 0.7, 1.0, 1.3, 1.6, 1.8, 2.0, 2.3, 2.7]
	else:
		t.stats.body = 30.0
		f[0].external_input.strikes.append("RBodyHook")
		times = [0.0, 0.1, 0.2, 0.3, 0.45, 0.6, 0.8, 0.95, 1.1, 1.3, 1.6]
	await physics_frame
	f[0].external_input.strikes.clear()
	var guard := 0
	while not t.hurt.active() and guard < 600:
		await physics_frame
		guard += 1
	print("%s: hurt started after %d ticks (kind %d, len %.2f)" % [kind, guard, t.hurt.kind, t.hurt.total_len()])
	Engine.time_scale = 0.2
	var n := 0
	for target in times:
		var g2 := 0
		while t.hurt.active() and t.hurt.t < target and g2 < 2000:
			await physics_frame
			g2 += 1
		await _shot(kind, n, t)
		print("  %s_%02d hurt.t=%.2f state=%s" % [kind, n, t.hurt.t, t.state_name])
		n += 1
	Engine.time_scale = 1.0
	root.remove_child(main)
	main.queue_free()
	await process_frame


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var which := "both"
	for a in OS.get_cmdline_user_args():
		which = a
	if which in ["head", "both"]:
		await _episode("head")
	if which in ["body", "both"]:
		await _episode("body")
	quit(0)
