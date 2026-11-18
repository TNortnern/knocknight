extends SceneTree
## Windowed: real main.tscn, P1 (scripted) throws an LJab at a standing P2; saves cropped frames every 5 physics
## ticks (1/24 s of sim time) to _build/shots/jab_*.png so the wind-up can be checked by eye.

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": "anvil", "rules": "kickboxing", "rounds": 1,
		"round_seconds": 180.0, "arena": "ring", "intro_delay": 0.0})
	var f: Array = main.current_match.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	f[0].global_position = Vector3(-0.5, 0, 0)
	f[1].global_position = Vector3(0.5, 0, 0)
	for i in 300:
		await physics_frame
	Engine.time_scale = 0.15
	f[0].external_input.strikes.append("LJab")
	await physics_frame
	f[0].external_input.strikes.clear()
	var n := 0
	for target in [0.02, 0.07, 0.11, 0.15, 0.19, 0.23, 0.27, 0.32, 0.40]:
		while f[0].atk.get("t", 9.0) < target and not f[0].atk.is_empty():
			await physics_frame
		await process_frame
		await process_frame
		var img := root.get_viewport().get_texture().get_image()
		var w := img.get_width()
		var h := img.get_height()
		img = img.get_region(Rect2i(int(w * 0.25), int(h * 0.12), int(w * 0.5), int(h * 0.62)))
		img.save_png("res://_build/shots/jab_%02d.png" % n)
		print("jab_%02d atk t=%.3f" % [n, f[0].atk.get("t", -1.0)])
		n += 1
	Engine.time_scale = 1.0
	quit(0)
