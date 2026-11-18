extends SceneTree
## Windowed: one frame per defence at its peak -> _build/shots/defence_*.png
## godot --path . --script res://tests/capture_defence.gd

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy", "p1_model": "viper", "p2_model": "anvil",
		"rules": "boxing", "rounds": 1, "round_seconds": 120.0, "arena": "ring", "intro_delay": 0.0})
	for i in 150:
		await physics_frame
	var m = main.find_children("*", "Match", true, false)[0]
	var f: Array = m.get_fighters()
	f[0].external_input = FighterInput.new()
	f[1].external_input = FighterInput.new()
	f[0].global_position = Vector3(-0.45, 0, 0)
	f[1].global_position = Vector3(0.45, 0, 0)
	var inp: FighterInput = f[1].external_input
	var combos := {
		"idle": [], "block": ["block"], "shell": ["block", "shell"], "tilt": ["block", "slip"], "slip": ["slip"],
		"sway": ["slip", "back"], "duck": ["duck"], "roll": ["duck", "slip"],
	}
	for name in combos:
		inp.clear()
		for tok in combos[name]:
			match tok:
				"block": inp.block = true
				"shell": inp.shell = true
				"slip": inp.slip = 1
				"duck": inp.duck = true
				"back": inp.move = Vector2(1, 0)
		for i in 60:
			await physics_frame
		await process_frame
		await create_timer(0.05).timeout
		root.get_viewport().get_texture().get_image().save_png("res://_build/shots/defence_%s.png" % name)
		print("saved defence_", name)
		inp.clear()
		for i in 120:
			await physics_frame
	quit(0)
