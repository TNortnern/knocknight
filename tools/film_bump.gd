extends SceneTree
## Windowed: films a point-blank whiff + bump, then the inside exchange. <godot> --path . --script res://tools/film_bump.gd -- tag=bump every=0.05 secs=4
func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := {}
	for a in OS.get_cmdline_user_args():
		var kv := a.split("=")
		if kv.size() == 2: args[kv[0]] = kv[1]
	var tag: String = args.get("tag", "bump")
	var every := float(args.get("every", "0.05"))
	var n := int(float(args.get("secs", "4")) / every)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://_build/film"))
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	main.start_match({"intro_delay": 0.0, "mode": "exhibition", "rounds": 1, "round_seconds": 600.0, "rules": "boxing",
		"p1_model": args.get("p1", "meshy_oak"), "p2_model": args.get("p2", "meshy_viper"), "arena": "ring", "p1_controller": "dummy", "p2_controller": "dummy"})
	await process_frame
	var f: Array = main.current_match.get_fighters()
	var a = f[0]
	var b = f[1]
	for x in f:
		x.external_input = FighterInput.new()
	await create_timer(1.5).timeout
	a.global_position = Vector3(-0.5, 0, 0)
	b.global_position = Vector3(0.45, 0, 0)
	await create_timer(0.6).timeout
	a.begin_attack("RHook")
	var t := 0.0
	for i in n:
		var inp := FighterInput.new()
		inp.move = Vector2(a.dir_to_foe().x, -a.dir_to_foe().z)
		a.external_input = inp
		if i == 6 and not a.atk.is_empty():
			a.atk["outcome"] = "missed"
		var bi := FighterInput.new()
		if t > 1.6:
			bi.block = true   # Viper frames
		b.external_input = bi
		await create_timer(every, true, false, true).timeout
		t += every
		root.get_viewport().get_texture().get_image().save_png("res://_build/film/%s_%03d.png" % [tag, i])
	quit(0)
