extends SceneTree
## Headless: drives main.tscn through the REAL menu -> setup screen START (no stub) and checks the fight runs.

var fails := 0

func check(ok: bool, msg: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + msg)
	if not ok:
		fails += 1

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	for mode in ["exhibition", "sparring", "training"]:
		print("== ", mode)
		main._on_mode_chosen(mode)
		await process_frame
		var cfg: Dictionary = main._setup.build_config()
		print("  config ", cfg)
		main._setup._start.pressed.emit()
		for i in 240:
			await physics_frame
		var m = main.current_match
		check(m != null and m.get_script() != null and m.get_script().get_global_name() == "Match", "real Match instanced")
		var f: Array = m.get_fighters() if m else []
		check(f.size() == 2 and f.all(func(x): return x.is_inside_tree()), "two fighters in tree")
		if f.size() == 2:
			check(f[0].display_name in ["Viper", "Anvil"], "P1 name " + str(f[0].display_name))
			check(f[0].global_position.distance_to(f[1].global_position) > 0.4, "fighters apart")
		check(main.get_state_name() != "", "state " + main.get_state_name())
		main.show_menu()
		await process_frame
	print("PASS: menu to fight" if fails == 0 else "FAIL: menu to fight (%d)" % fails)
	quit(1 if fails else 0)
