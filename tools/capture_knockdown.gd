extends SceneTree
## Windowed: forces a knockdown (dir from args, default R) on P2 and saves a frame every 0.15 s through fall/count/getup.
## <godot> --path . --script res://tools/capture_knockdown.gd -- dir=R tag=kdR

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var dir: String = args.get("dir", "R")
	var tag: String = args.get("tag", "kd" + dir)
	var ko: bool = args.get("ko", "0") == "1"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/shots"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "dummy", "p2_controller": "dummy",
		"p1_model": "viper", "p2_model": "anvil", "rules": "boxing", "rounds": 3,
		"round_seconds": 180.0, "cpu_difficulty": "normal", "arena": "ring", "intro_delay": 0.0})
	for i in 60:
		await physics_frame
	var f: Array = main.current_match.get_fighters()
	if ko:
		f[1]._do_ko("KO", dir, "head")
	else:
		f[1]._do_knockdown(dir)
	for i in int(args.get("n", "50")):
		await create_timer(0.15, true, false, true).timeout
		if paused:
			main.resume()   # losing window focus pauses the fight; keep capturing
		root.get_viewport().get_texture().get_image().save_png("res://_build/shots/%s_%02d.png" % [tag, i])
	print("P2 y at end: ", f[1].global_position.y, " state ", f[1].state)
	quit(0)
