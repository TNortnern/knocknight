extends SceneTree
## Windowed: films a real CPU-vs-CPU fight from main.tscn. Saves a frame every `every` s for `secs` s into
## _build/film/<tag>_NNN.png. <godot> --path . --script res://tools/film_fight.gd -- secs=40 every=0.2 tag=a diff=hard rules=boxing
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var secs := float(args.get("secs", "40"))
	var every := float(args.get("every", "0.2"))
	var tag: String = args.get("tag", "a")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/film"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"mode": "exhibition", "p1_controller": "cpu", "p2_controller": "cpu",
		"p1_model": args.get("p1", "viper"), "p2_model": args.get("p2", "anvil"), "rules": args.get("rules", "boxing"), "rounds": 3,
		"round_seconds": 180.0, "cpu_difficulty": args.get("diff", "hard"), "arena": "ring"})
	var hit_log: Array = []
	var clock := [0.0]
	if args.get("debug", "0") == "1":   # F3 overlay: hit / hurt / guard volumes + contact flashes
		main.current_match.toggle_debug_boxes()
	main.current_match.hit_landed.connect(func(i, info):
		hit_log.append("%.2f p%d %s %s blocked=%s glance=%s depth=%.3f" % [clock[0], i + 1, info.get("strike", ""), info.get("zone", ""), str(info.get("blocked", false)), str(info.get("glance", false)), float(info.get("depth", 0.0))]))
	var n := int(secs / every)
	for i in n:
		clock[0] = i * every
		await create_timer(every, true, false, true).timeout
		if get_root().get_tree().paused:
			main.resume()
		root.get_viewport().get_texture().get_image().save_png("res://_build/film/%s_%03d.png" % [tag, i])
	var fa := FileAccess.open(ProjectSettings.globalize_path("res://_build/film/%s_hits.txt" % tag), FileAccess.WRITE)
	fa.store_string(String.chr(10).join(hit_log))
	fa.close()
	quit(0)
