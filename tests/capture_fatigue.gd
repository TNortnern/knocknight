extends SceneTree
## Windowed: real main.tscn through the normal fight camera. Saves
##   _build/shots/fatigue_fresh_full.png / fatigue_tired_full.png (+ _crop) : P2 fresh vs gassed (stamina pinned at 8 %), same framing
##   _build/shots/rocked_cam_NN.png (full frame) and rocked_cam_crop_NN.png: P2 rocked by a counter hook
## godot --path . --script res://tests/capture_fatigue.gd

func _initialize() -> void:
	_run.call_deferred()


func _full(name: String) -> void:
	await process_frame
	await process_frame
	root.get_viewport().get_texture().get_image().save_png("res://_build/shots/%s.png" % name)


func _crop(name: String, t: Fighter, sz := Vector2i(420, 520)) -> void:
	await process_frame
	var img := root.get_viewport().get_texture().get_image()
	var cam := root.get_viewport().get_camera_3d()
	var c := cam.unproject_position(t.global_position + Vector3(0, 1.05, 0))
	var r := Rect2i(Vector2i(int(c.x), int(c.y)) - sz / 2, sz)
	r.position.x = clampi(r.position.x, 0, img.get_width() - sz.x)
	r.position.y = clampi(r.position.y, 0, img.get_height() - sz.y)
	img.get_region(r).save_png("res://_build/shots/%s.png" % name)


func _start() -> Array:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": "anvil", "rules": "boxing", "rounds": 1,
		"round_seconds": 180.0, "arena": "ring", "intro_delay": 0.0})
	var f: Array = main.current_match.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	f[0].global_position = Vector3(-0.55, 0, 0)
	f[1].global_position = Vector3(0.55, 0, 0)
	for i in 300:
		await physics_frame
	return [main, f]


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var mode := "both"
	for a in OS.get_cmdline_user_args():
		mode = a
	var r: Array = await _start()
	var main = r[0]
	var f: Array = r[1]
	var t: Fighter = f[1]
	# --- tired vs fresh (P2 holds a guard so the sag shows, then idles)
	if mode in ["both", "tired"]:
		f[1].external_input.block = true
		for i in 120:
			await physics_frame
		await _full("fatigue_fresh_full")
		await _crop("fatigue_fresh_crop", t)
		for i in 240:
			t.stats.stamina = 0.08 * t.stats.stamina_max
			await physics_frame
		await _full("fatigue_tired_full")
		await _crop("fatigue_tired_crop", t)
		for k in 6:
			for i in 14:
				t.stats.stamina = 0.08 * t.stats.stamina_max
				await physics_frame
			await _crop("fatigue_tired_crop_%d" % k, t)
		print("tired fatigue %.2f droop %.2f breath %.2f" % [t.fatigue, t.rig.skeleton.get_node("FatiguePose").droop, t.rig.skeleton.get_node("FatiguePose").breath])
		f[1].external_input.block = false
	# --- rocked
	if mode in ["both", "rocked"]:
		t.stats.stamina = t.stats.stamina_max
		for i in 120:
			await physics_frame
		f[0].external_input.strikes.append("RHook")
		await physics_frame
		f[0].atk["counter"] = true
		f[0].external_input.strikes.clear()
		var guard := 0
		while not t.hurt.active() and guard < 600:
			await physics_frame
			guard += 1
		print("rocked after %d ticks, daze %.2f" % [guard, t.hurt.daze_len])
		var n := 0
		for target in [0.15, 0.45, 0.8, 1.2, 1.8, 2.6]:
			var g2 := 0
			while t.hurt.active() and t.hurt.t < target and g2 < 2000:
				await physics_frame
				g2 += 1
			await _full("rocked_cam_%02d" % n)
			await _crop("rocked_cam_crop_%02d" % n, t)
			print("  shot %d hurt.t=%.2f" % [n, t.hurt.t])
			n += 1
	quit(0)
